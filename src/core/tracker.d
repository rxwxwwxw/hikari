module core.tracker;

import core.limits;
import core.model;
import std.algorithm : clamp;
import std.typecons : Nullable;

struct FixedString(size_t N) {
    static assert(N <= ushort.max);
    ushort len = 0;
    char[N] data;

    @nogc nothrow pure:

    void clear() @safe {
        len = 0;
    }

    void set(const(char)[] src) @safe {
        size_t n = src.length > N ? N : src.length;
        if (n > 0) data[0 .. n] = src[0 .. n];
        len = cast(ushort) n;
    }

    string slice() const return @trusted {
        return cast(string) data[0 .. len];
    }

    bool equals(const(char)[] other) const @safe {
        return len == other.length && data[0 .. len] == other;
    }

    bool opEquals(const ref FixedString!N other) const @safe {
        return len == other.len && data[0 .. len] == other.data[0 .. other.len];
    }

    size_t toHash() const @safe {
        size_t h = 2166136261u;
        foreach (char c; data[0 .. len]) {
            h ^= cast(ubyte) c;
            h *= 16777619u;
        }
        return h;
    }
}

struct NetCounterTable {
    struct Slot {
        bool occupied = false;
        FixedString!64 bootId;
        FixedString!64 id;
        ulong value = 0;
        long monoNs = 0;
        long bootNs = -1;
        ulong generation = 0;
    }

    enum long DEFAULT_MIN_INTERVAL_NS = 50_000_000L; // 50 ms
    enum long DEFAULT_SUSPEND_GAP_NS = 15_000_000_000L; // 15 s divergence between boot/wall and mono
    enum size_t MASK = NET_TRACKER_SLOTS - 1;
    static assert((NET_TRACKER_SLOTS & MASK) == 0, "NET_TRACKER_SLOTS must be power of two");

    long minIntervalNs = DEFAULT_MIN_INTERVAL_NS;
    long maxIntervalNs = 3_600_000_000_000L; // 1 hour max gap before resetting baseline
    long suspendGapNs = DEFAULT_SUSPEND_GAP_NS;

    private Slot[NET_TRACKER_SLOTS] slots;
    private size_t count = 0;
    private ulong currentGen = 0;

    @nogc nothrow pure @safe:

    private static size_t hashPair(const(char)[] bootId, const(char)[] id) {
        size_t h = 17;
        foreach (char c; bootId) h = h * 31 + cast(ubyte) c;
        foreach (char c; id) h = h * 31 + cast(ubyte) c;
        return h;
    }

    private static size_t slotHash(const ref Slot s) {
        return hashPair(s.bootId.slice(), s.id.slice());
    }

    Nullable!double update(const(char)[] bootId, const(char)[] id, ulong value, long monoNs, long bootOrWallNs = -1) {
        Nullable!double rate;
        size_t idx = hashPair(bootId, id) & MASK;
        Slot* found = null;
        size_t emptyIdx = size_t.max;

        foreach (_; 0 .. NET_TRACKER_SLOTS) {
            if (!slots[idx].occupied) {
                emptyIdx = idx;
                break;
            }
            if (slots[idx].bootId.equals(bootId) && slots[idx].id.equals(id)) {
                found = &slots[idx];
                break;
            }
            idx = (idx + 1) & MASK;
        }

        if (found is null) {
            if (emptyIdx != size_t.max && count + 1 < NET_TRACKER_SLOTS) {
                slots[emptyIdx].occupied = true;
                slots[emptyIdx].bootId.set(bootId);
                slots[emptyIdx].id.set(id);
                slots[emptyIdx].value = value;
                slots[emptyIdx].monoNs = monoNs;
                slots[emptyIdx].bootNs = bootOrWallNs;
                slots[emptyIdx].generation = currentGen;
                count++;
            }
            return rate;
        }

        auto prev = *found;

        if (monoNs <= prev.monoNs) {
            found.value = value;
            found.monoNs = monoNs;
            found.bootNs = bootOrWallNs;
            found.generation = currentGen;
            return rate;
        }

        long deltaNs = monoNs - prev.monoNs;

        if (bootOrWallNs >= 0 && prev.bootNs >= 0) {
            long bootDelta = bootOrWallNs - prev.bootNs;
            if (bootDelta < 0 || (bootDelta - deltaNs) > suspendGapNs) {
                found.value = value;
                found.monoNs = monoNs;
                found.bootNs = bootOrWallNs;
                found.generation = currentGen;
                return rate;
            }
        }

        if (maxIntervalNs > 0 && deltaNs > maxIntervalNs) {
            found.value = value;
            found.monoNs = monoNs;
            found.bootNs = bootOrWallNs;
            found.generation = currentGen;
            return rate;
        }

        if (value < prev.value) {
            found.value = value;
            found.monoNs = monoNs;
            found.bootNs = bootOrWallNs;
            found.generation = currentGen;
            return rate;
        }

        if (deltaNs < minIntervalNs) {
            found.generation = currentGen;
            return rate;
        }

        double deltaVal = cast(double)(value - prev.value);
        double deltaSec = cast(double) deltaNs / 1_000_000_000.0;
        rate = deltaVal / deltaSec;
        found.value = value;
        found.monoNs = monoNs;
        found.bootNs = bootOrWallNs;
        found.generation = currentGen;
        return rate;
    }

