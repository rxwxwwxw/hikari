module platform.api;

import core.model;
import std.typecons : Nullable;

interface PlatformBackend {
    PlatformIdentity identity();
    RawCpu sampleCpu();
    RawMemory sampleMemory();
    RawNetworkResult sampleNetwork();
    RawProcessResult sampleProcesses();
    RawFilesystemResult sampleFilesystems();
    RawGpuResult sampleGpus();
    RawBatteryResult sampleBatteries();
    RawMaintenanceResult sampleMaintenance();
    RawHardwareResult scanHardware();
}

struct FakeProbeCounts {
    uint identityCalls = 0;
    uint cpuCalls = 0;
    uint memoryCalls = 0;
    uint networkCalls = 0;
    uint processCalls = 0;
    uint filesystemCalls = 0;
    uint gpuCalls = 0;
    uint batteryCalls = 0;
    uint maintenanceCalls = 0;
    uint hardwareCalls = 0;
}

class FakePlatformBackend : PlatformBackend {
    string profile;
    FakeProbeCounts counts;

    // Injectable fault/delay controls for deterministic tests
    bool failCpu = false;
    bool failMemory = false;
    bool failNetwork = false;
    bool failFilesystems = false;
    bool failGpus = false;
    bool failHardware = false;
    uint sleepFilesystemsMs = 0;
    uint sleepGpusMs = 0;
    uint sleepHardwareMs = 0;

    // Injectable evolving counters
    ulong cpuTotalTicks = 100000;
    ulong cpuIdleTicks = 80000;
    ulong netRxBytes = 98412049120UL;
    ulong netTxBytes = 14209182310UL;
    ulong procCpuTicks = 12000;
    string bootId = "fake-boot-0001";
    long uptimeS = 432180;
    uint procPid = 4192;
    string procStartId = "10542";
    string procName = "firefox (content)";

    this(string profile = "desktop-x86_64") {
        this.profile = profile;
        if (profile == "failing-probes") {
            failFilesystems = true;
            failGpus = true;
        }
    }

    void advanceTick(ulong totalDelta = 1000, ulong idleDelta = 800, ulong rxDelta = 250000, ulong txDelta = 40000, ulong procDelta = 200) {
        cpuTotalTicks += totalDelta;
        cpuIdleTicks += idleDelta;
        netRxBytes += rxDelta;
        netTxBytes += txDelta;
        procCpuTicks += procDelta;
        uptimeS += 10;
    }

    override PlatformIdentity identity() {
        counts.identityCalls++;
        PlatformIdentity id;
        id.boot_id = bootId;
        id.uptime_s = uptimeS;
        if (profile == "arm64-sbc") {
            id.host = "orange-arm64";
            id.os = "linux";
            id.arch = "aarch64";
        } else if (profile == "laptop-battery") {
            id.host = "thinkpad-linux";
            id.os = "linux";
            id.arch = "x86_64";
        } else if (profile == "gaming-gpu") {
            id.host = "gaming-rig";
            id.os = "linux";
            id.arch = "x86_64";
        } else if (profile == "windows-gaming") {
            id.host = "gaming-win11";
            id.os = "windows";
            id.arch = "x86_64";
        } else if (profile == "macos-arm64") {
            id.host = "macbook-pro-m3";
            id.os = "darwin";
            id.arch = "arm64";
        } else if (profile == "macos-intel") {
            id.host = "imac-intel";
            id.os = "darwin";
            id.arch = "x86_64";
        } else {
            id.host = "workstation-linux";
            id.os = "linux";
            id.arch = "x86_64";
        }
        return id;
    }

    override RawCpu sampleCpu() {
        counts.cpuCalls++;
        RawCpu c;
        if (failCpu) {
            c.state = CapabilityState.error;
            c.error = "simulated_cpu_probe_failure";
            return c;
        }
        c.state = CapabilityState.ok;
        c.total_ticks = cpuTotalTicks;
        c.idle_ticks = cpuIdleTicks;
        c.logical_cores = profile == "macos-intel" ? 6 : (profile == "arm64-sbc" || profile == "macos-arm64") ? 8 : 24;
        if (profile != "windows-gaming") {
            c.load_1m = 1.35;
        }
        if (profile != "vm-minimal" && profile != "windows-gaming" && profile != "macos-arm64" && profile != "macos-intel") {
            c.temp_c = 49.5;
        }
        return c;
    }

