module core.tracker;

import core.model;
import std.algorithm : clamp;
import std.typecons : Nullable;

struct ProcessKey {
    uint pid;
    string start_id;

    size_t toHash() const nothrow @safe {
        size_t h = pid;
        foreach (char c; start_id) {
            h = h * 131 + cast(ubyte) c;
        }
        return h;
    }

    bool opEquals(const ref ProcessKey other) const pure nothrow @safe {
        return pid == other.pid && start_id == other.start_id;
    }
}

struct NetKey {
    string boot_id;
    string id;

    size_t toHash() const nothrow @safe {
        size_t h = 17;
        foreach (char c; boot_id) h = h * 31 + cast(ubyte) c;
        foreach (char c; id) h = h * 31 + cast(ubyte) c;
        return h;
    }

    bool opEquals(const ref NetKey other) const pure nothrow @safe {
        return boot_id == other.boot_id && id == other.id;
    }
}

struct CounterTracker(K) {
    struct Entry {
        ulong value;
        long monoNs;
        long bootNs = -1;
        ulong generation = 0;
    }

    enum long DEFAULT_MIN_INTERVAL_NS = 50_000_000L; // 50 ms
    enum long DEFAULT_SUSPEND_GAP_NS = 15_000_000_000L; // 15 s divergence between boot/wall and mono

    long minIntervalNs = DEFAULT_MIN_INTERVAL_NS;
    long maxIntervalNs = 3_600_000_000_000L; // 1 hour max gap before resetting baseline
    long suspendGapNs = DEFAULT_SUSPEND_GAP_NS;

    private Entry[K] entries;
    private ulong currentGen = 0;
    private uint sweepsSinceCompact = 0;
    private bool sawRemovals = false;

    Nullable!double update(K key, ulong value, long monoNs, long bootOrWallNs = -1) {
        Nullable!double rate;
        auto p = key in entries;
        if (p is null) {
            entries[key] = Entry(value, monoNs, bootOrWallNs, currentGen);
            return rate;
        }

        auto prev = *p;

        // Monotonic discontinuity (clock went backwards or stalled)
        if (monoNs <= prev.monoNs) {
            *p = Entry(value, monoNs, bootOrWallNs, currentGen);
            return rate;
        }

        long deltaNs = monoNs - prev.monoNs;

        // Detect suspend/resume if boot/wall clock jumped significantly more than monotonic clock
        if (bootOrWallNs >= 0 && prev.bootNs >= 0) {
            long bootDelta = bootOrWallNs - prev.bootNs;
            if (bootDelta < 0 || (bootDelta - deltaNs) > suspendGapNs) {
                *p = Entry(value, monoNs, bootOrWallNs, currentGen);
                return rate;
            }
        }

        // Baseline too old (e.g. post-resume or multi-hour gap)
        if (maxIntervalNs > 0 && deltaNs > maxIntervalNs) {
            *p = Entry(value, monoNs, bootOrWallNs, currentGen);
            return rate;
        }

        // Counter wrap or reset (e.g. interface recreated, counter overflow/zeroed)
        if (value < prev.value) {
            *p = Entry(value, monoNs, bootOrWallNs, currentGen);
            return rate;
        }

        // Sub-50ms measurement window: preserve prior baseline, report unknown (null) rate
        if (deltaNs < minIntervalNs) {
            p.generation = currentGen;
            return rate;
        }

        double deltaVal = cast(double)(value - prev.value);
        double deltaSec = cast(double) deltaNs / 1_000_000_000.0;
        rate = deltaVal / deltaSec;
        *p = Entry(value, monoNs, bootOrWallNs, currentGen);
        return rate;
    }

    void beginSweep() nothrow @safe {
        currentGen++;
    }

    void pruneUnseen() @safe {
        K[] toDelete;
        foreach (k, ref e; entries) {
            if (e.generation != currentGen) {
                toDelete ~= k;
            }
        }
        if (toDelete.length > 0) {
            foreach (k; toDelete) {
                entries.remove(k);
            }
            sawRemovals = true;
        }
        sweepsSinceCompact++;
        if (sweepsSinceCompact >= 64 && sawRemovals) {
            sweepsSinceCompact = 0;
            sawRemovals = false;
            if (entries.length == 0) {
                entries = null;
            } else {
                Entry[K] compacted;
                foreach (k, e; entries) compacted[k] = e;
                entries = compacted;
            }
        }
    }

    void remove(K key) @safe {
        if (entries.remove(key)) sawRemovals = true;
    }

