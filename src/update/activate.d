module update.activate;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : canFind;
import std.file : exists, mkdirRecurse, readText, remove, rename, write, isSymlink, FileException;
version (Posix) {
    import std.file : readLink, symlink;
}
import std.path : baseName;
import std.process : Config, execute;
import std.string : strip;
import update.stage;
import update.verify;
import platform.command : runLocalCommand, CommandResult;
import platform.durable : syncUpdatePath;
import std.path : dirName;

alias ServiceRestartFn = bool delegate(string action); // "restart"
alias HealthCheckFn = bool delegate(string expectedVersion);

struct ActivationOutcome {
    bool ok = false;
    bool rolledBack = false;
    string activeVersion;
    string previousVersion;
    string message;
}

void atomicSetSymlink(string target, string linkPath) {
    version (Posix) {
        auto tmpLink = linkPath ~ ".tmp";
        bool danglingLink;
        try { danglingLink = isSymlink(tmpLink); } catch (FileException) {}
        if (exists(tmpLink) || danglingLink) remove(tmpLink);
        symlink(target, tmpLink);
        rename(tmpLink, linkPath);
        syncUpdatePath(dirName(linkPath), true);
    } else version (Windows) {
        // Services launch versions\current\hikari.exe through a directory junction. The
        // running .exe lives in its own version directory and is never overwritten.
        // Build the new junction aside, then swap with two renames so `current` is
        // missing for at most an instant and the old pointer is restored on failure.
        import std.file : rmdir;
        auto tmpLink = linkPath ~ ".new";
        auto oldLink = linkPath ~ ".old";
        if (exists(tmpLink)) rmdir(tmpLink); // RemoveDirectoryW removes only the junction
        createJunction(target, tmpLink);
        if (exists(linkPath)) {
            if (exists(oldLink)) rmdir(oldLink);
            rename(linkPath, oldLink);
            try {
                rename(tmpLink, linkPath);
            } catch (Exception e) {
                rename(oldLink, linkPath);
                throw e;
            }
            try { rmdir(oldLink); } catch (Exception) {}
        } else {
            rename(tmpLink, linkPath);
        }
        // Text pointer is the source of truth for readVersionSymlink(); write it last.
        auto txtPath = linkPath ~ ".txt";
        auto tmpTxt = txtPath ~ ".tmp";
        write(tmpTxt, baseName(target) ~ "\n");
        rename(tmpTxt, txtPath);
    }
}

version (Windows) {
    private void createJunction(string target, string linkPath) {
        import std.path : absolutePath, buildNormalizedPath;
        import std.string : replace;
        auto t = buildNormalizedPath(absolutePath(target)).replace("/", "\\");
        auto l = buildNormalizedPath(absolutePath(linkPath)).replace("/", "\\");
        auto r = execute(["cmd", "/c", "mklink", "/J", l, t], null, Config.none, 4096);
        if (r.status != 0 || !exists(l)) {
            throw new Exception("Unable to create version junction " ~ l ~ ": " ~ r.output.strip());
        }
    }

    private enum ServiceResult { ok, missing, failed }

    /// Restarts one hikari-owned service through the Service Control Manager API and
    /// waits for real state transitions (sc.exe stop/start return before they finish).
    private ServiceResult restartWindowsService(string name, uint timeoutMs = 30_000) {
        import core.sys.windows.winsvc;
        import core.sys.windows.winbase : GetLastError;
        import std.utf : toUTF16z;

        enum uint ERROR_SERVICE_DOES_NOT_EXIST = 1060;
        auto scm = OpenSCManagerW(null, null, SC_MANAGER_CONNECT);
        if (scm is null) return ServiceResult.failed;
        scope (exit) CloseServiceHandle(scm);
        auto svc = OpenServiceW(scm, name.toUTF16z(), SERVICE_START | SERVICE_STOP | SERVICE_QUERY_STATUS);
        if (svc is null) {
            return GetLastError() == ERROR_SERVICE_DOES_NOT_EXIST ? ServiceResult.missing : ServiceResult.failed;
        }
        scope (exit) CloseServiceHandle(svc);

        bool waitFor(uint wanted) {
            SERVICE_STATUS st;
            for (uint waited = 0; waited <= timeoutMs; waited += 250) {
                if (!QueryServiceStatus(svc, &st)) return false;
                if (st.dwCurrentState == wanted) return true;
                if (wanted == SERVICE_RUNNING && st.dwCurrentState == SERVICE_STOPPED && waited > 2000) return false;
                Thread.sleep(msecs(250));
            }
            return false;
        }

        SERVICE_STATUS st;
        if (QueryServiceStatus(svc, &st) && st.dwCurrentState != SERVICE_STOPPED) {
            ControlService(svc, SERVICE_CONTROL_STOP, &st);
            if (!waitFor(SERVICE_STOPPED)) return ServiceResult.failed;
        }
        if (!StartServiceW(svc, 0, null)) return ServiceResult.failed;
        return waitFor(SERVICE_RUNNING) ? ServiceResult.ok : ServiceResult.failed;
    }
}

