module tests.platform.test_windows_parsers;

// Windows backend parsing/classification rules are pure functions, so they are
// exercised on every CI platform, not only on Windows runners.

import platform.windows;
import std.algorithm : canFind;

unittest {
    // Network interface classification (MIB_IF_ROW2 facts)
    enum ubyte HW = WIN_IF_FLAG_HARDWARE;
    enum ubyte FILTER = WIN_IF_FLAG_FILTER;

    // Lightweight filter rows ("...-WFP Native MAC Layer LightWeight Filter-0000") are dropped.
    assert(classifyWindowsInterface(71, 9, cast(ubyte)(HW | FILTER), "Wi-Fi-WFP", "Intel Wi-Fi 6E AX211-WFP Native MAC Layer") == "");
    // Loopback dropped.
    assert(classifyWindowsInterface(24, 0, 0, "Loopback Pseudo-Interface 1", "Software Loopback Interface 1") == "");
    // WAN Miniport / Teredo style software interfaces dropped.
    assert(classifyWindowsInterface(6, 0, 0, "Local Area Connection* 3", "WAN Miniport (IP)") == "");
    assert(classifyWindowsInterface(131, 0, 0, "Teredo Tunneling Pseudo-Interface", "Teredo Tunneling Pseudo-Interface") == "");
    // Kernel debug adapter dropped even if marked hardware.
    assert(classifyWindowsInterface(6, 14, HW, "Ethernet 3", "Microsoft Kernel Debug Network Adapter") == "");
    // Tailscale's Wintun adapter is not hardware but must be kept as tailnet.
    assert(classifyWindowsInterface(53, 0, 0, "Tailscale", "Tailscale Tunnel") == "tailnet");
    // Hyper-V virtual switch kept as virtual.
    assert(classifyWindowsInterface(6, 0, 0, "vEthernet (WSL)", "Hyper-V Virtual Ethernet Adapter") == "virtual");
    // Real NICs.
    assert(classifyWindowsInterface(71, 9, HW, "Wi-Fi", "Intel(R) Wi-Fi 6E AX211 160MHz") == "wireless");
    assert(classifyWindowsInterface(6, 14, HW, "Ethernet", "Intel(R) Ethernet Controller I225-V") == "physical");
    assert(classifyWindowsInterface(6, 14, HW, "Ethernet 2", "VirtualBox Host-Only Ethernet Adapter") == "virtual");
}

unittest {
    // PnP hardware ID parsing: bus + IDs, never instance-specific suffixes.
    auto p = parsePnpHardwareId(`PCI\VEN_8086&DEV_15F3&SUBSYS_7D251462&REV_03`);
    assert(p.bus == "pci" && p.vendor_id == "8086" && p.device_id == "15f3");

    auto u = parsePnpHardwareId(`USB\VID_0BDA&PID_8153&REV_3100`);
    assert(u.bus == "usb" && u.vendor_id == "0bda" && u.device_id == "8153");

    assert(parsePnpHardwareId("wintun").bus == "virtual" || parsePnpHardwareId("wintun").bus == "");
    assert(parsePnpHardwareId(`ROOT\VMS_MP`).bus == "virtual");
    assert(parsePnpHardwareId(`{5d624f94-8850-40c3-a3fa-a4fd2080baf3}\vwifimp_wfd`).bus == "virtual");
    assert(parsePnpHardwareId(`BTH\MS_BTHPAN`).bus == "bluetooth");
    assert(parsePnpHardwareId("").bus == "");
    // Malformed IDs yield empty IDs rather than garbage.
    auto bad = parsePnpHardwareId(`PCI\VEN_ZZZZ&DEV_12`);
    assert(bad.bus == "pci" && bad.vendor_id == "" && bad.device_id == "");

    assert(pciVendorName("10DE") == "NVIDIA");
    assert(pciVendorName("8086") == "Intel");
    assert(pciVendorName("ffff") == "");
}

