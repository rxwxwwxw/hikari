module hardware.inventory;

import core.model;
import core.serializer : sanitizeOsString;
import hardware.isa_names;
import std.algorithm : canFind, sort, uniq;
import std.array : array, split;
import std.file : exists, readText;
import std.stdio : File;
import std.string : startsWith, strip, toLower;

string scrubPlaceholderString(string s) pure @safe {
    auto clean = sanitizeOsString(s, 160);
    if (clean.length == 0) return "";
    auto low = clean.toLower();
    static immutable string[] placeholders = [
        "to be filled by o.e.m.",
        "default string",
        "not specified",
        "not available",
        "none",
        "system product name",
        "system manufacturer",
        "system version",
        "chassis serial number",
        "asset tag",
        "0123456789",
        "invalid",
        "unknown",
    ];
    foreach (p; placeholders) {
        if (low == p) return "";
    }
    return clean;
}

IsaInfo detectHostX86Isa() {
    IsaInfo isa;
    version (D_InlineAsm_X86_64) {
        static void cpuidLeaf(uint leaf, uint subleaf, out uint a, out uint b, out uint c, out uint d) nothrow @nogc {
            uint ra, rb, rc, rd;
            asm nothrow @nogc {
                mov EAX, leaf;
                mov ECX, subleaf;
                cpuid;
                mov ra, EAX;
                mov rb, EBX;
                mov rc, ECX;
                mov rd, EDX;
            }
            a = ra; b = rb; c = rc; d = rd;
        }

        static ulong readXcr0() nothrow @nogc {
            uint lo, hi;
            asm nothrow @nogc {
                xor ECX, ECX;
                db 0x0f, 0x01, 0xd0; // xgetbv
                mov lo, EAX;
                mov hi, EDX;
            }
            return (cast(ulong) hi << 32) | lo;
        }

        uint maxLeaf, ebx0, ecx0, edx0;
        cpuidLeaf(0, 0, maxLeaf, ebx0, ecx0, edx0);

        string[] hw;
        string[] us;

        uint a1 = 0, b1 = 0, c1 = 0, d1 = 0;
        if (maxLeaf >= 1) {
            cpuidLeaf(1, 0, a1, b1, c1, d1);
        }
        bool hasOsxsave = (c1 & (1u << 27)) != 0;
        ulong xcr0 = hasOsxsave ? readXcr0() : 0;
        bool osYmmOk = hasOsxsave && ((xcr0 & 0x6) == 0x6); // XMM + YMM state enabled by OS
        bool osZmmOk = osYmmOk && ((xcr0 & 0xE6) == 0xE6); // opmask + ZMM_Hi256 + Hi16_ZMM

        void addFeat(string name, bool hwCond, bool osCond = true) {
            if (hwCond) {
                hw ~= name;
                if (osCond) us ~= name;
            }
        }

        addFeat("sse", (d1 & (1u << 25)) != 0);
        addFeat("sse2", (d1 & (1u << 26)) != 0);
        addFeat("sse3", (c1 & (1u << 0)) != 0);
        addFeat("pclmulqdq", (c1 & (1u << 1)) != 0);
        addFeat("vmx", (c1 & (1u << 5)) != 0);
        addFeat("ssse3", (c1 & (1u << 9)) != 0);
        addFeat("fma", (c1 & (1u << 12)) != 0, osYmmOk);
        addFeat("cmpxchg16b", (c1 & (1u << 13)) != 0);
        addFeat("sse4_1", (c1 & (1u << 19)) != 0);
        addFeat("sse4_2", (c1 & (1u << 20)) != 0);
        addFeat("movbe", (c1 & (1u << 22)) != 0);
        addFeat("popcnt", (c1 & (1u << 23)) != 0);
        addFeat("aes", (c1 & (1u << 25)) != 0);
        addFeat("xsave", (c1 & (1u << 26)) != 0);
        addFeat("osxsave", hasOsxsave);
        addFeat("avx", (c1 & (1u << 28)) != 0, osYmmOk);
        addFeat("f16c", (c1 & (1u << 29)) != 0, osYmmOk);
        addFeat("rdrand", (c1 & (1u << 30)) != 0);

        if (maxLeaf >= 7) {
            uint a7, b7, c7, d7;
            cpuidLeaf(7, 0, a7, b7, c7, d7);
            addFeat("fsgsbase", (b7 & (1u << 0)) != 0);
            addFeat("bmi1", (b7 & (1u << 3)) != 0);
            addFeat("avx2", (b7 & (1u << 5)) != 0, osYmmOk);
            addFeat("bmi2", (b7 & (1u << 8)) != 0);
            addFeat("avx512f", (b7 & (1u << 16)) != 0, osZmmOk);
            addFeat("avx512dq", (b7 & (1u << 17)) != 0, osZmmOk);
            addFeat("rdseed", (b7 & (1u << 18)) != 0);
            addFeat("adx", (b7 & (1u << 19)) != 0);
            addFeat("avx512cd", (b7 & (1u << 28)) != 0, osZmmOk);
            addFeat("sha", (b7 & (1u << 29)) != 0);
            addFeat("avx512bw", (b7 & (1u << 30)) != 0, osZmmOk);
            addFeat("avx512vl", (b7 & (1u << 31)) != 0, osZmmOk);

            addFeat("vaes", (c7 & (1u << 9)) != 0, osYmmOk);
            addFeat("vpclmulqdq", (c7 & (1u << 10)) != 0, osYmmOk);
            addFeat("avx512vnni", (c7 & (1u << 11)) != 0, osZmmOk);

            if (a7 >= 1) {
                uint a71, b71, c71, d71;
                cpuidLeaf(7, 1, a71, b71, c71, d71);
                addFeat("avx_vnni", (a71 & (1u << 4)) != 0, osYmmOk);
                addFeat("avx512bf16", (a71 & (1u << 5)) != 0, osZmmOk);
            }
        }

        uint maxExt, bx, cx, dx;
        cpuidLeaf(0x80000000u, 0, maxExt, bx, cx, dx);
        if (maxExt >= 0x80000001u) {
            uint ae1, be1, ce1, de1;
            cpuidLeaf(0x80000001u, 0, ae1, be1, ce1, de1);
            addFeat("lzcnt", (ce1 & (1u << 5)) != 0);
            addFeat("svm", (ce1 & (1u << 2)) != 0);
        }

        isa.hardware = normalizeIsaList(hw);
        isa.usable = normalizeIsaList(us);
        isa.detection = "cpuid+os_state";
        return isa;
    } else {
        isa.detection = "unavailable";
        return isa;
    }
}

