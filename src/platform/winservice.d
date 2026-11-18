module platform.winservice;

// Native Windows Service Control Manager integration: lets hikari.exe run as a real
// service (no wrapper binary) and register/update/remove its own services and the
// isolated Caddy service with typed Win32 APIs.
//
// The command-line and ownership helpers are pure and compile on every platform so
// they are unit-tested on all CI runners.

import std.algorithm : canFind;
import std.path : baseName;
import std.string : replace, toLower;

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// Quotes one argument following the CommandLineToArgvW / MSVC CRT rules.
string quoteWindowsArg(string a) pure @safe {
    if (a.length > 0 && !a.canFind(' ') && !a.canFind('\t') && !a.canFind('"')) return a;
    string r = "\"";
    size_t backslashes = 0;
    foreach (ch; a) {
        if (ch == '\\') {
            backslashes++;
        } else if (ch == '"') {
            foreach (_; 0 .. backslashes * 2 + 1) r ~= '\\';
            r ~= '"';
            backslashes = 0;
        } else {
            foreach (_; 0 .. backslashes) r ~= '\\';
            backslashes = 0;
            r ~= ch;
        }
    }
    foreach (_; 0 .. backslashes * 2) r ~= '\\';
    r ~= '"';
    return r;
}

string buildServiceCommandLine(string exe, const string[] args) pure @safe {
    // The executable is always quoted: an unquoted path with spaces is the classic
    // "unquoted service path" privilege-escalation bug.
    string r = "\"" ~ exe ~ "\"";
    foreach (a; args) r ~= " " ~ quoteWindowsArg(a);
    return r;
}

/// Splits a command line using CommandLineToArgvW rules (argv[0] taken verbatim).
string[] parseWindowsCommandLine(string cmd) pure @safe {
    string[] argv;
    size_t i = 0;
    while (i < cmd.length && (cmd[i] == ' ' || cmd[i] == '\t')) i++;
    if (i >= cmd.length) return argv;

    // argv[0]: quotes delimit, no backslash processing.
    string first;
    if (cmd[i] == '"') {
        i++;
        while (i < cmd.length && cmd[i] != '"') first ~= cmd[i++];
        if (i < cmd.length) i++;
    } else {
        while (i < cmd.length && cmd[i] != ' ' && cmd[i] != '\t') first ~= cmd[i++];
    }
    argv ~= first;

    while (true) {
        while (i < cmd.length && (cmd[i] == ' ' || cmd[i] == '\t')) i++;
        if (i >= cmd.length) break;
        string cur;
        bool inQuotes = false;
        while (i < cmd.length) {
            char ch = cmd[i];
            if (ch == '\\') {
                size_t n = 0;
                while (i < cmd.length && cmd[i] == '\\') { n++; i++; }
                if (i < cmd.length && cmd[i] == '"') {
                    foreach (_; 0 .. n / 2) cur ~= '\\';
                    if (n % 2 == 1) { cur ~= '"'; i++; }
                } else {
                    foreach (_; 0 .. n) cur ~= '\\';
                }
                continue;
            }
            if (ch == '"') {
                if (inQuotes && i + 1 < cmd.length && cmd[i + 1] == '"') { cur ~= '"'; i += 2; continue; }
                inQuotes = !inQuotes;
                i++;
                continue;
            }
            if (!inQuotes && (ch == ' ' || ch == '\t')) break;
            cur ~= ch;
            i++;
        }
        argv ~= cur;
    }
    return argv;
}

/// Case-insensitive Windows path comparison key.
string normalizeWinPath(string p) pure @safe {
    auto s = p.replace("/", "\\").toLower();
    while (s.length > 3 && s[$ - 1] == '\\') s = s[0 .. $ - 1];
    return s;
}

private string flagValue(const string[] argv, string flag) pure @safe {
    foreach (i, a; argv) {
        if (a == flag && i + 1 < argv.length) return argv[i + 1];
    }
    return "";
}

enum HikariServiceKind { agent, caddy }

/// A service is hikari-owned only if its command line is exactly the shape hikari
/// registers AND it points at the same config file this installation manages. A
/// foreign service that merely shares the name is never modified or deleted.
bool isHikariOwnedImagePath(string imagePath, HikariServiceKind kind, string managedConfigPath) pure @safe {
    auto argv = parseWindowsCommandLine(imagePath);
    if (argv.length < 2 || managedConfigPath.length == 0) return false;
    auto cfg = flagValue(argv, "--config");
    if (cfg.length == 0 || normalizeWinPath(cfg) != normalizeWinPath(managedConfigPath)) return false;
    auto exe = baseName(argv[0].replace("\\", "/")).toLower();
    final switch (kind) {
        case HikariServiceKind.agent:
            return exe == "hikari.exe" && argv[1] == "serve" && argv.canFind("--service");
        case HikariServiceKind.caddy:
            return exe.length > 4 && exe[$ - 4 .. $] == ".exe" && argv[1] == "run" && flagValue(argv, "--adapter") == "caddyfile";
    }
}