unittest {
    // STORAGE_DEVICE_DESCRIPTOR parsing never touches the serial number.
    ubyte[128] b;
    void put32(size_t off, uint v) {
        b[off] = cast(ubyte) v;
        b[off + 1] = cast(ubyte)(v >> 8);
        b[off + 2] = cast(ubyte)(v >> 16);
        b[off + 3] = cast(ubyte)(v >> 24);
    }
    put32(0, 1);     // Version
    put32(4, 128);   // Size
    b[10] = 0;       // RemovableMedia
    put32(12, 40);   // VendorIdOffset
    put32(16, 48);   // ProductIdOffset
    put32(24, 80);   // SerialNumberOffset (must be ignored)
    put32(28, 0x11); // BusTypeNvme
    b[40 .. 44] = cast(const(ubyte)[]) "NVMe";
    b[48 .. 48 + 21] = cast(const(ubyte)[]) "Samsung SSD 990 PRO  ";
    b[80 .. 80 + 14] = cast(const(ubyte)[]) "SECRET-SERIAL1";

    auto f = parseStorageDeviceDescriptor(b[]);
    assert(f.ok);
    assert(f.vendor == "NVMe");
    assert(f.product == "Samsung SSD 990 PRO");
    assert(mapStorageBusType(f.busType) == "nvme");
    assert(!f.removable);
    assert(!(f.vendor ~ f.product).canFind("SECRET"));

    assert(mapStorageBusType(0x0B) == "sata");
    assert(mapStorageBusType(0x07) == "usb");
    assert(mapStorageBusType(0xFF) == "unknown");
    assert(!parseStorageDeviceDescriptor(b[0 .. 10]).ok);

    // VOLUME_DISK_EXTENTS: spanned volume across disks 0 and 2 (with a duplicate extent).
    ubyte[8 + 24 * 3] ext;
    ext[0] = 3;
    ext[8] = 0;
    ext[8 + 24] = 2;
    ext[8 + 48] = 2;
    assert(parseVolumeDiskExtents(ext[]) == [0u, 2u]);
    assert(parseVolumeDiskExtents(ext[0 .. 4]).length == 0);
}

unittest {
    // GetLogicalProcessorInformationEx: 1 package, 2 P-cores with SMT, 2 E-cores, caches.
    ubyte[] buf;
    void rec(uint rel, ubyte[] payload) {
        uint size = cast(uint)(8 + payload.length);
        ubyte[8] hdr;
        hdr[0] = cast(ubyte) rel;
        hdr[4] = cast(ubyte) size;
        buf ~= hdr[] ~ payload;
    }
    ubyte[] core(ubyte effClass, ulong mask) {
        auto p = new ubyte[24 + 16];
        p[0] = mask > 1 && (mask & (mask - 1)) != 0 ? 1 : 0; // LTP_PC_SMT
        p[1] = effClass;
        p[22] = 1; // GroupCount
        foreach (i; 0 .. 8) p[24 + i] = cast(ubyte)(mask >> (8 * i));
        return p;
    }
    ubyte[] cache(ubyte level, uint size, uint type) {
        auto p = new ubyte[32];
        p[0] = level;
        foreach (i; 0 .. 4) p[4 + i] = cast(ubyte)(size >> (8 * i));
        foreach (i; 0 .. 4) p[8 + i] = cast(ubyte)(type >> (8 * i));
        return p;
    }
    rec(3, new ubyte[24 + 16]);   // package
    rec(0, core(1, 0b0011));     // P-core, 2 threads
    rec(0, core(1, 0b1100));     // P-core, 2 threads
    rec(0, core(0, 0b10000));    // E-core
    rec(0, core(0, 0b100000));   // E-core
    rec(2, cache(1, 49152, 2));  // L1d
    rec(2, cache(1, 32768, 1));  // L1i
    rec(2, cache(2, 2097152, 0));
    rec(2, cache(3, 25165824, 0));

    auto t = parseLogicalProcessorInfoEx(buf);
    assert(t.ok);
    assert(t.sockets == 1);
    assert(t.physicalCores == 4);
    assert(t.logicalProcessors == 6);
    assert(t.heterogeneous && t.performanceCores == 2 && t.efficiencyCores == 2);
    assert(t.l1d == 49152 && t.l1i == 32768 && t.l2 == 2097152 && t.l3 == 25165824);

    // Homogeneous CPU: no P/E split reported.
    buf = null;
    rec(0, core(0, 0b11));
    rec(0, core(0, 0b1100));
    auto h = parseLogicalProcessorInfoEx(buf);
    assert(h.ok && !h.heterogeneous && h.performanceCores == 0);

    // Truncated buffer is not misparsed.
    assert(!parseLogicalProcessorInfoEx(buf[0 .. 6]).ok);
}

