module core.coordinator;

import core.cache;
import core.config;
import core.model;
import core.serializer;
import core.sync.condition;
import core.sync.mutex;
import core.thread;
import core.time : MonoTime, msecs;
import platform.api;
import platform.clock : continuousBootNanoseconds;
import std.algorithm : sort;
import std.datetime.systime : Clock;
import std.typecons : Nullable;

private shared bool gSystemResumed = false;

/// Records an OS resume from sleep (from the Windows SCM power event, or any platform
/// hook). The next rate computation drops all baselines so the first post-resume rate
/// is reported as unknown (null) instead of a bogus spike or dip.
void noteSystemResume() nothrow @nogc {
    import core.atomic : atomicStore;
    atomicStore(gSystemResumed, true);
}

private bool consumeSystemResume() nothrow @nogc {
    import core.atomic : cas;
    return cas(&gSystemResumed, true, false);
}

struct ClockSource {
    long delegate() monoNs;
    long delegate() wallTs;
    long delegate() bootNs;

    static ClockSource system() {
        ClockSource cs;
        cs.monoNs = () {
            auto t = MonoTime.currTime.ticks;
            auto tps = MonoTime.ticksPerSecond;
            if (tps == 1_000_000_000L) return t;
            long secs = t / tps;
            long rem = t % tps;
            return secs * 1_000_000_000L + (rem * 1_000_000_000L) / tps;
        };
        cs.wallTs = () => Clock.currTime.toUnixTime();
        cs.bootNs = () => continuousBootNanoseconds();
        return cs;
    }
}

enum EndpointOutcomeKind {
    ok,
    collecting,
    error,
}

struct StatusEndpointResult {
    EndpointOutcomeKind kind;
    int httpStatus;
    uint retryAfterS = 1;
    string errorCode;
    string errorMessage;
    StatusResponse payload;
    GroupMeta[string] groups;
}

struct HardwareEndpointResult {
    EndpointOutcomeKind kind;
    int httpStatus;
    uint retryAfterS = 1;
    string errorCode;
    string errorMessage;
    HardwareInventory payload;
}

class RefreshCoordinator {
    PlatformBackend backend;
    TelemetryCacheStore store;
    ClockSource clocks;

    private Mutex mtx;
    private Condition cond;

    this(PlatformBackend backend, TelemetryCacheStore store, ClockSource clocks = ClockSource.system()) {
        this.backend = backend;
        this.store = store;
        this.clocks = clocks;
        this.mtx = new Mutex();
        this.cond = new Condition(this.mtx);

        // Populate initial cheap OS identity so /info always has host/os/arch without running telemetry probes
        try {
            this.store.cachedIdentity = backend.identity();
        } catch (Exception) {
            this.store.cachedIdentity = PlatformIdentity("unknown", "unknown", "unknown", "", Nullable!long.init);
        }
    }

    void updateFqdn(string fqdn) {
        synchronized (mtx) {
            store.fqdn = fqdn;
        }
    }

    InfoResponse getInfo() {
        synchronized (mtx) {
            return store.buildInfoResponse(clocks.wallTs());
        }
    }

    HealthResponse getHealth() {
        synchronized (mtx) {
            HealthResponse hr;
            hr.node_id = store.nodeId;
            hr.server_ts = clocks.wallTs();
            auto f = store.groups[ProbeGroup.fast];
            hr.status = (f.consecutiveFailures > 0 && !f.hasSuccess) ? "degraded" : "ok";
            return hr;
        }
    }