struct FailurePolicy {
    uint resetPeriodSec;
    uint[] restartDelaysMs;
}

/// Restart with backoff; the failure counter resets after an hour without failures.
FailurePolicy defaultFailurePolicy() pure nothrow @safe {
    return FailurePolicy(3600, [5_000u, 30_000u, 120_000u]);
}

string serviceAccountName(string serviceName, string account) pure @safe {
    switch (account.toLower()) {
        case "virtual": return "NT SERVICE\\" ~ serviceName;
        case "localsystem": return "LocalSystem";
        case "localservice": return "NT AUTHORITY\\LocalService";
        default: throw new Exception("Unknown service account kind: " ~ account ~ " (use virtual|localsystem|localservice)");
    }
}

// ---------------------------------------------------------------------------
// Windows implementation
// ---------------------------------------------------------------------------

version (Windows) {
    pragma(lib, "advapi32");

    import core.atomic : atomicOp;
    import core.log : Logger;
    import core.sys.windows.windef : BOOL, DWORD, FALSE, TRUE;
    import core.thread : Thread, thread_attachThis, thread_detachThis;
    import core.time : msecs;
    import std.conv : to;
    import std.format : format;
    import std.stdio : stderr, writeln, writefln;
    import std.utf : toUTF16z, toUTF8;

    private alias SC_HANDLE = void*;
    private alias SERVICE_STATUS_HANDLE = void*;

    private struct H_SERVICE_STATUS {
        DWORD dwServiceType;
        DWORD dwCurrentState;
        DWORD dwControlsAccepted;
        DWORD dwWin32ExitCode;
        DWORD dwServiceSpecificExitCode;
        DWORD dwCheckPoint;
        DWORD dwWaitHint;
    }

    private struct H_SERVICE_TABLE_ENTRYW {
        const(wchar)* lpServiceName;
        extern (Windows) void function(DWORD, wchar**) lpServiceProc;
    }

    private struct H_QUERY_SERVICE_CONFIGW {
        DWORD dwServiceType;
        DWORD dwStartType;
        DWORD dwErrorControl;
        wchar* lpBinaryPathName;
        wchar* lpLoadOrderGroup;
        DWORD dwTagId;
        wchar* lpDependencies;
        wchar* lpServiceStartName;
        wchar* lpDisplayName;
    }

    private struct H_SC_ACTION { int Type; DWORD Delay; }
    private struct H_SERVICE_FAILURE_ACTIONSW {
        DWORD dwResetPeriod;
        wchar* lpRebootMsg;
        wchar* lpCommand;
        DWORD cActions;
        H_SC_ACTION* lpsaActions;
    }
    private struct H_SERVICE_DESCRIPTIONW { wchar* lpDescription; }
    private struct H_SERVICE_BOOL_INFO { BOOL value; }
    private struct H_SERVICE_SID_INFO { DWORD dwServiceSidType; }
    private struct H_SERVICE_REQUIRED_PRIVILEGES_INFOW { wchar* pmszRequiredPrivileges; }

    private alias HandlerExFn = extern (Windows) DWORD function(DWORD, DWORD, void*, void*) nothrow @nogc;

    private extern (Windows) nothrow @nogc {
        BOOL StartServiceCtrlDispatcherW(const(H_SERVICE_TABLE_ENTRYW)* lpServiceStartTable);
        SERVICE_STATUS_HANDLE RegisterServiceCtrlHandlerExW(const(wchar)* lpServiceName, HandlerExFn lpHandlerProc, void* lpContext);
        BOOL SetServiceStatus(SERVICE_STATUS_HANDLE hServiceStatus, H_SERVICE_STATUS* lpServiceStatus);
        SC_HANDLE OpenSCManagerW(const(wchar)* lpMachineName, const(wchar)* lpDatabaseName, DWORD dwDesiredAccess);
        SC_HANDLE OpenServiceW(SC_HANDLE hSCManager, const(wchar)* lpServiceName, DWORD dwDesiredAccess);
        SC_HANDLE CreateServiceW(SC_HANDLE hSCManager, const(wchar)* lpServiceName, const(wchar)* lpDisplayName,
            DWORD dwDesiredAccess, DWORD dwServiceType, DWORD dwStartType, DWORD dwErrorControl,
            const(wchar)* lpBinaryPathName, const(wchar)* lpLoadOrderGroup, DWORD* lpdwTagId,
            const(wchar)* lpDependencies, const(wchar)* lpServiceStartName, const(wchar)* lpPassword);
        BOOL ChangeServiceConfigW(SC_HANDLE hService, DWORD dwServiceType, DWORD dwStartType, DWORD dwErrorControl,
            const(wchar)* lpBinaryPathName, const(wchar)* lpLoadOrderGroup, DWORD* lpdwTagId,
            const(wchar)* lpDependencies, const(wchar)* lpServiceStartName, const(wchar)* lpPassword,
            const(wchar)* lpDisplayName);
        BOOL ChangeServiceConfig2W(SC_HANDLE hService, DWORD dwInfoLevel, void* lpInfo);
        BOOL QueryServiceConfigW(SC_HANDLE hService, void* lpServiceConfig, DWORD cbBufSize, DWORD* pcbBytesNeeded);
        BOOL QueryServiceStatus(SC_HANDLE hService, H_SERVICE_STATUS* lpServiceStatus);
        BOOL ControlService(SC_HANDLE hService, DWORD dwControl, H_SERVICE_STATUS* lpServiceStatus);
        BOOL StartServiceW(SC_HANDLE hService, DWORD dwNumServiceArgs, const(wchar)** lpServiceArgVectors);
        BOOL DeleteService(SC_HANDLE hService);
        BOOL CloseServiceHandle(SC_HANDLE hSCObject);
        DWORD GetLastError();
    }

    private enum : DWORD {
        SERVICE_WIN32_OWN_PROCESS = 0x10,
        SERVICE_AUTO_START = 2,
        SERVICE_ERROR_NORMAL = 1,
        SERVICE_NO_CHANGE = 0xFFFFFFFF,

        SERVICE_STOPPED = 1,
        SERVICE_START_PENDING = 2,
        SERVICE_STOP_PENDING = 3,
        SERVICE_RUNNING = 4,

        SERVICE_ACCEPT_STOP = 0x1,
        SERVICE_ACCEPT_SHUTDOWN = 0x4,
        SERVICE_ACCEPT_POWEREVENT = 0x40,
        SERVICE_ACCEPT_PRESHUTDOWN = 0x100,

        SERVICE_CONTROL_STOP = 1,
        SERVICE_CONTROL_INTERROGATE = 4,
        SERVICE_CONTROL_SHUTDOWN = 5,
        SERVICE_CONTROL_POWEREVENT = 0x0D,
        SERVICE_CONTROL_PRESHUTDOWN = 0x0F,

        PBT_APMRESUMESUSPEND = 0x7,
        PBT_APMRESUMEAUTOMATIC = 0x12,

        SC_MANAGER_CONNECT = 0x0001,
        SC_MANAGER_CREATE_SERVICE = 0x0002,
        SERVICE_QUERY_CONFIG = 0x0001,
        SERVICE_CHANGE_CONFIG = 0x0002,
        SERVICE_QUERY_STATUS = 0x0004,
        SERVICE_START = 0x0010,
        SERVICE_STOP = 0x0020,
        DELETE_ACCESS = 0x00010000,

        SERVICE_CONFIG_DESCRIPTION = 1,
        SERVICE_CONFIG_FAILURE_ACTIONS = 2,
        SERVICE_CONFIG_DELAYED_AUTO_START_INFO = 3,
        SERVICE_CONFIG_FAILURE_ACTIONS_FLAG = 4,
        SERVICE_CONFIG_SERVICE_SID_INFO = 5,
        SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO = 6,
        SERVICE_SID_TYPE_UNRESTRICTED = 1,
        SC_ACTION_RESTART = 1,

        NO_ERROR = 0,
        ERROR_CALL_NOT_IMPLEMENTED = 120,
        ERROR_SERVICE_SPECIFIC_ERROR = 1066,
        ERROR_SERVICE_DOES_NOT_EXIST = 1060,
        ERROR_FAILED_SERVICE_CONTROLLER_CONNECT = 1063,
        ERROR_SERVICE_MARKED_FOR_DELETE = 1072,
    }

    // ---------------- Service runtime ----------------

    /// Hooks the service host calls. Function pointers (not delegates) so the control
    /// handler can invoke them without touching the GC.
    struct ServiceHooks {
        /// Runs the service; must call `reportRunning` once ready and return the exit code.
        int delegate(void delegate() reportRunning) body_;
        void function() nothrow @nogc requestStop;
        void function() nothrow @nogc onResume;
        Logger log;
    }

    private __gshared ServiceHooks gHooks;
    private __gshared wstring gServiceName;
    private __gshared SERVICE_STATUS_HANDLE gStatusHandle;
    private __gshared H_SERVICE_STATUS gStatus;
    private __gshared int gExitCode;
    private shared uint gCheckPoint;

    private void setState(DWORD state, DWORD waitHint = 0) nothrow @nogc {
        gStatus.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        gStatus.dwCurrentState = state;
        gStatus.dwWaitHint = waitHint;
        gStatus.dwControlsAccepted = (state == SERVICE_START_PENDING || state == SERVICE_STOPPED)
            ? 0
            : (SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN | SERVICE_ACCEPT_PRESHUTDOWN | SERVICE_ACCEPT_POWEREVENT);
        gStatus.dwCheckPoint = (state == SERVICE_RUNNING || state == SERVICE_STOPPED) ? 0 : atomicOp!"+="(gCheckPoint, 1);
        if (gStatusHandle !is null) SetServiceStatus(gStatusHandle, &gStatus);
    }

    private extern (Windows) DWORD serviceControlHandler(DWORD control, DWORD eventType, void* eventData, void* ctx) nothrow @nogc {
        switch (control) {
            case SERVICE_CONTROL_STOP:
            case SERVICE_CONTROL_SHUTDOWN:
            case SERVICE_CONTROL_PRESHUTDOWN:
                setState(SERVICE_STOP_PENDING, 15_000);
                if (gHooks.requestStop !is null) gHooks.requestStop();
                return NO_ERROR;
            case SERVICE_CONTROL_INTERROGATE:
                return NO_ERROR;
            case SERVICE_CONTROL_POWEREVENT:
                if ((eventType == PBT_APMRESUMEAUTOMATIC || eventType == PBT_APMRESUMESUSPEND) && gHooks.onResume !is null) {
                    gHooks.onResume();
                }
                return NO_ERROR;
            default:
                return ERROR_CALL_NOT_IMPLEMENTED;
        }
    }

    private extern (Windows) void serviceMain(DWORD argc, wchar** argv) {
        // SCM calls this on a thread it created; register it with the D runtime first.
        thread_attachThis();
        scope (exit) thread_detachThis();

        gStatusHandle = RegisterServiceCtrlHandlerExW((gServiceName ~ "\0"w).ptr, &serviceControlHandler, null);
        if (gStatusHandle is null) {
            gExitCode = 1;
            return;
        }
        setState(SERVICE_START_PENDING, 30_000);

        int rc = 1;
        try {
            rc = gHooks.body_(() { setState(SERVICE_RUNNING); });
        } catch (Throwable t) {
            if (gHooks.log !is null) {
                try { gHooks.log.error("service terminated by unhandled error: " ~ t.msg); } catch (Throwable) {}
            }
            rc = 1;
        }
        gExitCode = rc;
        if (rc != 0) {
            // A non-zero exit triggers the configured recovery (FAILURE_ACTIONS_FLAG).
            gStatus.dwWin32ExitCode = ERROR_SERVICE_SPECIFIC_ERROR;
            gStatus.dwServiceSpecificExitCode = cast(DWORD) rc;
        } else {
            gStatus.dwWin32ExitCode = NO_ERROR;
            gStatus.dwServiceSpecificExitCode = 0;
        }
        setState(SERVICE_STOPPED);
    }

    /// Connects to the SCM and runs `hooks.body_` as service `name`. Returns 2 if the
    /// process was not started by the Service Control Manager.
    int runAsService(string name, ServiceHooks hooks) {
        gHooks = hooks;
        gServiceName = to!wstring(name);
        auto nameZ = (gServiceName ~ "\0"w).ptr;
        H_SERVICE_TABLE_ENTRYW[2] table;
        table[0] = H_SERVICE_TABLE_ENTRYW(nameZ, &serviceMain);
        if (!StartServiceCtrlDispatcherW(table.ptr)) {
            if (GetLastError() == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) {
                stderr.writeln("hikari: `serve --service` is the Windows Service Control Manager entry point. ",
                    "Run `hikari serve` to start the agent in this terminal.");
                return 2;
            }
            stderr.writeln("hikari: StartServiceCtrlDispatcher failed (error ", GetLastError(), ")");
            return 1;
        }
        return gExitCode;
    }

    // ---------------- Service management ----------------

    struct ServiceSpec {
        string name;
        string displayName;
        string description;
        string commandLine;
        string account; // virtual | localsystem | localservice
        bool delayedStart;
        bool minimalPrivileges;
        HikariServiceKind kind;
        string managedConfigPath;
    }

    struct ServiceInfo {
        bool exists;
        string imagePath;
        string account;
        string state;
    }

    private string fromWz(const(wchar)* p) {
        if (p is null) return "";
        size_t n = 0;
        while (p[n] != 0) n++;
        return toUTF8(p[0 .. n]);
    }

    private SC_HANDLE openScm(DWORD access) {
        auto scm = OpenSCManagerW(null, null, access);
        if (scm is null) {
            throw new Exception(format!"Cannot open the Service Control Manager (error %u). Run from an elevated Administrator prompt."(GetLastError()));
        }
        return scm;
    }

    private string stateName(DWORD s) {
        switch (s) {
            case SERVICE_STOPPED: return "stopped";
            case SERVICE_START_PENDING: return "start_pending";
            case SERVICE_STOP_PENDING: return "stop_pending";
            case SERVICE_RUNNING: return "running";
            default: return format!"state_%u"(s);
        }
    }

    private bool queryConfig(SC_HANDLE svc, out string imagePath, out string account, out DWORD startType) {
        DWORD need = 0;
        QueryServiceConfigW(svc, null, 0, &need);
        if (need == 0 || need > 64 * 1024) return false;
        auto buf = new ubyte[need];
        if (!QueryServiceConfigW(svc, buf.ptr, need, &need)) return false;
        auto qc = cast(H_QUERY_SERVICE_CONFIGW*) buf.ptr;
        imagePath = fromWz(qc.lpBinaryPathName);
        account = fromWz(qc.lpServiceStartName);
        startType = qc.dwStartType;
        return true;
    }

    ServiceInfo queryService(string name) {
        ServiceInfo info;
        auto scm = openScm(SC_MANAGER_CONNECT);
        scope (exit) CloseServiceHandle(scm);
        auto svc = OpenServiceW(scm, name.toUTF16z(), SERVICE_QUERY_CONFIG | SERVICE_QUERY_STATUS);
        if (svc is null) return info;
        scope (exit) CloseServiceHandle(svc);
        info.exists = true;
        DWORD st;
        queryConfig(svc, info.imagePath, info.account, st);
        H_SERVICE_STATUS ss;
        if (QueryServiceStatus(svc, &ss)) info.state = stateName(ss.dwCurrentState);
        return info;
    }

    private bool waitForState(SC_HANDLE svc, DWORD wanted, uint timeoutMs) {
        H_SERVICE_STATUS ss;
        for (uint waited = 0; waited <= timeoutMs; waited += 250) {
            if (!QueryServiceStatus(svc, &ss)) return false;
            if (ss.dwCurrentState == wanted) return true;
            if (wanted == SERVICE_RUNNING && ss.dwCurrentState == SERVICE_STOPPED && waited >= 2000) return false;
            Thread.sleep(msecs(250));
        }
        return false;
    }

    private void applyExtendedConfig(SC_HANDLE svc, const ref ServiceSpec spec) {
        void must(BOOL ok, string what) {
            if (!ok) throw new Exception(format!"Failed to set %s on service %s (error %u)"(what, spec.name, GetLastError()));
        }

        auto desc = to!wstring(spec.description) ~ "\0"w;
        H_SERVICE_DESCRIPTIONW d = H_SERVICE_DESCRIPTIONW(cast(wchar*) desc.ptr);
        must(ChangeServiceConfig2W(svc, SERVICE_CONFIG_DESCRIPTION, &d), "description");

        auto policy = defaultFailurePolicy();
        H_SC_ACTION[] actions;
        foreach (ms; policy.restartDelaysMs) actions ~= H_SC_ACTION(SC_ACTION_RESTART, ms);
        H_SERVICE_FAILURE_ACTIONSW fa;
        fa.dwResetPeriod = policy.resetPeriodSec;
        fa.cActions = cast(DWORD) actions.length;
        fa.lpsaActions = actions.ptr;
        must(ChangeServiceConfig2W(svc, SERVICE_CONFIG_FAILURE_ACTIONS, &fa), "failure actions");

        // Also recover when the service stops itself with a non-zero exit code.
        H_SERVICE_BOOL_INFO flag = H_SERVICE_BOOL_INFO(TRUE);
        must(ChangeServiceConfig2W(svc, SERVICE_CONFIG_FAILURE_ACTIONS_FLAG, &flag), "failure actions flag");

        H_SERVICE_BOOL_INFO delayed = H_SERVICE_BOOL_INFO(spec.delayedStart ? TRUE : FALSE);
        must(ChangeServiceConfig2W(svc, SERVICE_CONFIG_DELAYED_AUTO_START_INFO, &delayed), "delayed auto-start");

        // Per-service SID (NT SERVICE\<name>) so ACLs can target this service alone.
        H_SERVICE_SID_INFO sid = H_SERVICE_SID_INFO(SERVICE_SID_TYPE_UNRESTRICTED);
        must(ChangeServiceConfig2W(svc, SERVICE_CONFIG_SERVICE_SID_INFO, &sid), "service SID type");

        if (spec.minimalPrivileges) {
            // Strip every privilege except traverse checking from the service token.
            auto privs = "SeChangeNotifyPrivilege\0\0"w;
            H_SERVICE_REQUIRED_PRIVILEGES_INFOW rp = H_SERVICE_REQUIRED_PRIVILEGES_INFOW(cast(wchar*) privs.ptr);
            must(ChangeServiceConfig2W(svc, SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO, &rp), "required privileges");
        }
    }

    /// Creates or reconciles a hikari-owned service. Returns "created", "updated" or
    /// "unchanged". Throws without changing anything if a foreign service has the name.
    string installOrUpdateService(const ref ServiceSpec spec) {
        auto scm = openScm(SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE);
        scope (exit) CloseServiceHandle(scm);

        auto accountName = serviceAccountName(spec.name, spec.account);
        // Virtual/built-in accounts take no password (NULL for virtual accounts).
        const(wchar)* password = spec.account.toLower() == "virtual" ? null : ""w.ptr;
        enum DWORD access = SERVICE_QUERY_CONFIG | SERVICE_CHANGE_CONFIG | SERVICE_QUERY_STATUS | SERVICE_START | SERVICE_STOP;

        auto svc = OpenServiceW(scm, spec.name.toUTF16z(), access);
        string result;
        if (svc is null) {
            auto err = GetLastError();
            if (err != ERROR_SERVICE_DOES_NOT_EXIST) {
                throw new Exception(format!"Cannot open service %s (error %u)"(spec.name, err));
            }
            svc = CreateServiceW(scm, spec.name.toUTF16z(), spec.displayName.toUTF16z(), access,
                SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
                spec.commandLine.toUTF16z(), null, null, null, accountName.toUTF16z(), password);
            if (svc is null) {
                auto cerr = GetLastError();
                if (cerr == ERROR_SERVICE_MARKED_FOR_DELETE) {
                    throw new Exception("Service " ~ spec.name ~ " is still marked for deletion; close services.msc/Event Viewer handles or reboot, then retry.");
                }
                throw new Exception(format!"CreateService %s failed (error %u)"(spec.name, cerr));
            }
            result = "created";
        } else {
            string curPath, curAccount;
            DWORD curStart;
            if (!queryConfig(svc, curPath, curAccount, curStart)) {
                CloseServiceHandle(svc);
                throw new Exception("Cannot read configuration of existing service " ~ spec.name);
            }
            if (!isHikariOwnedImagePath(curPath, spec.kind, spec.managedConfigPath)) {
                CloseServiceHandle(svc);
                throw new Exception("A service named '" ~ spec.name ~ "' already exists and is not managed by this hikari installation ("
                    ~ curPath ~ "). Refusing to modify it.");
            }
            bool same = curPath == spec.commandLine && curStart == SERVICE_AUTO_START
                && curAccount.toLower() == accountName.toLower();
            if (!same) {
                if (!ChangeServiceConfigW(svc, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
                        spec.commandLine.toUTF16z(), null, null, null, accountName.toUTF16z(), password, spec.displayName.toUTF16z())) {
                    auto e = GetLastError();
                    CloseServiceHandle(svc);
                    throw new Exception(format!"ChangeServiceConfig %s failed (error %u)"(spec.name, e));
                }
                result = "updated";
            } else {
                result = "unchanged";
            }
        }
        scope (exit) CloseServiceHandle(svc);
        applyExtendedConfig(svc, spec);
        return result;
    }

    /// Stops (waiting for STOPPED) and deletes a hikari-owned service. Missing is fine.
    string uninstallService(string name, HikariServiceKind kind, string managedConfigPath, bool force = false) {
        auto scm = openScm(SC_MANAGER_CONNECT);
        scope (exit) CloseServiceHandle(scm);
        auto svc = OpenServiceW(scm, name.toUTF16z(), SERVICE_QUERY_CONFIG | SERVICE_QUERY_STATUS | SERVICE_STOP | DELETE_ACCESS);
        if (svc is null) {
            if (GetLastError() == ERROR_SERVICE_DOES_NOT_EXIST) return "absent";
            throw new Exception(format!"Cannot open service %s (error %u)"(name, GetLastError()));
        }
        scope (exit) CloseServiceHandle(svc);
        string curPath, curAccount;
        DWORD curStart;
        queryConfig(svc, curPath, curAccount, curStart);
        if (!force && !isHikariOwnedImagePath(curPath, kind, managedConfigPath)) {
            throw new Exception("Service '" ~ name ~ "' is not managed by this hikari installation (" ~ curPath ~ "); leaving it untouched.");
        }
        H_SERVICE_STATUS ss;
        if (QueryServiceStatus(svc, &ss) && ss.dwCurrentState != SERVICE_STOPPED) {
            ControlService(svc, SERVICE_CONTROL_STOP, &ss);
            if (!waitForState(svc, SERVICE_STOPPED, 30_000)) {
                throw new Exception("Service " ~ name ~ " did not stop within 30 s; not deleting it.");
            }
        }
        if (!DeleteService(svc) && GetLastError() != ERROR_SERVICE_MARKED_FOR_DELETE) {
            throw new Exception(format!"DeleteService %s failed (error %u)"(name, GetLastError()));
        }
        return "removed";
    }

    private struct H_ENUM_SERVICE_STATUS_PROCESSW {
        wchar* lpServiceName;
        wchar* lpDisplayName;
        DWORD[9] status; // SERVICE_STATUS_PROCESS
    }

    private extern (Windows) nothrow @nogc BOOL EnumServicesStatusExW(SC_HANDLE hSCManager, int InfoLevel, DWORD dwServiceType,
        DWORD dwServiceState, ubyte* lpServices, DWORD cbBufSize, DWORD* pcbBytesNeeded, DWORD* lpServicesReturned,
        DWORD* lpResumeHandle, const(wchar)* pszGroupName);

    /// Names of all Win32 services (read-only enumeration).
    string[] listServiceNames() {
        enum DWORD SC_MANAGER_ENUMERATE_SERVICE = 0x0004, SERVICE_WIN32 = 0x30, SERVICE_STATE_ALL = 3, ERROR_MORE_DATA = 234;
        string[] names;
        auto scm = openScm(SC_MANAGER_CONNECT | SC_MANAGER_ENUMERATE_SERVICE);
        scope (exit) CloseServiceHandle(scm);
        DWORD resume = 0;
        auto buf = new ubyte[64 * 1024];
        while (true) {
            DWORD needed = 0, returned = 0;
            auto ok = EnumServicesStatusExW(scm, 0, SERVICE_WIN32, SERVICE_STATE_ALL, buf.ptr, cast(DWORD) buf.length,
                &needed, &returned, &resume, null);
            auto err = ok ? 0 : GetLastError();
            if (!ok && err != ERROR_MORE_DATA) break;
            auto entries = (cast(H_ENUM_SERVICE_STATUS_PROCESSW*) buf.ptr)[0 .. returned];
            foreach (ref e; entries) names ~= fromWz(e.lpServiceName);
            if (ok) break;
            if (needed > buf.length) buf = new ubyte[needed];
        }
        return names;
    }

    bool startService(string name, uint timeoutMs = 30_000) {
        auto scm = openScm(SC_MANAGER_CONNECT);
        scope (exit) CloseServiceHandle(scm);
        auto svc = OpenServiceW(scm, name.toUTF16z(), SERVICE_START | SERVICE_QUERY_STATUS);
        if (svc is null) return false;
        scope (exit) CloseServiceHandle(svc);
        H_SERVICE_STATUS ss;
        if (QueryServiceStatus(svc, &ss) && ss.dwCurrentState == SERVICE_RUNNING) return true;
        if (!StartServiceW(svc, 0, null)) return false;
        return waitForState(svc, SERVICE_RUNNING, timeoutMs);
    }

    bool stopService(string name, uint timeoutMs = 30_000) {
        auto scm = openScm(SC_MANAGER_CONNECT);
        scope (exit) CloseServiceHandle(scm);
        auto svc = OpenServiceW(scm, name.toUTF16z(), SERVICE_STOP | SERVICE_QUERY_STATUS);
        if (svc is null) return GetLastError() == ERROR_SERVICE_DOES_NOT_EXIST;
        scope (exit) CloseServiceHandle(svc);
        H_SERVICE_STATUS ss;
        if (QueryServiceStatus(svc, &ss) && ss.dwCurrentState == SERVICE_STOPPED) return true;
        ControlService(svc, SERVICE_CONTROL_STOP, &ss);
        return waitForState(svc, SERVICE_STOPPED, timeoutMs);
    }

    // ---------------- CLI: hikari service ... ----------------

    private string opt(string[] args, string flag, string fallback = "") {
        foreach (i, a; args) {
            if (a == flag && i + 1 < args.length) return args[i + 1];
            if (a.length > flag.length && a[0 .. flag.length + 1] == flag ~ "=") return a[flag.length + 1 .. $];
        }
        return fallback;
    }

    private void usage() {
        writeln("Usage:");
        writeln("  hikari service install   --name <svc> --kind agent --config <config.json> [--exe <hikari.exe>] [--account virtual|localsystem]");
        writeln("  hikari service install   --name <svc> --kind caddy --caddy <caddy.exe> --caddyfile <Caddyfile>");
        writeln("  hikari service uninstall --name <svc> --kind agent --config <config.json>");
        writeln("  hikari service uninstall --name <svc> --kind caddy --caddyfile <Caddyfile>");
        writeln("  hikari service status|start|stop --name <svc>");
    }

    int cmdService(string[] args) {
        import std.file : exists, thisExePath;
        import std.path : absolutePath, buildNormalizedPath;

        if (args.length == 0) { usage(); return 2; }
        auto sub = args[0];
        auto rest = args[1 .. $];
        auto name = opt(rest, "--name");
        if (name.length == 0) { usage(); return 2; }

        string abs(string p) { return p.length == 0 ? p : buildNormalizedPath(absolutePath(p)); }

        try {
            switch (sub) {
                case "install":
                case "uninstall": {
                    auto kindStr = opt(rest, "--kind", name.canFind("caddy") ? "caddy" : "agent");
                    auto kind = kindStr == "caddy" ? HikariServiceKind.caddy : HikariServiceKind.agent;
                    string managed = kind == HikariServiceKind.agent ? abs(opt(rest, "--config")) : abs(opt(rest, "--caddyfile"));
                    if (managed.length == 0) {
                        stderr.writeln("hikari service: ", kind == HikariServiceKind.agent ? "--config" : "--caddyfile", " is required");
                        return 2;
                    }
                    if (sub == "uninstall") {
                        writefln("%s: %s", name, uninstallService(name, kind, managed));
                        return 0;
                    }
                    if (!exists(managed)) {
                        stderr.writeln("hikari service: file not found: ", managed);
                        return 2;
                    }
                    ServiceSpec spec;
                    spec.name = name;
                    spec.kind = kind;
                    spec.managedConfigPath = managed;
                    if (kind == HikariServiceKind.agent) {
                        auto exe = abs(opt(rest, "--exe", thisExePath()));
                        spec.displayName = "hikari Telemetry Agent";
                        spec.description = "On-demand Tailscale fleet telemetry and hardware inventory agent (loopback only).";
                        spec.commandLine = buildServiceCommandLine(exe, ["serve", "--service", "--config", managed]);
                        spec.account = opt(rest, "--account", "virtual");
                        spec.minimalPrivileges = true;
                    } else {
                        auto caddy = abs(opt(rest, "--caddy"));
                        if (caddy.length == 0 || !exists(caddy)) {
                            stderr.writeln("hikari service: --caddy <caddy.exe> is required and must exist");
                            return 2;
                        }
                        spec.displayName = "hikari Isolated Tailscale Caddy";
                        spec.description = "Isolated HTTPS proxy for hikari, bound only to this machine's Tailscale address.";
                        spec.commandLine = buildServiceCommandLine(caddy, ["run", "--config", managed, "--adapter", "caddyfile"]);
                        // tailscaled hands out HTTPS certificates to privileged local callers.
                        spec.account = opt(rest, "--account", "localsystem");
                        spec.delayedStart = true;
                    }
                    writefln("%s: %s", name, installOrUpdateService(spec));
                    return 0;
                }
                case "status": {
                    auto info = queryService(name);
                    if (!info.exists) { writefln("%s: absent", name); return 3; }
                    writefln("%s: %s\n  account: %s\n  command: %s", name, info.state, info.account, info.imagePath);
                    return 0;
                }
                case "start":
                    if (startService(name)) { writefln("%s: running", name); return 0; }
                    stderr.writefln("%s: failed to reach RUNNING", name);
                    return 1;
                case "stop":
                    if (stopService(name)) { writefln("%s: stopped", name); return 0; }
                    stderr.writefln("%s: failed to reach STOPPED", name);
                    return 1;
                default:
                    usage();
                    return 2;
            }
        } catch (Exception e) {
            stderr.writeln("hikari service: ", e.msg);
            return 1;
        }
    }
}