    void beginSweep() {
        currentGen++;
    }

    private void deleteAt(size_t delIdx) {
        size_t hole = delIdx;
        size_t cur = (hole + 1) & MASK;
        while (slots[cur].occupied) {
            size_t h = slotHash(slots[cur]) & MASK;
            if (((hole - h) & MASK) < ((cur - h) & MASK)) {
                slots[hole] = slots[cur];
                hole = cur;
            }
            cur = (cur + 1) & MASK;
        }
        slots[hole].occupied = false;
        slots[hole].generation = 0;
        if (count > 0) count--;
    }

    void pruneUnseen() {
        size_t i = 0;
        while (i < NET_TRACKER_SLOTS) {
            if (slots[i].occupied && slots[i].generation != currentGen) {
                deleteAt(i);
            } else {
                i++;
            }
        }
    }

    void reset() {
        foreach (ref s; slots) {
            s.occupied = false;
            s.generation = 0;
        }
        count = 0;
        currentGen = 0;
    }

    size_t length() const {
        return count;
    }
}

struct CpuSampleBaseline {
    bool valid = false;
    FixedString!128 bootId;
    ulong totalTicks;
    ulong idleTicks;
    long monoNs;
    long bootNs = -1;
}

class SystemRateState {
    private CpuSampleBaseline cpuBase;
    private NetCounterTable netRxTracker;
    private NetCounterTable netTxTracker;

    private struct ProcSlot {
        bool occupied = false;
        uint pid = 0;
        FixedString!31 startId;
        ulong procTicks = 0;
        ulong totalCpuTicks = 0;
        long monoNs = 0;
        long bootNs = -1;
        ulong generation = 0;
    }

    private enum size_t PROC_MASK = PROC_TRACKER_SLOTS - 1;
    static assert((PROC_TRACKER_SLOTS & PROC_MASK) == 0, "PROC_TRACKER_SLOTS must be power of two");

    private ProcSlot[] procSlots;
    private size_t procCount = 0;
    private ulong procGen = 0;
    private FixedString!128 lastBootId;

    // Preallocated rate output & string storage (0 steady-state allocations)
    private NetworkInterfaceStatus[MAX_NETWORK_INTERFACES] netOutBuf;
    private FixedString!64[MAX_NETWORK_INTERFACES] netIdStore;
    private FixedString!64[MAX_NETWORK_INTERFACES] netNameStore;
    private FixedString!16[MAX_NETWORK_INTERFACES] netKindStore;

    private ProcessStatus[] procOutBuf;
    private FixedString!31[] procStartStore;
    private FixedString!128[] procNameStore;

    private ProcessStatus[MAX_TOP_PROCESSES] topCpuBuf;
    private ProcessStatus[MAX_TOP_PROCESSES] topMemBuf;

    long minIntervalNs = NetCounterTable.DEFAULT_MIN_INTERVAL_NS;
    long suspendGapNs = NetCounterTable.DEFAULT_SUSPEND_GAP_NS;
    long maxIntervalNs = 3_600_000_000_000L;