    void reset() @safe {
        entries = null;
        currentGen = 0;
        sweepsSinceCompact = 0;
        sawRemovals = false;
    }

    size_t length() const nothrow @safe {
        return entries.length;
    }
}

struct CpuSampleBaseline {
    bool valid = false;
    string bootId;
    ulong totalTicks;
    ulong idleTicks;
    long monoNs;
    long bootNs = -1;
}

class SystemRateState {
    private CpuSampleBaseline cpuBase;
    private CounterTracker!NetKey netRxTracker;
    private CounterTracker!NetKey netTxTracker;

    private struct ProcEntry {
        ulong procTicks;
        ulong totalCpuTicks;
        long monoNs;
        long bootNs = -1;
        ulong generation;
    }
    private ProcEntry[ProcessKey] procEntries;
    private ulong procGen = 0;
    private uint procSweepsSinceCompact = 0;
    private bool procSawRemovals = false;
    private string lastBootId;

    long minIntervalNs = CounterTracker!NetKey.DEFAULT_MIN_INTERVAL_NS;
    long suspendGapNs = CounterTracker!NetKey.DEFAULT_SUSPEND_GAP_NS;
    long maxIntervalNs = 3_600_000_000_000L;

    void resetAll() @safe {
        cpuBase = CpuSampleBaseline.init;
        netRxTracker.reset();
        netTxTracker.reset();
        procEntries = null;
        procGen = 0;
        procSweepsSinceCompact = 0;
        procSawRemovals = false;
    }

    void checkBootId(string bootId) @safe {
        if (lastBootId.length > 0 && bootId.length > 0 && lastBootId != bootId) {
            resetAll();
        }
        if (bootId.length > 0) {
            lastBootId = bootId;
        }
    }

    Nullable!double computeAggregateCpuPct(string bootId, ulong totalTicks, ulong idleTicks, long monoNs, long bootOrWallNs = -1) @safe {
        Nullable!double pct;
        checkBootId(bootId);

        if (!cpuBase.valid || cpuBase.bootId != bootId) {
            cpuBase = CpuSampleBaseline(true, bootId, totalTicks, idleTicks, monoNs, bootOrWallNs);
            return pct;
        }

        if (monoNs <= cpuBase.monoNs) {
            cpuBase = CpuSampleBaseline(true, bootId, totalTicks, idleTicks, monoNs, bootOrWallNs);
            return pct;
        }

        long deltaNs = monoNs - cpuBase.monoNs;
        if (bootOrWallNs >= 0 && cpuBase.bootNs >= 0) {
            long bootDelta = bootOrWallNs - cpuBase.bootNs;
            if (bootDelta < 0 || (bootDelta - deltaNs) > suspendGapNs) {
                cpuBase = CpuSampleBaseline(true, bootId, totalTicks, idleTicks, monoNs, bootOrWallNs);
                return pct;
            }
        }

        if (maxIntervalNs > 0 && deltaNs > maxIntervalNs) {
            cpuBase = CpuSampleBaseline(true, bootId, totalTicks, idleTicks, monoNs, bootOrWallNs);
            return pct;
        }

        if (totalTicks < cpuBase.totalTicks || idleTicks < cpuBase.idleTicks) {
            cpuBase = CpuSampleBaseline(true, bootId, totalTicks, idleTicks, monoNs, bootOrWallNs);
            return pct;
        }

        if (deltaNs < minIntervalNs) {
            return pct;
        }

        ulong dTotal = totalTicks - cpuBase.totalTicks;
        ulong dIdle = idleTicks - cpuBase.idleTicks;
        cpuBase = CpuSampleBaseline(true, bootId, totalTicks, idleTicks, monoNs, bootOrWallNs);

        if (dTotal == 0) return pct;
        ulong active = dTotal > dIdle ? (dTotal - dIdle) : 0;
        double val = (cast(double) active / cast(double) dTotal) * 100.0;
        pct = clamp(val, 0.0, 100.0);
        return pct;
    }

