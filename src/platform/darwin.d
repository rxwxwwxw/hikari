module platform.darwin;

import core.model;
import core.serializer : sanitizeOsString;
import hardware.inventory;
import hardware.isa_names;
import platform.api;
import platform.clock : continuousBootNanoseconds;
import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.format : format;

import std.string : fromStringz, indexOf, split, strip, toLower;
import std.typecons : Nullable;

version (OSX) {
    import core.sys.darwin.ifaddrs : freeifaddrs, getifaddrs, ifaddrs;
    import core.sys.darwin.sys.sysctl : sysctlbyname, sysctl;
    import platform.darwin_native;
    import core.sys.posix.unistd : sysconf, _SC_CLK_TCK, close;
    import core.sys.posix.sys.socket : socket, AF_INET, SOCK_DGRAM;
    import core.sys.posix.sys.ioctl : ioctl;

    private enum int H_HOST_CPU_LOAD_INFO = 3;
    private enum uint H_HOST_CPU_LOAD_INFO_COUNT = 4;
    private enum int H_HOST_VM_INFO64 = 4;
    private enum uint H_HOST_VM_INFO64_COUNT = H_vm_statistics64.sizeof / int.sizeof;
    private enum int H_MNT_NOWAIT = 2;
    private enum int H_AF_LINK = 18;
    private enum int H_PROC_PIDTASKALLINFO = 2;

    private struct H_host_cpu_load_info_data {
        uint[4] cpu_ticks; // 0=user, 1=system, 2=idle, 3=nice
    }

    private struct H_vm_statistics64 {
        uint free_count;
        uint active_count;
        uint inactive_count;
        uint wire_count;
        ulong zero_fill_count;
        ulong reactivations;
        ulong pageins;
        ulong pageouts;
        ulong faults;
        ulong cow_faults;
        ulong lookups;
        ulong hits;
        ulong purges;
        uint purgeable_count;
        uint speculative_count;
        ulong decompressions;
        ulong compressions;
        ulong swapins;
        ulong swapouts;
        uint compressor_page_count;
        uint throttled_count;
        uint external_page_count;
        uint internal_page_count;
        ulong total_uncompressed_pages_in_compressor;
        ulong swapped_count;
    }

    private struct H_xsw_usage {
        ulong xsu_total;
        ulong xsu_avail;
        ulong xsu_used;
        uint xsu_pagesize;
        bool xsu_encrypted;
    }

    private struct H_timeval {
        long tv_sec;
        int tv_usec;
    }

    // Darwin SDK net/if_var.h uses 4-byte packing for if_data64.
    private struct H_if_data64 {
        align(4):
        ubyte[8] header;
        uint mtu;
        uint metric;
        ulong baudrate;
        ulong ipackets, ierrors, opackets, oerrors, collisions;
        ulong ibytes, obytes;
        ulong imcasts, omcasts, iqdrops, noproto;
        uint recvtiming, xmittiming;
        int[2] lastchange;
    }
    private struct H_ifmibdata {
        align(4):
        char[16] name;
        uint pcount, flags, snd_len, snd_maxlen, snd_drops;
        uint[4] filler;
        H_if_data64 data;
    }
    static assert(H_if_data64.sizeof == 128);
    static assert(H_ifmibdata.sizeof == 180);

    private struct H_ifmediareq {
        align(4):
        char[16] name;
        int current, mask, status, active, count;
        int* list;
    }
    static assert(H_ifmediareq.sizeof == 44);

    private struct H_proc_bsdinfo {
        uint pbi_flags;
        uint pbi_status;
        uint pbi_xstatus;
        uint pbi_pid;
        uint pbi_ppid;
        uint pbi_uid;
        uint pbi_gid;
        uint pbi_ruid;
        uint pbi_rgid;
        uint pbi_svuid;
        uint pbi_svgid;
        uint rfu_1;
        char[16] pbi_comm;
        char[32] pbi_name;
        uint pbi_nfiles;
        uint pbi_pgid;
        uint pbi_pjobc;
        uint e_tdev;
        uint e_tpgid;
        int pbi_nice;
        ulong pbi_start_tvsec;
        ulong pbi_start_tvusec;
    }

    private struct H_proc_taskinfo {
        ulong pti_virtual_size;
        ulong pti_resident_size;
        ulong pti_total_user;
        ulong pti_total_system;
        ulong pti_threads_user;
        ulong pti_threads_system;
        int pti_policy;
        int pti_faults;
        int pti_pageins;
        int pti_cow_faults;
        int pti_messages_sent;
        int pti_messages_received;
        int pti_syscalls_mach;
        int pti_syscalls_unix;
        int pti_csw;
        int pti_threadnum;
        int pti_numrunning;
        int pti_priority;
    }

    private struct H_proc_taskallinfo {
        H_proc_bsdinfo pbsd;
        H_proc_taskinfo ptinfo;
    }

    private struct H_statfs {
        uint f_bsize;
        int f_iosize;
        ulong f_blocks;
        ulong f_bfree;
        ulong f_bavail;
        ulong f_files;
        ulong f_ffree;
        long[1] f_fsid; // 8 bytes on Darwin (int[2])
        uint f_owner;
        uint f_type;
        uint f_flags;
        uint f_fssubtype;
        char[16] f_fstypename;
        char[1024] f_mntonname;
        char[1024] f_mntfromname;
        uint[8] f_reserved;
    }

    static assert(H_statfs.sizeof == 2168);
    static assert(H_proc_taskallinfo.sizeof == 232);
    static assert(H_vm_statistics64.sizeof == 160);

    private extern (C) nothrow @nogc {
        uint mach_host_self();
        extern __gshared uint mach_task_self_;
        int mach_port_deallocate(uint task, uint name);
        int host_statistics(uint host_priv, int flavor, int* host_info_out, uint* host_info_outCnt);
        int host_statistics64(uint host_priv, int flavor, int* host_info_out, uint* host_info_outCnt);
        int proc_listallpids(void* buffer, int buffersize);
        int proc_pidinfo(int pid, int flavor, ulong arg, void* buffer, int buffersize);
        version (X86_64) {
            // Intel Darwin retains a legacy ABI under the unsuffixed symbol.
            pragma(mangle, "getfsstat$INODE64")
            int getfsstat(H_statfs* buf, int bufsize, int flags);
        } else {
            int getfsstat(H_statfs* buf, int bufsize, int flags);
        }
        uint if_nametoindex(const(char)* ifname);
        int getloadavg(double* loadavg, int nelem);
    }
}