    this() {
        procSlots = new ProcSlot[PROC_TRACKER_SLOTS];
        procOutBuf = new ProcessStatus[MAX_TRACKED_PROCESSES];
        procStartStore = new FixedString!31[MAX_TRACKED_PROCESSES];
        procNameStore = new FixedString!128[MAX_TRACKED_PROCESSES];
    }

    @nogc nothrow @safe:

    void resetAll() {
        cpuBase = CpuSampleBaseline.init;
        netRxTracker.reset();
        netTxTracker.reset();
        foreach (ref s; procSlots) {
            s.occupied = false;
            s.generation = 0;
        }
        procCount = 0;
        procGen = 0;
    }

    void checkBootId(const(char)[] bootId) {
        if (lastBootId.len > 0 && bootId.length > 0 && !lastBootId.equals(bootId)) {
            resetAll();
        }
        if (bootId.length > 0) {
            lastBootId.set(bootId);
        }
    }

    Nullable!double computeAggregateCpuPct(const(char)[] bootId, ulong totalTicks, ulong idleTicks, long monoNs, long bootOrWallNs = -1) {
        Nullable!double pct;
        checkBootId(bootId);

        if (!cpuBase.valid || !cpuBase.bootId.equals(bootId)) {
            cpuBase.valid = true;
            cpuBase.bootId.set(bootId);
            cpuBase.totalTicks = totalTicks;
            cpuBase.idleTicks = idleTicks;
            cpuBase.monoNs = monoNs;
            cpuBase.bootNs = bootOrWallNs;
            return pct;
        }

        if (monoNs <= cpuBase.monoNs) {
            cpuBase.totalTicks = totalTicks;
            cpuBase.idleTicks = idleTicks;
            cpuBase.monoNs = monoNs;
            cpuBase.bootNs = bootOrWallNs;
            return pct;
        }

        long deltaNs = monoNs - cpuBase.monoNs;
        if (bootOrWallNs >= 0 && cpuBase.bootNs >= 0) {
            long bootDelta = bootOrWallNs - cpuBase.bootNs;
            if (bootDelta < 0 || (bootDelta - deltaNs) > suspendGapNs) {
                cpuBase.totalTicks = totalTicks;
                cpuBase.idleTicks = idleTicks;
                cpuBase.monoNs = monoNs;
                cpuBase.bootNs = bootOrWallNs;
                return pct;
            }
        }

        if (maxIntervalNs > 0 && deltaNs > maxIntervalNs) {
            cpuBase.totalTicks = totalTicks;
            cpuBase.idleTicks = idleTicks;
            cpuBase.monoNs = monoNs;
            cpuBase.bootNs = bootOrWallNs;
            return pct;
        }

        if (totalTicks < cpuBase.totalTicks || idleTicks < cpuBase.idleTicks) {
            cpuBase.totalTicks = totalTicks;
            cpuBase.idleTicks = idleTicks;
            cpuBase.monoNs = monoNs;
            cpuBase.bootNs = bootOrWallNs;
            return pct;
        }

        if (deltaNs < minIntervalNs) {
            return pct;
        }

        ulong dTotal = totalTicks - cpuBase.totalTicks;
        ulong dIdle = idleTicks - cpuBase.idleTicks;
        cpuBase.totalTicks = totalTicks;
        cpuBase.idleTicks = idleTicks;
        cpuBase.monoNs = monoNs;
        cpuBase.bootNs = bootOrWallNs;

        if (dTotal == 0) return pct;
        ulong active = dTotal > dIdle ? (dTotal - dIdle) : 0;
        double val = (cast(double) active / cast(double) dTotal) * 100.0;
        pct = clamp(val, 0.0, 100.0);
        return pct;
    }