    override RawMemory sampleMemory() {
        counts.memoryCalls++;
        RawMemory m;
        if (failMemory) {
            m.state = CapabilityState.error;
            m.error = "simulated_memory_failure";
            return m;
        }
        m.state = CapabilityState.ok;
        if (profile == "arm64-sbc") {
            m.total_bytes = 8589934592UL;
            m.used_bytes = 2147483648UL;
            m.swap_total_bytes = 0;
            m.swap_used_bytes = 0;
        } else if (profile == "macos-intel" || profile == "macos-arm64") {
            m.total_bytes = 17179869184UL;
            m.used_bytes = 4294967296UL;
            m.swap_total_bytes = 0;
            m.swap_used_bytes = 0;
        } else if (profile == "windows-gaming") {
            m.total_bytes = 34359738368UL;
            m.used_bytes = 12884901888UL;
            // Windows commit charge is separate from Unix swap
            m.commit_limit_bytes = 42949672960UL;
            m.commit_used_bytes = 15032385536UL;
        } else {
            m.total_bytes = 68719476736UL;
            m.used_bytes = 19756849562UL;
            m.swap_total_bytes = 8589934592UL;
            m.swap_used_bytes = 214748365UL;
        }
        return m;
    }

    override RawNetworkResult sampleNetwork() {
        counts.networkCalls++;
        RawNetworkResult r;
        if (failNetwork) {
            r.state = CapabilityState.error;
            r.error = "simulated_network_permission_failure";
            return r;
        }
        r.state = CapabilityState.ok;
        RawNetworkInterface eth;
        eth.id = "ifindex:2";
        eth.name = profile == "macos-arm64" || profile == "macos-intel" ? "en0" : (profile == "arm64-sbc") ? "end0" : "enp5s0";
        eth.kind = "physical";
        eth.rx_bytes = netRxBytes;
        eth.tx_bytes = netTxBytes;
        eth.link_up = true;
        eth.link_speed_bps = 2500000000UL;

        RawNetworkInterface ts;
        ts.id = "ifindex:3";
        ts.name = profile == "macos-arm64" || profile == "macos-intel" ? "utun7" : "tailscale0";
        ts.kind = profile == "macos-arm64" || profile == "macos-intel" ? "virtual" : "tailnet";
        ts.rx_bytes = netRxBytes / 10;
        ts.tx_bytes = netTxBytes / 10;
        ts.link_up = true;

        r.interfaces = [eth, ts];
        return r;
    }

    override RawProcessResult sampleProcesses() {
        counts.processCalls++;
        RawProcessResult r;
        r.state = CapabilityState.ok;
        r.total_cpu_ticks = cpuTotalTicks;
        r.logical_cores = profile == "macos-intel" ? 6 : (profile == "arm64-sbc" || profile == "macos-arm64") ? 8 : 24;
        r.processes = [
            RawProcess(procPid, procStartId, procName, procCpuTicks, 3272089600UL, "rss"),
            RawProcess(1024, "100", "ldc2", procCpuTicks / 3, 512000000UL, "rss"),
            RawProcess(512, "80", "tailscaled", 900, 96000000UL, "rss"),
            RawProcess(1, "1", profile == "macos-arm64" || profile == "macos-intel" ? "launchd" : "systemd", 300, 18000000UL, "rss"),
        ];
        return r;
    }

    override RawFilesystemResult sampleFilesystems() {
        counts.filesystemCalls++;
        if (sleepFilesystemsMs > 0) {
            import core.thread : Thread;
            import core.time : msecs;
            Thread.sleep(msecs(sleepFilesystemsMs));
        }
        RawFilesystemResult r;
        if (failFilesystems) {
            r.state = CapabilityState.error;
            r.error = "simulated_mount_timeout";
            return r;
        }
        r.state = CapabilityState.ok;
        MountStatus rootMount;
        rootMount.mount = "/";
        rootMount.source = profile == "macos-arm64" || profile == "macos-intel" ? "/dev/disk3s1" : (profile == "arm64-sbc") ? "/dev/mmcblk0p2" : "/dev/nvme0n1p2";
        rootMount.fs = profile == "macos-arm64" || profile == "macos-intel" ? "apfs" : "btrfs";
        rootMount.total_bytes = 1000204886016UL;
        rootMount.used_bytes = 225915279770UL;
        rootMount.pct = 22.6;
        r.mounts = [rootMount];
        return r;
    }