version (AArch64) {
    private extern (C) ulong getauxval(ulong type) nothrow @nogc;
}

IsaInfo detectHostArm64Isa(const string[] procCpuinfoFeatures) {
    IsaInfo isa;
    string[] hw;
    version (AArch64) {
        enum ulong AT_HWCAP = 16;
        enum ulong AT_HWCAP2 = 26;
        ulong hc = getauxval(AT_HWCAP);
        ulong hc2 = getauxval(AT_HWCAP2);

        if (hc & (1UL << 0)) hw ~= "fp";
        if (hc & (1UL << 1)) hw ~= "asimd";
        if (hc & (1UL << 3)) hw ~= "aes";
        if (hc & (1UL << 4)) hw ~= "pmull";
        if (hc & (1UL << 5)) hw ~= "sha1";
        if (hc & (1UL << 6)) hw ~= "sha2";
        if (hc & (1UL << 7)) hw ~= "crc32";
        if (hc & (1UL << 8)) hw ~= "atomics";
        if (hc & (1UL << 9)) hw ~= "fphp";
        if (hc & (1UL << 10)) hw ~= "asimdhp";
        if (hc & (1UL << 17)) hw ~= "sha3";
        if (hc & (1UL << 18)) hw ~= "sm3";
        if (hc & (1UL << 19)) hw ~= "sm4";
        if (hc & (1UL << 20)) hw ~= "asimddp";
        if (hc & (1UL << 21)) hw ~= "sha512";
        if (hc & (1UL << 22)) hw ~= "sve";
        if (hc & (1UL << 24)) hw ~= "fcma";
        if (hc & (1UL << 25)) hw ~= "jscvt";
        if (hc & (1UL << 30)) hw ~= "paca";

        if (hc2 & (1UL << 1)) hw ~= "sve2";
        if (hc2 & (1UL << 13)) hw ~= "i8mm";
        if (hc2 & (1UL << 14)) hw ~= "bf16";
        if (hc2 & (1UL << 16)) hw ~= "rng";
        if (hc2 & (1UL << 17)) hw ~= "bti";

        isa.detection = "hwcap";
    } else {
        isa.detection = "proc_cpuinfo";
    }
    foreach (f; procCpuinfoFeatures) hw ~= f;
    isa.hardware = normalizeIsaList(hw);
    isa.usable = isa.hardware.dup;
    return isa;
}

struct PciIdLookup {
    string[string] vendors;
    string[string] devices; // key: "vvvv:dddd"