private string boundedString(const(char)[] value) {
    auto end = value.indexOf('\0');
    return (end < 0 ? value : value[0 .. end]).idup;
}

// libproc exports native kernel Mach ticks, including to translated processes.
// hw.tbfrequency describes that clock; Rosetta's mach_timebase_info instead
// describes the translated process's emulated clock and cannot normalize it.
Nullable!ulong normalizeDarwinCpuTicks(ulong user, ulong system, ulong frequency, ulong schedulerHz) pure nothrow @safe {
    if (!frequency || !schedulerHz || system > ulong.max - user) return Nullable!ulong.init;
    ulong total = user + system;
    ulong whole = total / frequency;
    ulong remainder = total % frequency;
    if (whole > ulong.max / schedulerHz || remainder > ulong.max / schedulerHz)
        return Nullable!ulong.init;
    ulong base = whole * schedulerHz;
    ulong fraction = remainder * schedulerHz / frequency;
    if (fraction > ulong.max - base) return Nullable!ulong.init;
    return Nullable!ulong(base + fraction);
}

struct DarwinPowerSource {
    string state;
    Nullable!long currentCapacity;
    Nullable!long maxCapacity;
    Nullable!bool charging;
    Nullable!bool charged;
    Nullable!long minutesToEmpty;
}

BatteryStatus decodeDarwinPowerSource(const ref DarwinPowerSource source, string id) {
    BatteryStatus b;
    b.id = id;
    b.name = "Internal battery";
    if (!source.currentCapacity.isNull && !source.maxCapacity.isNull
        && source.maxCapacity.get > 0 && source.currentCapacity.get >= 0
        && source.currentCapacity.get <= source.maxCapacity.get)
        b.pct = 100.0 * source.currentCapacity.get / source.maxCapacity.get;
    b.status = "unknown";
    if (!source.charging.isNull && source.charging.get) b.status = "charging";
    else if (!source.charged.isNull && source.charged.get) b.status = "full";
    else if (source.state == "Battery Power") b.status = "discharging";
    else if (source.state == "AC Power") b.status = "not_charging";
    if (b.status == "discharging" && !source.minutesToEmpty.isNull
        && source.minutesToEmpty.get > 0 && source.minutesToEmpty.get <= long.max / 60)
        b.time_remaining_s = source.minutesToEmpty.get * 60;
    return b;
}

