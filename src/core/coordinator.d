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
    private long lastGcMonoNs = 0;

    private struct ProbeWorker {
        Condition workerCond;
        Thread thread;
        bool started = false;
        bool pending = false;
        ulong launchGen = 0;
    }
    private ProbeWorker[7] workers;

    private static size_t probeGroupIndex(ProbeGroup g) pure nothrow @safe @nogc {
        final switch (g) {
            case ProbeGroup.fast: return 0;
            case ProbeGroup.processes: return 1;
            case ProbeGroup.device_dynamic: return 2;
            case ProbeGroup.filesystems: return 3;
            case ProbeGroup.tailnet: return 4;
            case ProbeGroup.maintenance: return 5;
            case ProbeGroup.hardware: return 6;
        }
    }

    this(PlatformBackend backend, TelemetryCacheStore store, ClockSource clocks = ClockSource.system()) {
        this.backend = backend;
        this.store = store;
        this.clocks = clocks;
        this.mtx = new Mutex();
        this.cond = new Condition(this.mtx);
        foreach (ref w; this.workers) {
            w.workerCond = new Condition(this.mtx);
        }

        // Populate initial cheap OS identity so /info always has host/os/arch without running telemetry probes
        try {
            auto id = backend.identity();
            this.store.setIdentity(id);
        } catch (Exception) {
            auto fallback = PlatformIdentity("unknown", "unknown", "unknown", "", Nullable!long.init);
            this.store.setIdentity(fallback);
        }
    }

    void updateFqdn(string fqdn) {
        synchronized (mtx) {
            store.setFqdn(fqdn);
        }
    }

    InfoResponse getInfo() {
        synchronized (mtx) {
            auto ir = store.buildInfoResponse(clocks.wallTs());
            ir.hikari_version = ir.hikari_version.length > 0 ? ir.hikari_version.idup : "";
            ir.caddy_version = ir.caddy_version.length > 0 ? ir.caddy_version.idup : "";
            ir.tailscale_version = ir.tailscale_version.length > 0 ? ir.tailscale_version.idup : "";
            ir.host = ir.host.length > 0 ? ir.host.idup : "";
            ir.fqdn = ir.fqdn.length > 0 ? ir.fqdn.idup : "";
            ir.os = ir.os.length > 0 ? ir.os.idup : "";
            ir.arch = ir.arch.length > 0 ? ir.arch.idup : "";
            return ir;
        }
    }

    InfoResponse getInfoInto(ref InfoScratch scratch) {
        synchronized (mtx) {
            return store.copyInfoResponseInto(scratch, clocks.wallTs());
        }
    }

    bool getInfoJson(char[] jsonBuf, out size_t jsonLen) {
        synchronized (mtx) {
            auto ir = store.buildInfoResponse(clocks.wallTs());
            auto w = JsonBufferWriter(jsonBuf);
            writeInfoResponseJson(w, ir);
            jsonLen = w.pos;
            return !w.overflow;
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

    bool getHealthJson(char[] jsonBuf, out size_t jsonLen) {
        synchronized (mtx) {
            HealthResponse hr;
            hr.node_id = store.nodeId;
            hr.server_ts = clocks.wallTs();
            auto f = store.groups[ProbeGroup.fast];
            hr.status = (f.consecutiveFailures > 0 && !f.hasSuccess) ? "degraded" : "ok";
            auto w = JsonBufferWriter(jsonBuf);
            writeHealthResponseJson(w, hr);
            jsonLen = w.pos;
            return !w.overflow;
        }
    }

    private StatusEndpointResult prepareStatusLocked(bool forceRefresh, out long outNowMono, out long outNowWall) {
        long nowMono = clocks.monoNs();
        long nowWall = clocks.wallTs();

        bool needColdWait = false;
        bool[5] waitForRefresh = false;
        ulong[5] targetGen = 0;

        foreach (i, g; STATUS_PROBE_GROUPS) {
            reapTimedOutLocked(g, nowMono);
            bool fresh = !forceRefresh && store.isFresh(g, nowMono, nowWall);
            if (fresh) continue;

            bool usable = !forceRefresh && store.isUsableStale(g, nowMono, nowWall);
            auto e = store.groups[g];

            if (!usable) {
                if (g == ProbeGroup.fast || forceRefresh) {
                    needColdWait = true;
                    waitForRefresh[i] = true;
                    targetGen[i] = e.generation + 1;
                } else if (!e.unsupported && e.consecutiveFailures == 0) {
                    needColdWait = true;
                    waitForRefresh[i] = true;
                    targetGen[i] = e.generation + 1;
                }
            }

            if (canStartLocked(e, nowMono, forceRefresh)) {
                startGroupRefreshLocked(g, nowMono);
            }
        }

        if (needColdWait) {
            long deadlineMono = nowMono + cast(long) store.config.collection.cold_wait_ms * 1_000_000L;
            while (true) {
                nowMono = clocks.monoNs();
                nowWall = clocks.wallTs();

                foreach (g; STATUS_PROBE_GROUPS) reapTimedOutLocked(g, nowMono);

                bool allStartedColdDone = true;
                foreach (i, g; STATUS_PROBE_GROUPS) {
                    auto e = store.groups[g];
                    if (waitForRefresh[i] && e.inFlight && e.generation < targetGen[i]) {
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

        outNowMono = clocks.monoNs();
        outNowWall = clocks.wallTs();

        auto fastEntry = store.groups[ProbeGroup.fast];
        bool fastUsable = store.isUsableStale(ProbeGroup.fast, outNowMono, outNowWall);

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
            return res;
        }

        StatusEndpointResult res;
        res.kind = EndpointOutcomeKind.ok;
        res.httpStatus = 200;
        return res;
    }

    StatusEndpointResult getStatus(bool forceRefresh = false) {
        synchronized (mtx) {
            long nowMono = 0, nowWall = 0;
            auto res = prepareStatusLocked(forceRefresh, nowMono, nowWall);
            if (res.kind == EndpointOutcomeKind.ok) {
                res.payload = store.snapshotStatusResponse(nowMono, nowWall);
            } else if (res.kind == EndpointOutcomeKind.error) {
                auto snap = store.snapshotStatusResponse(nowMono, nowWall);
                res.groups = snap.groups;
            }
            return res;
        }
    }

    StatusEndpointResult getStatusJson(char[] jsonBuf, out size_t jsonLen, bool forceRefresh = false) {
        synchronized (mtx) {
            long nowMono = 0, nowWall = 0;
            auto res = prepareStatusLocked(forceRefresh, nowMono, nowWall);
            auto w = JsonBufferWriter(jsonBuf);
            final switch (res.kind) {
                case EndpointOutcomeKind.ok: {
                    StatusResponse snap;
                    store.snapshotStatusInto(snap, nowMono, nowWall);
                    writeStatusResponseJson(w, snap);
                    break;
                }
                case EndpointOutcomeKind.collecting: {
                    CollectingResponse cr;
                    cr.retry_after_s = res.retryAfterS;
                    writeCollectingResponseJson(w, cr);
                    break;
                }
                case EndpointOutcomeKind.error: {
                    StatusResponse snap;
                    store.snapshotStatusInto(snap, nowMono, nowWall);
                    writeErrorResponseFixedGroupsJson(w, res.errorCode, res.errorMessage, snap.fixed_groups);
                    break;
                }
            }
            jsonLen = w.overflow ? size_t.max : w.pos;
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

            if (!fresh && canStartLocked(e, nowMono, forceRefresh)) {
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

    /// A new worker may start only when no earlier worker for the group is still
    /// running (even one already reaped as timed out) and backoff has elapsed.
    /// This bounds collector threads to one per probe group: a probe stuck in the
    /// kernel (NFS statvfs, WMI, a GPU driver) cannot accumulate threads, and the
    /// backend never runs two collectors of the same group concurrently.
    private static bool canStartLocked(const ref GroupCacheEntry e, long nowMono, bool forceRefresh) pure nothrow @safe {
        if (e.inFlight || e.workerAlive) return false;
        return forceRefresh || nowMono >= e.backoffUntilMonoNs;
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
        e.workerAlive = true;
        e.lastAttemptMonoNs = nowMono;
        e.inFlightStartedMonoNs = nowMono;
        ulong launchGen = e.generation;
        e.workerGeneration = launchGen;
        store.groups[g] = e;

        size_t idx = probeGroupIndex(g);
        workers[idx].launchGen = launchGen;
        workers[idx].pending = true;
        if (!workers[idx].started) {
            workers[idx].started = true;
            spawnProbeWorkerThread(g, idx);
        } else {
            workers[idx].workerCond.notify();
        }
    }

    private void spawnProbeWorkerThread(ProbeGroup g, size_t idx) {
        auto t = new Thread({
            probeWorkerLoop(g, idx);
        });
        t.isDaemon = true;
        workers[idx].thread = t;
        t.start();
    }

    private void probeWorkerLoop(ProbeGroup g, size_t idx) {
        while (true) {
            ulong gen;
            synchronized (mtx) {
                while (!workers[idx].pending) {
                    workers[idx].workerCond.wait();
                }
                workers[idx].pending = false;
                gen = workers[idx].launchGen;
            }
            runProbe(g, gen);
        }
    }

    private void clearWorkerAlive(ProbeGroup g, ulong expectedGen) {
        bool runGc = false;
        long nowMono = clocks.monoNs();
        synchronized (mtx) {
            auto e = store.groups[g];
            if (e.workerGeneration == expectedGen) {
                e.workerAlive = false;
                store.groups[g] = e;
                cond.notifyAll();
            }
            bool anyAlive = false;
            foreach (_, entry; store.groups) {
                if (entry.workerAlive) {
                    anyAlive = true;
                    break;
                }
            }
            if (!anyAlive && (nowMono - lastGcMonoNs) >= 60_000_000_000L) {
                lastGcMonoNs = nowMono;
                runGc = true;
            }
        }
        if (runGc) {
            import core.memory : GC;
            GC.collect();
            GC.minimize();
        }
    }

    private void runProbe(ProbeGroup g, ulong expectedGen) {
        // (A helper call rather than `synchronized` inside scope(exit): LDC's
        // Windows funclet EH miscompiles nested synchronized in cleanup blocks.)
        scope (exit) clearWorkerAlive(g, expectedGen);
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

            store.setIdentity(id);
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
                store.setNetwork(store.rateState.computeNetworkRates(id.boot_id, net.interfaces, doneMono, doneBoot));
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
            ProcessStatus[] topCpu;
            ProcessStatus[] topMem;
            store.rateState.selectTopProcesses(rates, topCpu, topMem);
            store.setTopCpu(topCpu);
            store.setTopMem(topMem);

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
            store.setMounts(fs.mounts);
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
            store.setGpus(gpus.state == CapabilityState.ok ? gpus.gpus : null);
            store.setBatteries(bats.state == CapabilityState.ok ? bats.batteries : null);

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
        import caddyfile.integrate : IntegrationRecord, loadIntegrationRecord;
        import platform.command : queryLocalCaddyVersion, queryLocalTailscaleVersion;
        import update.activate : readVersionSymlink;

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

        string versionsDir;
        string stateDir;
        string tsFixture;
        synchronized (mtx) {
            versionsDir = store.config.paths.versions_dir;
            stateDir = store.config.paths.state_dir;
            tsFixture = store.config.tailscale_fixture;
        }

        if (versionsDir.length > 0) {
            auto activeVer = readVersionSymlink(versionsDir ~ "/current");
            if (activeVer.length > 0) {
                mr.drift.hikari_version = activeVer;
            }
        }
        if (mr.drift.hikari_version.length == 0) {
            mr.drift.hikari_version = AGENT_VERSION;
        }
        if (stateDir.length > 0) {
            IntegrationRecord rec;
            if (loadIntegrationRecord(stateDir, rec)) {
                auto integratedVer = queryLocalCaddyVersion(stateDir);
                if (integratedVer.length > 0) {
                    mr.drift.caddy_version = integratedVer;
                }
            }
        }
        if (tsFixture.length > 0) {
            auto fixTsVer = queryLocalTailscaleVersion(tsFixture);
            if (fixTsVer.length > 0) {
                mr.drift.tailscale_version = fixTsVer;
            }
        }

        synchronized (mtx) {
            if (store.groups[ProbeGroup.maintenance].generation != expectedGen) return;
            store.setDrift(mr.drift);
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

        auto hw = hr.inventory;
        hw.node_id = store.nodeId;
        hw.collected_at = doneWall;
        hw.collection.status = GroupStatus.fresh;
        hw.collection.age_s = 0;
        hw.collection.refreshing = false;
        synchronized (mtx) {
            if (store.groups[ProbeGroup.hardware].generation != expectedGen) return;
        }
        // Only this group's worker waits for disk; other endpoints keep using
        // their cache. Retain the single-flight reservation through persistence.
        store.persistHardware(hw);
        synchronized (mtx) {
            if (store.groups[ProbeGroup.hardware].generation != expectedGen) return;
            store.cachedHardware = hw;
            store.updateHardwareSummaryFromInventory(hw);
            markGroupSuccessLocked(ProbeGroup.hardware, doneMono, doneWall);
        }
    }

    private void markGroupSuccessLocked(ProbeGroup g, long doneMono, long doneWall) {
        auto e = store.groups[g];
        e.hasSuccess = true;
        e.unsupported = false;
        e.inFlight = false;
        e.workerAlive = false;
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
        e.workerAlive = false;
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
            e.workerAlive = false;
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
