module tests.platform.test_hardware_isa;

import core.model;
import core.serializer;
import hardware.inventory;
import hardware.isa_names;
import platform.linux;
import std.algorithm : canFind;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;

unittest {
    // Offline ISA dictionary & normalization
    auto norm = normalizeIsaList(["sse4.2", "AVX2", "aes", "neon", "evtstrm", "unknown_xyz"]);
    assert(norm.canFind("sse4_2"));
    assert(norm.canFind("avx2"));
    assert(norm.canFind("aes"));
    assert(norm.canFind("asimd"));
    assert(!norm.canFind("evtstrm"));
    assert(describeIsaFeature("avx2").category == IsaCategory.vector_simd);
    assert(describeIsaFeature("aes").category == IsaCategory.cryptography);

    // Real host CPUID+XCR0 test on x86_64
    version (X86_64) {
        auto isa = detectHostX86Isa();
        assert(isa.detection == "cpuid+os_state");
        assert(isa.usable.canFind("sse2"));
    }
}

// Linux sysfs fixture: PCI paths contain ":" which is not a valid Windows path character.
version (Posix) unittest {
    // Hardware inventory fixture test: placeholder scrubbing, ARM64 device-tree, and ZERO serial/MAC leakage
    auto root = tempDir() ~ "/hikari-test-hw-arm64";
    if (exists(root)) rmdirRecurse(root);
    scope (exit) { if (exists(root)) rmdirRecurse(root); }

    mkdirRecurse(root ~ "/proc/device-tree");
    mkdirRecurse(root ~ "/sys/class/dmi/id");
    mkdirRecurse(root ~ "/sys/class/net/end0/device");
    mkdirRecurse(root ~ "/sys/block/mmcblk0/device");
    mkdirRecurse(root ~ "/sys/block/mmcblk0/queue");
    mkdirRecurse(root ~ "/sys/bus/pci/devices/0000:01:00.0");

    write(root ~ "/proc/meminfo", "MemTotal: 8388608 kB\n");
    write(root ~ "/proc/device-tree/model", "Xunlong Orange Pi 5 Plus\0");
    write(root ~ "/proc/cpuinfo",
        "processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics\nCPU implementer\t: 0x41\n");

    // Sensitive DMI serial files that MUST NEVER be exposed, plus OEM placeholders
    write(root ~ "/sys/class/dmi/id/sys_vendor", "To Be Filled By O.E.M.\n");
    write(root ~ "/sys/class/dmi/id/product_name", "Default string\n");
    write(root ~ "/sys/class/dmi/id/product_serial", "SECRET-SERIAL-9999\n");
    write(root ~ "/sys/class/dmi/id/board_serial", "SECRET-BOARD-SERIAL\n");
    write(root ~ "/sys/class/dmi/id/product_uuid", "11112222-3333-4444-5555-666677778888\n");

    write(root ~ "/sys/class/net/end0/ifindex", "2\n");
    write(root ~ "/sys/class/net/end0/address", "aa:bb:cc:dd:ee:ff\n");
    write(root ~ "/sys/class/net/end0/device/vendor", "0x10ec\n");
    write(root ~ "/sys/class/net/end0/device/device", "0x8125\n");

    write(root ~ "/sys/block/mmcblk0/size", "124735488\n");
    write(root ~ "/sys/block/mmcblk0/queue/rotational", "0\n");
    write(root ~ "/sys/block/mmcblk0/device/model", "DA4064\n");

    auto backend = new LinuxPlatformBackend(root ~ "/proc", root ~ "/sys", root ~ "/etc", root ~ "/var", root ~ "/lib/modules", false);
    auto hr = backend.scanHardware();
    assert(hr.state == CapabilityState.ok);
    auto hw = hr.inventory;

    assert(hw.cpu.architecture == "aarch64");
    assert(hw.cpu.isa.usable.canFind("asimd") && hw.cpu.isa.usable.canFind("crc32"));
    assert(hw.system.model == "Xunlong Orange Pi 5 Plus");
    assert(hw.system.manufacturer == "", "OEM placeholder must be scrubbed");
    assert(hw.storage_devices.length == 1 && hw.storage_devices[0].bus == "mmc");
    assert(hw.network_adapters.length == 1 && hw.network_adapters[0].display_name.canFind("RTL8125"));

    auto jsonText = toJsonText(serializeHardwareInventory(hw));
    assert(!jsonText.canFind("SECRET-SERIAL-9999"), "Hardware serial must never leak");
    assert(!jsonText.canFind("SECRET-BOARD-SERIAL"), "Board serial must never leak");
    assert(!jsonText.canFind("aa:bb:cc:dd:ee:ff"), "MAC address must never leak by default");
}