    void loadBuiltins() {
        vendors = [
            "8086": "Intel Corporation",
            "1022": "AMD",
            "1002": "AMD/ATI",
            "10de": "NVIDIA Corporation",
            "10ec": "Realtek Semiconductor",
            "14e4": "Broadcom Inc.",
            "15b3": "Mellanox Technologies",
            "1af4": "Red Hat (Virtio)",
            "1b36": "Red Hat (QEMU)",
            "144d": "Samsung Electronics",
            "15b7": "SanDisk/WD",
            "1987": "Phison Electronics",
            "2646": "Kingston Technology",
            "1cc1": "ADATA Technology",
        ];
        devices = [
            "8086:15f3": "Intel Ethernet Controller I225-V",
            "8086:125c": "Intel Ethernet Controller I226-V",
            "8086:1539": "Intel I211 Gigabit Network Connection",
            "8086:2725": "Intel Wi-Fi 6 AX210/AX211",
            "10ec:8168": "Realtek RTL8111/8168/8411 PCI Express Gigabit Ethernet",
            "10ec:8125": "Realtek RTL8125 2.5GbE Controller",
            "10ec:8126": "Realtek RTL8126 5GbE Controller",
            "1af4:1000": "Virtio network device",
            "1af4:1041": "Virtio 1.0 network device",
            "10de:2484": "NVIDIA GeForce RTX 3070",
            "10de:2684": "NVIDIA GeForce RTX 4090",
            "1002:744c": "AMD Radeon RX 7900 XT/XTX",
        ];
    }

    void loadLocalPciIdsFile(const string[] candidatePaths = [
        "/usr/share/hwdata/pci.ids",
        "/usr/share/misc/pci.ids",
        "/usr/share/pci.ids",
    ]) {
        loadBuiltins();
        foreach (path; candidatePaths) {
            if (!exists(path)) continue;
            try {
                auto f = File(path, "r");
                string curVendor;
                foreach (rawLine; f.byLine()) {
                    if (rawLine.length == 0 || rawLine[0] == '#') continue;
                    // Class lines start with 'C ' -> stop vendor/device parsing
                    if (rawLine.length >= 2 && rawLine[0] == 'C' && rawLine[1] == ' ') break;
                    if (rawLine[0] != '\t') {
                        // Vendor line: "vvvv  Vendor Name"
                        if (rawLine.length >= 6 && rawLine[4] == ' ') {
                            curVendor = rawLine[0 .. 4].idup.toLower();
                            auto vname = sanitizeOsString(rawLine[4 .. $].idup, 128);
                            if (vname.length > 0) vendors[curVendor] = vname;
                        }
                    } else if (rawLine.length >= 7 && rawLine[0] == '\t' && rawLine[1] != '\t' && curVendor.length == 4) {
                        // Device line: "\tdddd  Device Name"
                        auto rest = rawLine[1 .. $];
                        if (rest.length >= 6 && rest[4] == ' ') {
                            auto devId = rest[0 .. 4].idup.toLower();
                            auto dname = sanitizeOsString(rest[4 .. $].idup, 160);
                            if (dname.length > 0) devices[curVendor ~ ":" ~ devId] = dname;
                        }
                    }
                }
                return;
            } catch (Exception) {
                // Fall back to next path or built-ins
            }
        }
    }

    string resolveVendor(string vendorHex) const {
        auto v = normalizeHex4(vendorHex);
        if (auto p = v in vendors) return *p;
        return "";
    }

    string resolveDevice(string vendorHex, string deviceHex) const {
        auto v = normalizeHex4(vendorHex);
        auto d = normalizeHex4(deviceHex);
        auto key = v ~ ":" ~ d;
        if (auto p = key in devices) return *p;
        return "";
    }

    static string normalizeHex4(string raw) pure @safe {
        auto s = raw.strip().toLower();
        if (s.startsWith("0x")) s = s[2 .. $];
        return s;
    }
}

private string mapSmbiosMemoryType(ubyte t) pure @safe {
    switch (t) {
        case 0x12: return "DDR";
        case 0x13: return "DDR2";
        case 0x18: return "DDR3";
        case 0x1A: return "DDR4";
        case 0x1B: return "LPDDR";
        case 0x1C: return "LPDDR2";
        case 0x1D: return "LPDDR3";
        case 0x1E: return "LPDDR4";
        case 0x22: return "DDR5";
        case 0x23: return "LPDDR5";
        default: return "";
    }
}

private string mapSmbiosChassisFormFactor(ubyte c) pure @safe {
    switch (c & 0x7F) {
        case 3: case 4: case 5: case 6: case 7: case 15: case 35:
            return "desktop";
        case 8: case 9: case 10: case 11: case 14: case 30: case 31: case 32:
            return "laptop";
        case 17: case 23: case 25: case 28: case 29:
            return "server";
        default:
            return "";
    }
}