    StatusEndpointResult getStatus(bool forceRefresh = false) {
        static immutable ProbeGroup[] statusGroups = [
            ProbeGroup.fast,
            ProbeGroup.processes,
            ProbeGroup.device_dynamic,
            ProbeGroup.filesystems,
            ProbeGroup.maintenance,
        ];

        long nowMono = clocks.monoNs();
        long nowWall = clocks.wallTs();

        bool needColdWait = false;
        bool[ProbeGroup] waitForRefresh;
        ulong[ProbeGroup] targetGen;

        synchronized (mtx) {
            foreach (g; statusGroups) {
                reapTimedOutLocked(g, nowMono);
                bool fresh = !forceRefresh && store.isFresh(g, nowMono, nowWall);
                if (fresh) continue;

                bool usable = !forceRefresh && store.isUsableStale(g, nowMono, nowWall);
                auto e = store.groups[g];

                if (!usable) {
                    if (g == ProbeGroup.fast || forceRefresh) {
                        needColdWait = true;
                        waitForRefresh[g] = true;
                        targetGen[g] = e.generation + 1;
                    } else if (!e.unsupported && e.consecutiveFailures == 0) {
                        needColdWait = true;
                        waitForRefresh[g] = true;
                        targetGen[g] = e.generation + 1;
                    }
                }

                if (!e.inFlight && (forceRefresh || nowMono >= e.backoffUntilMonoNs)) {
                    startGroupRefreshLocked(g, nowMono);
                }
            }

            if (needColdWait) {
                long deadlineMono = nowMono + cast(long) store.config.collection.cold_wait_ms * 1_000_000L;
                while (true) {
                    nowMono = clocks.monoNs();
                    nowWall = clocks.wallTs();

                    foreach (g; statusGroups) reapTimedOutLocked(g, nowMono);

                    bool allStartedColdDone = true;
                    foreach (g; statusGroups) {
                        auto e = store.groups[g];
                        if ((g in waitForRefresh) && e.inFlight && e.generation < targetGen[g]) {
                            allStartedColdDone = false;
                            break;
                        }
                    }

                    if (allStartedColdDone) break;

                    long remNs = deadlineMono - nowMono;
                    if (remNs <= 0) break;

                    long waitMs = remNs / 1_000_000L;
                    if (waitMs < 1) waitMs = 1;
                    if (waitMs > 50) waitMs = 50;
                    cond.wait(msecs(waitMs));
                }
            }

            nowMono = clocks.monoNs();
            nowWall = clocks.wallTs();

            auto fastEntry = store.groups[ProbeGroup.fast];
            bool fastUsable = store.isUsableStale(ProbeGroup.fast, nowMono, nowWall);

            if (!fastUsable) {
                if (fastEntry.inFlight) {
                    StatusEndpointResult res;
                    res.kind = EndpointOutcomeKind.collecting;
                    res.httpStatus = 202;
                    res.retryAfterS = 1;
                    return res;
                }
                StatusEndpointResult res;
                res.kind = EndpointOutcomeKind.error;
                res.httpStatus = 503;
                res.errorCode = fastEntry.lastError.length > 0 ? fastEntry.lastError : "fast_probe_unavailable";
                res.errorMessage = "Core telemetry probes failed with no usable cached snapshot";
                auto snap = store.snapshotStatusResponse(nowMono, nowWall);
                res.groups = snap.groups;
                return res;
            }

            // If fast is usable, check if all cold groups are still waiting vs ready
            // Note: fast is ready, so a hung slow probe (filesystems/device_dynamic) never blocks fast CPU status!
            StatusEndpointResult res;
            res.kind = EndpointOutcomeKind.ok;
            res.httpStatus = 200;
            res.payload = store.snapshotStatusResponse(nowMono, nowWall);
            return res;
        }
    }