    NetworkInterfaceStatus[] computeNetworkRates(const(char)[] bootId, const RawNetworkInterface[] rawIfs, long monoNs, long bootOrWallNs = -1) {
        checkBootId(bootId);
        netRxTracker.minIntervalNs = minIntervalNs;
        netRxTracker.maxIntervalNs = maxIntervalNs;
        netRxTracker.suspendGapNs = suspendGapNs;
        netTxTracker.minIntervalNs = minIntervalNs;
        netTxTracker.maxIntervalNs = maxIntervalNs;
        netTxTracker.suspendGapNs = suspendGapNs;

        netRxTracker.beginSweep();
        netTxTracker.beginSweep();

        size_t outCount = 0;
        foreach (const ref rif; rawIfs) {
            if (outCount >= MAX_NETWORK_INTERFACES) break;
            netIdStore[outCount].set(rif.id);
            netNameStore[outCount].set(rif.name);
            netKindStore[outCount].set(rif.kind);

            NetworkInterfaceStatus nis;
            nis.id = netIdStore[outCount].slice();
            nis.name = netNameStore[outCount].slice();
            nis.kind = netKindStore[outCount].slice();
            nis.rx_bytes = rif.rx_bytes;
            nis.tx_bytes = rif.tx_bytes;
            nis.rx_bytes_per_s = netRxTracker.update(bootId, rif.id, rif.rx_bytes, monoNs, bootOrWallNs);
            nis.tx_bytes_per_s = netTxTracker.update(bootId, rif.id, rif.tx_bytes, monoNs, bootOrWallNs);
            nis.link_up = rif.link_up;
            nis.link_speed_bps = rif.link_speed_bps;
            netOutBuf[outCount] = nis;
            outCount++;
        }

        netRxTracker.pruneUnseen();
        netTxTracker.pruneUnseen();
        return netOutBuf[0 .. outCount];
    }

    private static size_t hashProcess(uint pid, const(char)[] startId) pure {
        size_t h = pid;
        foreach (char c; startId) {
            h = h * 131 + cast(ubyte) c;
        }
        return h;
    }

    private void deleteProcAt(size_t delIdx) {
        size_t hole = delIdx;
        size_t cur = (hole + 1) & PROC_MASK;
        while (procSlots[cur].occupied) {
            size_t h = hashProcess(procSlots[cur].pid, procSlots[cur].startId.slice()) & PROC_MASK;
            if (((hole - h) & PROC_MASK) < ((cur - h) & PROC_MASK)) {
                procSlots[hole] = procSlots[cur];
                hole = cur;
            }
            cur = (cur + 1) & PROC_MASK;
        }
        procSlots[hole].occupied = false;
        procSlots[hole].generation = 0;
        if (procCount > 0) procCount--;
    }

    ProcessStatus[] computeProcessRates(const(char)[] bootId, const ref RawProcessResult raw, long monoNs, long bootOrWallNs = -1) {
        checkBootId(bootId);
        procGen++;

        size_t outCount = 0;
        uint cores = raw.logical_cores > 0 ? raw.logical_cores : 1;

        foreach (const ref rp; raw.processes) {
            if (outCount >= MAX_TRACKED_PROCESSES) break;

            procStartStore[outCount].set(rp.start_id);
            procNameStore[outCount].set(rp.name);

            ProcessStatus ps;
            ps.pid = rp.pid;
            ps.start_id = procStartStore[outCount].slice();
            ps.name = procNameStore[outCount].slice();
            ps.rss_bytes = rp.rss_bytes;
            ps.memory_kind = rp.memory_kind;

            size_t idx = hashProcess(rp.pid, rp.start_id) & PROC_MASK;
            ProcSlot* found = null;
            size_t emptyIdx = size_t.max;
            foreach (_; 0 .. PROC_TRACKER_SLOTS) {
                if (!procSlots[idx].occupied) {
                    emptyIdx = idx;
                    break;
                }
                if (procSlots[idx].pid == rp.pid && procSlots[idx].startId.equals(rp.start_id)) {
                    found = &procSlots[idx];
                    break;
                }
                idx = (idx + 1) & PROC_MASK;
            }

            if (found is null) {
                if (emptyIdx != size_t.max && procCount + 1 < PROC_TRACKER_SLOTS) {
                    procSlots[emptyIdx].occupied = true;
                    procSlots[emptyIdx].pid = rp.pid;
                    procSlots[emptyIdx].startId.set(rp.start_id);
                    procSlots[emptyIdx].procTicks = rp.cpu_ticks;
                    procSlots[emptyIdx].totalCpuTicks = raw.total_cpu_ticks;
                    procSlots[emptyIdx].monoNs = monoNs;
                    procSlots[emptyIdx].bootNs = bootOrWallNs;
                    procSlots[emptyIdx].generation = procGen;
                    procCount++;
                }
                procOutBuf[outCount++] = ps;
                continue;
            }

            auto prev = *found;
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
                found.procTicks = rp.cpu_ticks;
                found.totalCpuTicks = raw.total_cpu_ticks;
                found.monoNs = monoNs;
                found.bootNs = bootOrWallNs;
                found.generation = procGen;
                procOutBuf[outCount++] = ps;
                continue;
            }

            if (deltaNs < minIntervalNs) {
                found.generation = procGen;
                procOutBuf[outCount++] = ps;
                continue;
            }

            ulong dProc = rp.cpu_ticks - prev.procTicks;
            ulong dTotal = raw.total_cpu_ticks - prev.totalCpuTicks;
            found.procTicks = rp.cpu_ticks;
            found.totalCpuTicks = raw.total_cpu_ticks;
            found.monoNs = monoNs;
            found.bootNs = bootOrWallNs;
            found.generation = procGen;

            if (dTotal > 0) {
                double val = (cast(double) dProc / cast(double) dTotal) * 100.0 * cast(double) cores;
                ps.cpu_pct = clamp(val, 0.0, 100.0 * cast(double) cores);
            }
            procOutBuf[outCount++] = ps;
        }

