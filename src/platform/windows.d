module platform.windows;

import core.model;
import core.serializer : sanitizeOsString;
import hardware.inventory;
import platform.api;
import platform.nvml;
import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.format : format;
import std.string : indexOf, strip, toLower;
import std.typecons : Nullable;

// ---------------------------------------------------------------------------
// Pure, OS-independent helpers. These compile on every platform so Windows
// parsing/classification rules are unit-tested on Linux and macOS CI as well.
// ---------------------------------------------------------------------------

/// MIB_IF_ROW2.InterfaceAndOperStatusFlags bits.
enum ubyte WIN_IF_FLAG_HARDWARE = 0x01;
enum ubyte WIN_IF_FLAG_FILTER = 0x02;
enum ubyte WIN_IF_FLAG_CONNECTOR_PRESENT = 0x04;

/// Classifies a Windows network interface row into hikari's telemetry kinds
/// (`physical`, `wireless`, `virtual`, `tailnet`). Returns "" when the row is a
/// lightweight filter, loopback, or a software-only pseudo interface (WAN
/// Miniport, Teredo, ISATAP, kernel debugger) that should not be shown at all.
string classifyWindowsInterface(uint ifType, int physicalMedium, ubyte flags, string aliasName, string description) pure @safe {
    enum uint IF_TYPE_SOFTWARE_LOOPBACK = 24;
    enum uint IF_TYPE_IEEE80211 = 71;
    enum int NDIS_PHYSICAL_MEDIUM_WIRELESS_LAN = 1;
    enum int NDIS_PHYSICAL_MEDIUM_NATIVE_802_11 = 9;
    enum int NDIS_PHYSICAL_MEDIUM_BLUETOOTH = 10;

    if ((flags & WIN_IF_FLAG_FILTER) != 0) return "";
    if (ifType == IF_TYPE_SOFTWARE_LOOPBACK) return "";

    auto low = (aliasName ~ " " ~ description).toLower();
    if (low.canFind("tailscale") || low.canFind("wireguard") || low.canFind("wintun")) return "tailnet";
    if (low.canFind("kernel debug")) return "";

    if ((flags & WIN_IF_FLAG_HARDWARE) == 0) {
        // Hyper-V virtual switches carry real VM/WSL traffic; keep them as virtual.
        if (aliasName.toLower().startsWith("vethernet")) return "virtual";
        return "";
    }

    if (low.canFind("virtualbox") || low.canFind("vmware") || low.canFind("hyper-v")
        || low.canFind("virtual adapter") || low.canFind("wi-fi direct")) {
        return "virtual";
    }
    if (ifType == IF_TYPE_IEEE80211 || physicalMedium == NDIS_PHYSICAL_MEDIUM_NATIVE_802_11
        || physicalMedium == NDIS_PHYSICAL_MEDIUM_WIRELESS_LAN || physicalMedium == NDIS_PHYSICAL_MEDIUM_BLUETOOTH) {
        return "wireless";
    }
    return "physical";
}

struct PnpIds {
    string bus;
    string vendor_id;
    string device_id;
}

private string hexAfter(string low, string key, size_t width) pure @safe {
    auto at = low.indexOf(key);
    if (at < 0) return "";
    auto start = cast(size_t) at + key.length;
    if (start + width > low.length) return "";
    auto s = low[start .. start + width];
    foreach (ch; s) {
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) return "";
    }
    return s;
}

/// Parses a PnP hardware/component ID such as `PCI\VEN_8086&DEV_15F3&SUBSYS_...`
/// or `USB\VID_0BDA&PID_8153` into bus and lowercase hex vendor/device IDs.
/// Instance-specific suffixes (which can be unique identifiers) are ignored.
PnpIds parsePnpHardwareId(string hwid) pure @safe {
    PnpIds r;
    auto low = hwid.strip().toLower();
    if (low.length == 0) return r;
    auto sep = low.indexOf('\\');
    string enumerator = sep > 0 ? low[0 .. sep] : low;
    switch (enumerator) {
        case "pci":
            r.bus = "pci";
            r.vendor_id = hexAfter(low, "ven_", 4);
            r.device_id = hexAfter(low, "dev_", 4);
            break;
        case "usb":
            r.bus = "usb";
            r.vendor_id = hexAfter(low, "vid_", 4);
            r.device_id = hexAfter(low, "pid_", 4);
            break;
        case "bth":
        case "bthenum":
        case "bthpan":
            r.bus = "bluetooth";
            break;
        case "acpi":
            r.bus = "acpi";
            break;
        case "sd":
            r.bus = "sdio";
            break;
        case "root":
        case "swd":
            r.bus = "virtual";
            break;
        default:
            if (enumerator.startsWith("{") || enumerator.startsWith("ms_") || enumerator.startsWith("wintun")
                || enumerator.startsWith("tap")) {
                r.bus = "virtual";
            } else if (enumerator.length > 0 && enumerator.length <= 16 && sep > 0) {
                r.bus = enumerator;
            }
            break;
    }
    return r;
}

string pciVendorName(string vendorId) pure @safe {
    switch (vendorId.toLower()) {
        case "10de": return "NVIDIA";
        case "1002": case "1022": return "AMD";
        case "8086": return "Intel";
        case "1414": return "Microsoft";
        case "5143": case "17cb": return "Qualcomm";
        case "10ec": return "Realtek";
        case "14e4": return "Broadcom";
        case "168c": return "Qualcomm Atheros";
        case "1969": return "Qualcomm Atheros";
        case "15ad": return "VMware";
        case "80ee": return "VirtualBox";
        case "1af4": return "Red Hat (virtio)";
        default: return "";
    }
}