struct ParsedSmbiosAll {
    SystemHardwareInfo system;
    BoardHardwareInfo board;
    FirmwareHardwareInfo firmware;
    MemoryModuleInfo[] memoryModules;
}

ParsedSmbiosAll parseSmbiosTables(const(ubyte)[] data) {
    ParsedSmbiosAll res;
    size_t pos = 0;
    while (pos + 4 <= data.length) {
        ubyte recType = data[pos];
        ubyte recLen = data[pos + 1];
        if (recLen < 4 || pos + recLen > data.length) break;

        size_t strStart = pos + recLen;
        string[] strings;
        size_t cur = strStart;
        if (cur + 1 < data.length && data[cur] == 0 && data[cur + 1] == 0) {
            cur += 2;
        } else {
            while (cur < data.length) {
                size_t sEnd = cur;
                while (sEnd < data.length && data[sEnd] != 0) sEnd++;
                if (sEnd > cur) {
                    strings ~= sanitizeOsString(cast(string) data[cur .. sEnd], 128);
                }
                cur = sEnd + 1;
                if (cur < data.length && data[cur] == 0) {
                    cur++;
                    break;
                }
            }
        }

        string getStr(ubyte idx) {
            if (idx == 0 || idx > strings.length) return "";
            return scrubPlaceholderString(strings[idx - 1]);
        }

        if (recType == 0 && recLen >= 0x12) {
            // BIOS Information
            res.firmware.type = "UEFI";
            if (res.firmware.vendor.length == 0) res.firmware.vendor = getStr(data[pos + 0x04]);
            if (res.firmware.version_str.length == 0) res.firmware.version_str = getStr(data[pos + 0x05]);
            if (res.firmware.release_date.length == 0) res.firmware.release_date = getStr(data[pos + 0x08]);
        } else if (recType == 1 && recLen >= 0x08) {
            // System Information (never read serial/UUID offsets!)
            if (res.system.manufacturer.length == 0) res.system.manufacturer = getStr(data[pos + 0x04]);
            if (res.system.model.length == 0) res.system.model = getStr(data[pos + 0x05]);
            if (recLen >= 0x1B && res.system.product_family.length == 0) {
                res.system.product_family = getStr(data[pos + 0x1A]);
            }
        } else if (recType == 2 && recLen >= 0x08) {
            // Baseboard Information (never read serial offset!)
            if (res.board.manufacturer.length == 0) res.board.manufacturer = getStr(data[pos + 0x04]);
            if (res.board.model.length == 0) res.board.model = getStr(data[pos + 0x05]);
            if (res.board.revision.length == 0) res.board.revision = getStr(data[pos + 0x06]);
        } else if (recType == 3 && recLen >= 0x06) {
            // System Enclosure / Chassis
            if (res.system.form_factor.length == 0) {
                res.system.form_factor = mapSmbiosChassisFormFactor(data[pos + 0x05]);
            }
        } else if (recType == 17 && recLen >= 0x1B) {
            import std.typecons : Nullable;
            ushort sizeRaw = cast(ushort)(data[pos + 0x0C] | (data[pos + 0x0D] << 8));
            if (sizeRaw != 0 && sizeRaw != 0xFFFF) {
                ulong sizeBytes = 0;
                if (sizeRaw == 0x7FFF && recLen >= 0x20) {
                    uint extMb = data[pos + 0x1C] | (data[pos + 0x1D] << 8) | (data[pos + 0x1E] << 16) | (data[pos + 0x1F] << 24);
                    sizeBytes = cast(ulong) extMb * 1024UL * 1024UL;
                } else {
                    bool kb = (sizeRaw & 0x8000) != 0;
                    uint val = sizeRaw & 0x7FFF;
                    sizeBytes = kb ? (cast(ulong) val * 1024UL) : (cast(ulong) val * 1024UL * 1024UL);
                }

                if (sizeBytes > 0) {
                    MemoryModuleInfo mod;
                    mod.size_bytes = sizeBytes;
                    mod.slot = getStr(data[pos + 0x10]);
                    mod.technology = mapSmbiosMemoryType(data[pos + 0x12]);
                    ushort spd = cast(ushort)(data[pos + 0x15] | (data[pos + 0x16] << 8));
                    if (spd > 0 && spd != 0xFFFF) mod.speed_mt_s = spd;
                    mod.manufacturer = getStr(data[pos + 0x17]);
                    mod.part_number = getStr(data[pos + 0x1A]);
                    res.memoryModules ~= mod;
                }
            }
        } else if (recType == 127) {
            break;
        }
        pos = cur;
    }
    return res;
}