        size_t i = 0;
        while (i < PROC_TRACKER_SLOTS) {
            if (procSlots[i].occupied && procSlots[i].generation != procGen) {
                deleteProcAt(i);
            } else {
                i++;
            }
        }

        return procOutBuf[0 .. outCount];
    }

    private static bool cpuBetter(const ref ProcessStatus a, const ref ProcessStatus b) pure {
        double ac = a.cpu_pct.isNull ? -1.0 : a.cpu_pct.get;
        double bc = b.cpu_pct.isNull ? -1.0 : b.cpu_pct.get;
        if (ac != bc) return ac > bc;
        ulong ar = a.rss_bytes.isNull ? 0 : a.rss_bytes.get;
        ulong br = b.rss_bytes.isNull ? 0 : b.rss_bytes.get;
        return ar > br;
    }

    private static bool memBetter(const ref ProcessStatus a, const ref ProcessStatus b) pure {
        ulong ar = a.rss_bytes.isNull ? 0 : a.rss_bytes.get;
        ulong br = b.rss_bytes.isNull ? 0 : b.rss_bytes.get;
        return ar > br;
    }

    void selectTopProcesses(const ProcessStatus[] rates, out ProcessStatus[] topCpu, out ProcessStatus[] topMem) {
        size_t cpuCount = 0;
        size_t memCount = 0;

        foreach (const ref p; rates) {
            if (cpuCount < MAX_TOP_PROCESSES || cpuBetter(p, topCpuBuf[cpuCount - 1])) {
                size_t pos = cpuCount < MAX_TOP_PROCESSES ? cpuCount : MAX_TOP_PROCESSES - 1;
                while (pos > 0 && cpuBetter(p, topCpuBuf[pos - 1])) {
                    topCpuBuf[pos] = topCpuBuf[pos - 1];
                    pos--;
                }
                topCpuBuf[pos] = p;
                if (cpuCount < MAX_TOP_PROCESSES) cpuCount++;
            }
            if (memCount < MAX_TOP_PROCESSES || memBetter(p, topMemBuf[memCount - 1])) {
                size_t pos = memCount < MAX_TOP_PROCESSES ? memCount : MAX_TOP_PROCESSES - 1;
                while (pos > 0 && memBetter(p, topMemBuf[pos - 1])) {
                    topMemBuf[pos] = topMemBuf[pos - 1];
                    pos--;
                }
                topMemBuf[pos] = p;
                if (memCount < MAX_TOP_PROCESSES) memCount++;
            }
        }

        topCpu = topCpuBuf[0 .. cpuCount];
        topMem = topMemBuf[0 .. memCount];
    }

    size_t trackedProcessCount() const {
        return procCount;
    }

    size_t trackedNetworkCount() const {
        return netRxTracker.length;
    }
}