unittest {
    assert(detectVirtualizationFromSystemStrings("QEMU", "Standard PC (Q35 + ICH9, 2009)") == "kvm");
    assert(detectVirtualizationFromSystemStrings("Microsoft Corporation", "Virtual Machine") == "hyper-v");
    // Surface devices are Microsoft hardware, not VMs.
    assert(detectVirtualizationFromSystemStrings("Microsoft Corporation", "Surface Laptop 5") == "");
    assert(detectVirtualizationFromSystemStrings("Micro-Star International Co., Ltd.", "MS-7C84") == "");
}

version (Windows) unittest {
    // Junction-based versioned activation and automatic rollback on Windows.
    import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write, dirEntries, SpanMode;
    import std.path : baseName;
    import update.activate;

    auto root = tempDir() ~ `\hikari-test-win-activate`;
    if (exists(root)) rmdirRecurse(root);
    scope (exit) { if (exists(root)) rmdirRecurse(root); }

    auto versions = root ~ `\versions`;
    auto state = root ~ `\state`;
    mkdirRecurse(versions ~ `\0.1.0`);
    mkdirRecurse(versions ~ `\0.2.0`);
    mkdirRecurse(state);
    write(versions ~ `\0.1.0\hikari.exe`, "old");
    write(versions ~ `\0.2.0\hikari.exe`, "new");
    write(state ~ `\nodes.json`, `{"schema_version":1,"nodes":[]}`);

    atomicSetSymlink(versions ~ `\0.1.0`, versions ~ `\current`);
    assert(readVersionSymlink(versions ~ `\current`) == "0.1.0");
    assert(readText(versions ~ `\current\hikari.exe`) == "old");

    // Failed health check: automatic rollback, old binary untouched.
    auto bad = activateAndVerifyRelease(versions, state, "0.2.0", (string _) => true, (string v) => v == "0.1.0");
    assert(!bad.ok && bad.rolledBack);
    assert(readVersionSymlink(versions ~ `\current`) == "0.1.0");
    assert(readText(versions ~ `\current\hikari.exe`) == "old");
    assert(readText(versions ~ `\0.1.0\hikari.exe`) == "old");

    // Healthy activation: junction now resolves to 0.2.0, previous points to 0.1.0.
    auto ok = activateAndVerifyRelease(versions, state, "0.2.0", (string _) => true, (string v) => v == "0.2.0");
    assert(ok.ok && !ok.rolledBack);
    assert(readText(versions ~ `\current\hikari.exe`) == "new");
    assert(readVersionSymlink(versions ~ `\previous`) == "0.1.0");
    assert(readText(versions ~ `\previous\hikari.exe`) == "old");
    assert(exists(state ~ `\nodes.json`));

    // No stray temporary junctions are left behind.
    foreach (e; dirEntries(versions, SpanMode.shallow)) {
        auto n = baseName(e.name);
        assert(n != "current.new" && n != "current.old" && n != "previous.new" && n != "previous.old", n);
    }

    // Explicit rollback back to 0.1.0.
    auto rb = rollbackToPrevious(versions, state, (string _) => true, (string v) => v == "0.1.0");
    assert(rb.ok && readText(versions ~ `\current\hikari.exe`) == "old");
}