    HardwareEndpointResult getHardware(bool forceRefresh = false) {
        long nowMono = clocks.monoNs();
        long nowWall = clocks.wallTs();

        synchronized (mtx) {
            reapTimedOutLocked(ProbeGroup.hardware, nowMono);
            bool fresh = !forceRefresh && store.isFresh(ProbeGroup.hardware, nowMono, nowWall);
            bool usable = !forceRefresh && store.isUsableStale(ProbeGroup.hardware, nowMono, nowWall);
            auto e = store.groups[ProbeGroup.hardware];

            if (!fresh && !e.inFlight && (forceRefresh || nowMono >= e.backoffUntilMonoNs)) {
                startGroupRefreshLocked(ProbeGroup.hardware, nowMono);
            }

            if (!usable || forceRefresh) {
                ulong targetHwGen = e.generation + 1;
                long deadlineMono = nowMono + cast(long) store.config.collection.cold_wait_ms * 1_000_000L;
                while (store.groups[ProbeGroup.hardware].inFlight && store.groups[ProbeGroup.hardware].generation < targetHwGen) {
                    nowMono = clocks.monoNs();
                    reapTimedOutLocked(ProbeGroup.hardware, nowMono);
                    if (!store.groups[ProbeGroup.hardware].inFlight) break;
                    long remNs = deadlineMono - nowMono;
                    if (remNs <= 0) break;
                    long waitMs = remNs / 1_000_000L;
                    if (waitMs < 1) waitMs = 1;
                    if (waitMs > 50) waitMs = 50;
                    cond.wait(msecs(waitMs));
                }
            }

            nowMono = clocks.monoNs();
            nowWall = clocks.wallTs();
            e = store.groups[ProbeGroup.hardware];
            if (!store.isUsableStale(ProbeGroup.hardware, nowMono, nowWall)) {
                if (e.inFlight) {
                    HardwareEndpointResult res;
                    res.kind = EndpointOutcomeKind.collecting;
                    res.httpStatus = 202;
                    res.retryAfterS = 1;
                    return res;
                }
                HardwareEndpointResult res;
                res.kind = EndpointOutcomeKind.error;
                res.httpStatus = 503;
                res.errorCode = e.lastError.length > 0 ? e.lastError : "hardware_scan_failed";
                res.errorMessage = "Hardware inventory scan failed";
                return res;
            }

            HardwareEndpointResult res;
            res.kind = EndpointOutcomeKind.ok;
            res.httpStatus = 200;
            res.payload = store.snapshotHardwareResponse(nowMono, nowWall);
            return res;
        }
    }

    private void reapTimedOutLocked(ProbeGroup g, long nowMono) {
        auto e = store.groups[g];
        if (!e.inFlight) return;
        long timeoutNs = cast(long) store.config.collection.probe_timeout_ms * 1_000_000L;
        if (timeoutNs > 0 && (nowMono - e.inFlightStartedMonoNs) > timeoutNs) {
            e.inFlight = false;
            e.consecutiveFailures++;
            e.lastError = "probe_timeout";
            e.backoffUntilMonoNs = nowMono + computeBackoffNs(e.consecutiveFailures);
            e.generation++;
            store.groups[g] = e;
            cond.notifyAll();
        }
    }

    private long computeBackoffNs(uint failures) pure nothrow @safe {
        uint shift = failures > 5 ? 5 : failures;
        long sec = 2L << (shift - 1); // 2s, 4s, 8s, 16s, 32s, 64s
        if (sec > 60) sec = 60;
        return sec * 1_000_000_000L;
    }

    private void startGroupRefreshLocked(ProbeGroup g, long nowMono) {
        auto e = store.groups[g];
        e.inFlight = true;
        e.lastAttemptMonoNs = nowMono;
        e.inFlightStartedMonoNs = nowMono;
        ulong launchGen = e.generation;
        store.groups[g] = e;

        auto worker = new Thread({
            runProbe(g, launchGen);
        });
        worker.isDaemon = true;
        worker.start();
    }

    private void runProbe(ProbeGroup g, ulong expectedGen) {
        try {
            final switch (g) {
                case ProbeGroup.fast:
                    runFastProbe(expectedGen);
                    break;
                case ProbeGroup.processes:
                    runProcessProbe(expectedGen);
                    break;
                case ProbeGroup.filesystems:
                    runFilesystemProbe(expectedGen);
                    break;
                case ProbeGroup.device_dynamic:
                    runDeviceDynamicProbe(expectedGen);
                    break;
                case ProbeGroup.maintenance:
                    runMaintenanceProbe(expectedGen);
                    break;
                case ProbeGroup.hardware:
                    runHardwareProbe(expectedGen);
                    break;
                case ProbeGroup.tailnet:
                    markGroupUnsupported(ProbeGroup.tailnet, expectedGen);
                    break;
            }
        } catch (Exception ex) {
            markGroupFailure(g, expectedGen, "probe_exception");
        }
    }