    override RawGpuResult sampleGpus() {
        counts.gpuCalls++;
        if (sleepGpusMs > 0) {
            import core.thread : Thread;
            import core.time : msecs;
            Thread.sleep(msecs(sleepGpusMs));
        }
        RawGpuResult r;
        if (failGpus) {
            r.state = CapabilityState.error;
            r.error = "simulated_gpu_driver_fault";
            return r;
        }
        if (profile == "gaming-gpu" || profile == "desktop-x86_64" || profile == "windows-gaming") {
            r.state = CapabilityState.ok;
            GpuDynamicStatus g;
            g.id = "pci:0000:08:00.0";
            g.display_name = "NVIDIA GeForce RTX 3070";
            g.vendor = "NVIDIA";
            g.utilization_pct = (profile == "gaming-gpu" || profile == "windows-gaming") ? 74.0 : 4.0;
            g.temp_c = (profile == "gaming-gpu" || profile == "windows-gaming") ? 68.0 : 39.0;
            g.vram_used_bytes = 3221225472UL;
            g.vram_total_bytes = 8589934592UL;
            g.power_watts = (profile == "gaming-gpu") ? 195.4 : 18.2;
            g.capability = CapabilityState.ok;
            r.gpus = [g];
        } else {
            r.state = CapabilityState.unsupported;
        }
        return r;
    }

    override RawBatteryResult sampleBatteries() {
        counts.batteryCalls++;
        RawBatteryResult r;
        r.state = CapabilityState.ok;
        if (profile == "laptop-battery" || profile == "macos-arm64") {
            BatteryStatus b;
            b.id = "BAT0";
            b.name = "BAT0";
            b.status = "discharging";
            b.pct = 78.5;
            b.power_watts = 11.4;
            b.time_remaining_s = 14200;
            b.health_pct = 91.2;
            b.cycle_count = 287;
            b.design_capacity_wh = 52.44;
            b.full_charge_capacity_wh = 47.83;
            r.batteries = [b];
        }
        return r;
    }

    override RawMaintenanceResult sampleMaintenance() {
        counts.maintenanceCalls++;
        RawMaintenanceResult r;
        r.state = CapabilityState.ok;
        r.drift.running_kernel = profile == "macos-arm64" || profile == "macos-intel" ? "24.1.0" : "6.12.4";
        if (profile != "macos-arm64" && profile != "macos-intel")
            r.drift.installed_kernel = (profile == "desktop-x86_64") ? "6.12.5" : "6.12.4";
        if (profile != "macos-arm64" && profile != "macos-intel")
            r.drift.reboot_required = (profile == "desktop-x86_64");
        return r;
    }

