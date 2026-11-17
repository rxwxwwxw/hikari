module platform.linux;

import core.model;
import core.serializer : sanitizeOsString;
import hardware.inventory;
import hardware.isa_names;
import platform.api;
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
    import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
    import core.sys.posix.sys.utsname : uname, utsname;
    import core.sys.posix.unistd : _SC_CLK_TCK, _SC_PAGESIZE, sysconf;
}

alias StatvfsFn = bool delegate(string mountPath, out ulong totalBytes, out ulong usedBytes);

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
    }

    private bool isRealHost() const pure nothrow @safe {
        return procRoot == "/proc" && sysRoot == "/sys";
    }

    private string safeReadText(string path) const {
        if (!exists(path)) return "";
        try {
            return readText(path).strip();
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
        if (!isRealHost()) {
            auto ci = safeReadText(procRoot ~ "/cpuinfo").toLower();
            if (ci.canFind("aarch64") || ci.canFind("cortex-") || ci.canFind("asimd") || ci.canFind("cpu architecture: 8")) {
                return "aarch64";
            }
            if (ci.canFind("x86_64") || ci.canFind("lm ") || ci.canFind("authenticamd") || ci.canFind("genuineintel")) {
                return "x86_64";
            }
        }
        version (Posix) {
            utsname u;
            if (uname(&u) == 0) {
                import std.string : fromStringz;
                auto m = fromStringz(u.machine.ptr).idup;
                if (m == "arm64") return "aarch64";
                if (m.length > 0) return m;
            }
        }
        version (X86_64) return "x86_64";
        else version (AArch64) return "aarch64";
        else return "unknown";
    }

    override PlatformIdentity identity() {
        PlatformIdentity id;
        id.os = "linux";
        id.arch = detectArch();

        if (!isRealHost()) {
            id.host = sanitizeOsString(safeReadText(procRoot ~ "/sys/kernel/hostname"), 128);
        }
        if (id.host.length == 0) {
            version (Posix) {
                utsname u;
                if (uname(&u) == 0) {
                    import std.string : fromStringz;
                    id.host = sanitizeOsString(fromStringz(u.nodename.ptr).idup, 128);
                }
            }
        }
        if (id.host.length == 0) id.host = "linux-host";

        id.boot_id = sanitizeOsString(safeReadText(procRoot ~ "/sys/kernel/random/boot_id"), 128);
        if (id.boot_id.length == 0) id.boot_id = "unknown-boot";

        auto upTxt = safeReadText(procRoot ~ "/uptime");
        if (upTxt.length > 0) {
            auto parts = upTxt.split();
            if (parts.length >= 1) {
                try {
                    id.uptime_s = cast(long) to!double(parts[0]);
                } catch (Exception) {}
            }
        }
        return id;
    }

    override RawCpu sampleCpu() {
        RawCpu c;
        auto statTxt = safeReadText(procRoot ~ "/stat");
        if (statTxt.length == 0) {
            c.state = CapabilityState.error;
            c.error = "proc_stat_unreadable";
            return c;
        }

        bool foundAgg = false;
        uint cores = 0;
        foreach (line; statTxt.split('\n')) {
            auto s = line.strip();
            if (s.startsWith("cpu ")) {
                auto parts = s.split();
                if (parts.length >= 5) {
                    ulong[10] vals;
                    size_t n = parts.length - 1;
                    if (n > 8) n = 8; // user, nice, system, idle, iowait, irq, softirq, steal (exclude guest/guest_nice already in user/nice)
                    foreach (i; 0 .. n) {
                        try {
                            vals[i] = to!ulong(parts[i + 1]);
                        } catch (Exception) {
                            vals[i] = 0;
                        }
                    }
                    ulong total = 0;
                    foreach (i; 0 .. n) total += vals[i];
                    ulong idle = vals[3] + (n > 4 ? vals[4] : 0);
                    c.total_ticks = total;
                    c.idle_ticks = idle;
                    foundAgg = true;
                }
            } else if (s.startsWith("cpu") && s.length > 3 && s[3] >= '0' && s[3] <= '9') {
                cores++;
            }
        }

        if (!foundAgg) {
            c.state = CapabilityState.error;
            c.error = "proc_stat_missing_cpu_line";
            return c;
        }
        c.logical_cores = cores > 0 ? cores : 1;

        auto loadTxt = safeReadText(procRoot ~ "/loadavg");
        if (loadTxt.length > 0) {
            auto parts = loadTxt.split();
            if (parts.length >= 1) {
                try {
                    c.load_1m = to!double(parts[0]);
                } catch (Exception) {}
            }
        }

        c.temp_c = sampleCpuTemp();
        c.state = CapabilityState.ok;
        return c;
    }

    private Nullable!double sampleCpuTemp() const {
        Nullable!double res;
        auto hwmonDir = sysRoot ~ "/class/hwmon";
        if (!exists(hwmonDir)) return res;

        static immutable string[] preferredNames = ["k10temp", "zenpower", "coretemp", "cpu_thermal", "soc_thermal", "x86_pkg_temp"];
        try {
            foreach (DirEntry de; dirEntries(hwmonDir, SpanMode.shallow)) {
                auto name = safeReadText(de.name ~ "/name").toLower();
                if (!preferredNames.canFind(name)) continue;

                // Look for temp1_input or preferred package/Tdie/Tctl label
                foreach (idx; 1 .. 6) {
                    auto tempPath = de.name ~ "/temp" ~ to!string(idx) ~ "_input";
                    auto raw = safeReadText(tempPath);
                    if (raw.length == 0) continue;
                    try {
                        long milli = to!long(raw);
                        if (milli > -40_000 && milli < 150_000) {
                            res = cast(double) milli / 1000.0;
                            return res;
                        }
                    } catch (Exception) {}
                }
            }
        } catch (Exception) {}
        return res;
    }

    override RawMemory sampleMemory() {
        RawMemory m;
        auto txt = safeReadText(procRoot ~ "/meminfo");
        if (txt.length == 0) {
            m.state = CapabilityState.error;
            m.error = "proc_meminfo_unreadable";
            return m;
        }

        ulong[string] kb;
        foreach (line; txt.split('\n')) {
            auto colon = line.indexOf(':');
            if (colon <= 0) continue;
            auto key = line[0 .. colon].strip();
            auto rest = line[colon + 1 .. $].strip().split();
            if (rest.length == 0) continue;
            try {
                kb[key] = to!ulong(rest[0]);
            } catch (Exception) {}
        }

        if (auto pt = "MemTotal" in kb) {
            ulong total = (*pt) * 1024UL;
            m.total_bytes = total;
            if (auto pa = "MemAvailable" in kb) {
                ulong avail = (*pa) * 1024UL;
                m.used_bytes = total > avail ? (total - avail) : 0;
            } else {
                ulong freeB = (("MemFree" in kb) ? kb["MemFree"] : 0) * 1024UL;
                ulong bufB = (("Buffers" in kb) ? kb["Buffers"] : 0) * 1024UL;
                ulong cacheB = (("Cached" in kb) ? kb["Cached"] : 0) * 1024UL;
                ulong freeTotal = freeB + bufB + cacheB;
                m.used_bytes = total > freeTotal ? (total - freeTotal) : 0;
            }
        } else {
            m.state = CapabilityState.error;
            m.error = "proc_meminfo_missing_total";
            return m;
        }

        if (auto pst = "SwapTotal" in kb) {
            ulong swTotal = (*pst) * 1024UL;
            m.swap_total_bytes = swTotal;
            ulong swFree = (("SwapFree" in kb) ? kb["SwapFree"] : 0) * 1024UL;
            m.swap_used_bytes = swTotal > swFree ? (swTotal - swFree) : 0;
        }

        m.state = CapabilityState.ok;
        return m;
    }

    private string classifyNetKind(string ifName) const {
        if (ifName == "lo") return "loopback";
        if (ifName.startsWith("tailscale") || ifName.startsWith("ts")) return "tailnet";
        auto netPath = sysRoot ~ "/class/net/" ~ ifName;
        if (exists(netPath ~ "/wireless") || exists(netPath ~ "/phy80211") || ifName.startsWith("wl")) {
            return "wireless";
        }
        if (exists(netPath ~ "/tun_flags") || ifName.startsWith("veth") || ifName.startsWith("docker")
            || ifName.startsWith("br-") || ifName.startsWith("virbr") || ifName.startsWith("tun")
            || ifName.startsWith("tap") || ifName.startsWith("wg")) {
            return "virtual";
        }
        if (exists(netPath ~ "/device")) {
            return "physical";
        }
        return "virtual";
    }

    override RawNetworkResult sampleNetwork() {
        RawNetworkResult r;
        auto txt = safeReadText(procRoot ~ "/net/dev");
        if (txt.length == 0) {
            r.state = CapabilityState.error;
            r.error = "proc_net_dev_unreadable";
            return r;
        }

        foreach (line; txt.split('\n')) {
            auto colon = line.indexOf(':');
            if (colon <= 0) continue;
            auto ifName = sanitizeOsString(line[0 .. colon].strip(), 64);
            if (ifName.length == 0 || ifName == "lo") continue;

            auto cols = line[colon + 1 .. $].strip().split();
            if (cols.length < 10) continue;

            RawNetworkInterface ni;
            ni.name = ifName;
            ni.kind = classifyNetKind(ifName);

            auto ifIndexTxt = safeReadText(sysRoot ~ "/class/net/" ~ ifName ~ "/ifindex");
            ni.id = ifIndexTxt.length > 0 ? ("ifindex:" ~ ifIndexTxt) : ("name:" ~ ifName);

            try {
                ni.rx_bytes = to!ulong(cols[0]);
                ni.tx_bytes = to!ulong(cols[8]);
            } catch (Exception) {
                continue;
            }

            auto oper = safeReadText(sysRoot ~ "/class/net/" ~ ifName ~ "/operstate").toLower();
            if (oper.length > 0) {
                ni.link_up = (oper == "up" || oper == "unknown");
            }
            auto spd = safeReadText(sysRoot ~ "/class/net/" ~ ifName ~ "/speed");
            if (spd.length > 0) {
                try {
                    long mbps = to!long(spd);
                    if (mbps > 0 && mbps < 1_000_000) {
                        ni.link_speed_bps = cast(ulong) mbps * 1_000_000UL;
                    }
                } catch (Exception) {}
            }

            r.interfaces ~= ni;
        }

        r.state = CapabilityState.ok;
        return r;
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

        long pageSize = 4096;
        version (Posix) {
            long ps = sysconf(_SC_PAGESIZE);
            if (ps > 0) pageSize = ps;
        }

        try {
            foreach (DirEntry de; dirEntries(procRoot, SpanMode.shallow)) {
                auto name = baseName(de.name);
                if (name.length == 0 || name[0] < '0' || name[0] > '9') continue;
                uint pid;
                try {
                    pid = to!uint(name);
                } catch (Exception) {
                    continue;
                }

                // Never read /cmdline or /environ
                auto statTxt = safeReadText(de.name ~ "/stat");
                if (statTxt.length == 0) continue;

                auto openParen = statTxt.indexOf('(');
                auto closeParen = statTxt.lastIndexOf(')');
                if (openParen < 0 || closeParen <= openParen || closeParen + 2 >= statTxt.length) continue;

                auto comm = sanitizeOsString(statTxt[openParen + 1 .. closeParen], 128);
                auto fields = statTxt[closeParen + 2 .. $].strip().split();
                if (fields.length <= 21) continue;

                try {
                    ulong utime = to!ulong(fields[11]);
                    ulong stime = to!ulong(fields[12]);
                    string startId = fields[19];
                    ulong rssPages = to!ulong(fields[21]);

                    RawProcess rp;
                    rp.pid = pid;
                    rp.start_id = startId;
                    rp.name = comm;
                    rp.cpu_ticks = utime + stime;
                    rp.rss_bytes = rssPages * cast(ulong) pageSize;
                    rp.memory_kind = "rss";
                    r.processes ~= rp;
                } catch (Exception) {
                    continue;
                }
            }
        } catch (Exception) {
            r.state = CapabilityState.error;
            r.error = "proc_enumeration_failed";
            return r;
        }

        r.state = CapabilityState.ok;
        return r;
    }

    static string unescapeMountPath(string raw) pure @safe {
        auto s = raw.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\");
        return sanitizeOsString(s, 512);
    }

    private static bool isIgnoredFsType(string fsType) pure @safe {
        static immutable string[] ignored = [
            "proc", "sysfs", "tmpfs", "devtmpfs", "devpts", "cgroup", "cgroup2",
            "pstore", "bpf", "tracefs", "debugfs", "securityfs", "configfs",
            "fusectl", "hugetlbfs", "mqueue", "ramfs", "autofs", "overlay",
            "squashfs", "nsfs", "efivarfs", "rpc_pipefs", "binfmt_misc",
            "fuse.portal", "fuse.gvfsd-fuse", "selinuxfs",
        ];
        return ignored.canFind(fsType.toLower());
    }

    private static bool isNetworkFsType(string fsType) pure @safe {
        static immutable string[] netFs = [
            "nfs", "nfs4", "cifs", "smb3", "smbfs", "sshfs", "fuse.sshfs", "9p", "ceph", "glusterfs", "lustre",
        ];
        return netFs.canFind(fsType.toLower());
    }

    private struct ParsedMount {
        string dedupKey;
        string mountPoint;
        string source;
        string fsType;
    }

    private ParsedMount[] parseMounts() const {
        ParsedMount[] list;
        auto miTxt = safeReadText(procRoot ~ "/self/mountinfo");
        if (miTxt.length > 0) {
            bool[string] seenKey;
            foreach (line; miTxt.split('\n')) {
                auto s = line.strip();
                if (s.length == 0) continue;
                auto sep = s.indexOf(" - ");
                if (sep <= 0) continue;
                auto left = s[0 .. sep].split();
                auto right = s[sep + 3 .. $].split();
                if (left.length < 5 || right.length < 2) continue;

                string devId = left[2];
                string fsRoot = left[3];
                string mountPt = unescapeMountPath(left[4]);
                string fsType = right[0];
                string source = unescapeMountPath(right[1]);

                if (isIgnoredFsType(fsType) || isNetworkFsType(fsType)) continue;
                if (mountPt.startsWith("/sys") || mountPt.startsWith("/proc") || mountPt.startsWith("/dev") || mountPt.startsWith("/run/")) continue;

                // Deduplicate identical bind mounts of the same device+subroot while keeping distinct Btrfs subvolumes!
                auto key = devId ~ ":" ~ fsRoot;
                if (key in seenKey) continue;
                seenKey[key] = true;

                list ~= ParsedMount(key, mountPt, source, fsType);
            }
            return list;
        }

        auto mountsTxt = safeReadText(procRoot ~ "/mounts");
        if (mountsTxt.length > 0) {
            bool[string] seen;
            foreach (line; mountsTxt.split('\n')) {
                auto cols = line.strip().split();
                if (cols.length < 3) continue;
                string source = unescapeMountPath(cols[0]);
                string mountPt = unescapeMountPath(cols[1]);
                string fsType = cols[2];
                if (isIgnoredFsType(fsType) || isNetworkFsType(fsType)) continue;
                if (mountPt in seen) continue;
                seen[mountPt] = true;
                list ~= ParsedMount(source ~ ":" ~ mountPt, mountPt, source, fsType);
            }
        }
        return list;
    }

    private bool queryMountStats(string mountPoint, out ulong totalBytes, out ulong usedBytes) const {
        if (statvfsHook !is null) {
            return statvfsHook(mountPoint, totalBytes, usedBytes);
        }
        version (Posix) {
            import std.string : toStringz;
            statvfs_t sv;
            if (statvfs(mountPoint.toStringz(), &sv) != 0) return false;
            ulong frsize = sv.f_frsize > 0 ? sv.f_frsize : sv.f_bsize;
            totalBytes = cast(ulong) sv.f_blocks * frsize;
            ulong freeAvail = cast(ulong) sv.f_bavail * frsize;
            ulong freeTotal = cast(ulong) sv.f_bfree * frsize;
            usedBytes = totalBytes > freeTotal ? (totalBytes - freeTotal) : 0;
            // Use f_blocks - f_bfree + f_bavail for accurate user-visible capacity percentage denominator if desired,
            // or totalBytes with usedBytes = totalBytes - freeTotal:
            cast(void) freeAvail;
            return totalBytes > 0;
        } else {
            return false;
        }
    }

    override RawFilesystemResult sampleFilesystems() {
        RawFilesystemResult r;
        auto parsed = parseMounts();
        if (parsed.length == 0 && !exists(procRoot ~ "/self/mountinfo") && !exists(procRoot ~ "/mounts")) {
            r.state = CapabilityState.error;
            r.error = "mountinfo_unreadable";
            return r;
        }

        foreach (pm; parsed) {
            ulong totalB = 0, usedB = 0;
            if (!queryMountStats(pm.mountPoint, totalB, usedB)) continue;
            MountStatus ms;
            ms.mount = pm.mountPoint;
            ms.source = pm.source;
            ms.fs = pm.fsType;
            ms.total_bytes = totalB;
            ms.used_bytes = usedB;
            ms.pct = totalB > 0 ? (cast(double) usedB / cast(double) totalB) * 100.0 : 0.0;
            r.mounts ~= ms;
        }

        r.state = CapabilityState.ok;
        return r;
    }

    override RawGpuResult sampleGpus() {
        if (isRealHost()) {
            auto nvRes = nvml.sample();
            if (nvRes.state == CapabilityState.ok) return nvRes;
        }

        RawGpuResult r;
        auto drmDir = sysRoot ~ "/class/drm";
        if (exists(drmDir)) {
            try {
                foreach (DirEntry de; dirEntries(drmDir, SpanMode.shallow)) {
                    auto name = baseName(de.name);
                    if (!name.startsWith("card") || name.canFind('-')) continue;
                    auto devDir = de.name ~ "/device";
                    auto busyTxt = safeReadText(devDir ~ "/gpu_busy_percent");
                    auto vramUsedTxt = safeReadText(devDir ~ "/mem_info_vram_used");
                    auto vramTotTxt = safeReadText(devDir ~ "/mem_info_vram_total");
                    if (busyTxt.length == 0 && vramUsedTxt.length == 0) continue;

                    GpuDynamicStatus g;
                    g.id = "drm:" ~ name;
                    auto vendorHex = safeReadText(devDir ~ "/vendor");
                    g.vendor = vendorHex == "0x1002" ? "AMD" : (vendorHex == "0x8086" ? "Intel" : "GPU");
                    g.display_name = g.vendor ~ " (" ~ name ~ ")";
                    g.capability = CapabilityState.ok;

                    if (busyTxt.length > 0) {
                        try { g.utilization_pct = to!double(busyTxt); } catch (Exception) {}
                    }
                    if (vramUsedTxt.length > 0) {
                        try { g.vram_used_bytes = to!ulong(vramUsedTxt); } catch (Exception) {}
                    }
                    if (vramTotTxt.length > 0) {
                        try { g.vram_total_bytes = to!ulong(vramTotTxt); } catch (Exception) {}
                    }
                    r.gpus ~= g;
                }
            } catch (Exception) {}
        }

        r.state = r.gpus.length > 0 ? CapabilityState.ok : CapabilityState.unsupported;
        return r;
    }

    override RawBatteryResult sampleBatteries() {
        RawBatteryResult r;
        auto psDir = sysRoot ~ "/class/power_supply";
        if (!exists(psDir)) {
            r.state = CapabilityState.ok;
            return r;
        }

        try {
            foreach (DirEntry de; dirEntries(psDir, SpanMode.shallow)) {
                auto name = baseName(de.name);
                auto ptype = safeReadText(de.name ~ "/type").toLower();
                if (ptype != "battery" && !name.startsWith("BAT")) continue;

                BatteryStatus b;
                b.id = name;
                b.name = name;
                auto st = safeReadText(de.name ~ "/status").toLower();
                switch (st) {
                    case "charging": b.status = "charging"; break;
                    case "discharging": b.status = "discharging"; break;
                    case "full": b.status = "full"; break;
                    case "not charging": b.status = "not_charging"; break;
                    default: b.status = "unknown"; break;
                }

                // Prefer energy_* (µWh), fall back to charge_* (µAh) * voltage_now (µV), or capacity %
                double energyNowUwh = -1, energyFullUwh = -1, energyDesignUwh = -1, powerUw = -1;
                try {
                    auto en = safeReadText(de.name ~ "/energy_now");
                    auto ef = safeReadText(de.name ~ "/energy_full");
                    auto ed = safeReadText(de.name ~ "/energy_full_design");
                    auto pn = safeReadText(de.name ~ "/power_now");
                    if (en.length > 0 && ef.length > 0) {
                        energyNowUwh = to!double(en);
                        energyFullUwh = to!double(ef);
                        if (ed.length > 0) energyDesignUwh = to!double(ed);
                        if (pn.length > 0) powerUw = to!double(pn);
                    } else {
                        auto cn = safeReadText(de.name ~ "/charge_now");
                        auto cf = safeReadText(de.name ~ "/charge_full");
                        auto cd = safeReadText(de.name ~ "/charge_full_design");
                        auto vn = safeReadText(de.name ~ "/voltage_now");
                        auto cur = safeReadText(de.name ~ "/current_now");
                        double v = vn.length > 0 ? to!double(vn) / 1_000_000.0 : 0.0;
                        if (cn.length > 0 && cf.length > 0) {
                            double cnVal = to!double(cn);
                            double cfVal = to!double(cf);
                            if (v > 0) {
                                energyNowUwh = cnVal * v;
                                energyFullUwh = cfVal * v;
                                if (cd.length > 0) energyDesignUwh = to!double(cd) * v;
                                if (cur.length > 0) powerUw = to!double(cur) * v;
                            } else if (cfVal > 0) {
                                b.pct = (cnVal / cfVal) * 100.0;
                            }
                        }
                    }
                } catch (Exception) {}

                if (energyNowUwh >= 0 && energyFullUwh > 0) {
                    b.pct = (energyNowUwh / energyFullUwh) * 100.0;
                } else if (b.pct.isNull) {
                    auto capTxt = safeReadText(de.name ~ "/capacity");
                    if (capTxt.length > 0) {
                        try { b.pct = to!double(capTxt); } catch (Exception) {}
                    }
                }

                if (energyFullUwh > 0 && energyDesignUwh > 0) {
                    b.health_pct = (energyFullUwh / energyDesignUwh) * 100.0;
                }
                if (powerUw > 0) {
                    b.power_watts = powerUw / 1_000_000.0;
                    if (b.status == "discharging" && energyNowUwh >= 0) {
                        b.time_remaining_s = cast(long)((energyNowUwh / powerUw) * 3600.0);
                    } else if (b.status == "charging" && energyFullUwh > energyNowUwh) {
                        b.time_remaining_s = cast(long)(((energyFullUwh - energyNowUwh) / powerUw) * 3600.0);
                    }
                }

                r.batteries ~= b;
            }
        } catch (Exception) {}

        r.state = CapabilityState.ok;
        return r;
    }

    override RawMaintenanceResult sampleMaintenance() {
        RawMaintenanceResult r;
        r.state = CapabilityState.ok;

        string runningKernel;
        if (!isRealHost()) {
            runningKernel = sanitizeOsString(safeReadText(procRoot ~ "/sys/kernel/osrelease"), 128);
        }
        if (runningKernel.length == 0) {
            version (Posix) {
                utsname u;
                if (uname(&u) == 0) {
                    import std.string : fromStringz;
                    runningKernel = sanitizeOsString(fromStringz(u.release.ptr).idup, 128);
                }
            }
        }
        r.drift.running_kernel = runningKernel;

        // Check Debian/Ubuntu /var/run/reboot-required
        if (exists(varRoot ~ "/run/reboot-required")) {
            r.drift.reboot_required = true;
        }

        // Check /lib/modules to detect running kernel vs installed kernel drift (Arch/CachyOS/Fedora/Ubuntu)
        if (runningKernel.length > 0 && exists(libModulesRoot)) {
            string[] installed;
            try {
                foreach (DirEntry de; dirEntries(libModulesRoot, SpanMode.shallow)) {
                    if (de.isDir) installed ~= baseName(de.name);
                }
            } catch (Exception) {}

            if (installed.length > 0) {
                if (!installed.canFind(runningKernel)) {
                    r.drift.installed_kernel = installed[0];
                    r.drift.reboot_required = true;
                } else {
                    r.drift.installed_kernel = runningKernel;
                    if (r.drift.reboot_required.isNull) r.drift.reboot_required = false;
                }
            }
        }

        // Check local package cache mtime without running apt/pacman/dnf or network
        static immutable string[] cacheHints = [
            "/var/lib/apt/periodic/update-success-stamp",
            "/var/cache/apt/pkgcache.bin",
            "/var/lib/pacman/sync",
            "/var/cache/libdnf5",
            "/var/cache/dnf",
        ];
        long nowWall = Clock.currTime.toUnixTime();
        foreach (rel; cacheHints) {
            string p = varRoot == "/var" ? rel : (varRoot ~ rel[4 .. $]);
            if (exists(p)) {
                try {
                    long mtime = timeLastModified(p).toUnixTime();
                    if (nowWall >= mtime) {
                        r.drift.package_cache_age_s = nowWall - mtime;
                        break;
                    }
                } catch (Exception) {}
            }
        }

        return r;
    }

    override RawHardwareResult scanHardware() {
        RawHardwareResult r;
        if (!pciIdsLoaded) {
            pciIds.loadLocalPciIdsFile();
            pciIdsLoaded = true;
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
