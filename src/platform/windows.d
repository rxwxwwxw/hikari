module platform.windows;

import core.model;
import core.serializer : sanitizeOsString;
import hardware.inventory;
import platform.api;
import platform.nvml;
import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.format : format;
import std.string : fromStringz, indexOf, strip, toLower;
import std.typecons : Nullable;

version (Windows) {
    pragma(lib, "iphlpapi");
    pragma(lib, "advapi32");
    pragma(lib, "psapi");

    import core.sys.windows.winbase;
    import core.sys.windows.windef;
    import core.sys.windows.winnt;
    import core.sys.windows.winreg;
    import core.sys.windows.tlhelp32;
    import core.sys.windows.psapi : PROCESS_MEMORY_COUNTERS, GetProcessMemoryInfo;
    import core.sys.windows.iphlpapi : GetIfTable;
    import core.sys.windows.iprtrmib : MIB_IFTABLE, MIB_IFROW;
    import core.sys.windows.winerror : ERROR_INSUFFICIENT_BUFFER, ERROR_SUCCESS, NO_ERROR;

    private enum uint H_PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private enum uint H_DRIVE_FIXED = 3;
    private enum uint H_RSMB_SIG = 0x52534D42; // 'RSMB'

    private struct H_RawSMBIOSData {
        ubyte Used20CallingMethod;
        ubyte SMBIOSMajorVersion;
        ubyte SMBIOSMinorVersion;
        ubyte DmiRevision;
        uint Length;
    }

    private struct H_SYSTEM_POWER_STATUS {
        ubyte ACLineStatus;
        ubyte BatteryFlag;
        ubyte BatteryLifePercent;
        ubyte SystemStatusFlag;
        uint BatteryLifeTime;
        uint BatteryFullLifeTime;
    }

    private struct H_RTL_OSVERSIONINFOW {
        uint dwOSVersionInfoSize;
        uint dwMajorVersion;
        uint dwMinorVersion;
        uint dwBuildNumber;
        uint dwPlatformId;
        wchar[128] szCSDVersion;
    }

    private extern (Windows) nothrow @nogc {
        BOOL GetSystemTimes(FILETIME* lpIdleTime, FILETIME* lpKernelTime, FILETIME* lpUserTime);
        ulong GetTickCount64();
        BOOL GetSystemPowerStatus(H_SYSTEM_POWER_STATUS* lpSystemPowerStatus);
        uint GetSystemFirmwareTable(uint FirmwareTableProviderSignature, uint FirmwareTableID, void* pFirmwareTableBuffer, uint BufferSize);
        BOOL GetDiskFreeSpaceExW(const(wchar)* lpDirectoryName, ULARGE_INTEGER* lpFreeBytesAvailableToCaller, ULARGE_INTEGER* lpTotalNumberOfBytes, ULARGE_INTEGER* lpTotalNumberOfFreeBytes);
        alias fn_RtlGetVersion = int function(H_RTL_OSVERSIONINFOW*);
    }

    private ulong fileTimeToU64(FILETIME ft) pure nothrow @nogc @safe {
        return (cast(ulong) ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    }
}

class WindowsPlatformBackend : PlatformBackend {
    bool exposeMacAddresses;
    private NvmlLoader nvml;

    this(bool exposeMacAddresses = false) {
        this.exposeMacAddresses = exposeMacAddresses;
        this.nvml = new NvmlLoader();
    }

    override PlatformIdentity identity() {
        PlatformIdentity id;
        id.os = "windows";
        version (X86_64) id.arch = "x86_64";
        else version (AArch64) id.arch = "aarch64";
        else id.arch = "unknown";

        version (Windows) {
            char[256] compName;
            DWORD sz = cast(DWORD) compName.length;
            if (GetComputerNameA(compName.ptr, &sz) && sz > 0) {
                id.host = sanitizeOsString(cast(string) compName[0 .. sz], 128);
            }
            if (id.host.length == 0) id.host = "windows-host";

            ulong upMs = GetTickCount64();
            id.uptime_s = cast(long)(upMs / 1000UL);

            // Derive stable boot_id for current OS boot session using WallTime - Uptime rounded to minute
            import std.datetime.systime : Clock;
            long nowWall = Clock.currTime.toUnixTime();
            long bootSec = nowWall - id.uptime_s.get;
            id.boot_id = format!"winboot-%d"(bootSec / 60);
        }
        return id;
    }

    override RawCpu sampleCpu() {
        RawCpu c;
        version (Windows) {
            FILETIME idleFt, kernFt, userFt;
            if (!GetSystemTimes(&idleFt, &kernFt, &userFt)) {
                c.state = CapabilityState.error;
                c.error = "get_system_times_failed";
                return c;
            }
            // In Win32 GetSystemTimes, kernelTime INCLUDES idleTime
            ulong idle = fileTimeToU64(idleFt);
            ulong kern = fileTimeToU64(kernFt);
            ulong user = fileTimeToU64(userFt);
            c.idle_ticks = idle;
            c.total_ticks = kern + user;

            SYSTEM_INFO si;
            GetSystemInfo(&si);
            c.logical_cores = si.dwNumberOfProcessors > 0 ? si.dwNumberOfProcessors : 1;
            // Unix load_1m is unsupported on Windows; leave null explicitly
            c.state = CapabilityState.ok;
        } else {
            c.state = CapabilityState.unsupported;
            c.error = "windows_only_backend";
        }
        return c;
    }

    override RawMemory sampleMemory() {
        RawMemory m;
        version (Windows) {
            MEMORYSTATUSEX ms;
            ms.dwLength = MEMORYSTATUSEX.sizeof;
            if (!GlobalMemoryStatusEx(&ms)) {
                m.state = CapabilityState.error;
                m.error = "global_memory_status_failed";
                return m;
            }
            m.total_bytes = ms.ullTotalPhys;
            m.used_bytes = ms.ullTotalPhys > ms.ullAvailPhys ? (ms.ullTotalPhys - ms.ullAvailPhys) : 0;
            // Windows ullTotalPageFile is commit limit, NOT Unix swap; populate distinct commit fields
            m.commit_limit_bytes = ms.ullTotalPageFile;
            m.commit_used_bytes = ms.ullTotalPageFile > ms.ullAvailPageFile ? (ms.ullTotalPageFile - ms.ullAvailPageFile) : 0;
            m.state = CapabilityState.ok;
        } else {
            m.state = CapabilityState.unsupported;
            m.error = "windows_only_backend";
        }
        return m;
    }

    override RawNetworkResult sampleNetwork() {
        RawNetworkResult r;
        version (Windows) {
            DWORD bufSz = 0;
            if (GetIfTable(null, &bufSz, FALSE) != ERROR_INSUFFICIENT_BUFFER || bufSz == 0) {
                r.state = CapabilityState.error;
                r.error = "get_if_table_size_failed";
                return r;
            }
            auto buf = new ubyte[bufSz];
            auto table = cast(MIB_IFTABLE*) buf.ptr;
            if (GetIfTable(table, &bufSz, FALSE) != NO_ERROR) {
                r.state = CapabilityState.error;
                r.error = "get_if_table_failed";
                return r;
            }

            r.state = CapabilityState.ok;
            auto rows = (&table.table[0])[0 .. table.dwNumEntries];
            foreach (const ref row; rows) {
                // MIB_IF_TYPE_LOOPBACK = 24
                if (row.dwType == 24) continue;
                RawNetworkInterface ni;
                ni.id = "ifindex:" ~ to!string(row.dwIndex);

                size_t dlen = row.dwDescrLen;
                if (dlen > row.bDescr.length) dlen = row.bDescr.length;
                auto desc = sanitizeOsString(cast(string) row.bDescr[0 .. dlen], 64);
                while (desc.length > 0 && desc[$ - 1] == '\0') desc = desc[0 .. $ - 1];
                ni.name = desc.length > 0 ? desc : ("if" ~ to!string(row.dwIndex));

                auto low = ni.name.toLower();
                if (low.canFind("tailscale") || low.canFind("wireguard")) ni.kind = "tailnet";
                else if (row.dwType == 71 || low.canFind("wi-fi") || low.canFind("wireless") || low.canFind("802.11")) ni.kind = "wireless";
                else if (low.canFind("vethernet") || low.canFind("hyper-v") || low.canFind("vmware") || low.canFind("virtualbox") || low.canFind("loopback")) ni.kind = "virtual";
                else if (row.dwType == 6) ni.kind = "physical";
                else ni.kind = "virtual";

                ni.rx_bytes = row.dwInOctets;
                ni.tx_bytes = row.dwOutOctets;
                ni.link_up = (row.dwOperStatus == 4 || row.dwOperStatus == 5); // IF_OPER_STATUS_CONNECTED / OPERATIONAL
                if (row.dwSpeed > 0 && row.dwSpeed < 0xFFFFFFFFu) {
                    ni.link_speed_bps = cast(ulong) row.dwSpeed;
                }
                r.interfaces ~= ni;
            }
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "windows_only_backend";
        }
        return r;
    }

    override RawProcessResult sampleProcesses() {
        RawProcessResult r;
        version (Windows) {
            auto cpu = sampleCpu();
            if (cpu.state == CapabilityState.error) {
                r.state = CapabilityState.error;
                r.error = cpu.error;
                return r;
            }
            r.total_cpu_ticks = cpu.total_ticks;
            r.logical_cores = cpu.logical_cores;

            HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snap == INVALID_HANDLE_VALUE) {
                r.state = CapabilityState.error;
                r.error = "toolhelp_snapshot_failed";
                return r;
            }
            scope (exit) CloseHandle(snap);

            PROCESSENTRY32W pe;
            pe.dwSize = PROCESSENTRY32W.sizeof;
            if (!Process32FirstW(snap, &pe)) {
                r.state = CapabilityState.error;
                r.error = "process32_first_failed";
                return r;
            }

            r.state = CapabilityState.ok;
            do {
                if (pe.th32ProcessID == 0) continue;
                HANDLE hProc = OpenProcess(H_PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
                if (hProc is null) continue;
                scope (exit) CloseHandle(hProc);

                FILETIME ct, et, kt, ut;
                if (!GetProcessTimes(hProc, &ct, &et, &kt, &ut)) continue;

                PROCESS_MEMORY_COUNTERS pmc;
                pmc.cb = PROCESS_MEMORY_COUNTERS.sizeof;
                if (!GetProcessMemoryInfo(hProc, &pmc, PROCESS_MEMORY_COUNTERS.sizeof)) continue;

                size_t nameLen = 0;
                while (nameLen < pe.szExeFile.length && pe.szExeFile[nameLen] != 0) nameLen++;
                import std.utf : toUTF8;
                auto pname = sanitizeOsString(toUTF8(pe.szExeFile[0 .. nameLen]), 128);

                RawProcess rp;
                rp.pid = pe.th32ProcessID;
                rp.start_id = to!string(fileTimeToU64(ct));
                rp.name = pname.length > 0 ? pname : ("pid-" ~ to!string(pe.th32ProcessID));
                rp.cpu_ticks = fileTimeToU64(kt) + fileTimeToU64(ut);
                rp.rss_bytes = pmc.WorkingSetSize;
                rp.memory_kind = "working_set";
                r.processes ~= rp;
            } while (Process32NextW(snap, &pe));
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "windows_only_backend";
        }
        return r;
    }

    override RawFilesystemResult sampleFilesystems() {
        RawFilesystemResult r;
        version (Windows) {
            wchar[512] drivesBuf;
            DWORD len = GetLogicalDriveStringsW(cast(DWORD) drivesBuf.length, drivesBuf.ptr);
            if (len == 0) {
                r.state = CapabilityState.error;
                r.error = "get_logical_drives_failed";
                return r;
            }

            r.state = CapabilityState.ok;
            size_t pos = 0;
            while (pos < len) {
                size_t end = pos;
                while (end < len && drivesBuf[end] != 0) end++;
                if (end == pos) break;
                const(wchar)* drivePtr = &drivesBuf[pos];
                if (GetDriveTypeW(drivePtr) == H_DRIVE_FIXED) {
                    ULARGE_INTEGER availBytes, totalBytes, freeBytes;
                    if (GetDiskFreeSpaceExW(drivePtr, &availBytes, &totalBytes, &freeBytes) && totalBytes.QuadPart > 0) {
                        wchar[64] fsNameBuf;
                        string fsType = "ntfs";
                        if (GetVolumeInformationW(drivePtr, null, 0, null, null, null, fsNameBuf.ptr, cast(DWORD) fsNameBuf.length)) {
                            size_t flen = 0;
                            while (flen < fsNameBuf.length && fsNameBuf[flen] != 0) flen++;
                            import std.utf : toUTF8;
                            fsType = sanitizeOsString(toUTF8(fsNameBuf[0 .. flen]), 32).toLower();
                        }
                        import std.utf : toUTF8;
                        auto mnt = sanitizeOsString(toUTF8(drivesBuf[pos .. end]), 32);
                        ulong tot = totalBytes.QuadPart;
                        ulong fre = freeBytes.QuadPart;
                        ulong used = tot > fre ? (tot - fre) : 0;

                        MountStatus ms;
                        ms.mount = mnt;
                        ms.source = mnt;
                        ms.fs = fsType;
                        ms.total_bytes = tot;
                        ms.used_bytes = used;
                        ms.pct = (cast(double) used / cast(double) tot) * 100.0;
                        r.mounts ~= ms;
                    }
                }
                pos = end + 1;
            }
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "windows_only_backend";
        }
        return r;
    }

    override RawGpuResult sampleGpus() {
        version (Windows) {
            return nvml.sample();
        } else {
            return RawGpuResult(CapabilityState.unsupported, "windows_only_backend", null);
        }
    }

    override RawBatteryResult sampleBatteries() {
        RawBatteryResult r;
        version (Windows) {
            H_SYSTEM_POWER_STATUS sps;
            if (!GetSystemPowerStatus(&sps)) {
                r.state = CapabilityState.error;
                r.error = "power_status_failed";
                return r;
            }
            r.state = CapabilityState.ok;
            // BatteryFlag == 128 means no system battery; 255 means unknown
            if ((sps.BatteryFlag & 128) == 0 && sps.BatteryFlag != 255 && sps.BatteryLifePercent <= 100) {
                BatteryStatus b;
                b.id = "BAT0";
                b.name = "System Battery";
                if (sps.ACLineStatus == 1) {
                    b.status = (sps.BatteryFlag & 8) != 0 ? "charging" : "full";
                } else if (sps.ACLineStatus == 0) {
                    b.status = "discharging";
                } else {
                    b.status = "unknown";
                }
                b.pct = cast(double) sps.BatteryLifePercent;
                if (sps.BatteryLifeTime != 0xFFFFFFFFu) {
                    b.time_remaining_s = cast(long) sps.BatteryLifeTime;
                }
                r.batteries ~= b;
            }
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "windows_only_backend";
        }
        return r;
    }

    override RawMaintenanceResult sampleMaintenance() {
        RawMaintenanceResult r;
        version (Windows) {
            r.state = CapabilityState.ok;
            HMODULE ntdll = GetModuleHandleA("ntdll.dll".ptr);
            if (ntdll !is null) {
                auto pRtl = cast(fn_RtlGetVersion) GetProcAddress(ntdll, "RtlGetVersion".ptr);
                if (pRtl !is null) {
                    H_RTL_OSVERSIONINFOW vi;
                    vi.dwOSVersionInfoSize = H_RTL_OSVERSIONINFOW.sizeof;
                    if (pRtl(&vi) == 0) {
                        r.drift.running_kernel = format!"%u.%u.%u"(vi.dwMajorVersion, vi.dwMinorVersion, vi.dwBuildNumber);
                    }
                }
            }

            static bool regKeyExists(const(char)* subKey) {
                HKEY hk;
                if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, subKey, 0, KEY_READ, &hk) == ERROR_SUCCESS) {
                    RegCloseKey(hk);
                    return true;
                }
                return false;
            }

            bool cbsReboot = regKeyExists(`SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending`.ptr);
            bool wuReboot = regKeyExists(`SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired`.ptr);
            r.drift.reboot_required = (cbsReboot || wuReboot);
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "windows_only_backend";
        }
        return r;
    }

    override RawHardwareResult scanHardware() {
        RawHardwareResult r;
        version (Windows) {
            HardwareInventory hw;

            // 1. SMBIOS via GetSystemFirmwareTable('RSMB', 0)
            uint rawSz = GetSystemFirmwareTable(H_RSMB_SIG, 0, null, 0);
            if (rawSz > H_RawSMBIOSData.sizeof) {
                auto rawBuf = new ubyte[rawSz];
                if (GetSystemFirmwareTable(H_RSMB_SIG, 0, rawBuf.ptr, rawSz) == rawSz) {
                    auto hdr = cast(H_RawSMBIOSData*) rawBuf.ptr;
                    size_t tableOff = H_RawSMBIOSData.sizeof;
                    size_t tableEnd = tableOff + hdr.Length;
                    if (tableEnd > rawBuf.length) tableEnd = rawBuf.length;
                    auto parsed = parseSmbiosTables(rawBuf[tableOff .. tableEnd]);
                    hw.system = parsed.system;
                    hw.board = parsed.board;
                    hw.firmware = parsed.firmware;
                    hw.memory.modules = parsed.memoryModules;
                    if (hw.memory.modules.length > 0) {
                        hw.memory.module_enumeration = CapabilityState.ok;
                        hw.capabilities["memory_modules"] = CapabilityState.ok;
                        foreach (m; hw.memory.modules) {
                            if (hw.memory.technology.length == 0 && m.technology.length > 0) hw.memory.technology = m.technology;
                            if (hw.memory.speed_mt_s.isNull && !m.speed_mt_s.isNull) hw.memory.speed_mt_s = m.speed_mt_s;
                        }
                    } else {
                        hw.memory.module_enumeration = CapabilityState.unavailable;
                        hw.capabilities["memory_modules"] = CapabilityState.unavailable;
                    }
                    hw.capabilities["board"] = (hw.board.manufacturer.length > 0 || hw.board.model.length > 0)
                        ? CapabilityState.ok
                        : CapabilityState.unavailable;
                }
            } else {
                hw.capabilities["board"] = CapabilityState.unavailable;
                hw.capabilities["memory_modules"] = CapabilityState.unavailable;
            }

            // 2. CPU brand & ISA
            hw.cpu = readWindowsCpuInfo();
            hw.capabilities["isa"] = hw.cpu.isa.usable.length > 0 ? CapabilityState.ok : CapabilityState.unavailable;

            // 3. Memory total
            auto rawMem = sampleMemory();
            hw.memory.total_bytes = rawMem.total_bytes;

            // 4. Network adapters (from MIB_IFTABLE; physical & wireless)
            auto netRes = sampleNetwork();
            if (netRes.state == CapabilityState.ok) {
                foreach (ni; netRes.interfaces) {
                    NetworkAdapterHardware na;
                    na.id = ni.id;
                    na.display_name = ni.name;
                    na.interface_name = ni.name;
                    na.kind = ni.kind == "physical" ? "ethernet" : ni.kind;
                    na.link_speed_bps = ni.link_speed_bps;
                    hw.network_adapters ~= na;
                }
            }
            hw.capabilities["network_adapters"] = CapabilityState.ok;

            // 5. Graphics adapters from Windows Display Class registry (safe non-secret descriptions)
            hw.graphics_adapters = readRegistryDisplayAdapters();
            hw.capabilities["storage_devices"] = CapabilityState.unavailable;

            hw.collection.status = GroupStatus.fresh;
            hw.collection.partial = true;
            r.state = CapabilityState.ok;
            r.inventory = hw;
        } else {
            r.state = CapabilityState.unsupported;
            r.error = "windows_only_backend";
        }
        return r;
    }

    version (Windows) {
        private CpuHardwareInfo readWindowsCpuInfo() {
            CpuHardwareInfo cpu;
            version (X86_64) cpu.architecture = "x86_64";
            else version (AArch64) cpu.architecture = "aarch64";
            else cpu.architecture = "unknown";

            SYSTEM_INFO si;
            GetSystemInfo(&si);
            cpu.logical_cores = si.dwNumberOfProcessors > 0 ? si.dwNumberOfProcessors : 1;

            version (D_InlineAsm_X86_64) {
                static void cpuidReg(uint leaf, out uint a, out uint b, out uint c, out uint d) nothrow @nogc {
                    uint ra, rb, rc, rd;
                    asm nothrow @nogc {
                        mov EAX, leaf;
                        xor ECX, ECX;
                        cpuid;
                        mov ra, EAX;
                        mov rb, EBX;
                        mov rc, ECX;
                        mov rd, EDX;
                    }
                    a = ra; b = rb; c = rc; d = rd;
                }

                uint maxExt, dummy1, dummy2, dummy3;
                cpuidReg(0x80000000u, maxExt, dummy1, dummy2, dummy3);
                if (maxExt >= 0x80000004u) {
                    uint[12] brand;
                    cpuidReg(0x80000002u, brand[0], brand[1], brand[2], brand[3]);
                    cpuidReg(0x80000003u, brand[4], brand[5], brand[6], brand[7]);
                    cpuidReg(0x80000004u, brand[8], brand[9], brand[10], brand[11]);
                    auto raw = cast(const(char)[]) brand[0 .. $];
                    size_t nul = raw.length;
                    foreach (idx, ch; raw) {
                        if (ch == '\0') { nul = idx; break; }
                    }
                    cpu.display_name = sanitizeOsString(raw[0 .. nul].idup, 160);
                }
            }

            if (cpu.display_name.length == 0) {
                HKEY hk;
                if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, `HARDWARE\DESCRIPTION\System\CentralProcessor\0`.ptr, 0, KEY_READ, &hk) == ERROR_SUCCESS) {
                    scope (exit) RegCloseKey(hk);
                    char[256] buf;
                    DWORD bsz = cast(DWORD) buf.length;
                    DWORD rtype = 0;
                    if (RegQueryValueExA(hk, "ProcessorNameString".ptr, null, &rtype, cast(ubyte*) buf.ptr, &bsz) == ERROR_SUCCESS && bsz > 0) {
                        cpu.display_name = sanitizeOsString(cast(string) buf[0 .. bsz - 1], 160);
                    }
                }
            }

            auto low = cpu.display_name.toLower();
            if (low.canFind("amd")) cpu.vendor = "AMD";
            else if (low.canFind("intel")) cpu.vendor = "Intel";
            else if (low.canFind("qualcomm") || low.canFind("arm")) cpu.vendor = "ARM";

            cpu.isa = detectHostX86Isa();
            return cpu;
        }

        private GraphicsAdapterHardware[] readRegistryDisplayAdapters() {
            GraphicsAdapterHardware[] gpus;
            enum baseKey = `SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}`;
            HKEY hkRoot;
            if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, baseKey.ptr, 0, KEY_READ, &hkRoot) != ERROR_SUCCESS) {
                return gpus;
            }
            scope (exit) RegCloseKey(hkRoot);

            for (DWORD i = 0; i < 16; i++) {
                char[32] subName;
                DWORD subLen = cast(DWORD) subName.length;
                if (RegEnumKeyExA(hkRoot, i, subName.ptr, &subLen, null, null, null, null) != ERROR_SUCCESS) break;
                auto s = cast(string) subName[0 .. subLen];
                if (s.length != 4 || s[0] < '0' || s[0] > '9') continue;

                HKEY hkSub;
                auto fullSub = baseKey ~ `\` ~ s;
                if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, fullSub.ptr, 0, KEY_READ, &hkSub) != ERROR_SUCCESS) continue;
                scope (exit) RegCloseKey(hkSub);

                char[256] descBuf;
                DWORD dsz = cast(DWORD) descBuf.length;
                DWORD dtype = 0;
                if (RegQueryValueExA(hkSub, "DriverDesc".ptr, null, &dtype, cast(ubyte*) descBuf.ptr, &dsz) == ERROR_SUCCESS && dsz > 1) {
                    GraphicsAdapterHardware ga;
                    ga.id = "win-display:" ~ s;
                    ga.display_name = sanitizeOsString(cast(string) descBuf[0 .. dsz - 1], 160);
                    auto low = ga.display_name.toLower();
                    if (low.canFind("nvidia")) ga.vendor = "NVIDIA";
                    else if (low.canFind("amd") || low.canFind("radeon")) ga.vendor = "AMD";
                    else if (low.canFind("intel")) ga.vendor = "Intel";

                    ulong vramBytes = 0;
                    DWORD vsz = ulong.sizeof;
                    DWORD vtype = 0;
                    if (RegQueryValueExA(hkSub, "HardwareInformation.qwMemorySize".ptr, null, &vtype, cast(ubyte*) &vramBytes, &vsz) == ERROR_SUCCESS && vramBytes > 0) {
                        ga.memory_total_bytes = vramBytes;
                    }
                    gpus ~= ga;
                }
            }
            return gpus;
        }
    }
}