    override RawHardwareResult scanHardware() {
        counts.hardwareCalls++;
        if (sleepHardwareMs > 0) {
            import core.thread : Thread;
            import core.time : msecs;
            Thread.sleep(msecs(sleepHardwareMs));
        }
        RawHardwareResult r;
        if (failHardware) {
            r.state = CapabilityState.error;
            r.error = "simulated_hardware_scan_failure";
            return r;
        }
        r.state = CapabilityState.ok;
        HardwareInventory hw;
        if (profile == "arm64-sbc") {
            hw.system = SystemHardwareInfo("Xunlong", "Orange Pi 5 Plus", "ARM64 SBC", "sbc", "");
            hw.board = BoardHardwareInfo("Xunlong", "Orange Pi 5 Plus", "v1.2");
            hw.firmware = FirmwareHardwareInfo("DeviceTree", "U-Boot", "2024.04", "");
            hw.cpu.display_name = "Rockchip RK3588 (Cortex-A76/A55)";
            hw.cpu.vendor = "ARM";
            hw.cpu.architecture = "aarch64";
            hw.cpu.sockets = 1;
            hw.cpu.physical_cores = 8;
            hw.cpu.logical_cores = 8;
            hw.cpu.performance_cores = 4;
            hw.cpu.efficiency_cores = 4;
            hw.cpu.isa.hardware = ["fp", "asimd", "aes", "pmull", "sha1", "sha2", "crc32", "atomics", "asimddp"];
            hw.cpu.isa.usable = hw.cpu.isa.hardware.dup;
            hw.cpu.isa.detection = "hwcap";
            hw.memory.total_bytes = 8589934592UL;
            hw.memory.module_enumeration = CapabilityState.unsupported;
            hw.capabilities = [
                "board": CapabilityState.ok,
                "memory_modules": CapabilityState.unsupported,
                "network_adapters": CapabilityState.ok,
                "storage_devices": CapabilityState.ok,
                "isa": CapabilityState.ok,
            ];
        } else if (profile == "macos-arm64") {
            hw.system = SystemHardwareInfo("Apple Inc.", "Mac15,3", "", "laptop", "");
            hw.board = BoardHardwareInfo("Apple Inc.", "Mac15,3", "");
            hw.cpu.display_name = "Apple M3";
            hw.cpu.vendor = "Apple";
            hw.cpu.architecture = "arm64";
            hw.cpu.sockets = 1;
            hw.cpu.physical_cores = 8;
            hw.cpu.logical_cores = 8;
            hw.cpu.performance_cores = 4;
            hw.cpu.efficiency_cores = 4;
            hw.cpu.isa.hardware = ["fp", "asimd", "aes", "pmull", "sha1", "sha2", "sha3", "crc32", "atomics", "asimddp"];
            hw.cpu.isa.usable = hw.cpu.isa.hardware.dup;
            hw.cpu.isa.detection = "sysctl_hw_optional";
            hw.memory.total_bytes = 17179869184UL;
            hw.memory.module_enumeration = CapabilityState.unsupported;
            hw.capabilities = [
                "board": CapabilityState.ok,
                "memory_modules": CapabilityState.unsupported,
                "network_adapters": CapabilityState.ok,
                "storage_devices": CapabilityState.unavailable,
                "isa": CapabilityState.ok,
            ];
        } else if (profile == "macos-intel") {
            hw.system = SystemHardwareInfo("Apple Inc.", "iMac19,1", "", "desktop", "");
            hw.board = BoardHardwareInfo("Apple Inc.", "iMac19,1", "");
            hw.cpu.display_name = "Intel(R) Core(TM) i5-9600K CPU @ 3.70GHz";
            hw.cpu.vendor = "Intel";
            hw.cpu.architecture = "x86_64";
            hw.cpu.sockets = 1;
            hw.cpu.physical_cores = 6;
            hw.cpu.logical_cores = 6;
            hw.cpu.isa.hardware = ["sse2", "sse4_2", "avx", "avx2", "aes", "bmi1", "bmi2"];
            hw.cpu.isa.usable = hw.cpu.isa.hardware.dup;
            hw.cpu.isa.detection = "cpuid+os_state";
            hw.memory.total_bytes = 17179869184UL;
            hw.memory.module_enumeration = CapabilityState.unavailable;
            hw.capabilities = ["board": CapabilityState.ok, "memory_modules": CapabilityState.unavailable,
                "network_adapters": CapabilityState.unavailable, "storage_devices": CapabilityState.unavailable,
                "graphics_adapters": CapabilityState.unavailable, "isa": CapabilityState.ok];
        } else {
            hw.system = SystemHardwareInfo("Micro-Star International", "MS-7C84", "Desktop", "desktop", "");
            hw.board = BoardHardwareInfo("Micro-Star International", "MAG X570 TOMAHAWK WIFI", "1.0");
            hw.firmware = FirmwareHardwareInfo("UEFI", "American Megatrends", "1.G0", "2024-03-15");
            hw.cpu.display_name = "AMD Ryzen 9 5900X";
            hw.cpu.vendor = "AMD";
            hw.cpu.architecture = "x86_64";
            hw.cpu.sockets = 1;
            hw.cpu.physical_cores = 12;
            hw.cpu.logical_cores = 24;
            hw.cpu.cache_bytes.l1d = 32768 * 12;
            hw.cpu.cache_bytes.l1i = 32768 * 12;
            hw.cpu.cache_bytes.l2 = 524288 * 12;
            hw.cpu.cache_bytes.l3 = 67108864;
            hw.cpu.isa.hardware = ["sse2", "sse4_1", "sse4_2", "avx", "avx2", "fma", "aes", "pclmulqdq", "sha", "bmi1", "bmi2", "svm"];
            hw.cpu.isa.usable = hw.cpu.isa.hardware.dup;
            hw.cpu.isa.detection = "cpuid+os_state";
            hw.memory.total_bytes = 68719476736UL;
            hw.memory.module_enumeration = CapabilityState.unavailable;
            hw.network_adapters = [
                NetworkAdapterHardware("pci:0000:05:00.0", "Realtek RTL8125 2.5GbE Controller", "enp5s0", "ethernet", "pci", "r8169", "10ec", "8125", Nullable!ulong(2500000000UL)),
            ];
            hw.storage_devices = [
                StorageDeviceHardware("nvme:nvme0n1", "Samsung SSD 980 PRO 1TB", "nvme", "ssd", Nullable!ulong(1000204886016UL), ["/"]),
            ];
            hw.graphics_adapters = [
                GraphicsAdapterHardware("pci:0000:08:00.0", "NVIDIA GeForce RTX 3070", "NVIDIA", "nvidia", "10de", "2484", Nullable!ulong(8589934592UL)),
            ];
            hw.capabilities = [
                "board": CapabilityState.ok,
                "memory_modules": CapabilityState.unavailable,
                "network_adapters": CapabilityState.ok,
                "storage_devices": CapabilityState.ok,
                "isa": CapabilityState.ok,
            ];
        }
        r.inventory = hw;
        return r;
    }
}