class DarwinPlatformBackend : PlatformBackend {
    bool exposeMacAddresses;

    this(bool exposeMacAddresses = false) {
        this.exposeMacAddresses = exposeMacAddresses;
    }

    version (OSX) {
        private string sysctlString(const(char)* name) const {
            size_t len = 0;
            if (sysctlbyname(name, null, &len, null, 0) != 0 || len == 0 || len > 1024) return "";
            auto buf = new char[len];
            if (sysctlbyname(name, buf.ptr, &len, null, 0) != 0) return "";
            size_t end = len;
            foreach (i, c; buf[0 .. len]) {
                if (c == '\0') { end = i; break; }
            }
            return sanitizeOsString(cast(string) buf[0 .. end], 160);
        }

        private bool sysctlU64(const(char)* name, out ulong val) const {
            size_t sz = ulong.sizeof;
            ulong tmp = 0;
            if (sysctlbyname(name, &tmp, &sz, null, 0) == 0 && sz == ulong.sizeof) {
                val = tmp;
                return true;
            }
            uint u32 = 0;
            sz = uint.sizeof;
            if (sysctlbyname(name, &u32, &sz, null, 0) == 0 && sz == uint.sizeof) {
                val = u32;
                return true;
            }
            return false;
        }

        private bool sysctlU32(const(char)* name, out uint val) const {
            size_t sz = uint.sizeof;
            uint tmp = 0;
            if (sysctlbyname(name, &tmp, &sz, null, 0) == 0 && sz == uint.sizeof) {
                val = tmp;
                return true;
            }
            return false;
        }
    }

    override PlatformIdentity identity() {
        PlatformIdentity id;
        id.os = "darwin";
        version (AArch64) id.arch = "arm64";
        else version (X86_64) id.arch = "x86_64";
        else id.arch = "unknown";

        version (OSX) {
            id.host = sysctlString("kern.hostname");
            if (id.host.length == 0) id.host = "macos-host";

            H_timeval bt;
            size_t bsz = H_timeval.sizeof;
            if (sysctlbyname("kern.boottime".ptr, &bt, &bsz, null, 0) == 0 && bt.tv_sec > 0) {
                id.boot_id = format!"darwinboot-%d"(bt.tv_sec);
                auto continuous = continuousBootNanoseconds();
                if (continuous >= 0) id.uptime_s = continuous / 1_000_000_000L;
            } else {
                id.boot_id = "darwin-boot";
            }
        }
        return id;
    }

    override RawCpu sampleCpu() {
        RawCpu c;
        version (OSX) {
            H_host_cpu_load_info_data info;
            uint cnt = H_HOST_CPU_LOAD_INFO_COUNT;
            auto host = mach_host_self();
            scope (exit) mach_port_deallocate(mach_task_self_, host);
            if (host_statistics(host, H_HOST_CPU_LOAD_INFO, cast(int*) &info, &cnt) != 0) {
                c.state = CapabilityState.error;
                c.error = "mach_host_statistics_failed";
                return c;
            }
            ulong u = info.cpu_ticks[0];
            ulong sys = info.cpu_ticks[1];
            ulong idl = info.cpu_ticks[2];
            ulong ni = info.cpu_ticks[3];
            c.idle_ticks = idl;
            c.total_ticks = u + sys + idl + ni;

            uint lcores = 1;
            if (sysctlU32("hw.logicalcpu".ptr, lcores) && lcores > 0) {
                c.logical_cores = lcores;
            }

            double[3] loads;
            if (getloadavg(loads.ptr, 3) >= 1) {
                c.load_1m = loads[0];
            }
            c.state = CapabilityState.ok;
        } else {
            c.state = CapabilityState.unsupported;
            c.error = "darwin_only_backend";
        }
        return c;
    }

