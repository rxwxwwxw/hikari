module tests.core.test_tracker;

import core.model;
import core.tracker;
import std.math : abs;
import std.typecons : Nullable;

unittest {
    auto state = new SystemRateState();

    // 1. First sample must return null (unknown), never 0
    auto pct1 = state.computeAggregateCpuPct("boot-1", 1000, 800, 1_000_000_000L, 1_000_000_000L);
    assert(pct1.isNull, "First CPU sample rate must be null");

    // 2. Second sample 1s later: delta total=1000, idle=750 => 25% active
    auto pct2 = state.computeAggregateCpuPct("boot-1", 2000, 1550, 2_000_000_000L, 2_000_000_000L);
    assert(!pct2.isNull);
    assert(abs(pct2.get - 25.0) < 0.01);

    // 3. Sub-50ms interval must return null and preserve baseline so next valid sample works
    auto pctSub = state.computeAggregateCpuPct("boot-1", 2010, 1555, 2_010_000_000L, 2_010_000_000L);
    assert(pctSub.isNull, "Sub-50ms CPU interval must be null");

    auto pct3 = state.computeAggregateCpuPct("boot-1", 3000, 2050, 3_000_000_000L, 3_000_000_000L);
    assert(!pct3.isNull);
    assert(abs(pct3.get - 50.0) < 0.01);

    // 4. Counter reset (current < previous) resets baseline and returns null
    auto pctReset = state.computeAggregateCpuPct("boot-1", 100, 80, 4_000_000_000L, 4_000_000_000L);
    assert(pctReset.isNull, "Counter reset must return null");

    // 5. Monotonic clock discontinuity (backwards) returns null
    auto pctBack = state.computeAggregateCpuPct("boot-1", 200, 150, 3_500_000_000L, 4_500_000_000L);
    assert(pctBack.isNull, "Backwards monotonic clock must return null");

    // 6. Suspend/resume divergence: monotonic +1s while boottime +120s => suspend gap > 15s => null
    auto pctPreSleep = state.computeAggregateCpuPct("boot-1", 1000, 800, 5_000_000_000L, 5_000_000_000L);
    assert(!pctPreSleep.isNull);
    auto pctWake = state.computeAggregateCpuPct("boot-1", 2000, 1000, 6_000_000_000L, 126_000_000_000L);
    assert(pctWake.isNull, "Post-suspend jump must reset baseline and return null");

    // 7. Boot ID change resets all baselines
    auto pctPostWake = state.computeAggregateCpuPct("boot-1", 3000, 1500, 7_000_000_000L, 127_000_000_000L);
    assert(!pctPostWake.isNull);
    auto pctReboot = state.computeAggregateCpuPct("boot-2", 500, 400, 8_000_000_000L, 128_000_000_000L);
    assert(pctReboot.isNull, "New boot_id must invalidate old baseline");
}

unittest {
    // CounterTracker wrap, network interface reuse, PID reuse, and exited PID pruning
    auto state = new SystemRateState();

    auto r1 = state.computeNetworkRates("b1", [
        RawNetworkInterface("ifindex:2", "enp5s0", "physical", 1000, 500, Nullable!bool(true), Nullable!ulong.init),
    ], 1_000_000_000L);
    assert(r1.length == 1 && r1[0].rx_bytes_per_s.isNull && r1[0].tx_bytes_per_s.isNull);

    // 2 seconds later: +20000 RX, +4000 TX => 10000 B/s RX, 2000 B/s TX
    auto r2 = state.computeNetworkRates("b1", [
        RawNetworkInterface("ifindex:2", "enp5s0", "physical", 21000, 4500, Nullable!bool(true), Nullable!ulong.init),
    ], 3_000_000_000L);
    assert(!r2[0].rx_bytes_per_s.isNull && abs(r2[0].rx_bytes_per_s.get - 10000.0) < 0.1);
    assert(!r2[0].tx_bytes_per_s.isNull && abs(r2[0].tx_bytes_per_s.get - 2000.0) < 0.1);

    // Counter wrap / NIC reset (rx dropped to 50)
    auto r3 = state.computeNetworkRates("b1", [
        RawNetworkInterface("ifindex:2", "enp5s0", "physical", 50, 4600, Nullable!bool(true), Nullable!ulong.init),
    ], 4_000_000_000L);
    assert(r3[0].rx_bytes_per_s.isNull, "Wrapped RX counter must return null");
    assert(!r3[0].tx_bytes_per_s.isNull, "Monotonic TX counter remains valid");

    // Same interface name "eth0" but new stable ID "ifindex:9" must NOT inherit old counters
    auto r4 = state.computeNetworkRates("b1", [
        RawNetworkInterface("ifindex:9", "enp5s0", "physical", 99999, 99999, Nullable!bool(true), Nullable!ulong.init),
    ], 5_000_000_000L);
    assert(r4[0].rx_bytes_per_s.isNull && r4[0].tx_bytes_per_s.isNull);

    // Process PID reuse & exited process cleanup (4 logical cores; 1 full core = 100%)
    RawProcessResult p1;
    p1.total_cpu_ticks = 1000;
    p1.logical_cores = 4;
    p1.processes = [
        RawProcess(100, "startA", "worker", 100, 1024, "rss"),
        RawProcess(200, "startB", "exiting", 50, 2048, "rss"),
    ];
    auto pr1 = state.computeProcessRates("b1", p1, 1_000_000_000L);
    assert(pr1[0].cpu_pct.isNull);
    assert(state.trackedProcessCount() == 2);

    // 1 second later: total +400 ticks across 4 cores, PID 100 used +200 ticks => 200% (2 cores)!
    // PID 200 exited; PID 300 took over PID 200's number with start_id="startC" -> must be null!
    RawProcessResult p2;
    p2.total_cpu_ticks = 1400;
    p2.logical_cores = 4;
    p2.processes = [
        RawProcess(100, "startA", "worker", 300, 1024, "rss"),
        RawProcess(200, "startC", "newcomer", 999, 4096, "rss"),
    ];
    auto pr2 = state.computeProcessRates("b1", p2, 2_000_000_000L);
    assert(!pr2[0].cpu_pct.isNull && abs(pr2[0].cpu_pct.get - 200.0) < 0.01);
    assert(pr2[1].cpu_pct.isNull, "Reused PID with new start_id must report null initial CPU");
    assert(state.trackedProcessCount() == 2, "Old exited PID entry must be pruned");
}
