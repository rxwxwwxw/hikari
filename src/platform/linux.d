module platform.linux;

import core.limits;
import core.model;
import core.serializer : sanitizeOsString;
import core.sync.mutex : Mutex;
import core.tracker : FixedString;
import hardware.inventory;
import hardware.isa_names;
import platform.api;
import platform.command : queryLocalCaddyVersion, queryLocalTailscaleVersion;
import platform.nvml;
import std.algorithm : canFind, map, sort, startsWith, uniq;
import std.array : array, split;
import std.conv : to;
import std.datetime.systime : Clock;
import std.file : dirEntries, DirEntry, exists, isDir, isFile, read, readText, SpanMode, timeLastModified;
version (Posix) {
    import std.file : readLink;
}
import std.path : baseName, dirName;
import std.string : endsWith, indexOf, lastIndexOf, replace, strip, toLower;
import std.typecons : Nullable;

version (Posix) {
    import core.stdc.string : memmove, strlen;
    import core.sys.posix.dirent : closedir, DIR, dirent, opendir, readdir;
    import core.sys.posix.fcntl : O_RDONLY, posixOpen = open;
    import core.sys.posix.sys.stat : posixStat = stat, S_ISDIR, stat_t;
    import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
    import core.sys.posix.sys.utsname : uname, utsname;
    import core.sys.posix.unistd : _SC_CLK_TCK, _SC_PAGESIZE, F_OK, posixAccess = access, posixClose = close, posixRead = read, sysconf;
}

alias StatvfsFn = bool delegate(string mountPath, out ulong totalBytes, out ulong usedBytes);

private struct PathBuf(size_t N = 512) {
    char[N] buf = void;
    size_t len = 0;

    nothrow @nogc @safe:

    void clear() {
        len = 0;
        buf[0] = '\0';
    }

    bool put(const(char)[] s) {
        if (len + s.length >= N) return false;
        if (s.length > 0) {
            buf[len .. len + s.length] = s[];
            len += s.length;
        }
        buf[len] = '\0';
        return true;
    }

    bool putUint(ulong v) {
        char[24] tmp = void;
        size_t p = 0;
        do {
            tmp[p++] = cast(char)('0' + (v % 10));
            v /= 10;
        } while (v > 0);
        if (len + p >= N) return false;
        foreach (i; 0 .. p) {
            buf[len++] = tmp[p - 1 - i];
        }
        buf[len] = '\0';
        return true;
    }

    const(char)[] slice() const return {
        return buf[0 .. len];
    }

    const(char)* ptr() const return @trusted {
        return len == 0 ? "".ptr : buf.ptr;
    }
}

version (Posix) {
    private struct PosixLineReader(size_t BUF_SIZE = 4096) {
        int fd = -1;
        char[BUF_SIZE] buf = void;
        size_t cursor = 0;
        size_t filled = 0;
        bool eof = false;
        bool hadBytes = false;

        nothrow @trusted:

        bool open(const(char)* pathZ) {
            close();
            if (pathZ is null) return false;
            fd = posixOpen(pathZ, O_RDONLY);
            cursor = 0;
            filled = 0;
            eof = false;
            hadBytes = false;
            return fd >= 0;
        }

        void close() {
            if (fd >= 0) {
                posixClose(fd);
                fd = -1;
            }
        }

        bool nextLine(out const(char)[] line) {
            line = null;
            if (fd < 0) return false;

            while (true) {
                foreach (i; cursor .. filled) {
                    if (buf[i] == '\n') {
                        size_t end = i;
                        if (end > cursor && buf[end - 1] == '\r') end--;
                        line = buf[cursor .. end];
                        cursor = i + 1;
                        return true;
                    }
                }

                if (eof) {
                    if (cursor < filled) {
                        size_t end = filled;
                        if (end > cursor && buf[end - 1] == '\r') end--;
                        line = buf[cursor .. end];
                        cursor = filled;
                        return true;
                    }
                    return false;
                }

                size_t rem = filled - cursor;
                if (rem == BUF_SIZE) {
                    // Single line longer than BUF_SIZE: yield chunk to guarantee forward progress.
                    line = buf[0 .. BUF_SIZE];
                    cursor = BUF_SIZE;
                    return true;
                }
                if (rem > 0 && cursor > 0) {
                    memmove(buf.ptr, buf.ptr + cursor, rem);
                }
                cursor = 0;
                filled = rem;

                auto n = posixRead(fd, buf.ptr + filled, BUF_SIZE - filled);
                if (n <= 0) {
                    eof = true;
                } else {
                    hadBytes = true;
                    filled += cast(size_t) n;
                }
            }
        }
    }
}

class LinuxPlatformBackend : PlatformBackend {
    string procRoot;
    string sysRoot;
    string etcRoot;
    string varRoot;
    string libModulesRoot;
    bool exposeMacAddresses;
    StatvfsFn statvfsHook;

    private NvmlLoader nvml;
    private PciIdLookup pciIds;
    private bool pciIdsLoaded = false;

    // Thread-safe identity cache (boot_id / host only allocate if changed from cached value)
    private Mutex idMtx;
    private FixedString!128 idHostStore;
    private string idHostCached;
    private FixedString!128 idBootStore;
    private string idBootCached;
    private FixedString!64 idArchStore;
    private string idArchCached;

    // Preallocated buffers for single-group periodic/on-demand probes (fast, processes, filesystems, gpu, battery, maintenance)
    private RawNetworkInterface[MAX_NETWORK_INTERFACES] netBuf;
    private FixedString!64[MAX_NETWORK_INTERFACES] netIdStore;
    private FixedString!64[MAX_NETWORK_INTERFACES] netNameStore;

    private RawProcess[MAX_TRACKED_PROCESSES] procBuf;
    private FixedString!64[MAX_TRACKED_PROCESSES] procStartStore;
    private FixedString!128[MAX_TRACKED_PROCESSES] procNameStore;

    private MountStatus[MAX_FILESYSTEM_MOUNTS] mountBuf;
    private FixedString!512[MAX_FILESYSTEM_MOUNTS] mountPathStore;
    private FixedString!512[MAX_FILESYSTEM_MOUNTS] mountSrcStore;
    private FixedString!64[MAX_FILESYSTEM_MOUNTS] mountFsStore;
    private FixedString!256[MAX_FILESYSTEM_MOUNTS] mountDedupKeyStore;

    private GpuDynamicStatus[MAX_GPUS] gpuBuf;
    private FixedString!64[MAX_GPUS] gpuIdStore;
    private FixedString!128[MAX_GPUS] gpuNameStore;

    private BatteryStatus[MAX_BATTERIES] batBuf;
    private FixedString!64[MAX_BATTERIES] batIdStore;

    private FixedString!128 maintKernelStore;
    private FixedString!128 maintInstalledKernelStore;

    this(
        string procRoot = "/proc",
        string sysRoot = "/sys",
        string etcRoot = "/etc",
        string varRoot = "/var",
        string libModulesRoot = "/lib/modules",
        bool exposeMacAddresses = false,
        StatvfsFn statvfsHook = null
    ) {
        this.procRoot = procRoot;
        this.sysRoot = sysRoot;
        this.etcRoot = etcRoot;
        this.varRoot = varRoot;
        this.libModulesRoot = libModulesRoot;
        this.exposeMacAddresses = exposeMacAddresses;
        this.statvfsHook = statvfsHook;
        this.nvml = new NvmlLoader();
        this.idMtx = new Mutex();
    }

    private bool isRealHost() const pure nothrow @safe {
        return procRoot == "/proc" && sysRoot == "/sys";
    }

    private static bool isAsciiSpace(char c) pure nothrow @nogc @safe {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
    }

    private static const(char)[] trimAscii(const(char)[] s) pure nothrow @nogc @safe {
        size_t start = 0;
        while (start < s.length && isAsciiSpace(s[start])) start++;
        size_t end = s.length;
        while (end > start && isAsciiSpace(s[end - 1])) end--;
        return s[start .. end];
    }