    override RawMemory sampleMemory() {
        RawMemory m;
        version (OSX) {
            ulong memSize = 0;
            if (!sysctlU64("hw.memsize".ptr, memSize) || memSize == 0) {
                m.state = CapabilityState.error;
                m.error = "sysctl_hw_memsize_failed";
                return m;
            }
            m.total_bytes = memSize;

            ulong pageSize = 4096;
            ulong psTmp = 0;
            if (sysctlU64("hw.pagesize".ptr, psTmp) && psTmp > 0) pageSize = psTmp;

            H_vm_statistics64 vm;
            uint cnt = H_HOST_VM_INFO64_COUNT;
            auto host = mach_host_self();
            scope (exit) mach_port_deallocate(mach_task_self_, host);
            if (host_statistics64(host, H_HOST_VM_INFO64, cast(int*) &vm, &cnt) == 0) {
                ulong usedPages = cast(ulong) vm.active_count + cast(ulong) vm.wire_count + cast(ulong) vm.compressor_page_count;
                ulong usedB = usedPages * pageSize;
                m.used_bytes = usedB <= memSize ? usedB : memSize;
            } else {
                m.state = CapabilityState.error;
                m.error = "mach_vm_statistics_failed";
                return m;
            }

            H_xsw_usage xsw;
            size_t xsz = H_xsw_usage.sizeof;
            if (sysctlbyname("vm.swapusage".ptr, &xsw, &xsz, null, 0) == 0) {
                m.swap_total_bytes = xsw.xsu_total;
                m.swap_used_bytes = xsw.xsu_used;
            }

            m.state = CapabilityState.ok;
        } else {
            m.state = CapabilityState.unsupported;
            m.error = "darwin_only_backend";
        }
        return m;
    }

    override RawNetworkResult sampleNetwork() {
        RawNetworkResult r;
        version (OSX) {
            ifaddrs* head = null;
            if (getifaddrs(&head) != 0 || head is null) {
                r.state = CapabilityState.error;
                r.error = "getifaddrs_failed";
                return r;
            }
            scope (exit) freeifaddrs(head);

            bool[string] tailnetIfs;
            for (ifaddrs* cur = head; cur !is null; cur = cur.ifa_next) {
                if (cur.ifa_addr is null || cur.ifa_name is null) continue;
                auto fam = cur.ifa_addr.sa_family;
                if (fam != 2 && fam != 30) continue;
                auto ifName = sanitizeOsString(fromStringz(cur.ifa_name).idup, 64);
                if (ifName.length == 0) continue;
                const(ubyte)* raw = cast(const(ubyte)*) cur.ifa_addr;
                if (fam == 2 && raw[0] >= 8) {
                    if (raw[4] == 100 && (raw[5] & 0xC0) == 64) {
                        tailnetIfs[ifName] = true;
                    }
                } else if (fam == 30 && raw[0] >= 24) {
                    if (raw[8] == 0xfd && raw[9] == 0x7a && raw[10] == 0x11
                        && raw[11] == 0x5c && raw[12] == 0xa1 && raw[13] == 0xe0) {
                        tailnetIfs[ifName] = true;
                    }
                }
            }
            auto scKinds = nativeNetworkInterfaceKinds();

            int mediaSocket = socket(AF_INET, SOCK_DGRAM, 0);
            scope (exit) if (mediaSocket >= 0) close(mediaSocket);
            r.state = CapabilityState.ok;
            for (ifaddrs* cur = head; cur !is null; cur = cur.ifa_next) {
                if (cur.ifa_addr is null || cur.ifa_data is null) continue;
                if (cur.ifa_addr.sa_family != H_AF_LINK) continue;

                auto ifName = sanitizeOsString(fromStringz(cur.ifa_name).idup, 64);
                if (ifName.length == 0 || ifName == "lo0") continue;

                uint ifIdx = if_nametoindex(cur.ifa_name);

                RawNetworkInterface ni;
                ni.id = ifIdx > 0 ? ("ifindex:" ~ to!string(ifIdx)) : ("name:" ~ ifName);
                ni.name = ifName;
                if ((ifName in tailnetIfs) !is null) ni.kind = "tailnet";
                else if (ifName.startsWith("anpi")) ni.kind = "virtual";
                else if (auto pk = ifName in scKinds) ni.kind = *pk;
                else if (ifName.startsWith("en")) ni.kind = "physical";
                else ni.kind = "virtual";

                // Read the 64-bit IF-MIB counters; getifaddrs exposes only 32 bits.
                int[6] mib = [4 /* CTL_NET */, 18 /* PF_LINK */, 0,
                    2 /* IFMIB_IFDATA */, cast(int) ifIdx, 1 /* IFDATA_GENERAL */];
                H_ifmibdata stats;
                size_t statsSize = stats.sizeof;
                if (ifIdx == 0 || sysctl(mib.ptr, mib.length, &stats, &statsSize, null, 0) != 0
                    || statsSize != stats.sizeof) {
                    // Never change counter width underneath an existing tracker identity.
                    r.state = CapabilityState.error;
                    r.error = "interface_counters_unavailable";
                    continue;
                }
                ni.rx_bytes = stats.data.ibytes;
                ni.tx_bytes = stats.data.obytes;
                if (stats.data.baudrate > 0) ni.link_speed_bps = stats.data.baudrate;
                // IFF_RUNNING is resource allocation, not carrier state.
                if (mediaSocket >= 0 && ifName.length < 16) {
                    H_ifmediareq media;
                    media.name[0 .. ifName.length] = ifName[];
                    enum ulong getMedia = 0xc02c6938UL; // SDK _IOWR('i', 56, ifmediareq)
                    if (ioctl(mediaSocket, getMedia, &media) == 0 && (media.status & 1))
                        ni.link_up = (media.status & 2) != 0;
                }
                r.interfaces ~= ni;
            }
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "darwin_only_backend";
        }
        return r;
    }