    NetworkInterfaceStatus[] computeNetworkRates(string bootId, const RawNetworkInterface[] rawIfs, long monoNs, long bootOrWallNs = -1) @safe {
        checkBootId(bootId);
        netRxTracker.minIntervalNs = minIntervalNs;
        netRxTracker.maxIntervalNs = maxIntervalNs;
        netRxTracker.suspendGapNs = suspendGapNs;
        netTxTracker.minIntervalNs = minIntervalNs;
        netTxTracker.maxIntervalNs = maxIntervalNs;
        netTxTracker.suspendGapNs = suspendGapNs;

        netRxTracker.beginSweep();
        netTxTracker.beginSweep();

        NetworkInterfaceStatus[] outIfs;
        outIfs.reserve(rawIfs.length);
        foreach (rif; rawIfs) {
            auto key = NetKey(bootId, rif.id);
            NetworkInterfaceStatus nis;
            nis.id = rif.id;
            nis.name = rif.name;
            nis.kind = rif.kind;
            nis.rx_bytes = rif.rx_bytes;
            nis.tx_bytes = rif.tx_bytes;
            nis.rx_bytes_per_s = netRxTracker.update(key, rif.rx_bytes, monoNs, bootOrWallNs);
            nis.tx_bytes_per_s = netTxTracker.update(key, rif.tx_bytes, monoNs, bootOrWallNs);
            nis.link_up = rif.link_up;
            nis.link_speed_bps = rif.link_speed_bps;
            outIfs ~= nis;
        }

        netRxTracker.pruneUnseen();
        netTxTracker.pruneUnseen();
        return outIfs;
    }

    ProcessStatus[] computeProcessRates(string bootId, const ref RawProcessResult raw, long monoNs, long bootOrWallNs = -1) @safe {
        checkBootId(bootId);
        procGen++;

        ProcessStatus[] result;
        result.reserve(raw.processes.length);
        uint cores = raw.logical_cores > 0 ? raw.logical_cores : 1;

        foreach (rp; raw.processes) {
            auto key = ProcessKey(rp.pid, rp.start_id);
            ProcessStatus ps;
            ps.pid = rp.pid;
            ps.start_id = rp.start_id;
            ps.name = rp.name;
            ps.rss_bytes = rp.rss_bytes;
            ps.memory_kind = rp.memory_kind;

            auto p = key in procEntries;
            if (p is null) {
                procEntries[key] = ProcEntry(rp.cpu_ticks, raw.total_cpu_ticks, monoNs, bootOrWallNs, procGen);
                result ~= ps;
                continue;
            }

            auto prev = *p;
            long deltaNs = monoNs - prev.monoNs;

            bool invalid = false;
            if (monoNs <= prev.monoNs) invalid = true;
            if (bootOrWallNs >= 0 && prev.bootNs >= 0) {
                long bootDelta = bootOrWallNs - prev.bootNs;
                if (bootDelta < 0 || (bootDelta - deltaNs) > suspendGapNs) invalid = true;
            }
            if (maxIntervalNs > 0 && deltaNs > maxIntervalNs) invalid = true;
            if (rp.cpu_ticks < prev.procTicks || raw.total_cpu_ticks <= prev.totalCpuTicks) invalid = true;

            if (invalid) {
                *p = ProcEntry(rp.cpu_ticks, raw.total_cpu_ticks, monoNs, bootOrWallNs, procGen);
                result ~= ps;
                continue;
            }

            if (deltaNs < minIntervalNs) {
                p.generation = procGen;
                result ~= ps;
                continue;
            }

            ulong dProc = rp.cpu_ticks - prev.procTicks;
            ulong dTotal = raw.total_cpu_ticks - prev.totalCpuTicks;
            *p = ProcEntry(rp.cpu_ticks, raw.total_cpu_ticks, monoNs, bootOrWallNs, procGen);

            if (dTotal > 0) {
                // One logical CPU = 100.0%
                double val = (cast(double) dProc / cast(double) dTotal) * 100.0 * cast(double) cores;
                ps.cpu_pct = clamp(val, 0.0, 100.0 * cast(double) cores);
            }
            result ~= ps;
        }

        ProcessKey[] stale;
        foreach (k, ref e; procEntries) {
            if (e.generation != procGen) stale ~= k;
        }
        if (stale.length > 0) {
            foreach (k; stale) procEntries.remove(k);
            procSawRemovals = true;
        }
        procSweepsSinceCompact++;
        if (procSweepsSinceCompact >= 64 && procSawRemovals) {
            procSweepsSinceCompact = 0;
            procSawRemovals = false;
            if (procEntries.length == 0) {
                procEntries = null;
            } else {
                ProcEntry[ProcessKey] compacted;
                foreach (k, e; procEntries) compacted[k] = e;
                procEntries = compacted;
            }
        }

        return result;
    }

    size_t trackedProcessCount() const nothrow @safe {
        return procEntries.length;
    }

    size_t trackedNetworkCount() const nothrow @safe {
        return netRxTracker.length;
    }
}