    private static char toAsciiLower(char c) pure nothrow @nogc @safe {
        return (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
    }

    private static bool equalsIgnoreCase(const(char)[] a, const(char)[] b) pure nothrow @nogc @safe {
        if (a.length != b.length) return false;
        foreach (i; 0 .. a.length) {
            if (toAsciiLower(a[i]) != toAsciiLower(b[i])) return false;
        }
        return true;
    }

    private static bool startsWithAscii(const(char)[] s, const(char)[] prefix) pure nothrow @nogc @safe {
        return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
    }

    private static bool startsWithIgnoreCase(const(char)[] s, const(char)[] prefix) pure nothrow @nogc @safe {
        return s.length >= prefix.length && equalsIgnoreCase(s[0 .. prefix.length], prefix);
    }

    private static bool containsIgnoreCase(const(char)[] hay, const(char)[] needle) pure nothrow @nogc @safe {
        if (needle.length == 0) return true;
        if (hay.length < needle.length) return false;
        foreach (i; 0 .. hay.length - needle.length + 1) {
            if (equalsIgnoreCase(hay[i .. i + needle.length], needle)) return true;
        }
        return false;
    }

    private static ptrdiff_t indexOfChar(const(char)[] s, char ch) pure nothrow @nogc @safe {
        foreach (i, char c; s) {
            if (c == ch) return cast(ptrdiff_t) i;
        }
        return -1;
    }

    private static ptrdiff_t indexOfSlice(const(char)[] hay, const(char)[] needle) pure nothrow @nogc @safe {
        if (needle.length == 0) return 0;
        if (hay.length < needle.length) return -1;
        foreach (i; 0 .. hay.length - needle.length + 1) {
            if (hay[i .. i + needle.length] == needle) return cast(ptrdiff_t) i;
        }
        return -1;
    }

    private static bool nextToken(const(char)[] s, ref size_t pos, out const(char)[] tok) pure nothrow @nogc @safe {
        while (pos < s.length && isAsciiSpace(s[pos])) pos++;
        if (pos >= s.length) {
            tok = null;
            return false;
        }
        size_t start = pos;
        while (pos < s.length && !isAsciiSpace(s[pos])) pos++;
        tok = s[start .. pos];
        return true;
    }

    private static bool parseI64Token(const(char)[] tok, out long val) pure nothrow @safe {
        if (tok.length == 0) return false;
        size_t i = 0;
        bool neg = false;
        if (tok[0] == '-') {
            neg = true;
            i = 1;
        } else if (tok[0] == '+') {
            i = 1;
        }
        if (i >= tok.length) return false;
        ulong acc = 0;
        ulong limit = neg ? (cast(ulong) long.max + 1) : cast(ulong) long.max;
        foreach (char c; tok[i .. $]) {
            if (c < '0' || c > '9') return false;
            ulong d = cast(ulong)(c - '0');
            if (acc > (limit - d) / 10) return false;
            acc = acc * 10 + d;
        }
        val = neg ? (acc == cast(ulong) long.max + 1 ? long.min : -cast(long) acc) : cast(long) acc;
        return true;
    }

    private static bool parseDoubleToken(const(char)[] tok, out double val) pure nothrow @safe {
        if (tok.length == 0) return false;
        size_t i = 0;
        bool neg = false;
        if (tok[0] == '-') {
            neg = true;
            i = 1;
        } else if (tok[0] == '+') {
            i = 1;
        }
        if (i >= tok.length) return false;

        double acc = 0.0;
        bool anyDigit = false;
        while (i < tok.length && tok[i] >= '0' && tok[i] <= '9') {
            anyDigit = true;
            acc = acc * 10.0 + cast(double)(tok[i] - '0');
            i++;
        }
        if (i < tok.length && tok[i] == '.') {
            i++;
            double fracScale = 0.1;
            while (i < tok.length && tok[i] >= '0' && tok[i] <= '9') {
                anyDigit = true;
                acc += cast(double)(tok[i] - '0') * fracScale;
                fracScale *= 0.1;
                i++;
            }
        }
        if (!anyDigit) return false;

        if (i < tok.length && (tok[i] == 'e' || tok[i] == 'E')) {
            i++;
            bool expNeg = false;
            if (i < tok.length && (tok[i] == '-' || tok[i] == '+')) {
                expNeg = (tok[i] == '-');
                i++;
            }
            if (i >= tok.length || tok[i] < '0' || tok[i] > '9') return false;
            int exp = 0;
            while (i < tok.length && tok[i] >= '0' && tok[i] <= '9') {
                if (exp < 1000) exp = exp * 10 + (tok[i] - '0');
                i++;
            }
            double scale = 1.0;
            foreach (_; 0 .. exp) scale *= 10.0;
            acc = expNeg ? (acc / scale) : (acc * scale);
        }

        if (i != tok.length) return false;
        val = neg ? -acc : acc;
        return true;
    }

    private static void sanitizeInto(size_t N)(ref FixedString!N dst, const(char)[] raw, size_t maxLen = N) pure nothrow @safe {
        dst.clear();
        if (raw.length == 0) return;
        size_t limit = maxLen < N ? maxLen : N;

        if (raw.length <= limit) {
            auto trimmed = trimAscii(raw);
            if (trimmed.length == 0) return;
            bool clean = true;
            foreach (char c; trimmed) {
                ubyte b = cast(ubyte) c;
                if (b < 0x20 || b == 0x7F) {
                    clean = false;
                    break;
                }
            }
            if (clean) {
                dst.set(trimmed);
                return;
            }
        }

        char[N] tmp = void;
        size_t tmpLen = 0;
        bool prevSpace = false;
        foreach (char c; raw) {
            ubyte b = cast(ubyte) c;
            if (b == '\r' || b == '\n' || b == '\t') {
                if (!prevSpace && tmpLen > 0) {
                    tmp[tmpLen++] = ' ';
                    prevSpace = true;
                }
                if (tmpLen >= limit) break;
                continue;
            }
            if (b < 0x20 || b == 0x7F) continue;
            tmp[tmpLen++] = c;
            prevSpace = (c == ' ');
            if (tmpLen >= limit) break;
        }
        auto res = trimAscii(tmp[0 .. tmpLen]);
        if (res.length > 0) dst.set(res);
    }

    private static const(char)[] readStackFile(ref PathBuf!512 path, char[] dst, bool stripWs = true) nothrow @trusted {
        version (Posix) {
            int fd = posixOpen(path.ptr, O_RDONLY);
            if (fd < 0) return null;
            scope (exit) posixClose(fd);
            size_t total = 0;
            while (total < dst.length) {
                auto n = posixRead(fd, dst.ptr + total, dst.length - total);
                if (n <= 0) break;
                total += cast(size_t) n;
            }
            auto s = cast(const(char)[]) dst[0 .. total];
            return stripWs ? trimAscii(s) : s;
        } else {
            return null;
        }
    }

    private string safeReadText(string path) const {
        if (!exists(path)) return "";
        try {
            import std.stdio : File;
            import std.array : appender;
            auto f = File(path, "rb");
            scope (exit) f.close();
            char[4096] stackBuf;
            auto first = f.rawRead(stackBuf[]);
            if (first.length == 0) return "";
            if (first.length < stackBuf.length) {
                auto trimmed = (cast(const(char)[]) first).strip();
                return trimmed.length == 0 ? "" : trimmed.idup;
            }
            auto app = appender!(char[])();
            app.put(first);
            while (true) {
                auto more = f.rawRead(stackBuf[]);
                if (more.length == 0) break;
                app.put(more);
                if (app.data.length >= 4 * 1024 * 1024) break;
            }
            auto trimmed = (cast(const(char)[]) app.data).strip();
            return trimmed.length == 0 ? "" : trimmed.idup;
        } catch (Exception) {
            return "";
        }
    }

    private string safeReadLink(string path) const {
        version (Posix) {
            return readLink(path);
        } else {
            return "";
        }
    }

    private string[] readCpuinfoFlags() const {
        auto txt = safeReadText(procRoot ~ "/cpuinfo");
        foreach (line; txt.split('\n')) {
            auto low = line.toLower();
            if (low.startsWith("flags") || low.startsWith("features")) {
                auto colon = line.indexOf(':');
                if (colon >= 0 && colon + 1 < line.length) {
                    return line[colon + 1 .. $].strip().split();
                }
            }
        }
        return null;
    }

    private string detectArch() const {
        version (Posix) {
            if (!isRealHost()) {
                PathBuf!512 p;
                p.put(procRoot);
                p.put("/cpuinfo");
                PosixLineReader!2048 reader;
                if (reader.open(p.ptr)) {
                    scope (exit) reader.close();
                    const(char)[] line;
                    bool foundX86 = false;
                    while (reader.nextLine(line)) {
                        if (containsIgnoreCase(line, "aarch64") || containsIgnoreCase(line, "cortex-")
                            || containsIgnoreCase(line, "asimd") || containsIgnoreCase(line, "cpu architecture: 8")) {
                            return "aarch64";
                        }
                        if (containsIgnoreCase(line, "x86_64") || containsIgnoreCase(line, "lm ")
                            || containsIgnoreCase(line, "authenticamd") || containsIgnoreCase(line, "genuineintel")) {
                            foundX86 = true;
                        }
                    }
                    if (foundX86) return "x86_64";
                }
            }
            utsname u;
            if (uname(&u) == 0) {
                const(char)[] m = u.machine[0 .. strlen(u.machine.ptr)];
                if (m == "x86_64") return "x86_64";
                if (m == "aarch64" || m == "arm64") return "aarch64";
                if (m == "i686") return "i686";
                if (m == "armv7l") return "armv7l";
                if (m == "riscv64") return "riscv64";
                if (m == "ppc64le") return "ppc64le";
                if (m == "s390x") return "s390x";
                if (m.length > 0) return m.idup;
            }
        }
        version (X86_64) return "x86_64";
        else version (AArch64) return "aarch64";
        else return "unknown";
    }

    override PlatformIdentity identity() {
        PlatformIdentity id;
        id.os = "linux";

        auto arch = detectArch();
        FixedString!128 cleanHost;
        FixedString!128 cleanBoot;
        char[256] tmp = void;

        version (Posix) {
            PathBuf!512 p;
            if (!isRealHost()) {
                p.clear();
                p.put(procRoot);
                p.put("/sys/kernel/hostname");
                auto h = readStackFile(p, tmp);
                sanitizeInto(cleanHost, h, 128);
            }
            if (cleanHost.len == 0) {
                utsname u;
                if (uname(&u) == 0) {
                    const(char)[] nodename = u.nodename[0 .. strlen(u.nodename.ptr)];
                    sanitizeInto(cleanHost, nodename, 128);
                }
            }

            p.clear();
            p.put(procRoot);
            p.put("/sys/kernel/random/boot_id");
            auto bi = readStackFile(p, tmp);
            sanitizeInto(cleanBoot, bi, 128);

            p.clear();
            p.put(procRoot);
            p.put("/uptime");
            auto upTxt = readStackFile(p, tmp);
            if (upTxt.length > 0) {
                size_t pos = 0;
                const(char)[] tok;
                double upSec;
                if (nextToken(upTxt, pos, tok) && parseDoubleToken(tok, upSec)) {
                    id.uptime_s = cast(long) upSec;
                }
            }
        }

        synchronized (idMtx) {
            if (idArchCached.length > 0 && idArchStore.equals(arch)) {
                id.arch = idArchCached;
            } else {
                idArchStore.set(arch);
                idArchCached = arch;
                id.arch = arch;
            }

            if (cleanHost.len == 0) {
                id.host = "linux-host";
            } else if (idHostCached.length > 0 && idHostStore == cleanHost) {
                id.host = idHostCached;
            } else {
                idHostStore = cleanHost;
                idHostCached = cleanHost.slice().idup;
                id.host = idHostCached;
            }

            if (cleanBoot.len == 0) {
                id.boot_id = "unknown-boot";
            } else if (idBootCached.length > 0 && idBootStore == cleanBoot) {
                id.boot_id = idBootCached;
            } else {
                idBootStore = cleanBoot;
                idBootCached = cleanBoot.slice().idup;
                id.boot_id = idBootCached;
            }
        }
        return id;
    }

    override RawCpu sampleCpu() {
        RawCpu c;
        version (Posix) {
            PathBuf!512 p;
            p.put(procRoot);
            p.put("/stat");
            PosixLineReader!4096 reader;
            if (!reader.open(p.ptr)) {
                c.state = CapabilityState.error;
                c.error = "proc_stat_unreadable";
                return c;
            }
            bool foundAgg = false;
            uint cores = 0;
            {
                scope (exit) reader.close();
                const(char)[] line;
                while (reader.nextLine(line)) {
                    auto s = trimAscii(line);
                    if (startsWithAscii(s, "cpu ")) {
                        size_t pos = 0;
                        const(char)[] tok;
                        nextToken(s, pos, tok); // "cpu"
                        ulong[8] vals = 0;
                        size_t n = 0;
                        while (n < 8 && nextToken(s, pos, tok)) {
                            ulong v = 0;
                            if (parseU64Token(tok, v)) {
                                vals[n] = v;
                            } else {
                                vals[n] = 0;
                            }
                            n++;
                        }
                        if (n >= 4) {
                            ulong total = 0;
                            foreach (i; 0 .. n) total += vals[i];
                            ulong idle = vals[3] + (n > 4 ? vals[4] : 0);
                            c.total_ticks = total;
                            c.idle_ticks = idle;
                            foundAgg = true;
                        }
                    } else if (startsWithAscii(s, "cpu") && s.length > 3 && s[3] >= '0' && s[3] <= '9') {
                        cores++;
                    }
                }
            }

            if (!reader.hadBytes) {
                c.state = CapabilityState.error;
                c.error = "proc_stat_unreadable";
                return c;
            }
            if (!foundAgg) {
                c.state = CapabilityState.error;
                c.error = "proc_stat_missing_cpu_line";
                return c;
            }
            c.logical_cores = cores > 0 ? cores : 1;

            p.clear();
            p.put(procRoot);
            p.put("/loadavg");
            char[256] loadBuf = void;
            auto loadTxt = readStackFile(p, loadBuf);
            if (loadTxt.length > 0) {
                size_t pos = 0;
                const(char)[] tok;
                double l1;
                if (nextToken(loadTxt, pos, tok) && parseDoubleToken(tok, l1)) {
                    c.load_1m = l1;
                }
            }

            c.temp_c = sampleCpuTemp();
            c.state = CapabilityState.ok;
            return c;
        } else {
            c.state = CapabilityState.unsupported;
            return c;
        }
    }

    private Nullable!double sampleCpuTemp() const {
        Nullable!double res;
        version (Posix) {
            static immutable string[] preferredNames = ["k10temp", "zenpower", "coretemp", "cpu_thermal", "soc_thermal", "x86_pkg_temp"];
            PathBuf!512 hwmonDir;
            hwmonDir.put(sysRoot);
            hwmonDir.put("/class/hwmon");
            DIR* dir = opendir(hwmonDir.ptr);
            if (dir is null) return res;
            scope (exit) closedir(dir);

            PathBuf!512 p;
            char[64] buf = void;
            dirent* ent;
            while ((ent = readdir(dir)) !is null) {
                auto dname = ent.d_name[0 .. strlen(ent.d_name.ptr)];
                if (dname == "." || dname == "..") continue;

                p.clear();
                p.put(sysRoot);
                p.put("/class/hwmon/");
                p.put(dname);
                p.put("/name");
                auto name = readStackFile(p, buf);
                if (name.length == 0) continue;

                bool preferred = false;
                foreach (pn; preferredNames) {
                    if (equalsIgnoreCase(name, pn)) {
                        preferred = true;
                        break;
                    }
                }
                if (!preferred) continue;

                foreach (ulong idx; 1 .. 6) {
                    p.clear();
                    p.put(sysRoot);
                    p.put("/class/hwmon/");
                    p.put(dname);
                    p.put("/temp");
                    p.putUint(idx);
                    p.put("_input");
                    auto raw = readStackFile(p, buf);
                    if (raw.length == 0) continue;
                    long milli;
                    if (parseI64Token(raw, milli) && milli > -40_000 && milli < 150_000) {
                        res = cast(double) milli / 1000.0;
                        return res;
                    }
                }
            }
        }
        return res;
    }

    override RawMemory sampleMemory() {
        RawMemory m;
        version (Posix) {
            PathBuf!512 p;
            p.put(procRoot);
            p.put("/meminfo");
            PosixLineReader!4096 reader;
            if (!reader.open(p.ptr)) {
                m.state = CapabilityState.error;
                m.error = "proc_meminfo_unreadable";
                return m;
            }

            bool hasTotal = false, hasAvail = false, hasFree = false, hasBuf = false, hasCache = false, hasSwapTotal = false, hasSwapFree = false;
            ulong memTotalKb = 0, memAvailKb = 0, memFreeKb = 0, buffersKb = 0, cachedKb = 0, swapTotalKb = 0, swapFreeKb = 0;

            {
                scope (exit) reader.close();
                const(char)[] line;
                while (reader.nextLine(line)) {
                    auto colon = indexOfChar(line, ':');
                    if (colon <= 0) continue;
                    auto key = trimAscii(line[0 .. colon]);
                    size_t pos = cast(size_t)(colon + 1);
                    const(char)[] tok;
                    if (!nextToken(line, pos, tok)) continue;
                    ulong valKb = 0;
                    if (!parseU64Token(tok, valKb)) continue;

                    if (key == "MemTotal") { hasTotal = true; memTotalKb = valKb; }
                    else if (key == "MemAvailable") { hasAvail = true; memAvailKb = valKb; }
                    else if (key == "MemFree") { hasFree = true; memFreeKb = valKb; }
                    else if (key == "Buffers") { hasBuf = true; buffersKb = valKb; }
                    else if (key == "Cached") { hasCache = true; cachedKb = valKb; }
                    else if (key == "SwapTotal") { hasSwapTotal = true; swapTotalKb = valKb; }
                    else if (key == "SwapFree") { hasSwapFree = true; swapFreeKb = valKb; }
                }
            }

            if (!reader.hadBytes) {
                m.state = CapabilityState.error;
                m.error = "proc_meminfo_unreadable";
                return m;
            }

            if (hasTotal) {
                ulong total = memTotalKb * 1024UL;
                m.total_bytes = total;
                if (hasAvail) {
                    ulong avail = memAvailKb * 1024UL;
                    m.used_bytes = total > avail ? (total - avail) : 0;
                } else {
                    ulong freeB = (hasFree ? memFreeKb : 0) * 1024UL;
                    ulong bufB = (hasBuf ? buffersKb : 0) * 1024UL;
                    ulong cacheB = (hasCache ? cachedKb : 0) * 1024UL;
                    ulong freeTotal = freeB + bufB + cacheB;
                    m.used_bytes = total > freeTotal ? (total - freeTotal) : 0;
                }
            } else {
                m.state = CapabilityState.error;
                m.error = "proc_meminfo_missing_total";
                return m;
            }

            if (hasSwapTotal) {
                ulong swTotal = swapTotalKb * 1024UL;
                m.swap_total_bytes = swTotal;
                ulong swFree = (hasSwapFree ? swapFreeKb : 0) * 1024UL;
                m.swap_used_bytes = swTotal > swFree ? (swTotal - swFree) : 0;
            }

            m.state = CapabilityState.ok;
            return m;
        } else {
            m.state = CapabilityState.unsupported;
            return m;
        }
    }

    private bool netAttrExists(const(char)[] ifName, const(char)[] suffix) const nothrow @nogc @trusted {
        version (Posix) {
            PathBuf!512 p;
            p.put(sysRoot);
            p.put("/class/net/");
            p.put(ifName);
            p.put(suffix);
            return posixAccess(p.ptr, F_OK) == 0;
        } else {
            return false;
        }
    }

    private string classifyNetKind(const(char)[] ifName) const nothrow @nogc @safe {
        if (ifName == "lo") return "loopback";
        if (startsWithAscii(ifName, "tailscale") || startsWithAscii(ifName, "ts")) return "tailnet";

        version (Posix) {
            if (netAttrExists(ifName, "/wireless") || netAttrExists(ifName, "/phy80211") || startsWithAscii(ifName, "wl")) {
                return "wireless";
            }
            if (netAttrExists(ifName, "/tun_flags") || startsWithAscii(ifName, "veth") || startsWithAscii(ifName, "docker")
                || startsWithAscii(ifName, "br-") || startsWithAscii(ifName, "virbr") || startsWithAscii(ifName, "tun")
                || startsWithAscii(ifName, "tap") || startsWithAscii(ifName, "wg")) {
                return "virtual";
            }
            if (netAttrExists(ifName, "/device")) {
                return "physical";
            }
            return "virtual";
        } else {
            return "virtual";
        }
    }

    override RawNetworkResult sampleNetwork() {
        RawNetworkResult r;
        version (Posix) {
            PathBuf!512 p;
            p.put(procRoot);
            p.put("/net/dev");
            PosixLineReader!4096 reader;
            if (!reader.open(p.ptr)) {
                r.state = CapabilityState.error;
                r.error = "proc_net_dev_unreadable";
                return r;
            }

            size_t outCount = 0;
            {
                scope (exit) reader.close();
                const(char)[] line;
                char[64] tmpBuf = void;
                while (reader.nextLine(line)) {
                    if (outCount >= MAX_NETWORK_INTERFACES) break;
                    auto colon = indexOfChar(line, ':');
                    if (colon <= 0) continue;

                    sanitizeInto(netNameStore[outCount], line[0 .. colon], 64);
                    auto ifName = netNameStore[outCount].slice();
                    if (ifName.length == 0 || ifName == "lo") continue;

                    size_t pos = cast(size_t)(colon + 1);
                    const(char)[] rxTok, txTok, dummy;
                    if (!nextToken(line, pos, rxTok)) continue;
                    bool enoughCols = true;
                    foreach (_; 1 .. 8) {
                        if (!nextToken(line, pos, dummy)) { enoughCols = false; break; }
                    }
                    if (!enoughCols || !nextToken(line, pos, txTok)) continue;
                    if (!nextToken(line, pos, dummy)) continue; // require >= 10 columns

                    ulong rxBytes = 0, txBytes = 0;
                    if (!parseU64Token(rxTok, rxBytes) || !parseU64Token(txTok, txBytes)) continue;

                    RawNetworkInterface ni;
                    ni.name = ifName;
                    ni.kind = classifyNetKind(ifName);
                    ni.rx_bytes = rxBytes;
                    ni.tx_bytes = txBytes;

                    p.clear();
                    p.put(sysRoot);
                    p.put("/class/net/");
                    p.put(ifName);
                    p.put("/ifindex");
                    auto ifIndexTxt = readStackFile(p, tmpBuf);
                    PathBuf!64 idFmt;
                    if (ifIndexTxt.length > 0) {
                        idFmt.put("ifindex:");
                        idFmt.put(ifIndexTxt);
                    } else {
                        idFmt.put("name:");
                        idFmt.put(ifName);
                    }
                    netIdStore[outCount].set(idFmt.slice());
                    ni.id = netIdStore[outCount].slice();

                    p.clear();
                    p.put(sysRoot);
                    p.put("/class/net/");
                    p.put(ifName);
                    p.put("/operstate");
                    auto oper = readStackFile(p, tmpBuf);
                    if (oper.length > 0) {
                        ni.link_up = (equalsIgnoreCase(oper, "up") || equalsIgnoreCase(oper, "unknown"));
                    }

                    p.clear();
                    p.put(sysRoot);
                    p.put("/class/net/");
                    p.put(ifName);
                    p.put("/speed");
                    auto spd = readStackFile(p, tmpBuf);
                    if (spd.length > 0) {
                        long mbps;
                        if (parseI64Token(spd, mbps) && mbps > 0 && mbps < 1_000_000) {
                            ni.link_speed_bps = cast(ulong) mbps * 1_000_000UL;
                        }
                    }

                    netBuf[outCount++] = ni;
                }
            }

            if (!reader.hadBytes) {
                r.state = CapabilityState.error;
                r.error = "proc_net_dev_unreadable";
                return r;
            }

            r.interfaces = netBuf[0 .. outCount];
            r.state = CapabilityState.ok;
            return r;
        } else {
            r.state = CapabilityState.unsupported;
            return r;
        }
    }

    private static bool parseU64Token(const(char)[] tok, out ulong val) pure nothrow @safe {
        if (tok.length == 0) return false;
        ulong acc = 0;
        foreach (char c; tok) {
            if (c < '0' || c > '9') return false;
            ulong d = cast(ulong)(c - '0');
            if (acc > (ulong.max - d) / 10) return false;
            acc = acc * 10 + d;
        }
        val = acc;
        return true;
    }

    override RawProcessResult sampleProcesses() {
        RawProcessResult r;
        auto cpu = sampleCpu();
        if (cpu.state == CapabilityState.error) {
            r.state = CapabilityState.error;
            r.error = cpu.error;
            return r;
        }
        r.total_cpu_ticks = cpu.total_ticks;
        r.logical_cores = cpu.logical_cores;

        version (Posix) {
            long pageSize = 4096;
            long ps = sysconf(_SC_PAGESIZE);
            if (ps > 0) pageSize = ps;

            PathBuf!512 procDirPb;
            procDirPb.put(procRoot);
            DIR* dir = opendir(procDirPb.ptr);
            if (dir is null) {
                r.state = CapabilityState.error;
                r.error = "proc_enumeration_failed";
                return r;
            }
            scope (exit) closedir(dir);

            size_t outCount = 0;
            char[1024] statBuf = void;
            PathBuf!512 statPath;
            dirent* ent;
            while ((ent = readdir(dir)) !is null) {
                if (outCount >= MAX_TRACKED_PROCESSES) break;
                auto dname = ent.d_name[0 .. strlen(ent.d_name.ptr)];
                if (dname.length == 0 || dname[0] < '0' || dname[0] > '9') continue;

                uint pid = 0;
                bool validPid = true;
                foreach (char ch; dname) {
                    if (ch < '0' || ch > '9') { validPid = false; break; }
                    pid = pid * 10 + cast(uint)(ch - '0');
                }
                if (!validPid) continue;

                // Never read /cmdline or /environ
                statPath.clear();
                statPath.put(procRoot);
                statPath.put("/");
                statPath.put(dname);
                statPath.put("/stat");
                auto statSlice = readStackFile(statPath, statBuf, false);
                if (statSlice.length == 0) continue;

                ptrdiff_t openParen = -1;
                ptrdiff_t closeParen = -1;
                foreach (idx, char c; statSlice) {
                    if (c == '(' && openParen < 0) openParen = cast(ptrdiff_t) idx;
                    else if (c == ')') closeParen = cast(ptrdiff_t) idx;
                }
                if (openParen < 0 || closeParen <= openParen || closeParen + 2 >= statSlice.length) continue;

                sanitizeInto(procNameStore[outCount], statSlice[openParen + 1 .. closeParen], 128);
                auto rest = statSlice[closeParen + 2 .. $];

                ulong utime = 0, stime = 0, rssPages = 0;
                const(char)[] startTok;
                size_t fieldIdx = 0;
                size_t pos = 0;
                bool parseErr = false;
                while (pos < rest.length && fieldIdx <= 21) {
                    const(char)[] tok;
                    if (!nextToken(rest, pos, tok)) break;
                    if (fieldIdx == 11) {
                        if (!parseU64Token(tok, utime)) { parseErr = true; break; }
                    } else if (fieldIdx == 12) {
                        if (!parseU64Token(tok, stime)) { parseErr = true; break; }
                    } else if (fieldIdx == 19) {
                        startTok = tok;
                    } else if (fieldIdx == 21) {
                        if (!parseU64Token(tok, rssPages)) { parseErr = true; break; }
                    }
                    fieldIdx++;
                }
                if (parseErr || fieldIdx <= 21 || startTok.length == 0) continue;

                procStartStore[outCount].set(startTok);
                RawProcess rp;
                rp.pid = pid;
                rp.start_id = procStartStore[outCount].slice();
                rp.name = procNameStore[outCount].slice();
                rp.cpu_ticks = utime + stime;
                rp.rss_bytes = rssPages * cast(ulong) pageSize;
                rp.memory_kind = "rss";
                procBuf[outCount++] = rp;
            }

            r.processes = procBuf[0 .. outCount];
            r.state = CapabilityState.ok;
            return r;
        } else {
            r.state = CapabilityState.unsupported;
            return r;
        }
    }

    static string unescapeMountPath(string raw) pure @safe {
        auto s = raw.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\");
        return sanitizeOsString(s, 512);
    }

    private static void unescapeMountInto(size_t N)(ref FixedString!N dst, const(char)[] raw) pure nothrow @safe {
        char[512] tmp = void;
        size_t tmpLen = 0;
        size_t i = 0;
        while (i < raw.length && tmpLen < tmp.length) {
            if (i + 3 < raw.length && raw[i] == '\\') {
                auto esc = raw[i + 1 .. i + 4];
                if (esc == "040") {
                    tmp[tmpLen++] = ' ';
                    i += 4;
                    continue;
                } else if (esc == "011") {
                    tmp[tmpLen++] = '\t';
                    i += 4;
                    continue;
                } else if (esc == "012") {
                    tmp[tmpLen++] = '\n';
                    i += 4;
                    continue;
                } else if (esc == "134") {
                    tmp[tmpLen++] = '\\';
                    i += 4;
                    continue;
                }
            }
            tmp[tmpLen++] = raw[i++];
        }
        sanitizeInto(dst, tmp[0 .. tmpLen], N < 512 ? N : 512);
    }

    private static bool isIgnoredFsType(const(char)[] fsType) pure nothrow @safe {
        static immutable string[] ignored = [
            "proc", "sysfs", "tmpfs", "devtmpfs", "devpts", "cgroup", "cgroup2",
            "pstore", "bpf", "tracefs", "debugfs", "securityfs", "configfs",
            "fusectl", "hugetlbfs", "mqueue", "ramfs", "autofs", "overlay",
            "squashfs", "nsfs", "efivarfs", "rpc_pipefs", "binfmt_misc",
            "fuse.portal", "fuse.gvfsd-fuse", "selinuxfs",
        ];
        foreach (ig; ignored) {
            if (equalsIgnoreCase(fsType, ig)) return true;
        }
        return false;
    }

    private static bool isNetworkFsType(const(char)[] fsType) pure nothrow @safe {
        static immutable string[] netFs = [
            "nfs", "nfs4", "cifs", "smb3", "smbfs", "sshfs", "fuse.sshfs", "9p", "ceph", "glusterfs", "lustre",
        ];
        foreach (nf; netFs) {
            if (equalsIgnoreCase(fsType, nf)) return true;
        }
        return false;
    }

    private size_t parseMountsFixed() {
        size_t count = 0;
        version (Posix) {
            PathBuf!512 p;
            p.put(procRoot);
            p.put("/self/mountinfo");
            PosixLineReader!8192 reader;
            if (reader.open(p.ptr)) {
                scope (exit) reader.close();
                const(char)[] line;
                FixedString!512 tmpMount;
                while (reader.nextLine(line)) {
                    if (count >= MAX_FILESYSTEM_MOUNTS) break;
                    auto s = trimAscii(line);
                    if (s.length == 0) continue;
                    auto sep = indexOfSlice(s, " - ");
                    if (sep <= 0) continue;

                    auto leftSlice = s[0 .. sep];
                    auto rightSlice = s[sep + 3 .. $];

                    const(char)[] l0, l1, devId, fsRoot, rawMountPt;
                    size_t lp = 0;
                    if (!nextToken(leftSlice, lp, l0) || !nextToken(leftSlice, lp, l1)
                        || !nextToken(leftSlice, lp, devId) || !nextToken(leftSlice, lp, fsRoot)
                        || !nextToken(leftSlice, lp, rawMountPt)) {
                        continue;
                    }

                    const(char)[] fsType, rawSource;
                    size_t rp = 0;
                    if (!nextToken(rightSlice, rp, fsType) || !nextToken(rightSlice, rp, rawSource)) {
                        continue;
                    }

                    if (isIgnoredFsType(fsType) || isNetworkFsType(fsType)) continue;
                    unescapeMountInto(tmpMount, rawMountPt);
                    auto mp = tmpMount.slice();
                    if (startsWithAscii(mp, "/sys") || startsWithAscii(mp, "/proc")
                        || startsWithAscii(mp, "/dev") || startsWithAscii(mp, "/run/")) {
                        continue;
                    }

                    // Deduplicate identical bind mounts of the same device+subroot while keeping distinct Btrfs subvolumes!
                    PathBuf!256 keyFmt;
                    keyFmt.put(devId);
                    keyFmt.put(":");
                    keyFmt.put(fsRoot);
                    bool dup = false;
                    foreach (i; 0 .. count) {
                        if (mountDedupKeyStore[i].equals(keyFmt.slice())) {
                            dup = true;
                            break;
                        }
                    }
                    if (dup) continue;

                    mountDedupKeyStore[count].set(keyFmt.slice());
                    mountPathStore[count] = tmpMount;
                    unescapeMountInto(mountSrcStore[count], rawSource);
                    sanitizeInto(mountFsStore[count], fsType, 64);
                    count++;
                }
                if (reader.hadBytes) return count;
            }

            p.clear();
            p.put(procRoot);
            p.put("/mounts");
            if (reader.open(p.ptr)) {
                scope (exit) reader.close();
                const(char)[] line;
                FixedString!512 tmpMount;
                while (reader.nextLine(line)) {
                    if (count >= MAX_FILESYSTEM_MOUNTS) break;
                    auto s = trimAscii(line);
                    if (s.length == 0) continue;
                    const(char)[] rawSource, rawMountPt, fsType;
                    size_t pos = 0;
                    if (!nextToken(s, pos, rawSource) || !nextToken(s, pos, rawMountPt) || !nextToken(s, pos, fsType)) {
                        continue;
                    }
                    if (isIgnoredFsType(fsType) || isNetworkFsType(fsType)) continue;
                    unescapeMountInto(tmpMount, rawMountPt);
                    auto mp = tmpMount.slice();
                    bool dup = false;
                    foreach (i; 0 .. count) {
                        if (mountPathStore[i].equals(mp)) {
                            dup = true;
                            break;
                        }
                    }
                    if (dup) continue;

                    mountPathStore[count] = tmpMount;
                    unescapeMountInto(mountSrcStore[count], rawSource);
                    sanitizeInto(mountFsStore[count], fsType, 64);
                    count++;
                }
            }
        }
        return count;
    }

    private bool queryMountStats(const(char)[] mountPoint, out ulong totalBytes, out ulong usedBytes) const {
        if (statvfsHook !is null) {
            return statvfsHook(cast(string) mountPoint, totalBytes, usedBytes);
        }
        version (Posix) {
            char[514] pathZ = void;
            if (mountPoint.length >= pathZ.length) return false;
            if (mountPoint.length > 0) pathZ[0 .. mountPoint.length] = mountPoint[];
            pathZ[mountPoint.length] = '\0';
            statvfs_t sv;
            if (statvfs(pathZ.ptr, &sv) != 0) return false;
            ulong frsize = sv.f_frsize > 0 ? sv.f_frsize : sv.f_bsize;
            totalBytes = cast(ulong) sv.f_blocks * frsize;
            ulong freeAvail = cast(ulong) sv.f_bavail * frsize;
            ulong freeTotal = cast(ulong) sv.f_bfree * frsize;
            usedBytes = totalBytes > freeTotal ? (totalBytes - freeTotal) : 0;
            cast(void) freeAvail;
            return totalBytes > 0;
        } else {
            return false;
        }
    }

    override RawFilesystemResult sampleFilesystems() {
        RawFilesystemResult r;
        size_t candCount = parseMountsFixed();
        if (candCount == 0) {
            version (Posix) {
                PathBuf!512 p1, p2;
                p1.put(procRoot);
                p1.put("/self/mountinfo");
                p2.put(procRoot);
                p2.put("/mounts");
                if (posixAccess(p1.ptr, F_OK) != 0 && posixAccess(p2.ptr, F_OK) != 0) {
                    r.state = CapabilityState.error;
                    r.error = "mountinfo_unreadable";
                    return r;
                }
            }
        }

        size_t outCount = 0;
        foreach (i; 0 .. candCount) {
            ulong totalB = 0, usedB = 0;
            if (!queryMountStats(mountPathStore[i].slice(), totalB, usedB)) continue;
            if (outCount != i) {
                mountPathStore[outCount] = mountPathStore[i];
                mountSrcStore[outCount] = mountSrcStore[i];
                mountFsStore[outCount] = mountFsStore[i];
            }
            MountStatus ms;
            ms.mount = mountPathStore[outCount].slice();
            ms.source = mountSrcStore[outCount].slice();
            ms.fs = mountFsStore[outCount].slice();
            ms.total_bytes = totalB;
            ms.used_bytes = usedB;
            ms.pct = totalB > 0 ? (cast(double) usedB / cast(double) totalB) * 100.0 : 0.0;
            mountBuf[outCount++] = ms;
        }

        r.mounts = mountBuf[0 .. outCount];
        r.state = CapabilityState.ok;
        return r;
    }

    override RawGpuResult sampleGpus() {
        if (isRealHost()) {
            auto nvRes = nvml.sample();
            if (nvRes.state == CapabilityState.ok) return nvRes;
        }

        RawGpuResult r;
        version (Posix) {
            PathBuf!512 drmDir;
            drmDir.put(sysRoot);
            drmDir.put("/class/drm");
            DIR* dir = opendir(drmDir.ptr);
            size_t outCount = 0;
            if (dir !is null) {
                scope (exit) closedir(dir);
                PathBuf!512 p;
                char[64] busyBuf = void, vramUsedBuf = void, vramTotBuf = void, vendBuf = void;
                dirent* ent;
                while ((ent = readdir(dir)) !is null) {
                    if (outCount >= MAX_GPUS) break;
                    auto dname = ent.d_name[0 .. strlen(ent.d_name.ptr)];
                    if (!startsWithAscii(dname, "card") || indexOfChar(dname, '-') >= 0) continue;

                    p.clear(); p.put(sysRoot); p.put("/class/drm/"); p.put(dname); p.put("/device/gpu_busy_percent");
                    auto busyTxt = readStackFile(p, busyBuf);
                    p.clear(); p.put(sysRoot); p.put("/class/drm/"); p.put(dname); p.put("/device/mem_info_vram_used");
                    auto vramUsedTxt = readStackFile(p, vramUsedBuf);
                    p.clear(); p.put(sysRoot); p.put("/class/drm/"); p.put(dname); p.put("/device/mem_info_vram_total");
                    auto vramTotTxt = readStackFile(p, vramTotBuf);
                    if (busyTxt.length == 0 && vramUsedTxt.length == 0) continue;

                    p.clear(); p.put(sysRoot); p.put("/class/drm/"); p.put(dname); p.put("/device/vendor");
                    auto vendorHex = readStackFile(p, vendBuf);
                    string vendor = vendorHex == "0x1002" ? "AMD" : (vendorHex == "0x8086" ? "Intel" : "GPU");

                    PathBuf!64 idFmt;
                    idFmt.put("drm:");
                    idFmt.put(dname);
                    gpuIdStore[outCount].set(idFmt.slice());

                    PathBuf!128 nameFmt;
                    nameFmt.put(vendor);
                    nameFmt.put(" (");
                    nameFmt.put(dname);
                    nameFmt.put(")");
                    gpuNameStore[outCount].set(nameFmt.slice());

                    GpuDynamicStatus g;
                    g.id = gpuIdStore[outCount].slice();
                    g.vendor = vendor;
                    g.display_name = gpuNameStore[outCount].slice();
                    g.capability = CapabilityState.ok;

                    double busyVal;
                    if (busyTxt.length > 0 && parseDoubleToken(busyTxt, busyVal)) {
                        g.utilization_pct = busyVal;
                    }
                    ulong uVal;
                    if (vramUsedTxt.length > 0 && parseU64Token(vramUsedTxt, uVal)) {
                        g.vram_used_bytes = uVal;
                    }
                    if (vramTotTxt.length > 0 && parseU64Token(vramTotTxt, uVal)) {
                        g.vram_total_bytes = uVal;
                    }
                    gpuBuf[outCount++] = g;
                }
            }
            r.gpus = gpuBuf[0 .. outCount];
            r.state = outCount > 0 ? CapabilityState.ok : CapabilityState.unsupported;
            return r;
        } else {
            r.state = CapabilityState.unsupported;
            return r;
        }
    }

    override RawBatteryResult sampleBatteries() {
        RawBatteryResult r;
        version (Posix) {
            PathBuf!512 psDir;
            psDir.put(sysRoot);
            psDir.put("/class/power_supply");
            DIR* dir = opendir(psDir.ptr);
            if (dir is null) {
                r.state = CapabilityState.ok;
                return r;
            }
            scope (exit) closedir(dir);

            size_t outCount = 0;
            PathBuf!512 p;
            char[64] tmpBuf = void;
            dirent* ent;
            while ((ent = readdir(dir)) !is null) {
                if (outCount >= MAX_BATTERIES) break;
                auto dname = ent.d_name[0 .. strlen(ent.d_name.ptr)];
                if (dname == "." || dname == "..") continue;

                p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/type");
                auto ptype = readStackFile(p, tmpBuf);
                if (!equalsIgnoreCase(ptype, "battery") && !startsWithAscii(dname, "BAT")) continue;

                batIdStore[outCount].set(dname);
                BatteryStatus b;
                b.id = batIdStore[outCount].slice();
                b.name = b.id;

                p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/status");
                auto st = readStackFile(p, tmpBuf);
                if (equalsIgnoreCase(st, "charging")) b.status = "charging";
                else if (equalsIgnoreCase(st, "discharging")) b.status = "discharging";
                else if (equalsIgnoreCase(st, "full")) b.status = "full";
                else if (equalsIgnoreCase(st, "not charging")) b.status = "not_charging";
                else b.status = "unknown";

                // Prefer energy_* (µWh), fall back to charge_* (µAh) * voltage_now (µV), or capacity %
                double energyNowUwh = -1, energyFullUwh = -1, energyDesignUwh = -1, powerUw = -1;
                bool hasEnergyDesignFile = false;

                p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/energy_now");
                double enVal = 0, efVal = 0;
                auto enTxt = readStackFile(p, tmpBuf);
                bool hasEn = enTxt.length > 0 && parseDoubleToken(enTxt, enVal);

                p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/energy_full");
                auto efTxt = readStackFile(p, tmpBuf);
                bool hasEf = efTxt.length > 0 && parseDoubleToken(efTxt, efVal);

                if (hasEn && hasEf) {
                    energyNowUwh = enVal;
                    energyFullUwh = efVal;
                    p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/energy_full_design");
                    auto edTxt = readStackFile(p, tmpBuf);
                    double edVal;
                    if (edTxt.length > 0) {
                        hasEnergyDesignFile = true;
                        if (parseDoubleToken(edTxt, edVal)) energyDesignUwh = edVal;
                    }
                    p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/power_now");
                    auto pnTxt = readStackFile(p, tmpBuf);
                    double pnVal;
                    if (pnTxt.length > 0 && parseDoubleToken(pnTxt, pnVal)) powerUw = pnVal;
                } else {
                    p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/charge_now");
                    double cnVal = 0, cfVal = 0, v = 0;
                    auto cnTxt = readStackFile(p, tmpBuf);
                    bool hasCn = cnTxt.length > 0 && parseDoubleToken(cnTxt, cnVal);

                    p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/charge_full");
                    auto cfTxt = readStackFile(p, tmpBuf);
                    bool hasCf = cfTxt.length > 0 && parseDoubleToken(cfTxt, cfVal);

                    p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/voltage_now");
                    auto vnTxt = readStackFile(p, tmpBuf);
                    double vnVal;
                    if (vnTxt.length > 0 && parseDoubleToken(vnTxt, vnVal)) v = vnVal / 1_000_000.0;

                    if (hasCn && hasCf) {
                        if (v > 0) {
                            energyNowUwh = cnVal * v;
                            energyFullUwh = cfVal * v;
                            p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/charge_full_design");
                            auto cdTxt = readStackFile(p, tmpBuf);
                            double cdVal;
                            if (cdTxt.length > 0 && parseDoubleToken(cdTxt, cdVal)) energyDesignUwh = cdVal * v;
                            p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/current_now");
                            auto curTxt = readStackFile(p, tmpBuf);
                            double curVal;
                            if (curTxt.length > 0 && parseDoubleToken(curTxt, curVal)) powerUw = curVal * v;
                        } else if (cfVal > 0) {
                            b.pct = (cnVal / cfVal) * 100.0;
                        }
                    }
                }

                if (energyNowUwh >= 0 && energyFullUwh > 0) {
                    b.pct = (energyNowUwh / energyFullUwh) * 100.0;
                } else if (b.pct.isNull) {
                    p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/capacity");
                    auto capTxt = readStackFile(p, tmpBuf);
                    double capVal;
                    if (capTxt.length > 0 && parseDoubleToken(capTxt, capVal)) {
                        b.pct = capVal;
                    }
                }

                if (energyFullUwh > 0 && energyDesignUwh > 0) {
                    b.health_pct = (energyFullUwh / energyDesignUwh) * 100.0;
                    if (!hasEnergyDesignFile) {
                        p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/energy_full_design");
                        hasEnergyDesignFile = readStackFile(p, tmpBuf).length > 0;
                    }
                    if (hasEnergyDesignFile) {
                        b.design_capacity_wh = energyDesignUwh / 1_000_000.0;
                        b.full_charge_capacity_wh = energyFullUwh / 1_000_000.0;
                    }
                }

                p.clear(); p.put(sysRoot); p.put("/class/power_supply/"); p.put(dname); p.put("/cycle_count");
                auto cycTxt = readStackFile(p, tmpBuf);
                ulong cycVal;
                if (cycTxt.length > 0 && parseU64Token(cycTxt, cycVal) && cycVal > 0) {
                    b.cycle_count = cycVal;
                }

                if (powerUw > 0) {
                    b.power_watts = powerUw / 1_000_000.0;
                    if (b.status == "discharging" && energyNowUwh >= 0) {
                        b.time_remaining_s = cast(long)((energyNowUwh / powerUw) * 3600.0);
                    } else if (b.status == "charging" && energyFullUwh > energyNowUwh) {
                        b.time_remaining_s = cast(long)(((energyFullUwh - energyNowUwh) / powerUw) * 3600.0);
                    }
                }

                batBuf[outCount++] = b;
            }

            r.batteries = batBuf[0 .. outCount];
            r.state = CapabilityState.ok;
            return r;
        } else {
            r.state = CapabilityState.ok;
            return r;
        }
    }

    override RawMaintenanceResult sampleMaintenance() {
        RawMaintenanceResult r;
        r.state = CapabilityState.ok;

        maintKernelStore.clear();
        maintInstalledKernelStore.clear();

        version (Posix) {
            PathBuf!512 p;
            char[128] osBuf = void;
            if (!isRealHost()) {
                p.put(procRoot);
                p.put("/sys/kernel/osrelease");
                sanitizeInto(maintKernelStore, readStackFile(p, osBuf), 128);
            }
            if (maintKernelStore.len == 0) {
                utsname u;
                if (uname(&u) == 0) {
                    const(char)[] rel = u.release[0 .. strlen(u.release.ptr)];
                    sanitizeInto(maintKernelStore, rel, 128);
                }
            }
            r.drift.running_kernel = maintKernelStore.slice();

            // Check Debian/Ubuntu /var/run/reboot-required
            p.clear();
            p.put(varRoot);
            p.put("/run/reboot-required");
            if (posixAccess(p.ptr, F_OK) == 0) {
                r.drift.reboot_required = true;
            }

            // Check /lib/modules to detect running kernel vs installed kernel drift
            auto runningKernel = maintKernelStore.slice();
            if (runningKernel.length > 0) {
                p.clear();
                p.put(libModulesRoot);
                DIR* dir = opendir(p.ptr);
                if (dir !is null) {
                    scope (exit) closedir(dir);
                    bool anyInstalled = false;
                    bool foundRunning = false;
                    PathBuf!512 subPb;
                    dirent* ent;
                    while ((ent = readdir(dir)) !is null) {
                        auto dname = ent.d_name[0 .. strlen(ent.d_name.ptr)];
                        if (dname == "." || dname == "..") continue;
                        subPb.clear();
                        subPb.put(libModulesRoot);
                        subPb.put("/");
                        subPb.put(dname);
                        stat_t st;
                        if (posixStat(subPb.ptr, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
                        if (!anyInstalled) {
                            anyInstalled = true;
                            maintInstalledKernelStore.set(dname);
                        }
                        if (dname == runningKernel) {
                            foundRunning = true;
                            break;
                        }
                    }
                    if (anyInstalled) {
                        if (!foundRunning) {
                            r.drift.installed_kernel = maintInstalledKernelStore.slice();
                            r.drift.reboot_required = true;
                        } else {
                            r.drift.installed_kernel = runningKernel;
                            if (r.drift.reboot_required.isNull) r.drift.reboot_required = false;
                        }
                    }
                }
            }

            // Check local package cache mtime without running apt/pacman/dnf or network
            static immutable string[] cacheHints = [
                "/lib/apt/periodic/update-success-stamp",
                "/cache/apt/pkgcache.bin",
                "/lib/pacman/sync",
                "/cache/libdnf5",
                "/cache/dnf",
            ];
            long nowWall = Clock.currTime.toUnixTime();
            foreach (rel; cacheHints) {
                p.clear();
                p.put(varRoot);
                p.put(rel);
                stat_t st;
                if (posixStat(p.ptr, &st) == 0) {
                    long mtime = cast(long) st.st_mtime;
                    if (nowWall >= mtime) {
                        r.drift.package_cache_age_s = nowWall - mtime;
                        break;
                    }
                }
            }
        }

        r.drift.hikari_version = AGENT_VERSION;
        if (isRealHost()) {
            r.drift.caddy_version = queryLocalCaddyVersion();
            r.drift.tailscale_version = queryLocalTailscaleVersion();
        }

        return r;
    }

    override RawHardwareResult scanHardware() {
        RawHardwareResult r;
        if (!pciIdsLoaded) {
            pciIds.loadLocalPciIdsFile();
            pciIdsLoaded = true;
        }
        scope (exit) {
            pciIds.vendors = null;
            pciIds.devices = null;
            pciIdsLoaded = false;
        }

        HardwareInventory hw;
        hw.system = readSystemInfo(hw);
        hw.board = readBoardInfo(hw);
        hw.firmware = readFirmwareInfo();
        hw.cpu = readCpuHardware();
        hw.memory = readMemoryHardware(hw);
        hw.network_adapters = readNetworkAdapters(hw);
        hw.storage_devices = readStorageDevices(hw);
        hw.graphics_adapters = readGraphicsAdapters();

        hw.capabilities["isa"] = hw.cpu.isa.usable.length > 0 ? CapabilityState.ok : CapabilityState.unavailable;
        hw.capabilities["network_adapters"] = CapabilityState.ok;
        hw.capabilities["storage_devices"] = CapabilityState.ok;
        hw.collection.status = GroupStatus.fresh;
        hw.collection.partial = (hw.memory.module_enumeration != CapabilityState.ok);

        r.state = CapabilityState.ok;
        r.inventory = hw;
        return r;
    }

    private SystemHardwareInfo readSystemInfo(ref HardwareInventory hw) {
        SystemHardwareInfo sys;
        auto dmi = sysRoot ~ "/class/dmi/id";
        if (exists(dmi)) {
            sys.manufacturer = scrubPlaceholderString(safeReadText(dmi ~ "/sys_vendor"));
            sys.model = scrubPlaceholderString(safeReadText(dmi ~ "/product_name"));
            sys.product_family = scrubPlaceholderString(safeReadText(dmi ~ "/product_family"));
            auto chassis = safeReadText(dmi ~ "/chassis_type");
            sys.form_factor = mapChassisType(chassis);
        }

        // Device-tree fallback for ARM SBCs when DMI is absent
        if (sys.model.length == 0) {
            auto dtModel = scrubPlaceholderString(safeReadText(procRoot ~ "/device-tree/model").replace("\0", ""));
            if (dtModel.length > 0) {
                sys.model = dtModel;
                if (sys.form_factor.length == 0) sys.form_factor = "sbc";
            }
        }

        auto lowVendor = (sys.manufacturer ~ " " ~ sys.model).toLower();
        if (lowVendor.canFind("qemu") || lowVendor.canFind("kvm") || lowVendor.canFind("bochs")) {
            sys.virtualization = "kvm";
            sys.form_factor = "vm";
        } else if (lowVendor.canFind("vmware")) {
            sys.virtualization = "vmware";
            sys.form_factor = "vm";
        } else if (lowVendor.canFind("virtualbox") || lowVendor.canFind("innotek")) {
            sys.virtualization = "virtualbox";
            sys.form_factor = "vm";
        } else if (lowVendor.canFind("microsoft corporation") && lowVendor.canFind("virtual")) {
            sys.virtualization = "hyper-v";
            sys.form_factor = "vm";
        } else if (readCpuinfoFlags().canFind("hypervisor")) {
            sys.virtualization = "vm";
            if (sys.form_factor.length == 0) sys.form_factor = "vm";
        }
        cast(void) hw;
        return sys;
    }

    private static string mapChassisType(string codeTxt) pure @safe {
        switch (codeTxt.strip()) {
            case "3": case "4": case "5": case "6": case "7": case "15": case "35":
                return "desktop";
            case "8": case "9": case "10": case "11": case "14": case "30": case "31": case "32":
                return "laptop";
            case "17": case "23": case "25": case "28": case "29":
                return "server";
            default:
                return "";
        }
    }

    private BoardHardwareInfo readBoardInfo(ref HardwareInventory hw) {
        BoardHardwareInfo brd;
        auto dmi = sysRoot ~ "/class/dmi/id";
        if (!exists(dmi)) {
            hw.capabilities["board"] = CapabilityState.unsupported;
            return brd;
        }
        brd.manufacturer = scrubPlaceholderString(safeReadText(dmi ~ "/board_vendor"));
        brd.model = scrubPlaceholderString(safeReadText(dmi ~ "/board_name"));
        brd.revision = scrubPlaceholderString(safeReadText(dmi ~ "/board_version"));
        hw.capabilities["board"] = (brd.manufacturer.length > 0 || brd.model.length > 0)
            ? CapabilityState.ok
            : CapabilityState.unavailable;
        return brd;
    }

    private FirmwareHardwareInfo readFirmwareInfo() {
        FirmwareHardwareInfo fw;
        auto dmi = sysRoot ~ "/class/dmi/id";
        if (exists(sysRoot ~ "/firmware/efi")) {
            fw.type = "UEFI";
        } else if (exists(dmi ~ "/bios_version")) {
            fw.type = "BIOS";
        } else if (exists(procRoot ~ "/device-tree")) {
            fw.type = "DeviceTree";
        }
        if (exists(dmi)) {
            fw.vendor = scrubPlaceholderString(safeReadText(dmi ~ "/bios_vendor"));
            fw.version_str = scrubPlaceholderString(safeReadText(dmi ~ "/bios_version"));
            fw.release_date = scrubPlaceholderString(safeReadText(dmi ~ "/bios_date"));
        }
        return fw;
    }

    private CpuHardwareInfo readCpuHardware() {
        CpuHardwareInfo cpu;
        cpu.architecture = detectArch();
        auto ci = safeReadText(procRoot ~ "/cpuinfo");

        string modelName;
        string vendorId;
        uint procCount = 0;
        foreach (line; ci.split('\n')) {
            auto colon = line.indexOf(':');
            if (colon <= 0) continue;
            auto k = line[0 .. colon].strip().toLower();
            auto v = sanitizeOsString(line[colon + 1 .. $].strip(), 160);
            if (k == "processor") procCount++;
            else if (k == "model name" && modelName.length == 0) modelName = v;
            else if (k == "hardware" && modelName.length == 0) modelName = v;
            else if (k == "vendor_id" && vendorId.length == 0) vendorId = v;
            else if (k == "cpu implementer" && vendorId.length == 0) vendorId = v;
        }

        if (vendorId == "AuthenticAMD") cpu.vendor = "AMD";
        else if (vendorId == "GenuineIntel") cpu.vendor = "Intel";
        else if (vendorId == "0x41" || cpu.architecture == "aarch64") cpu.vendor = "ARM";
        else cpu.vendor = vendorId;

        cpu.display_name = modelName.length > 0 ? modelName : (cpu.vendor.length > 0 ? cpu.vendor ~ " " ~ cpu.architecture : cpu.architecture);
        if (procCount > 0) cpu.logical_cores = procCount;

        // Topology from /sys/devices/system/cpu/cpu*/topology
        auto cpuSysDir = sysRoot ~ "/devices/system/cpu";
        if (exists(cpuSysDir)) {
            bool[string] pkgSet;
            bool[string] coreSet;
            uint sysLogical = 0;
            try {
                foreach (DirEntry de; dirEntries(cpuSysDir, SpanMode.shallow)) {
                    auto bn = baseName(de.name);
                    if (!bn.startsWith("cpu") || bn.length < 4 || bn[3] < '0' || bn[3] > '9') continue;
                    sysLogical++;
                    auto pkg = safeReadText(de.name ~ "/topology/physical_package_id");
                    auto cid = safeReadText(de.name ~ "/topology/core_id");
                    if (pkg.length > 0) pkgSet[pkg] = true;
                    if (cid.length > 0) coreSet[(pkg.length > 0 ? pkg : "0") ~ ":" ~ cid] = true;
                }
            } catch (Exception) {}

            if (sysLogical > 0) cpu.logical_cores = sysLogical;
            if (pkgSet.length > 0) cpu.sockets = cast(uint) pkgSet.length;
            if (coreSet.length > 0) cpu.physical_cores = cast(uint) coreSet.length;

            // Heterogenous P/E core layout if exposed (Intel hybrid / ARM big.LITTLE)
            auto pMask = safeReadText(cpuSysDir ~ "/cpu_core/cpus");
            auto eMask = safeReadText(cpuSysDir ~ "/cpu_atom/cpus");
            if (pMask.length > 0 && eMask.length > 0) {
                cpu.performance_cores = countCpuList(pMask);
                cpu.efficiency_cores = countCpuList(eMask);
            }

            // Cache sizes from cpu0/cache/index*
            auto cacheDir = cpuSysDir ~ "/cpu0/cache";
            if (exists(cacheDir)) {
                try {
                    foreach (DirEntry de; dirEntries(cacheDir, SpanMode.shallow)) {
                        if (!baseName(de.name).startsWith("index")) continue;
                        auto lvl = safeReadText(de.name ~ "/level");
                        auto ctype = safeReadText(de.name ~ "/type").toLower();
                        auto sz = parseCacheSize(safeReadText(de.name ~ "/size"));
                        if (sz == 0) continue;
                        if (lvl == "1" && ctype == "data") cpu.cache_bytes.l1d = sz;
                        else if (lvl == "1" && ctype == "instruction") cpu.cache_bytes.l1i = sz;
                        else if (lvl == "2") cpu.cache_bytes.l2 = sz;
                        else if (lvl == "3") cpu.cache_bytes.l3 = sz;
                    }
                } catch (Exception) {}
            }
        }

        // ISA capabilities
        auto procFlags = readCpuinfoFlags();
        if (cpu.architecture == "x86_64") {
            if (isRealHost()) {
                cpu.isa = detectHostX86Isa();
            } else {
                cpu.isa.hardware = normalizeIsaList(procFlags);
                cpu.isa.usable = cpu.isa.hardware.dup;
                cpu.isa.detection = "proc_cpuinfo_fixture";
            }
        } else if (cpu.architecture == "aarch64") {
            if (isRealHost()) {
                cpu.isa = detectHostArm64Isa(procFlags);
            } else {
                cpu.isa.hardware = normalizeIsaList(procFlags);
                cpu.isa.usable = cpu.isa.hardware.dup;
                cpu.isa.detection = "proc_cpuinfo_fixture";
            }
        } else {
            cpu.isa.hardware = normalizeIsaList(procFlags);
            cpu.isa.usable = cpu.isa.hardware.dup;
            cpu.isa.detection = "proc_cpuinfo";
        }

        return cpu;
    }

    private static uint countCpuList(string listSpec) pure @safe {
        uint count = 0;
        foreach (part; listSpec.strip().split(',')) {
            auto p = part.strip();
            auto dash = p.indexOf('-');
            if (dash > 0) {
                try {
                    uint lo = to!uint(p[0 .. dash]);
                    uint hi = to!uint(p[dash + 1 .. $]);
                    if (hi >= lo) count += (hi - lo + 1);
                } catch (Exception) {}
            } else if (p.length > 0) {
                count++;
            }
        }
        return count;
    }

    private static ulong parseCacheSize(string s) pure @safe {
        auto t = s.strip().toLower();
        if (t.length == 0) return 0;
        ulong mult = 1;
        if (t.endsWith("k")) { mult = 1024; t = t[0 .. $ - 1]; }
        else if (t.endsWith("m")) { mult = 1024 * 1024; t = t[0 .. $ - 1]; }
        try {
            return to!ulong(t) * mult;
        } catch (Exception) {
            return 0;
        }
    }

    private MemoryHardwareInfo readMemoryHardware(ref HardwareInventory hw) {
        MemoryHardwareInfo mem;
        auto rawMem = sampleMemory();
        mem.total_bytes = rawMem.total_bytes;

        auto dmiTable = sysRoot ~ "/firmware/dmi/tables/DMI";
        if (!exists(dmiTable)) {
            mem.module_enumeration = CapabilityState.unavailable;
            hw.capabilities["memory_modules"] = CapabilityState.unavailable;
            return mem;
        }

        try {
            auto bytes = cast(const(ubyte)[]) read(dmiTable);
            mem.modules = parseSmbiosMemoryModules(bytes);
            if (mem.modules.length > 0) {
                mem.module_enumeration = CapabilityState.ok;
                hw.capabilities["memory_modules"] = CapabilityState.ok;
                foreach (mod; mem.modules) {
                    if (mem.technology.length == 0 && mod.technology.length > 0) mem.technology = mod.technology;
                    if (mem.speed_mt_s.isNull && !mod.speed_mt_s.isNull) mem.speed_mt_s = mod.speed_mt_s;
                }
            } else {
                mem.module_enumeration = CapabilityState.unavailable;
                hw.capabilities["memory_modules"] = CapabilityState.unavailable;
            }
        } catch (Exception) {
            mem.module_enumeration = CapabilityState.permission_denied;
            hw.capabilities["memory_modules"] = CapabilityState.permission_denied;
        }
        return mem;
    }

    static MemoryModuleInfo[] parseSmbiosMemoryModules(const(ubyte)[] data) {
        return parseSmbiosTables(data).memoryModules;
    }

    private NetworkAdapterHardware[] readNetworkAdapters(ref HardwareInventory hw) {
        NetworkAdapterHardware[] outNics;
        auto netDir = sysRoot ~ "/class/net";
        if (!exists(netDir)) return outNics;

        try {
            foreach (DirEntry de; dirEntries(netDir, SpanMode.shallow)) {
                auto ifName = baseName(de.name);
                if (ifName == "lo") continue;

                NetworkAdapterHardware na;
                na.interface_name = ifName;
                auto dynKind = classifyNetKind(ifName);
                na.kind = (dynKind == "physical") ? "ethernet" : dynKind;

                auto devPath = de.name ~ "/device";
                if (exists(devPath)) {
                    auto vend = PciIdLookup.normalizeHex4(safeReadText(devPath ~ "/vendor"));
                    auto dev = PciIdLookup.normalizeHex4(safeReadText(devPath ~ "/device"));
                    na.vendor_id = vend;
                    na.device_id = dev;

                    // Resolve PCI slot ID and driver via symlinks
                    try {
                        auto drvTarget = safeReadLink(devPath ~ "/driver");
                        na.driver = baseName(drvTarget);
                    } catch (Exception) {}

                    try {
                        auto devTarget = safeReadLink(devPath);
                        auto slot = baseName(devTarget);
                        if (slot.canFind(':')) {
                            na.bus = "pci";
                            na.id = "pci:" ~ slot;
                        }
                    } catch (Exception) {}

                    if (na.bus.length == 0) {
                        auto uevent = safeReadText(devPath ~ "/uevent");
                        if (uevent.canFind("PCI_SLOT_NAME=")) {
                            na.bus = "pci";
                            foreach (l; uevent.split('\n')) {
                                if (l.startsWith("PCI_SLOT_NAME=")) {
                                    na.id = "pci:" ~ l[14 .. $].strip();
                                } else if (l.startsWith("DRIVER=") && na.driver.length == 0) {
                                    na.driver = l[7 .. $].strip();
                                }
                            }
                        }
                    }

                    auto resolved = pciIds.resolveDevice(vend, dev);
                    if (resolved.length > 0) {
                        na.display_name = resolved;
                    } else {
                        auto vname = pciIds.resolveVendor(vend);
                        if (vname.length > 0 && dev.length > 0) {
                            na.display_name = vname ~ " (" ~ vend ~ ":" ~ dev ~ ")";
                        } else if (na.driver.length > 0) {
                            na.display_name = ifName ~ " (" ~ na.driver ~ ")";
                        } else {
                            na.display_name = ifName;
                        }
                    }
                } else {
                    na.bus = "virtual";
                    na.display_name = na.kind == "tailnet" ? ("Tailscale Tunnel (" ~ ifName ~ ")") : ("Virtual Adapter (" ~ ifName ~ ")");
                }

                if (na.id.length == 0) {
                    auto idx = safeReadText(de.name ~ "/ifindex");
                    na.id = idx.length > 0 ? ("ifindex:" ~ idx) : ("net:" ~ ifName);
                }

                auto spd = safeReadText(de.name ~ "/speed");
                if (spd.length > 0) {
                    try {
                        long mbps = to!long(spd);
                        if (mbps > 0 && mbps < 1_000_000) na.link_speed_bps = cast(ulong) mbps * 1_000_000UL;
                    } catch (Exception) {}
                }

                if (exposeMacAddresses) {
                    na.mac_address = safeReadText(de.name ~ "/address");
                }

                outNics ~= na;
            }
        } catch (Exception) {}
        cast(void) hw;
        return outNics;
    }

    private StorageDeviceHardware[] readStorageDevices(ref HardwareInventory hw) {
        StorageDeviceHardware[] outStor;
        auto blkDir = sysRoot ~ "/block";
        if (!exists(blkDir)) return outStor;

        auto mounts = sampleFilesystems().mounts;

        try {
            foreach (DirEntry de; dirEntries(blkDir, SpanMode.shallow)) {
                auto devName = baseName(de.name);
                if (devName.startsWith("loop") || devName.startsWith("ram") || devName.startsWith("zram") || devName.startsWith("dm-")) {
                    continue;
                }
                auto sizeTxt = safeReadText(de.name ~ "/size");
                if (sizeTxt.length == 0) continue;
                ulong sectors = 0;
                try { sectors = to!ulong(sizeTxt); } catch (Exception) {}
                if (sectors == 0) continue;

                StorageDeviceHardware sd;
                sd.capacity_bytes = sectors * 512UL;

                if (devName.startsWith("nvme")) sd.bus = "nvme";
                else if (devName.startsWith("mmcblk")) sd.bus = "mmc";
                else if (devName.startsWith("vd")) sd.bus = "virtio";
                else {
                    try {
                        auto target = safeReadLink(de.name);
                        if (target.canFind("/usb")) sd.bus = "usb";
                        else sd.bus = "sata";
                    } catch (Exception) {
                        sd.bus = "sata";
                    }
                }
                sd.id = sd.bus ~ ":" ~ devName;

                auto rot = safeReadText(de.name ~ "/queue/rotational");
                if (sd.bus == "nvme") sd.media_type = "ssd";
                else if (rot == "0") sd.media_type = "ssd";
                else if (rot == "1") sd.media_type = "hdd";
                else sd.media_type = "unknown";

                auto model = sanitizeOsString(safeReadText(de.name ~ "/device/model"), 128);
                auto vendor = sanitizeOsString(safeReadText(de.name ~ "/device/vendor"), 64);
                if (model.length > 0 && vendor.length > 0 && !model.toLower().startsWith(vendor.toLower())) {
                    sd.display_name = vendor ~ " " ~ model;
                } else if (model.length > 0) {
                    sd.display_name = model;
                } else {
                    sd.display_name = devName;
                }

                // Map partitions / mounts belonging to this physical device
                foreach (m; mounts) {
                    auto srcBase = baseName(m.source);
                    if (srcBase == devName || srcBase.startsWith(devName ~ "p") || srcBase.startsWith(devName)) {
                        if (!sd.mounts.canFind(m.mount)) sd.mounts ~= m.mount;
                    } else if (srcBase.startsWith("dm-") || m.source.startsWith("/dev/mapper/")) {
                        // Check dm-* slaves if available
                        try {
                            foreach (DirEntry dm; dirEntries(blkDir, SpanMode.shallow)) {
                                auto dmn = baseName(dm.name);
                                if (!dmn.startsWith("dm-")) continue;
                                if (exists(dm.name ~ "/slaves/" ~ devName) || exists(dm.name ~ "/slaves/" ~ devName ~ "p1") || exists(dm.name ~ "/slaves/" ~ devName ~ "p2")) {
                                    // Best-effort dm correlation when single backing disk
                                    if (!sd.mounts.canFind(m.mount)) sd.mounts ~= m.mount;
                                }
                            }
                        } catch (Exception) {}
                    }
                }

                outStor ~= sd;
            }
        } catch (Exception) {}
        cast(void) hw;
        return outStor;
    }

    private GraphicsAdapterHardware[] readGraphicsAdapters() {
        GraphicsAdapterHardware[] outGpus;
        auto pciDir = sysRoot ~ "/bus/pci/devices";
        if (!exists(pciDir)) return outGpus;

        try {
            foreach (DirEntry de; dirEntries(pciDir, SpanMode.shallow)) {
                auto cls = safeReadText(de.name ~ "/class").toLower();
                if (!cls.startsWith("0x03")) continue; // Display controller PCI class 0x03xx

                GraphicsAdapterHardware ga;
                ga.id = "pci:" ~ baseName(de.name);
                ga.vendor_id = PciIdLookup.normalizeHex4(safeReadText(de.name ~ "/vendor"));
                ga.device_id = PciIdLookup.normalizeHex4(safeReadText(de.name ~ "/device"));
                ga.vendor = pciIds.resolveVendor(ga.vendor_id);
                if (ga.vendor_id == "10de") ga.vendor = "NVIDIA";
                else if (ga.vendor_id == "1002") ga.vendor = "AMD";
                else if (ga.vendor_id == "8086") ga.vendor = "Intel";

                try {
                    ga.driver = baseName(safeReadLink(de.name ~ "/driver"));
                } catch (Exception) {}

                auto devName = pciIds.resolveDevice(ga.vendor_id, ga.device_id);
                if (devName.length > 0) {
                    ga.display_name = devName;
                } else {
                    ga.display_name = (ga.vendor.length > 0 ? ga.vendor : "Graphics Adapter") ~ " [" ~ ga.vendor_id ~ ":" ~ ga.device_id ~ "]";
                }

                auto vramTxt = safeReadText(de.name ~ "/mem_info_vram_total");
                if (vramTxt.length > 0) {
                    try { ga.memory_total_bytes = to!ulong(vramTxt); } catch (Exception) {}
                }

                outGpus ~= ga;
            }
        } catch (Exception) {}
        return outGpus;
    }
}