/// Maps the STORAGE_BUS_TYPE enumeration to hikari's bus vocabulary.
string mapStorageBusType(uint busType) pure @safe {
    switch (busType) {
        case 0x01: return "scsi";
        case 0x02: return "atapi";
        case 0x03: return "ata";
        case 0x04: return "ieee1394";
        case 0x06: return "fibre";
        case 0x07: return "usb";
        case 0x08: return "raid";
        case 0x09: return "iscsi";
        case 0x0A: return "sas";
        case 0x0B: return "sata";
        case 0x0C: return "sd";
        case 0x0D: return "mmc";
        case 0x0E: return "virtual";
        case 0x0F: return "virtual";
        case 0x10: return "storage_spaces";
        case 0x11: return "nvme";
        case 0x12: return "scm";
        case 0x13: return "ufs";
        default: return "unknown";
    }
}

struct StorageDescriptorFacts {
    bool ok = false;
    string vendor;
    string product;
    uint busType;
    bool removable;
}

private uint readU32(const(ubyte)[] b, size_t off) pure nothrow @safe {
    if (off + 4 > b.length) return 0;
    return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (cast(uint) b[off + 3] << 24);
}

private ulong readU64(const(ubyte)[] b, size_t off) pure nothrow @safe {
    if (off + 8 > b.length) return 0;
    return cast(ulong) readU32(b, off) | (cast(ulong) readU32(b, off + 4) << 32);
}

private string cStringAt(const(ubyte)[] b, uint off) pure @safe {
    if (off == 0 || off >= b.length) return "";
    size_t end = off;
    while (end < b.length && b[end] != 0) end++;
    return sanitizeOsString(cast(string) b[off .. end].idup, 96).strip();
}

/// Parses a STORAGE_DEVICE_DESCRIPTOR. The serial-number offset is deliberately
/// never read: hikari must not publish unique disk identifiers.
StorageDescriptorFacts parseStorageDeviceDescriptor(const(ubyte)[] b) pure @safe {
    StorageDescriptorFacts f;
    if (b.length < 36) return f;
    uint size = readU32(b, 4);
    auto view = size >= 36 && size <= b.length ? b[0 .. size] : b;
    f.removable = view[10] != 0;
    f.vendor = cStringAt(view, readU32(view, 12));
    f.product = cStringAt(view, readU32(view, 16));
    f.busType = readU32(view, 28);
    f.ok = true;
    return f;
}

/// Parses VOLUME_DISK_EXTENTS and returns the distinct physical disk numbers.
uint[] parseVolumeDiskExtents(const(ubyte)[] b) pure @safe {
    uint[] disks;
    if (b.length < 8) return disks;
    uint n = readU32(b, 0);
    foreach (i; 0 .. n) {
        size_t off = 8 + cast(size_t) i * 24;
        if (off + 24 > b.length) break;
        uint d = readU32(b, off);
        if (!disks.canFind(d)) disks ~= d;
    }
    return disks;
}

struct WinCpuTopology {
    bool ok = false;
    uint sockets;
    uint physicalCores;
    uint logicalProcessors;
    uint performanceCores;
    uint efficiencyCores;
    bool heterogeneous;
    ulong l1d, l1i, l2, l3;
}

/// Parses the buffer returned by GetLogicalProcessorInformationEx(RelationAll).
WinCpuTopology parseLogicalProcessorInfoEx(const(ubyte)[] b) pure @safe {
    enum uint RelationProcessorCore = 0;
    enum uint RelationCache = 2;
    enum uint RelationProcessorPackage = 3;

    WinCpuTopology t;
    ubyte[] coreClasses;
    size_t pos = 0;
    while (pos + 8 <= b.length) {
        uint rel = readU32(b, pos);
        uint size = readU32(b, pos + 4);
        if (size < 8 || pos + size > b.length) break;
        auto rec = b[pos .. pos + size];
        if (rel == RelationProcessorCore && rec.length >= 8 + 24) {
            t.physicalCores++;
            coreClasses ~= rec[8 + 1];
            uint groupCount = rec[8 + 22] | (rec[8 + 23] << 8);
            foreach (g; 0 .. groupCount) {
                size_t mo = 8 + 24 + cast(size_t) g * 16;
                if (mo + 8 > rec.length) break;
                ulong mask = readU64(rec, mo);
                while (mask != 0) {
                    t.logicalProcessors += cast(uint)(mask & 1);
                    mask >>= 1;
                }
            }
        } else if (rel == RelationProcessorPackage) {
            t.sockets++;
        } else if (rel == RelationCache && rec.length >= 8 + 12) {
            ubyte level = rec[8];
            uint cacheSize = readU32(rec, 8 + 4);
            uint type = readU32(rec, 8 + 8); // 0 unified, 1 instruction, 2 data, 3 trace
            if (level == 1 && type == 2) t.l1d += cacheSize;
            else if (level == 1 && type == 1) t.l1i += cacheSize;
            else if (level == 2) t.l2 += cacheSize;
            else if (level == 3) t.l3 += cacheSize;
        }
        pos += size;
    }
    if (t.physicalCores > 0) {
        ubyte maxClass = 0;
        ubyte minClass = 255;
        foreach (c; coreClasses) {
            if (c > maxClass) maxClass = c;
            if (c < minClass) minClass = c;
        }
        if (maxClass != minClass) {
            t.heterogeneous = true;
            foreach (c; coreClasses) {
                if (c == maxClass) t.performanceCores++;
                else t.efficiencyCores++;
            }
        }
        t.ok = true;
    }
    return t;
}