string readVersionSymlink(string linkPath) {
    version (Posix) {
        if (!exists(linkPath)) return "";
        try {
            return baseName(readLink(linkPath));
        } catch (Exception) {
            return "";
        }
    } else version (Windows) {
        auto txtPath = linkPath ~ ".txt";
        if (exists(txtPath)) {
            try { return readText(txtPath).strip(); } catch (Exception) {}
        }
        return "";
    }
}

alias LaunchctlFn = CommandResult delegate(const string[] args, uint timeoutMs, size_t limit);

bool restartLaunchdJob(string target, LaunchctlFn command = null) {
    import std.functional : toDelegate;
    import std.string : splitLines, startsWith;
    import core.time : MonoTime;
    if (target != "system/io.hikari.agent" && target != "system/io.hikari.caddy") return false;
    if (command is null) command = toDelegate(&runLocalCommand);
    string pid(string output) {
        foreach (line; output.splitLines) {
            auto text = line.strip;
            if (text.startsWith("pid = ")) return text[6 .. $].strip;
        }
        return "";
    }
    auto before = command(["/bin/launchctl", "print", target], 3000, 16384);
    if (before.status != 0 || before.outputTruncated) return false;
    auto oldPid = pid(before.output);
    if (oldPid.length) {
        // SuccessfulExit=false jobs do not restart after hikari's graceful exit.
        // Wait for that process to drain before a non-killing kickstart. For
        // KeepAlive=true jobs an automatic replacement may already be running.
        if (command(["/bin/launchctl", "kill", "SIGTERM", target], 3000, 4096).status != 0) return false;
        auto deadline = MonoTime.currTime + msecs(30000);
        while (true) {
            auto state = command(["/bin/launchctl", "print", target], 3000, 16384);
            if (state.status != 0 || state.outputTruncated) return false;
            if (pid(state.output) != oldPid) break;
            if (MonoTime.currTime >= deadline) return false;
            Thread.sleep(msecs(250));
        }
    }
    return command(["/bin/launchctl", "kickstart", target], 10000, 4096).status == 0;
}

bool defaultRestartHikariServices(string action) {
    version (linux) {
        auto r1 = execute(["systemctl", action, "hikari.service"], null, Config.none, 4096);
        if (r1.status != 0) return false;
        auto r2chk = execute(["systemctl", "list-unit-files", "hikari-caddy.service"], null, Config.none, 4096);
        if (r2chk.status == 0 && r2chk.output.canFind("hikari-caddy.service")) {
            auto r2 = execute(["systemctl", action, "hikari-caddy.service"], null, Config.none, 4096);
            if (r2.status != 0) return false;
        }
        return true;
    } else version (OSX) {
        if (!restartLaunchdJob("system/io.hikari.agent")) return false;
        if (exists("/Library/LaunchDaemons/io.hikari.caddy.plist") &&
            !restartLaunchdJob("system/io.hikari.caddy")) return false;
        return true;
    } else version (Windows) {
        if (restartWindowsService("hikari") != ServiceResult.ok) return false;
        // hikari-caddy is optional (snippet-only installs have none).
        return restartWindowsService("hikari-caddy") != ServiceResult.failed;
    } else {
        return false;
    }
}

HealthCheckFn makeLoopbackHealthChecker(string loopbackBind, ushort loopbackPort, uint attempts = 10, uint sleepMs = 200) {
    import std.conv : to;
    string host = loopbackBind == "::1" ? "[::1]" : "127.0.0.1";
    string url = "http://" ~ host ~ ":" ~ to!string(loopbackPort) ~ "/healthz";
    string infoUrl = "http://" ~ host ~ ":" ~ to!string(loopbackPort) ~ "/api/v1/info";
    return (string expectedVersion) {
        foreach (_; 0 .. attempts) {
            auto r1 = execute(["curl", "-fsS", "--max-time", "2", url], null, Config.none, 4096);
            auto r2 = execute(["curl", "-fsS", "--max-time", "2", infoUrl], null, Config.none, 8192);
            if (r1.status == 0 && r2.status == 0 && r2.output.canFind(`"agent_version":"` ~ expectedVersion ~ `"`)) {
                return true;
            }
            Thread.sleep(msecs(sleepMs));
        }
        return false;
    };
}

private string versionBinaryPath(string dir) pure nothrow @safe {
    version (Windows) {
        return dir ~ "/hikari.exe";
    } else {
        return dir ~ "/hikari";
    }
}