    override RawProcessResult sampleProcesses() {
        RawProcessResult r;
        version (OSX) {
            auto cpu = sampleCpu();
            if (cpu.state == CapabilityState.error) {
                r.state = CapabilityState.error;
                r.error = cpu.error;
                return r;
            }
            r.total_cpu_ticks = cpu.total_ticks;
            r.logical_cores = cpu.logical_cores;

            // libproc returns a PID count, while its buffer argument is in bytes.
            int capacity = proc_listallpids(null, 0);
            if (capacity <= 0 || capacity > 1_000_000) {
                r.state = CapabilityState.error;
                r.error = "proc_listallpids_failed";
                return r;
            }
            auto pids = new int[capacity + 128];
            int actual = proc_listallpids(pids.ptr, cast(int)(pids.length * int.sizeof));
            if (actual <= 0 || actual > pids.length) {
                r.state = CapabilityState.error;
                r.error = "proc_listallpids_failed";
                return r;
            }
            size_t count = actual;
            auto hz = sysconf(_SC_CLK_TCK);
            if (hz <= 0) {
                r.state = CapabilityState.error;
                r.error = "clock_tick_frequency_unavailable";
                return r;
            }

            ulong timebaseFrequency;
            if (!sysctlU64("hw.tbfrequency".ptr, timebaseFrequency) || timebaseFrequency == 0) {
                r.state = CapabilityState.unavailable;
                r.error = "process_timebase_unavailable";
                return r;
            }
            r.state = CapabilityState.ok;
            foreach (i; 0 .. count) {
                int pid = pids[i];
                if (pid <= 0) continue;
                H_proc_taskallinfo pti;
                int resSz = proc_pidinfo(pid, H_PROC_PIDTASKALLINFO, 0, &pti, cast(int) H_proc_taskallinfo.sizeof);
                if (resSz != cast(int) H_proc_taskallinfo.sizeof) continue;

                auto pname = sanitizeOsString(boundedString(pti.pbsd.pbi_name[]), 128);
                if (pname.length == 0) {
                    pname = sanitizeOsString(boundedString(pti.pbsd.pbi_comm[]), 128);
                }
                if (pname.length == 0) pname = "pid-" ~ to!string(pid);

                auto cpuTicks = normalizeDarwinCpuTicks(pti.ptinfo.pti_total_user,
                    pti.ptinfo.pti_total_system, timebaseFrequency, cast(ulong) hz);
                if (cpuTicks.isNull) continue;

                RawProcess rp;
                rp.pid = cast(uint) pid;
                rp.start_id = format!"%u:%u"(pti.pbsd.pbi_start_tvsec, pti.pbsd.pbi_start_tvusec);
                rp.name = pname;
                rp.cpu_ticks = cpuTicks.get;
                rp.rss_bytes = pti.ptinfo.pti_resident_size;
                rp.memory_kind = "rss";
                r.processes ~= rp;
            }
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "darwin_only_backend";
        }
        return r;
    }