/// Identifies common hypervisors from SMBIOS system strings. CPUID's hypervisor
/// bit is intentionally not used on Windows: with VBS/Hyper-V enabled, the
/// physical host's root partition also reports it.
string detectVirtualizationFromSystemStrings(string manufacturer, string model) pure @safe {
    auto low = (manufacturer ~ " " ~ model).toLower();
    if (low.canFind("qemu") || low.canFind("kvm") || low.canFind("bochs")) return "kvm";
    if (low.canFind("vmware")) return "vmware";
    if (low.canFind("virtualbox") || low.canFind("innotek")) return "virtualbox";
    if (low.canFind("microsoft corporation") && low.canFind("virtual")) return "hyper-v";
    if (low.canFind("parallels")) return "parallels";
    return "";
}

// ---------------------------------------------------------------------------
// Win32 bindings (declared locally to avoid druntime version gating).
// ---------------------------------------------------------------------------

version (Windows) {
    pragma(lib, "iphlpapi");
    pragma(lib, "advapi32");
    pragma(lib, "psapi");
    pragma(lib, "setupapi");

    import core.sys.windows.basetyps : GUID;
    import core.sys.windows.winbase;
    import core.sys.windows.windef;
    import core.sys.windows.winnt;
    import core.sys.windows.winreg : HKEY_LOCAL_MACHINE, RegCloseKey, RegOpenKeyExW, RegQueryValueExW;
    import core.sys.windows.tlhelp32;
    import core.sys.windows.psapi : PROCESS_MEMORY_COUNTERS, GetProcessMemoryInfo;
    import core.sys.windows.winerror : ERROR_INSUFFICIENT_BUFFER, ERROR_SUCCESS, NO_ERROR;
    import std.utf : toUTF16z, toUTF8;

    private enum uint H_PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private enum uint H_DRIVE_REMOVABLE = 2;
    private enum uint H_DRIVE_FIXED = 3;
    private enum uint H_RSMB_SIG = 0x52534D42; // 'RSMB'
    private enum uint H_IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400;
    private enum uint H_IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x000700A0;
    private enum uint H_IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = 0x00560000;
    private enum uint H_DIGCF_PRESENT = 0x2;
    private enum uint H_SPDRP_DEVICEDESC = 0x0;
    private enum uint H_SPDRP_HARDWAREID = 0x1;
    private enum uint H_SPDRP_SERVICE = 0x4;
    private enum uint H_SPDRP_DRIVER = 0x9;
    private enum uint H_SPDRP_FRIENDLYNAME = 0xC;

    private immutable GUID H_GUID_DEVCLASS_DISPLAY = GUID(0x4d36e968, 0xe325, 0x11ce, [0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18]);
    private immutable GUID H_GUID_DEVCLASS_NET = GUID(0x4d36e972, 0xe325, 0x11ce, [0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18]);

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

    private struct H_MIB_IF_ROW2 {
        ulong InterfaceLuid;
        uint InterfaceIndex;
        GUID InterfaceGuid;
        wchar[257] Alias;
        wchar[257] Description;
        uint PhysicalAddressLength;
        ubyte[32] PhysicalAddress;
        ubyte[32] PermanentPhysicalAddress;
        uint Mtu;
        uint Type;
        int TunnelType;
        int MediaType;
        int PhysicalMediumType;
        int AccessType;
        int DirectionType;
        ubyte InterfaceAndOperStatusFlags;
        int OperStatus;
        int AdminStatus;
        int MediaConnectState;
        GUID NetworkGuid;
        int ConnectionType;
        ulong TransmitLinkSpeed;
        ulong ReceiveLinkSpeed;
        ulong InOctets;
        ulong InUcastPkts;
        ulong InNUcastPkts;
        ulong InDiscards;
        ulong InErrors;
        ulong InUnknownProtos;
        ulong InUcastOctets;
        ulong InMulticastOctets;
        ulong InBroadcastOctets;
        ulong OutOctets;
        ulong OutUcastPkts;
        ulong OutNUcastPkts;
        ulong OutDiscards;
        ulong OutErrors;
        ulong OutUcastOctets;
        ulong OutMulticastOctets;
        ulong OutBroadcastOctets;
        ulong OutQLen;
    }
    version (X86_64) static assert(H_MIB_IF_ROW2.sizeof == 1352, "MIB_IF_ROW2 layout mismatch");

    private struct H_MIB_IF_TABLE2 {
        uint NumEntries;
        H_MIB_IF_ROW2[1] Table;
    }

    private struct H_SP_DEVINFO_DATA {
        uint cbSize;
        GUID ClassGuid;
        uint DevInst;
        size_t Reserved;
    }

    private extern (Windows) nothrow @nogc {
        BOOL GetSystemTimes(FILETIME* lpIdleTime, FILETIME* lpKernelTime, FILETIME* lpUserTime);
        ulong GetTickCount64();
        BOOL GetSystemPowerStatus(H_SYSTEM_POWER_STATUS* lpSystemPowerStatus);
        uint GetSystemFirmwareTable(uint FirmwareTableProviderSignature, uint FirmwareTableID, void* pFirmwareTableBuffer, uint BufferSize);
        BOOL GetDiskFreeSpaceExW(const(wchar)* lpDirectoryName, ULARGE_INTEGER* lpFreeBytesAvailableToCaller, ULARGE_INTEGER* lpTotalNumberOfBytes, ULARGE_INTEGER* lpTotalNumberOfFreeBytes);
        BOOL GetLogicalProcessorInformationEx(int RelationshipType, void* Buffer, uint* ReturnedLength);
        BOOL GetFirmwareType(uint* FirmwareType);
        uint GetActiveProcessorCount(ushort GroupNumber);
        uint GetIfTable2(H_MIB_IF_TABLE2** Table);
        void FreeMibTable(void* Memory);
        void* SetupDiGetClassDevsW(const(GUID)* ClassGuid, const(wchar)* Enumerator, void* hwndParent, uint Flags);
        BOOL SetupDiEnumDeviceInfo(void* DeviceInfoSet, uint MemberIndex, H_SP_DEVINFO_DATA* DeviceInfoData);
        BOOL SetupDiGetDeviceRegistryPropertyW(void* DeviceInfoSet, H_SP_DEVINFO_DATA* DeviceInfoData, uint Property,
            uint* PropertyRegDataType, ubyte* PropertyBuffer, uint PropertyBufferSize, uint* RequiredSize);
        BOOL SetupDiDestroyDeviceInfoList(void* DeviceInfoSet);
        alias fn_RtlGetVersion = int function(H_RTL_OSVERSIONINFOW*);
    }

    private ulong fileTimeToU64(FILETIME ft) pure nothrow @nogc @safe {
        return (cast(ulong) ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    }

    private string wideToString(const(wchar)[] w, size_t maxLen = 160) {
        size_t n = 0;
        while (n < w.length && w[n] != 0) n++;
        if (n == 0) return "";
        try {
            return sanitizeOsString(toUTF8(w[0 .. n]), maxLen).strip();
        } catch (Exception) {
            return "";
        }
    }

    private string guidToString(const ref GUID g) {
        return format!"{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}"(
            g.Data1, g.Data2, g.Data3, g.Data4[0], g.Data4[1],
            g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7]);
    }

    /// Reads a registry value under HKLM; returns raw bytes and type, or null.
    private ubyte[] regReadRaw(string subKey, string valueName, out uint valueType) {
        HKEY hk;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, subKey.toUTF16z(), 0, KEY_READ, &hk) != ERROR_SUCCESS) return null;
        scope (exit) RegCloseKey(hk);
        uint sz = 0;
        auto vname = valueName.toUTF16z();
        if (RegQueryValueExW(hk, vname, null, &valueType, null, &sz) != ERROR_SUCCESS || sz == 0 || sz > 65536) return null;
        auto buf = new ubyte[sz];
        if (RegQueryValueExW(hk, vname, null, &valueType, buf.ptr, &sz) != ERROR_SUCCESS) return null;
        return buf[0 .. sz];
    }

    private string regString(string subKey, string valueName, size_t maxLen = 160) {
        enum uint REG_SZ = 1, REG_EXPAND_SZ = 2, REG_MULTI_SZ = 7;
        uint t;
        auto raw = regReadRaw(subKey, valueName, t);
        if (raw is null || (t != REG_SZ && t != REG_EXPAND_SZ && t != REG_MULTI_SZ)) return "";
        auto w = (cast(const(wchar)*) raw.ptr)[0 .. raw.length / 2];
        return wideToString(w, maxLen);
    }

    private Nullable!ulong regUlong(string subKey, string valueName) {
        enum uint REG_BINARY = 3, REG_DWORD = 4, REG_QWORD = 11;
        Nullable!ulong r;
        uint t;
        auto raw = regReadRaw(subKey, valueName, t);
        if (raw is null) return r;
        if ((t == REG_DWORD || t == REG_BINARY) && raw.length == 4) r = cast(ulong) readU32(raw, 0);
        else if ((t == REG_QWORD || t == REG_BINARY) && raw.length == 8) r = readU64(raw, 0);
        return r;
    }

    private struct PnpDevice {
        string description;
        string hardwareId;
        string service;
        string driverKey;
    }

    private string devProperty(void* set, H_SP_DEVINFO_DATA* dd, uint prop) {
        ubyte[1024] stackBuf;
        uint regType = 0, required = 0;
        if (SetupDiGetDeviceRegistryPropertyW(set, dd, prop, &regType, stackBuf.ptr, cast(uint) stackBuf.length, &required)) {
            // For REG_MULTI_SZ (hardware IDs) the first entry is the most specific.
            return wideToString((cast(const(wchar)*) stackBuf.ptr)[0 .. stackBuf.length / 2]);
        }
        if (GetLastError() == ERROR_INSUFFICIENT_BUFFER && required > 0 && required <= 65536) {
            auto heap = new ubyte[required];
            if (SetupDiGetDeviceRegistryPropertyW(set, dd, prop, &regType, heap.ptr, required, &required)) {
                return wideToString((cast(const(wchar)*) heap.ptr)[0 .. heap.length / 2]);
            }
        }
        return "";
    }

    /// Enumerates *present* devices of a setup class (ghost devices are skipped).
    private PnpDevice[] enumeratePresentDevices(const ref GUID cls) {
        PnpDevice[] devs;
        void* set = SetupDiGetClassDevsW(&cls, null, null, H_DIGCF_PRESENT);
        if (set is null || set == INVALID_HANDLE_VALUE) return devs;
        scope (exit) SetupDiDestroyDeviceInfoList(set);
        for (uint i = 0; i < 256; i++) {
            H_SP_DEVINFO_DATA dd;
            dd.cbSize = H_SP_DEVINFO_DATA.sizeof;
            if (!SetupDiEnumDeviceInfo(set, i, &dd)) break;
            PnpDevice d;
            d.description = devProperty(set, &dd, H_SPDRP_FRIENDLYNAME);
            if (d.description.length == 0) d.description = devProperty(set, &dd, H_SPDRP_DEVICEDESC);
            d.hardwareId = devProperty(set, &dd, H_SPDRP_HARDWAREID);
            d.service = devProperty(set, &dd, H_SPDRP_SERVICE);
            d.driverKey = devProperty(set, &dd, H_SPDRP_DRIVER);
            devs ~= d;
        }
        return devs;
    }

    private struct WinIfRow {
        string id;
        string guid;
        string aliasName;
        string description;
        string kind;
        ulong rxBytes;
        ulong txBytes;
        bool up;
        Nullable!ulong speedBps;
        string mac;
    }

    private bool readIfRows(out WinIfRow[] rows, bool withMac) {
        H_MIB_IF_TABLE2* table = null;
        if (GetIfTable2(&table) != NO_ERROR || table is null) return false;
        scope (exit) FreeMibTable(table);
        auto all = (&table.Table[0])[0 .. table.NumEntries];
        foreach (const ref row; all) {
            auto aliasName = wideToString(row.Alias[], 128);
            auto desc = wideToString(row.Description[], 160);
            auto kind = classifyWindowsInterface(row.Type, row.PhysicalMediumType, row.InterfaceAndOperStatusFlags, aliasName, desc);
            if (kind.length == 0) continue;
            WinIfRow r;
            // NET_LUID is stable across reboots, unlike ifIndex, and is not a hardware identifier.
            r.id = format!"luid:%x"(row.InterfaceLuid);
            r.guid = guidToString(row.InterfaceGuid);
            r.aliasName = aliasName.length > 0 ? aliasName : desc;
            r.description = desc.length > 0 ? desc : aliasName;
            r.kind = kind;
            r.rxBytes = row.InOctets;
            r.txBytes = row.OutOctets;
            r.up = row.OperStatus == 1; // IfOperStatusUp
            if (row.ReceiveLinkSpeed > 0 && row.ReceiveLinkSpeed != ulong.max) r.speedBps = row.ReceiveLinkSpeed;
            if (withMac && row.PhysicalAddressLength > 0 && row.PhysicalAddressLength <= 8) {
                string m;
                foreach (i; 0 .. row.PhysicalAddressLength) {
                    if (i > 0) m ~= ":";
                    m ~= format!"%02x"(row.PhysicalAddress[i]);
                }
                r.mac = m;
            }
            rows ~= r;
        }
        return true;
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
            wchar[256] compName;
            DWORD sz = cast(DWORD) compName.length;
            if (GetComputerNameW(compName.ptr, &sz) && sz > 0) {
                id.host = wideToString(compName[0 .. sz], 128);
            }
            if (id.host.length == 0) id.host = "windows-host";

            ulong upMs = GetTickCount64();
            id.uptime_s = cast(long)(upMs / 1000UL);

            // Boot session identity: wall-clock boot time rounded to minutes.
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
            // GetSystemTimes kernel time INCLUDES idle time.
            ulong idle = fileTimeToU64(idleFt);
            ulong kern = fileTimeToU64(kernFt);
            ulong user = fileTimeToU64(userFt);
            c.idle_ticks = idle;
            c.total_ticks = kern + user;

            uint active = GetActiveProcessorCount(0xFFFF); // ALL_PROCESSOR_GROUPS
            if (active == 0) {
                SYSTEM_INFO si;
                GetSystemInfo(&si);
                active = si.dwNumberOfProcessors;
            }
            c.logical_cores = active > 0 ? active : 1;
            // Unix load_1m has no Windows equivalent; left null deliberately.
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
            // ullTotalPageFile is the commit limit, NOT Unix swap.
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
            WinIfRow[] rows;
            if (!readIfRows(rows, false)) {
                r.state = CapabilityState.error;
                r.error = "get_if_table2_failed";
                return r;
            }
            r.state = CapabilityState.ok;
            foreach (row; rows) {
                RawNetworkInterface ni;
                ni.id = row.id;
                ni.name = row.aliasName;
                ni.kind = row.kind;
                ni.rx_bytes = row.rxBytes;
                ni.tx_bytes = row.txBytes;
                ni.link_up = row.up;
                if (row.up) ni.link_speed_bps = row.speedBps;
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
                // Processes we may not query (protected, or other users' processes
                // when running as a restricted service account) are skipped, not zeroed.
                HANDLE hProc = OpenProcess(H_PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pe.th32ProcessID);
                if (hProc is null) continue;
                scope (exit) CloseHandle(hProc);

                FILETIME ct, et, kt, ut;
                if (!GetProcessTimes(hProc, &ct, &et, &kt, &ut)) continue;

                PROCESS_MEMORY_COUNTERS pmc;
                pmc.cb = PROCESS_MEMORY_COUNTERS.sizeof;
                if (!GetProcessMemoryInfo(hProc, &pmc, PROCESS_MEMORY_COUNTERS.sizeof)) continue;

                auto pname = wideToString(pe.szExeFile[], 128);

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

    version (Windows) {
        /// Drive letters ("C:\") with their GetDriveType classification.
        private wstring[] logicalDrives(bool includeRemovable) {
            wstring[] res;
            wchar[512] drivesBuf;
            DWORD len = GetLogicalDriveStringsW(cast(DWORD) drivesBuf.length, drivesBuf.ptr);
            if (len == 0 || len > drivesBuf.length) return res;
            size_t pos = 0;
            while (pos < len) {
                size_t end = pos;
                while (end < len && drivesBuf[end] != 0) end++;
                if (end == pos) break;
                auto root = drivesBuf[pos .. end].idup;
                auto dt = GetDriveTypeW((root ~ "\0"w).ptr);
                // Network, CD-ROM and RAM-disk roots are never queried: they can block.
                if (dt == H_DRIVE_FIXED || (includeRemovable && dt == H_DRIVE_REMOVABLE)) res ~= root;
                pos = end + 1;
            }
            return res;
        }
    }

    override RawFilesystemResult sampleFilesystems() {
        RawFilesystemResult r;
        version (Windows) {
            // Suppress "insert disk" dialogs for empty readers in service context.
            auto prevMode = SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
            scope (exit) SetErrorMode(prevMode);

            r.state = CapabilityState.ok;
            foreach (root; logicalDrives(false)) {
                auto rootZ = (root ~ "\0"w).ptr;
                ULARGE_INTEGER availBytes, totalBytes, freeBytes;
                if (!GetDiskFreeSpaceExW(rootZ, &availBytes, &totalBytes, &freeBytes) || totalBytes.QuadPart == 0) continue;
                wchar[64] fsNameBuf;
                string fsType = "unknown";
                if (GetVolumeInformationW(rootZ, null, 0, null, null, null, fsNameBuf.ptr, cast(DWORD) fsNameBuf.length)) {
                    auto f = wideToString(fsNameBuf[], 32).toLower();
                    if (f.length > 0) fsType = f;
                }
                auto mnt = wideToString(root, 32);
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
            // BatteryFlag 128 = no system battery; 255 = unknown status.
            if ((sps.BatteryFlag & 128) == 0 && sps.BatteryFlag != 255 && sps.BatteryLifePercent <= 100) {
                BatteryStatus b;
                b.id = "BAT0";
                b.name = "System Battery";
                if ((sps.BatteryFlag & 8) != 0) {
                    b.status = "charging";
                } else if (sps.ACLineStatus == 1) {
                    b.status = sps.BatteryLifePercent >= 100 ? "full" : "not_charging";
                } else if (sps.ACLineStatus == 0) {
                    b.status = "discharging";
                } else {
                    b.status = "unknown";
                }
                b.pct = cast(double) sps.BatteryLifePercent;
                if (sps.ACLineStatus == 0 && sps.BatteryLifeTime != 0xFFFFFFFFu) {
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
                        enum cvKey = `SOFTWARE\Microsoft\Windows NT\CurrentVersion`;
                        auto ubr = regUlong(cvKey, "UBR");
                        r.drift.running_kernel = ubr.isNull
                            ? format!"%u.%u.%u"(vi.dwMajorVersion, vi.dwMinorVersion, vi.dwBuildNumber)
                            : format!"%u.%u.%u.%u"(vi.dwMajorVersion, vi.dwMinorVersion, vi.dwBuildNumber, ubr.get);
                    }
                }
            }

            static bool regKeyExists(string subKey) {
                HKEY hk;
                if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, subKey.toUTF16z(), 0, KEY_READ, &hk) == ERROR_SUCCESS) {
                    RegCloseKey(hk);
                    return true;
                }
                return false;
            }

            // Servicing-stack and Windows Update reboot flags. PendingFileRenameOperations is
            // intentionally ignored: installers set it routinely and it is a poor signal.
            bool cbsReboot = regKeyExists(`SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending`);
            bool wuReboot = regKeyExists(`SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired`);
            r.drift.reboot_required = (cbsReboot || wuReboot);
            // pending_updates stays null: counting them needs the WU agent (network/slow).
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
            bool partial = false;

            // 1. SMBIOS via GetSystemFirmwareTable('RSMB'): no admin rights required.
            uint rawSz = GetSystemFirmwareTable(H_RSMB_SIG, 0, null, 0);
            bool smbiosOk = false;
            if (rawSz > H_RawSMBIOSData.sizeof) {
                auto rawBuf = new ubyte[rawSz];
                if (GetSystemFirmwareTable(H_RSMB_SIG, 0, rawBuf.ptr, rawSz) == rawSz) {
                    smbiosOk = true;
                    auto hdr = cast(H_RawSMBIOSData*) rawBuf.ptr;
                    size_t tableOff = H_RawSMBIOSData.sizeof;
                    size_t tableEnd = tableOff + hdr.Length;
                    if (tableEnd > rawBuf.length) tableEnd = rawBuf.length;
                    auto parsed = parseSmbiosTables(rawBuf[tableOff .. tableEnd]);
                    hw.system = parsed.system;
                    hw.board = parsed.board;
                    hw.firmware = parsed.firmware;
                    hw.memory.modules = parsed.memoryModules;
                    foreach (m; hw.memory.modules) {
                        if (hw.memory.technology.length == 0 && m.technology.length > 0) hw.memory.technology = m.technology;
                        if (hw.memory.speed_mt_s.isNull && !m.speed_mt_s.isNull) hw.memory.speed_mt_s = m.speed_mt_s;
                    }
                }
            }
            auto modState = hw.memory.modules.length > 0 ? CapabilityState.ok : CapabilityState.unavailable;
            hw.memory.module_enumeration = modState;
            hw.capabilities["memory_modules"] = modState;
            hw.capabilities["board"] = (hw.board.manufacturer.length > 0 || hw.board.model.length > 0)
                ? CapabilityState.ok : CapabilityState.unavailable;
            if (!smbiosOk) partial = true;

            // Actual boot firmware mode (SMBIOS only says what is supported).
            uint fwType = 0;
            if (GetFirmwareType(&fwType)) {
                if (fwType == 1) hw.firmware.type = "BIOS";
                else if (fwType == 2) hw.firmware.type = "UEFI";
            }

            auto virt = detectVirtualizationFromSystemStrings(hw.system.manufacturer, hw.system.model);
            if (virt.length > 0) {
                hw.system.virtualization = virt;
                hw.system.form_factor = "vm";
            }

            // 2. CPU brand, topology and usable ISA.
            hw.cpu = readWindowsCpuInfo();
            hw.capabilities["isa"] = hw.cpu.isa.usable.length > 0 ? CapabilityState.ok : CapabilityState.unavailable;

            // 3. Memory total.
            auto rawMem = sampleMemory();
            if (rawMem.state == CapabilityState.ok) hw.memory.total_bytes = rawMem.total_bytes;

            // 4. Network adapters: IP Helper rows enriched with SetupAPI driver/bus/IDs.
            WinIfRow[] ifRows;
            if (readIfRows(ifRows, exposeMacAddresses)) {
                PnpDevice[string] netByGuid;
                foreach (d; enumeratePresentDevices(H_GUID_DEVCLASS_NET)) {
                    if (d.driverKey.length == 0) continue;
                    auto cfgId = regString(`SYSTEM\CurrentControlSet\Control\Class\` ~ d.driverKey, "NetCfgInstanceId", 64);
                    if (cfgId.length > 0) netByGuid[cfgId.toLower()] = d;
                }
                foreach (row; ifRows) {
                    NetworkAdapterHardware na;
                    na.id = row.id;
                    na.display_name = row.description;
                    na.interface_name = row.aliasName;
                    na.kind = row.kind == "physical" ? "ethernet" : row.kind;
                    if (row.up) na.link_speed_bps = row.speedBps;
                    if (exposeMacAddresses) na.mac_address = row.mac;
                    if (auto d = row.guid.toLower() in netByGuid) {
                        if (d.description.length > 0) na.display_name = d.description;
                        auto ids = parsePnpHardwareId(d.hardwareId);
                        na.bus = ids.bus;
                        na.vendor_id = ids.vendor_id;
                        na.device_id = ids.device_id;
                        na.driver = sanitizeOsString(d.service, 64);
                    }
                    hw.network_adapters ~= na;
                }
                hw.capabilities["network_adapters"] = CapabilityState.ok;
            } else {
                hw.capabilities["network_adapters"] = CapabilityState.error;
                partial = true;
            }

            // 5. Graphics adapters (present devices only).
            hw.graphics_adapters = readDisplayAdapters();

            // 6. Physical storage devices and their volume mapping.
            bool storageOk;
            hw.storage_devices = readPhysicalDisks(storageOk);
            hw.capabilities["storage_devices"] = storageOk ? CapabilityState.ok : CapabilityState.unavailable;
            if (!storageOk) partial = true;

            hw.collection.status = GroupStatus.fresh;
            hw.collection.partial = partial;
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

            uint active = GetActiveProcessorCount(0xFFFF);
            if (active > 0) cpu.logical_cores = active;

            // Topology: packages, cores, SMT, caches and heterogeneous efficiency classes.
            uint len = 0;
            GetLogicalProcessorInformationEx(0xFFFF, null, &len);
            if (len > 0 && len < 4 * 1024 * 1024) {
                auto buf = new ubyte[len];
                if (GetLogicalProcessorInformationEx(0xFFFF, buf.ptr, &len)) {
                    auto topo = parseLogicalProcessorInfoEx(buf[0 .. len]);
                    if (topo.ok) {
                        cpu.sockets = topo.sockets > 0 ? topo.sockets : 1;
                        cpu.physical_cores = topo.physicalCores;
                        if (topo.logicalProcessors > 0) cpu.logical_cores = topo.logicalProcessors;
                        if (topo.heterogeneous) {
                            cpu.performance_cores = topo.performanceCores;
                            cpu.efficiency_cores = topo.efficiencyCores;
                        }
                        if (topo.l1d > 0) cpu.cache_bytes.l1d = topo.l1d;
                        if (topo.l1i > 0) cpu.cache_bytes.l1i = topo.l1i;
                        if (topo.l2 > 0) cpu.cache_bytes.l2 = topo.l2;
                        if (topo.l3 > 0) cpu.cache_bytes.l3 = topo.l3;
                    }
                }
            }

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

                uint maxLeaf, vb, vc, vd;
                cpuidReg(0, maxLeaf, vb, vc, vd);
                uint[3] vendorRegs = [vb, vd, vc];
                auto vendorStr = cast(string)(cast(const(char)[]) vendorRegs[]).idup;
                if (vendorStr == "GenuineIntel") cpu.vendor = "Intel";
                else if (vendorStr == "AuthenticAMD") cpu.vendor = "AMD";
                else if (vendorStr == "HygonGenuine") cpu.vendor = "Hygon";
                else if (vendorStr == "CentaurHauls" || vendorStr == "  Shanghai  ") cpu.vendor = "Zhaoxin";

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
                    cpu.display_name = sanitizeOsString(raw[0 .. nul].idup, 160).strip();
                }
            }

            if (cpu.display_name.length == 0) {
                cpu.display_name = regString(`HARDWARE\DESCRIPTION\System\CentralProcessor\0`, "ProcessorNameString");
            }
            if (cpu.vendor.length == 0) {
                auto low = cpu.display_name.toLower();
                if (low.canFind("qualcomm") || low.canFind("snapdragon")) cpu.vendor = "Qualcomm";
                else if (low.canFind("amd")) cpu.vendor = "AMD";
                else if (low.canFind("intel")) cpu.vendor = "Intel";
            }

            version (X86_64) {
                cpu.isa = detectHostX86Isa();
            } else {
                // Windows on ARM: IsProcessorFeaturePresent-based detection not yet implemented.
                cpu.isa.detection = "unavailable";
            }
            return cpu;
        }

        private GraphicsAdapterHardware[] readDisplayAdapters() {
            GraphicsAdapterHardware[] gpus;
            foreach (idx, d; enumeratePresentDevices(H_GUID_DEVCLASS_DISPLAY)) {
                if (d.description.length == 0) continue;
                // RDP session adapters are per-session virtual devices, not hardware.
                if (d.description.toLower().startsWith("microsoft remote display")) continue;

                GraphicsAdapterHardware ga;
                auto ids = parsePnpHardwareId(d.hardwareId);
                ga.display_name = d.description;
                ga.vendor_id = ids.vendor_id;
                ga.device_id = ids.device_id;
                ga.id = ids.vendor_id.length > 0
                    ? format!"%s:%s:%s:%d"(ids.bus, ids.vendor_id, ids.device_id, idx)
                    : format!"display:%d"(idx);
                ga.vendor = pciVendorName(ids.vendor_id);
                if (ga.vendor.length == 0) {
                    auto low = ga.display_name.toLower();
                    if (low.canFind("nvidia")) ga.vendor = "NVIDIA";
                    else if (low.canFind("amd") || low.canFind("radeon")) ga.vendor = "AMD";
                    else if (low.canFind("intel")) ga.vendor = "Intel";
                    else if (low.canFind("microsoft")) ga.vendor = "Microsoft";
                }

                if (d.driverKey.length > 0) {
                    auto classKey = `SYSTEM\CurrentControlSet\Control\Class\` ~ d.driverKey;
                    auto ver = regString(classKey, "DriverVersion", 48);
                    ga.driver = d.service.length > 0
                        ? (ver.length > 0 ? sanitizeOsString(d.service, 48) ~ " " ~ ver : sanitizeOsString(d.service, 48))
                        : ver;
                    auto vram = regUlong(classKey, "HardwareInformation.qwMemorySize");
                    if (vram.isNull || vram.get == 0) vram = regUlong(classKey, "HardwareInformation.MemorySize");
                    // Dedicated VRAM only; integrated GPUs commonly report nothing (left null).
                    if (!vram.isNull && vram.get > 0) ga.memory_total_bytes = vram.get;
                } else if (d.service.length > 0) {
                    ga.driver = sanitizeOsString(d.service, 48);
                }
                gpus ~= ga;
            }
            return gpus;
        }

        private HANDLE openDeviceNoAccess(string path) {
            // Zero access rights: attribute queries only, no reads, no admin required.
            return CreateFileW(path.toUTF16z(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
        }

        private StorageDeviceHardware[] readPhysicalDisks(out bool ok) {
            StorageDeviceHardware[] disks;
            ok = false;

            auto prevMode = SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
            scope (exit) SetErrorMode(prevMode);

            // Map physical disk number -> mounted drive letters.
            string[][uint] mountsByDisk;
            foreach (root; logicalDrives(true)) {
                auto letter = wideToString(root, 8); // "C:\"
                if (letter.length < 2) continue;
                auto h = openDeviceNoAccess(`\\.\` ~ letter[0 .. 2]);
                if (h == INVALID_HANDLE_VALUE) continue;
                scope (exit) CloseHandle(h);
                ubyte[8 + 24 * 16] ext;
                DWORD got = 0;
                if (DeviceIoControl(h, H_IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, null, 0, ext.ptr, cast(DWORD) ext.length, &got, null)) {
                    foreach (dn; parseVolumeDiskExtents(ext[0 .. got])) mountsByDisk[dn] ~= letter;
                }
            }

            uint misses = 0;
            for (uint n = 0; n < 64 && misses < 16; n++) {
                auto h = openDeviceNoAccess(format!`\\.\PhysicalDrive%u`(n));
                if (h == INVALID_HANDLE_VALUE) {
                    misses++;
                    continue;
                }
                misses = 0;
                scope (exit) CloseHandle(h);
                ok = true;

                // STORAGE_PROPERTY_QUERY { PropertyId, QueryType, AdditionalParameters[1] }
                uint[3] query = [0 /* StorageDeviceProperty */, 0 /* PropertyStandardQuery */, 0];
                ubyte[1024] desc;
                DWORD got = 0;
                if (!DeviceIoControl(h, H_IOCTL_STORAGE_QUERY_PROPERTY, query.ptr, cast(DWORD) query.sizeof,
                        desc.ptr, cast(DWORD) desc.length, &got, null)) {
                    continue;
                }
                auto facts = parseStorageDeviceDescriptor(desc[0 .. got]);
                if (!facts.ok) continue;

                StorageDeviceHardware sd;
                sd.id = format!"physicaldrive:%u"(n);
                sd.bus = mapStorageBusType(facts.busType);
                string name = facts.product;
                // Storport reports bus names ("NVMe", "ATA") as the vendor; they are not manufacturers.
                auto vlow = facts.vendor.toLower();
                bool genericVendor = vlow == "nvme" || vlow == "ata" || vlow == "scsi" || vlow == "usb";
                if (facts.vendor.length > 0 && !genericVendor && !name.toLower().startsWith(vlow)) {
                    name = facts.vendor ~ " " ~ name;
                }
                sd.display_name = name.length > 0 ? name : ("Disk " ~ to!string(n));

                // Media type: NVMe is solid-state; otherwise ask for seek penalty.
                if (sd.bus == "nvme") {
                    sd.media_type = "ssd";
                } else {
                    uint[3] spQuery = [7 /* StorageDeviceSeekPenaltyProperty */, 0, 0];
                    ubyte[12] sp;
                    DWORD spGot = 0;
                    if (DeviceIoControl(h, H_IOCTL_STORAGE_QUERY_PROPERTY, spQuery.ptr, cast(DWORD) spQuery.sizeof,
                            sp.ptr, cast(DWORD) sp.length, &spGot, null) && spGot >= 9) {
                        sd.media_type = sp[8] != 0 ? "hdd" : "ssd";
                    } else {
                        sd.media_type = "unknown";
                    }
                }

                // DISK_GEOMETRY_EX: DiskSize follows the 24-byte DISK_GEOMETRY.
                ubyte[256] geo;
                DWORD geoGot = 0;
                if (DeviceIoControl(h, H_IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, null, 0, geo.ptr, cast(DWORD) geo.length, &geoGot, null)
                        && geoGot >= 32) {
                    ulong size = readU64(geo[], 24);
                    if (size > 0) sd.capacity_bytes = size;
                } else if (facts.removable) {
                    continue; // empty card reader / removable slot without media
                }

                if (auto m = n in mountsByDisk) sd.mounts = *m;
                disks ~= sd;
            }
            return disks;
        }
    }
}