    private void runFastProbe(ulong expectedGen) {
        auto id = backend.identity();
        auto cpu = backend.sampleCpu();
        auto mem = backend.sampleMemory();
        auto net = backend.sampleNetwork();
        long doneMono = clocks.monoNs();
        long doneWall = clocks.wallTs();
        long doneBoot = clocks.bootNs();

        if (cpu.state != CapabilityState.ok || mem.state != CapabilityState.ok
            || net.state != CapabilityState.ok) {
            string err = cpu.state != CapabilityState.ok ? cpu.error
                : mem.state != CapabilityState.ok ? mem.error : net.error;
            markGroupFailure(ProbeGroup.fast, expectedGen, err.length > 0 ? err : "fast_probe_error");
            return;
        }

        synchronized (mtx) {
            auto e = store.groups[ProbeGroup.fast];
            if (e.generation != expectedGen) return; // timed out / superseded
            if (consumeSystemResume()) store.rateState.resetAll();

            store.cachedIdentity = id;
            store.cachedCpu.pct = store.rateState.computeAggregateCpuPct(id.boot_id, cpu.total_ticks, cpu.idle_ticks, doneMono, doneBoot);
            store.cachedCpu.load_1m = cpu.load_1m;
            store.cachedCpu.temp_c = cpu.temp_c;

            store.cachedMemory.total_bytes = mem.total_bytes;
            store.cachedMemory.used_bytes = mem.used_bytes;
            if (!mem.total_bytes.isNull && !mem.used_bytes.isNull && mem.total_bytes.get > 0) {
                store.cachedMemory.pct = (cast(double) mem.used_bytes.get / cast(double) mem.total_bytes.get) * 100.0;
            } else {
                store.cachedMemory.pct = Nullable!double.init;
            }

            if (!mem.swap_total_bytes.isNull && !mem.swap_used_bytes.isNull) {
                SwapStatus sw;
                sw.total_bytes = mem.swap_total_bytes;
                sw.used_bytes = mem.swap_used_bytes;
                if (mem.swap_total_bytes.get > 0) {
                    sw.pct = (cast(double) mem.swap_used_bytes.get / cast(double) mem.swap_total_bytes.get) * 100.0;
                } else {
                    sw.pct = 0.0;
                }
                store.cachedSwap = sw;
            } else {
                store.cachedSwap = Nullable!SwapStatus.init;
            }

            if (!mem.commit_limit_bytes.isNull && !mem.commit_used_bytes.isNull) {
                CommitStatus cm;
                cm.limit_bytes = mem.commit_limit_bytes;
                cm.used_bytes = mem.commit_used_bytes;
                if (mem.commit_limit_bytes.get > 0) {
                    cm.pct = (cast(double) mem.commit_used_bytes.get / cast(double) mem.commit_limit_bytes.get) * 100.0;
                }
                store.cachedCommit = cm;
            } else {
                store.cachedCommit = Nullable!CommitStatus.init;
            }

            if (net.state == CapabilityState.ok) {
                store.cachedNetwork = store.rateState.computeNetworkRates(id.boot_id, net.interfaces, doneMono, doneBoot);
            }

            markGroupSuccessLocked(ProbeGroup.fast, doneMono, doneWall);
        }
    }