    override RawFilesystemResult sampleFilesystems() {
        RawFilesystemResult r;
        version (OSX) {
            int cnt = getfsstat(null, 0, H_MNT_NOWAIT);
            if (cnt <= 0) {
                r.state = CapabilityState.error;
                r.error = "getfsstat_failed";
                return r;
            }
            auto buf = new H_statfs[cnt + 8];
            int actual = getfsstat(buf.ptr, cast(int)(buf.length * H_statfs.sizeof), H_MNT_NOWAIT);
            if (actual <= 0) {
                r.state = CapabilityState.error;
                r.error = "getfsstat_empty";
                return r;
            }

            r.state = CapabilityState.ok;
            if (actual > buf.length) actual = cast(int) buf.length;
            foreach (const ref fs; buf[0 .. actual]) {
                auto fsType = sanitizeOsString(boundedString(fs.f_fstypename[]), 32).toLower();
                auto mnt = sanitizeOsString(boundedString(fs.f_mntonname[]), 512);
                auto src = sanitizeOsString(boundedString(fs.f_mntfromname[]), 256);
                // Network mount sources may contain usernames or credentials.
                if (!src.startsWith("/dev/")) src = "";
                if (fsType == "devfs" || fsType == "autofs" || fsType == "nullfs") continue;
                if (mnt.startsWith("/System/Volumes/VM") || mnt.startsWith("/System/Volumes/Preboot")
                    || mnt.startsWith("/System/Volumes/Update") || mnt.startsWith("/System/Volumes/xarts")
                    || mnt.startsWith("/System/Volumes/iSCPreboot") || mnt.startsWith("/System/Volumes/Hardware")) {
                    continue;
                }
                if (fs.f_blocks == 0) continue;

                ulong tot = fs.f_blocks * cast(ulong) fs.f_bsize;
                ulong fre = fs.f_bfree * cast(ulong) fs.f_bsize;
                ulong used = tot > fre ? (tot - fre) : 0;

                MountStatus ms;
                ms.mount = mnt;
                ms.source = src;
                ms.fs = fsType;
                ms.total_bytes = tot;
                ms.used_bytes = used;
                ms.pct = tot > 0 ? (cast(double) used / cast(double) tot) * 100.0 : 0.0;
                r.mounts ~= ms;
            }
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "darwin_only_backend";
        }
        return r;
    }

    override RawGpuResult sampleGpus() {
        version (OSX) {
            return nativeSampleGpus();
        } else {
            return RawGpuResult(CapabilityState.unsupported, "darwin_only_backend", null);
        }
    }

    override RawBatteryResult sampleBatteries() {
        RawBatteryResult r;
        version (OSX) {
            return nativePowerSources();
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "darwin_only_backend";
        }
        return r;
    }

    override RawMaintenanceResult sampleMaintenance() {
        RawMaintenanceResult r;
        version (OSX) {
            r.state = CapabilityState.ok;
            auto osRelease = sysctlString("kern.osrelease");
            if (osRelease.length == 0) {
                r.state = CapabilityState.unavailable;
                r.error = "local_kernel_metadata_unavailable";
                return r;
            }
            auto osProdVer = sysctlString("kern.osproductversion");
            auto osBuild = sysctlString("kern.osversion");
            if (osProdVer.length > 0 && osBuild.length > 0) {
                r.drift.running_kernel = format!"macOS %s (%s) · Darwin %s"(osProdVer, osBuild, osRelease);
            } else if (osProdVer.length > 0) {
                r.drift.running_kernel = format!"macOS %s · Darwin %s"(osProdVer, osRelease);
            } else {
                r.drift.running_kernel = osRelease;
            }
            nativeSampleMaintenance(r.drift, osBuild);
            // Never invoke `softwareupdate -l` during passive telemetry
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "darwin_only_backend";
        }
        return r;
    }