ActivationOutcome activateAndVerifyRelease(
    string versionsDir,
    string stateDir,
    string targetVersion,
    ServiceRestartFn serviceHook = null,
    HealthCheckFn healthHook = null,
    UpdateLock transaction = null
) {
    ActivationOutcome outc;
    validateReleaseDirectoryName(targetVersion);
    auto targetDir = versionsDir ~ "/" ~ targetVersion;
    if (!exists(versionBinaryPath(targetDir))) {
        outc.message = "Target version directory is incomplete: " ~ targetDir;
        return outc;
    }

    auto lock = transaction is null ? new UpdateLock(versionsDir) : transaction;
    if (!lock.isHeld() || lock.lockPath != versionsDir ~ "/update.lock")
        throw new Exception("Activation requires the matching held update lock");
    scope (exit) if (transaction is null) lock.release();

    auto pendingPath = versionsDir ~ "/.activation-previous";
    if (exists(pendingPath)) {
        outc.message = "An interrupted activation requires `hikari update recover` first";
        return outc;
    }

    auto currentLink = versionsDir ~ "/current";
    auto prevLink = versionsDir ~ "/previous";

    string oldVersion = readVersionSymlink(currentLink);
    outc.previousVersion = oldVersion;

    if (oldVersion.length > 0 && oldVersion != targetVersion && exists(versionsDir ~ "/" ~ oldVersion)) {
        atomicSetSymlink(versionsDir ~ "/" ~ oldVersion, prevLink);
    }

    if (oldVersion.length > 0 && oldVersion != targetVersion) {
        write(pendingPath ~ ".tmp", oldVersion ~ "\n");
        syncUpdatePath(pendingPath ~ ".tmp");
        rename(pendingPath ~ ".tmp", pendingPath);
        syncUpdatePath(versionsDir, true);
    }
    atomicSetSymlink(targetDir, currentLink);

    import std.functional : toDelegate;
    auto restartFn = serviceHook !is null ? serviceHook : toDelegate(&defaultRestartHikariServices);
    bool restarted = restartFn("restart");
    bool healthy = restarted && (healthHook is null || healthHook(targetVersion));

    if (healthy) {
        if (exists(pendingPath)) { remove(pendingPath); syncUpdatePath(versionsDir, true); }
        outc.ok = true;
        outc.activeVersion = targetVersion;
        outc.message = "Activated version " ~ targetVersion;
        return outc;
    }

    // Automatic rollback to previous known-good release
    if (oldVersion.length > 0 && exists(versionsDir ~ "/" ~ oldVersion)) {
        atomicSetSymlink(versionsDir ~ "/" ~ oldVersion, currentLink);
        bool recovered = restartFn("restart") && (healthHook is null || healthHook(oldVersion));
        if (recovered && exists(pendingPath)) { remove(pendingPath); syncUpdatePath(versionsDir, true); }
        outc.rolledBack = true;
        outc.activeVersion = oldVersion;
        outc.message = "Health check or service restart failed for " ~ targetVersion ~ "; automatically rolled back to " ~ oldVersion;
    } else {
        outc.message = "Activation failed for " ~ targetVersion ~ " and no previous release available";
    }
    return outc;
}

ActivationOutcome recoverInterruptedActivation(
    string versionsDir, string stateDir,
    ServiceRestartFn serviceHook = null, HealthCheckFn healthHook = null
) {
    ActivationOutcome outc;
    auto lock = new UpdateLock(versionsDir);
    scope (exit) lock.release();
    auto pendingPath = versionsDir ~ "/.activation-previous";
    if (!exists(pendingPath)) {
        outc.ok = true;
        outc.message = "No interrupted activation";
        return outc;
    }
    auto previous = readText(pendingPath).strip();
    validateReleaseDirectoryName(previous);
    if (!exists(versionBinaryPath(versionsDir ~ "/" ~ previous))) {
        outc.message = "Interrupted activation has no usable prior release";
        return outc;
    }
    atomicSetSymlink(versionsDir ~ "/" ~ previous, versionsDir ~ "/current");
    import std.functional : toDelegate;
    auto restartFn = serviceHook !is null ? serviceHook : toDelegate(&defaultRestartHikariServices);
    outc.ok = restartFn("restart") && (healthHook is null || healthHook(previous));
    outc.rolledBack = true;
    outc.activeVersion = previous;
    if (outc.ok) { remove(pendingPath); syncUpdatePath(versionsDir, true); }
    outc.message = outc.ok ? "Recovered interrupted activation to " ~ previous
        : "Prior release restored; service recovery still requires attention";
    return outc;
}

ActivationOutcome rollbackToPrevious(
    string versionsDir,
    string stateDir,
    ServiceRestartFn serviceHook = null,
    HealthCheckFn healthHook = null
) {
    ActivationOutcome outc;
    auto prevVer = readVersionSymlink(versionsDir ~ "/previous");
    if (prevVer.length == 0 || !exists(versionBinaryPath(versionsDir ~ "/" ~ prevVer))) {
        outc.message = "No valid previous version available for rollback";
        return outc;
    }
    // Rollback is itself a transaction: a broken previous version must not strand
    // the operator on an unhealthy release or lose interrupted-operation recovery.
    outc = activateAndVerifyRelease(versionsDir, stateDir, prevVer, serviceHook, healthHook);
    if (outc.ok) {
        outc.rolledBack = true;
        outc.message = "Rolled back to " ~ prevVer;
    }
    return outc;
}