    private void runProcessProbe(ulong expectedGen) {
        auto id = backend.identity();
        auto pr = backend.sampleProcesses();
        long doneMono = clocks.monoNs();
        long doneWall = clocks.wallTs();
        long doneBoot = clocks.bootNs();

        if (pr.state != CapabilityState.ok && pr.state != CapabilityState.unsupported) {
            markGroupFailure(ProbeGroup.processes, expectedGen, pr.error.length > 0 ? pr.error : "process_probe_error");
            return;
        }
        if (pr.state == CapabilityState.unsupported) {
            markGroupUnsupported(ProbeGroup.processes, expectedGen);
            return;
        }

        synchronized (mtx) {
            auto e = store.groups[ProbeGroup.processes];
            if (e.generation != expectedGen) return;
            if (consumeSystemResume()) store.rateState.resetAll();

            auto rates = store.rateState.computeProcessRates(id.boot_id, pr, doneMono, doneBoot);

            auto byCpu = rates.dup;
            sort!((a, b) {
                double ac = a.cpu_pct.isNull ? -1.0 : a.cpu_pct.get;
                double bc = b.cpu_pct.isNull ? -1.0 : b.cpu_pct.get;
                if (ac != bc) return ac > bc;
                ulong ar = a.rss_bytes.isNull ? 0 : a.rss_bytes.get;
                ulong br = b.rss_bytes.isNull ? 0 : b.rss_bytes.get;
                return ar > br;
            })(byCpu);
            store.cachedTopCpu = byCpu.length > 5 ? byCpu[0 .. 5] : byCpu;

            auto byMem = rates.dup;
            sort!((a, b) {
                ulong ar = a.rss_bytes.isNull ? 0 : a.rss_bytes.get;
                ulong br = b.rss_bytes.isNull ? 0 : b.rss_bytes.get;
                return ar > br;
            })(byMem);
            store.cachedTopMem = byMem.length > 5 ? byMem[0 .. 5] : byMem;

            markGroupSuccessLocked(ProbeGroup.processes, doneMono, doneWall);
        }
    }

    private void runFilesystemProbe(ulong expectedGen) {
        auto fs = backend.sampleFilesystems();
        long doneMono = clocks.monoNs();
        long doneWall = clocks.wallTs();

        if (fs.state != CapabilityState.ok && fs.state != CapabilityState.unsupported) {
            markGroupFailure(ProbeGroup.filesystems, expectedGen, fs.error.length > 0 ? fs.error : "filesystem_probe_error");
            return;
        }
        if (fs.state == CapabilityState.unsupported) {
            markGroupUnsupported(ProbeGroup.filesystems, expectedGen);
            return;
        }

        synchronized (mtx) {
            if (store.groups[ProbeGroup.filesystems].generation != expectedGen) return;
            store.cachedMounts = fs.mounts.dup;
            markGroupSuccessLocked(ProbeGroup.filesystems, doneMono, doneWall);
        }
    }

    private void runDeviceDynamicProbe(ulong expectedGen) {
        auto gpus = backend.sampleGpus();
        auto bats = backend.sampleBatteries();
        long doneMono = clocks.monoNs();
        long doneWall = clocks.wallTs();

        if ((bats.state != CapabilityState.ok && bats.state != CapabilityState.unsupported)
            || (gpus.state != CapabilityState.ok && gpus.state != CapabilityState.unsupported)) {
            markGroupFailure(ProbeGroup.device_dynamic, expectedGen, gpus.error.length > 0 ? gpus.error : bats.error.length > 0 ? bats.error : "device_dynamic_error");
            return;
        }

        if (gpus.state == CapabilityState.unsupported && bats.state == CapabilityState.unsupported) {
            markGroupUnsupported(ProbeGroup.device_dynamic, expectedGen);
            return;
        }

        synchronized (mtx) {
            if (store.groups[ProbeGroup.device_dynamic].generation != expectedGen) return;
            store.cachedGpus = gpus.state == CapabilityState.ok ? gpus.gpus.dup : [];
            store.cachedBatteries = bats.state == CapabilityState.ok ? bats.batteries.dup : [];

            if (gpus.state == CapabilityState.error && bats.batteries.length == 0) {
                // Record error explicitly instead of pretending unsupported or 0%
                markGroupFailureLocked(ProbeGroup.device_dynamic, doneMono, gpus.error.length > 0 ? gpus.error : "gpu_probe_error");
                return;
            }

            if (gpus.state == CapabilityState.unsupported && bats.batteries.length == 0) {
                auto e = store.groups[ProbeGroup.device_dynamic];
                e.inFlight = false;
                e.unsupported = true;
                e.lastAttemptMonoNs = doneMono;
                e.generation++;
                store.groups[ProbeGroup.device_dynamic] = e;
                cond.notifyAll();
                return;
            }

            markGroupSuccessLocked(ProbeGroup.device_dynamic, doneMono, doneWall);
        }
    }