    override RawHardwareResult scanHardware() {
        RawHardwareResult r;
        version (OSX) {
            HardwareInventory hw;
            auto modelId = sysctlString("hw.model");
            hw.system.manufacturer = "Apple Inc.";
            hw.system.model = modelId;
            // OS version is not a hardware product family.
            auto lowMod = modelId.toLower();
            if (lowMod.canFind("macbook")) hw.system.form_factor = "laptop";
            else if (lowMod.startsWith("imac") || lowMod.startsWith("macmini")
                || lowMod.startsWith("macpro") || lowMod.startsWith("macstudio"))
                hw.system.form_factor = "desktop";

            uint vmm = 0;
            if (sysctlU32("kern.hv_vmm_present".ptr, vmm) && vmm != 0) {
                hw.system.virtualization = "apple-hypervisor-guest";
            } else {
                uint hvs = 0;
                if (sysctlU32("kern.hv_support".ptr, hvs) && hvs != 0) {
                    hw.system.virtualization = "Bare metal (Apple Hypervisor)";
                }
            }

            // On Macs without PC-style motherboard info, expose Mac model identifier cleanly
            hw.board.manufacturer = "Apple Inc.";
            hw.board.model = modelId;
            // Firmware is populated only from an actual firmware property.

            version (AArch64) hw.cpu.architecture = "arm64";
            else version (X86_64) hw.cpu.architecture = "x86_64";
            else hw.cpu.architecture = "unknown";

            hw.cpu.display_name = sysctlString("machdep.cpu.brand_string");

            version (AArch64) {
                hw.cpu.vendor = "Apple";
                uint cpufam = 0;
                if (sysctlU32("hw.cpufamily".ptr, cpufam)) {
                    switch (cpufam) {
                        case 0x1b588bb3: hw.cpu.microarchitecture = "Firestorm + Icestorm (ARMv8.5-A)"; break;
                        case 0xda33d83d: hw.cpu.microarchitecture = "Avalanche + Blizzard (ARMv8.6-A)"; break;
                        case 0xfa33415e:
                        case 0x8765edea:
                        case 0x5f4dea93: hw.cpu.microarchitecture = "Everest + Sawtooth (ARMv8.6-A)"; break;
                        case 0x6f5129ac:
                        case 0x17d5b93a:
                        case 0x72015832: hw.cpu.microarchitecture = "Apple M4 (ARMv9.2-A)"; break;
                        default: break;
                    }
                }
            } else {
                auto bv = hw.cpu.display_name.toLower();
                hw.cpu.vendor = bv.canFind("intel") ? "Intel" : "Apple";
            }

            uint val32 = 0;
            if (sysctlU32("hw.packages".ptr, val32)) hw.cpu.sockets = val32;
            if (sysctlU32("hw.physicalcpu".ptr, val32)) hw.cpu.physical_cores = val32;
            if (sysctlU32("hw.logicalcpu".ptr, val32)) hw.cpu.logical_cores = val32;
            if (sysctlU32("hw.perflevel0.physicalcpu".ptr, val32)) hw.cpu.performance_cores = val32;
            if (sysctlU32("hw.perflevel1.physicalcpu".ptr, val32)) hw.cpu.efficiency_cores = val32;

            ulong csz = 0;
            ulong p0L1d = 0, p0L1i = 0, p0L2 = 0, p1L2 = 0;
            if (sysctlU64("hw.perflevel0.l1dcachesize".ptr, p0L1d) && p0L1d > 0) hw.cpu.cache_bytes.l1d = p0L1d;
            else if (sysctlU64("hw.l1dcachesize".ptr, csz) && csz > 0) hw.cpu.cache_bytes.l1d = csz;

            if (sysctlU64("hw.perflevel0.l1icachesize".ptr, p0L1i) && p0L1i > 0) hw.cpu.cache_bytes.l1i = p0L1i;
            else if (sysctlU64("hw.l1icachesize".ptr, csz) && csz > 0) hw.cpu.cache_bytes.l1i = csz;

            if (sysctlU64("hw.perflevel0.l2cachesize".ptr, p0L2) && p0L2 > 0) {
                sysctlU64("hw.perflevel1.l2cachesize".ptr, p1L2);
                hw.cpu.cache_bytes.l2 = p0L2 + p1L2;
            } else if (sysctlU64("hw.l2cachesize".ptr, csz) && csz > 0) {
                hw.cpu.cache_bytes.l2 = csz;
            }

            if (sysctlU64("hw.l3cachesize".ptr, csz) && csz > 0) hw.cpu.cache_bytes.l3 = csz;

            version (X86_64) {
                hw.cpu.isa = detectHostX86Isa();
            } else version (AArch64) {
                hw.cpu.isa = detectAppleSiliconIsa();
            }

            auto rawMem = sampleMemory();
            hw.memory.total_bytes = rawMem.total_bytes;
            hw.memory.module_enumeration = CapabilityState.unsupported;

            auto netRes = sampleNetwork();
            if (netRes.state == CapabilityState.ok) {
                foreach (ni; netRes.interfaces) {
                    NetworkAdapterHardware na;
                    na.id = ni.id;
                    na.interface_name = ni.name;
                    na.link_speed_bps = ni.link_speed_bps;
                    if (ni.kind == "tailnet") {
                        na.kind = "tailnet";
                        na.display_name = "Tailscale Tunnel (" ~ ni.name ~ ")";
                        na.driver = "utun";
                        na.bus = "virtual";
                    } else if (ni.kind == "wireless") {
                        na.kind = "wifi";
                        na.display_name = ni.name;
                    } else {
                        na.kind = ni.kind == "physical" ? "unknown" : ni.kind;
                        na.display_name = ni.name;
                    }
                    hw.network_adapters ~= na;
                }
            }

            hw.capabilities["board"] = hw.board.model.length > 0 ? CapabilityState.ok : CapabilityState.unavailable;
            hw.capabilities["memory_modules"] = CapabilityState.unsupported;
            hw.capabilities["network_adapters"] = netRes.state;
            hw.capabilities["storage_devices"] = CapabilityState.unavailable;
            hw.capabilities["isa"] = hw.cpu.isa.usable.length > 0 ? CapabilityState.ok : CapabilityState.unavailable;

            auto fsRes = sampleFilesystems();
            enrichNativeHardware(hw, fsRes.state == CapabilityState.ok ? fsRes.mounts : null);
            hw.collection.status = GroupStatus.fresh;
            hw.collection.partial = true;
            r.state = CapabilityState.ok;
            r.inventory = hw;
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "darwin_only_backend";
        }
        return r;
    }

