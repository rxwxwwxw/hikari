module tests.platform.test_linux_parsers;

import core.model;
import platform.linux;
import std.algorithm : canFind;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.math : abs;

private string makeFakeSysTree(string name) {
    auto root = tempDir() ~ "/hikari-test-linux-" ~ name;
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root ~ "/proc/sys/kernel/random");
    mkdirRecurse(root ~ "/proc/net");
    mkdirRecurse(root ~ "/proc/self");
    mkdirRecurse(root ~ "/proc/4192");
    mkdirRecurse(root ~ "/proc/5000");
    mkdirRecurse(root ~ "/sys/class/net/enp5s0");
    mkdirRecurse(root ~ "/sys/class/net/tailscale0");
    mkdirRecurse(root ~ "/sys/class/power_supply/BAT0");
    mkdirRecurse(root ~ "/sys/class/power_supply/BAT1");
    mkdirRecurse(root ~ "/var/run");
    mkdirRecurse(root ~ "/lib/modules/6.12.5-1-cachyos");
    return root;
}

unittest {
    auto root = makeFakeSysTree("parsers");
    scope (exit) { if (exists(root)) rmdirRecurse(root); }

    write(root ~ "/proc/sys/kernel/hostname", "fixture-box\n");
    write(root ~ "/proc/sys/kernel/random/boot_id", "boot-uuid-1234\n");
    write(root ~ "/proc/sys/kernel/osrelease", "6.12.4-1-cachyos\n");
    write(root ~ "/proc/uptime", "432180.55 12345.00\n");
    write(root ~ "/proc/loadavg", "1.42 1.10 0.95 2/400 5000\n");
    write(root ~ "/proc/stat",
        "cpu  1000 100 500 8000 200 50 50 100 0 0\n" ~
        "cpu0 500 50 250 4000 100 25 25 50 0 0\n" ~
        "cpu1 500 50 250 4000 100 25 25 50 0 0\n");
    write(root ~ "/proc/meminfo",
        "MemTotal:       16384000 kB\n" ~
        "MemFree:         2000000 kB\n" ~
        "MemAvailable:   10000000 kB\n" ~
        "SwapTotal:       4096000 kB\n" ~
        "SwapFree:        3096000 kB\n");
    write(root ~ "/proc/net/dev",
        "Inter-|   Receive | Transmit\n" ~
        " face |bytes packets errs drop fifo frame compressed multicast|bytes packets\n" ~
        "    lo: 12345 10 0 0 0 0 0 0 12345 10 0 0 0 0 0 0\n" ~
        "enp5s0: 98412049120 1000 0 0 0 0 0 0 14209182310 500 0 0 0 0 0 0\n" ~
        "tailscale0: 1000 10 0 0 0 0 0 0 2000 10 0 0 0 0 0 0\n");
    write(root ~ "/sys/class/net/enp5s0/ifindex", "2\n");
    write(root ~ "/sys/class/net/enp5s0/operstate", "up\n");
    write(root ~ "/sys/class/net/enp5s0/speed", "2500\n");
    mkdirRecurse(root ~ "/sys/class/net/enp5s0/device");
    write(root ~ "/sys/class/net/tailscale0/ifindex", "7\n");
    write(root ~ "/sys/class/net/tailscale0/operstate", "unknown\n");

    // Process names with spaces AND nested parentheses
    write(root ~ "/proc/4192/stat",
        "4192 (Web (Isolated) Content) S 1 4192 4192 0 -1 4194304 100 0 0 0 1200 300 0 0 20 0 8 0 10542 100000 2048 18446744073709551615\n");
    write(root ~ "/proc/5000/stat",
        "5000 (helper) R 1 5000 5000 0 -1 4194304 100 0 0 0 50 10 0 0 20 0 1 0 20999 100000 512 18446744073709551615\n");

    // Mountinfo: Btrfs subvolumes retained, duplicate bind mount deduplicated, tmpfs/nfs4 excluded, \040 unescaped
    write(root ~ "/proc/self/mountinfo",
        "26 1 0:25 /@ / rw,relatime shared:1 - btrfs /dev/nvme0n1p2 rw\n" ~
        "27 26 0:25 /@home /home rw,relatime shared:2 - btrfs /dev/nvme0n1p2 rw\n" ~
        "28 26 0:25 /@ /mnt/dup-bind rw,relatime shared:1 - btrfs /dev/nvme0n1p2 rw\n" ~
        "29 26 8:1 / /mnt/My\\040Drive rw,relatime - ext4 /dev/sda1 rw\n" ~
        "30 26 0:30 / /tmp rw,nosuid - tmpfs tmpfs rw\n" ~
        "31 26 0:31 /export /mnt/nfs-slow rw - nfs4 10.0.0.5:/export rw\n");

    // Batteries: BAT0 (energy_*) and BAT1 (charge_*)
    write(root ~ "/sys/class/power_supply/BAT0/type", "Battery\n");
    write(root ~ "/sys/class/power_supply/BAT0/status", "Discharging\n");
    write(root ~ "/sys/class/power_supply/BAT0/energy_now", "30000000\n");
    write(root ~ "/sys/class/power_supply/BAT0/energy_full", "40000000\n");
    write(root ~ "/sys/class/power_supply/BAT0/energy_full_design", "50000000\n");
    write(root ~ "/sys/class/power_supply/BAT0/power_now", "10000000\n");
    write(root ~ "/sys/class/power_supply/BAT0/cycle_count", "312\n");
    write(root ~ "/sys/class/power_supply/BAT1/cycle_count", "0\n"); // driver does not track cycles

    write(root ~ "/sys/class/power_supply/BAT1/type", "Battery\n");
    write(root ~ "/sys/class/power_supply/BAT1/status", "Charging\n");
    write(root ~ "/sys/class/power_supply/BAT1/charge_now", "2000000\n");
    write(root ~ "/sys/class/power_supply/BAT1/charge_full", "4000000\n");
    write(root ~ "/sys/class/power_supply/BAT1/voltage_now", "12000000\n");

    auto backend = new LinuxPlatformBackend(
        root ~ "/proc",
        root ~ "/sys",
        root ~ "/etc",
        root ~ "/var",
        root ~ "/lib/modules",
        false,
        (string mp, out ulong tot, out ulong used) {
            tot = 100_000_000_000UL;
            used = 25_000_000_000UL;
            return true;
        }
    );

    auto id = backend.identity();
    assert(id.host == "fixture-box");
    assert(id.boot_id == "boot-uuid-1234");
    assert(!id.uptime_s.isNull && id.uptime_s.get == 432180);

    auto cpu = backend.sampleCpu();
    assert(cpu.state == CapabilityState.ok);
    assert(cpu.total_ticks == 10000);
    assert(cpu.idle_ticks == 8200);
    assert(cpu.logical_cores == 2);

    auto mem = backend.sampleMemory();
    assert(mem.total_bytes.get == 16384000UL * 1024UL);
    assert(mem.used_bytes.get == 6384000UL * 1024UL);
    assert(mem.swap_total_bytes.get == 4096000UL * 1024UL);
    assert(mem.swap_used_bytes.get == 1000000UL * 1024UL);

    auto net = backend.sampleNetwork();
    assert(net.interfaces.length == 2); // lo skipped
    assert(net.interfaces[0].id == "ifindex:2" || net.interfaces[1].id == "ifindex:2");

    auto procs = backend.sampleProcesses();
    assert(procs.processes.length == 2);
    bool foundParenProc = false;
    foreach (p; procs.processes) {
        if (p.pid == 4192) {
            assert(p.name == "Web (Isolated) Content", "Parens/spaces in comm failed: " ~ p.name);
            assert(p.start_id == "10542");
            assert(p.cpu_ticks == 1500);
            foundParenProc = true;
        }
    }
    assert(foundParenProc);

    auto fs = backend.sampleFilesystems();
    assert(fs.mounts.length == 3, "Expected /, /home, and '/mnt/My Drive'");
    string[] mpaths;
    foreach (m; fs.mounts) mpaths ~= m.mount;
    assert(mpaths.canFind("/") && mpaths.canFind("/home") && mpaths.canFind("/mnt/My Drive"));
    assert(!mpaths.canFind("/mnt/dup-bind") && !mpaths.canFind("/tmp") && !mpaths.canFind("/mnt/nfs-slow"));

    auto bats = backend.sampleBatteries();
    assert(bats.batteries.length == 2);
    foreach (b; bats.batteries) {
        if (b.id == "BAT0") {
            assert(abs(b.pct.get - 75.0) < 0.01);
            assert(abs(b.health_pct.get - 80.0) < 0.01);
            assert(b.time_remaining_s.get == 10800); // 30Wh / 10W = 3h
            assert(b.cycle_count.get == 312);
            assert(abs(b.design_capacity_wh.get - 50.0) < 0.001);
            assert(abs(b.full_charge_capacity_wh.get - 40.0) < 0.001);
        } else if (b.id == "BAT1") {
            assert(abs(b.pct.get - 50.0) < 0.01);
            assert(b.cycle_count.isNull, "0 cycles from the driver means unknown, not a new battery");
            // No design capacity and charge-based units: no health or Wh figures.
            assert(b.health_pct.isNull && b.design_capacity_wh.isNull && b.full_charge_capacity_wh.isNull);
        }
    }

    auto drift = backend.sampleMaintenance();
    assert(drift.drift.running_kernel == "6.12.4-1-cachyos");
    assert(drift.drift.installed_kernel == "6.12.5-1-cachyos");
    assert(drift.drift.reboot_required.get == true);

    // SMBIOS Type 17 synthetic test (16 GiB DDR5-5600 DIMM in slot DIMM_A1)
    ubyte[] smbios = [
        17, 0x20, 0x11, 0x00, // Type 17, length 32, handle
        0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x40, 0x00,
        0x00, 0x40, // Size = 0x4000 = 16384 MiB (16 GiB)
        0x09, 0x00,
        1,    // Device Locator string index 1
        0,    // Bank Locator
        0x22, // DDR5
        0x00, 0x00,
        0xE0, 0x15, // Speed = 5600 MT/s (0x15E0)
        2,    // Manufacturer string index 2
        0, 0, 0, 0, 0, 0, 0, 0,
    ];
    smbios ~= cast(const(ubyte)[]) "DIMM_A1\0Crucial\0\0";
    auto mods = LinuxPlatformBackend.parseSmbiosMemoryModules(smbios);
    assert(mods.length == 1);
    assert(mods[0].slot == "DIMM_A1");
    assert(mods[0].technology == "DDR5");
    assert(mods[0].speed_mt_s.get == 5600);
    assert(mods[0].size_bytes.get == 16384UL * 1024UL * 1024UL);
}