    private void runMaintenanceProbe(ulong expectedGen) {
        auto mr = backend.sampleMaintenance();
        long doneMono = clocks.monoNs();
        long doneWall = clocks.wallTs();

        if (mr.state != CapabilityState.ok && mr.state != CapabilityState.unsupported) {
            markGroupFailure(ProbeGroup.maintenance, expectedGen, mr.error.length > 0 ? mr.error : "maintenance_probe_error");
            return;
        }
        if (mr.state == CapabilityState.unsupported) {
            markGroupUnsupported(ProbeGroup.maintenance, expectedGen);
            return;
        }

        synchronized (mtx) {
            if (store.groups[ProbeGroup.maintenance].generation != expectedGen) return;
            store.cachedDrift = mr.drift;
            markGroupSuccessLocked(ProbeGroup.maintenance, doneMono, doneWall);
        }
    }

    private void runHardwareProbe(ulong expectedGen) {
        auto hr = backend.scanHardware();
        long doneMono = clocks.monoNs();
        long doneWall = clocks.wallTs();

        if (hr.state != CapabilityState.ok && hr.state != CapabilityState.unsupported) {
            markGroupFailure(ProbeGroup.hardware, expectedGen, hr.error.length > 0 ? hr.error : "hardware_scan_error");
            return;
        }
        if (hr.state == CapabilityState.unsupported) {
            markGroupUnsupported(ProbeGroup.hardware, expectedGen);
            return;
        }

        synchronized (mtx) {
            if (store.groups[ProbeGroup.hardware].generation != expectedGen) return;
            auto hw = hr.inventory;
            hw.node_id = store.nodeId;
            hw.collected_at = doneWall;
            hw.collection.status = GroupStatus.fresh;
            hw.collection.age_s = 0;
            hw.collection.refreshing = false;
            store.cachedHardware = hw;
            store.updateHardwareSummaryFromInventory(hw);
            store.persistHardware(hw);
            markGroupSuccessLocked(ProbeGroup.hardware, doneMono, doneWall);
        }
    }

    private void markGroupSuccessLocked(ProbeGroup g, long doneMono, long doneWall) {
        auto e = store.groups[g];
        e.hasSuccess = true;
        e.unsupported = false;
        e.inFlight = false;
        e.lastSuccessMonoNs = doneMono;
        e.lastSuccessWallTs = doneWall;
        e.consecutiveFailures = 0;
        e.lastError = "";
        e.backoffUntilMonoNs = 0;
        e.generation++;
        store.groups[g] = e;
        cond.notifyAll();
    }

    private void markGroupFailure(ProbeGroup g, ulong expectedGen, string err) {
        long nowMono = clocks.monoNs();
        synchronized (mtx) {
            if (store.groups[g].generation != expectedGen) return;
            markGroupFailureLocked(g, nowMono, err);
        }
    }

    private void markGroupFailureLocked(ProbeGroup g, long nowMono, string err) {
        auto e = store.groups[g];
        e.inFlight = false;
        e.consecutiveFailures++;
        e.lastError = sanitizeOsString(err, 128);
        e.backoffUntilMonoNs = nowMono + computeBackoffNs(e.consecutiveFailures);
        e.generation++;
        store.groups[g] = e;
        cond.notifyAll();
    }

    private void markGroupUnsupported(ProbeGroup g, ulong expectedGen) {
        long nowMono = clocks.monoNs();
        synchronized (mtx) {
            if (store.groups[g].generation != expectedGen) return;
            auto e = store.groups[g];
            e.inFlight = false;
            e.unsupported = true;
            e.lastAttemptMonoNs = nowMono;
            e.consecutiveFailures = 0;
            e.lastError = "";
            e.generation++;
            store.groups[g] = e;
            cond.notifyAll();
        }
    }
}