    version (OSX) {
        private IsaInfo detectAppleSiliconIsa() const {
            IsaInfo isa;
            static immutable string[2][] sysctlMap = [
                ["hw.optional.floatingpoint", "fp"],
                ["hw.optional.neon", "asimd"],
                ["hw.optional.AdvSIMD", "asimd"],
                ["hw.optional.arm.AdvSIMD", "asimd"],
                ["hw.optional.arm.FEAT_AES", "aes"],
                ["hw.optional.arm.FEAT_PMULL", "pmull"],
                ["hw.optional.arm.FEAT_SHA1", "sha1"],
                ["hw.optional.arm.FEAT_SHA256", "sha2"],
                ["hw.optional.arm.FEAT_SHA3", "sha3"],
                ["hw.optional.arm.FEAT_SHA512", "sha512"],
                ["hw.optional.armv8_crc32", "crc32"],
                ["hw.optional.arm.FEAT_CRC32", "crc32"],
                ["hw.optional.arm.FEAT_LSE", "atomics"],
                ["hw.optional.armv8_1_atomics", "atomics"],
                ["hw.optional.arm.FEAT_FP16", "fphp"],
                ["hw.optional.neon_fp16", "fphp"],
                ["hw.optional.arm.FEAT_DotProd", "asimddp"],
                ["hw.optional.arm.FEAT_BF16", "bf16"],
                ["hw.optional.arm.FEAT_I8MM", "i8mm"],
                ["hw.optional.arm.FEAT_FCMA", "fcma"],
                ["hw.optional.arm.FEAT_JSCVT", "jscvt"],
                ["hw.optional.arm.FEAT_BTI", "bti"],
                ["hw.optional.arm.FEAT_PAuth", "paca"],
                ["hw.optional.arm.FEAT_RDM", "asimdrdm"],
                ["hw.optional.arm.FEAT_FHM", "asimdfhm"],
                ["hw.optional.armv8_2_fhm", "asimdfhm"],
                ["hw.optional.arm.FEAT_FRINTTS", "frintts"],
                ["hw.optional.arm.FEAT_SME", "sme"],
                ["hw.optional.arm.FEAT_SME2", "sme2"],
                ["hw.optional.arm.FEAT_DIT", "dit"],
                ["hw.optional.arm.FEAT_FlagM", "flagm"],
                ["hw.optional.arm.FEAT_FlagM2", "flagm2"],
                ["hw.optional.arm.FEAT_LSE2", "lse2"],
                ["hw.optional.arm.FEAT_LRCPC", "lrcpc"],
                ["hw.optional.arm.FEAT_LRCPC2", "lrcpc2"],
                ["hw.optional.arm.FEAT_DPB", "dpb"],
                ["hw.optional.arm.FEAT_DPB2", "dpb2"],
                ["hw.optional.arm.FEAT_SB", "sb"],
                ["hw.optional.arm.FEAT_SSBS", "ssbs"],
                ["hw.optional.arm.FEAT_CSV2", "csv2"],
                ["hw.optional.arm.FEAT_CSV3", "csv3"],
                ["hw.optional.arm.FEAT_MTE", "mte"],
                ["kern.hv_support", "vhe"],
            ];
            string[] feats;
            foreach (pair; sysctlMap) {
                uint v = 0;
                if (sysctlU32(pair[0].ptr, v) && v != 0) {
                    feats ~= pair[1];
                }
            }
            isa.hardware = normalizeIsaList(feats);
            isa.usable = isa.hardware.dup;
            isa.detection = "sysctl_hw_optional";
            return isa;
        }
    }
}
