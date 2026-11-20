module tests.core.test_cache_coordinator;

import core.cache;
import core.config;
import core.coordinator;
import core.model;
import core.sync.mutex;
import core.thread;
import platform.api;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.uuid;

private string makeTempStateDir(string suffix) {
    auto p = tempDir() ~ "/hikari-test-cache-" ~ suffix;
    if (exists(p)) rmdirRecurse(p);
    mkdirRecurse(p);
    return p;
}

unittest {
    // A worker finishing cleanup after publishing success is not a hung probe.
    auto stateDir = makeTempStateDir("completion-meta");
    scope (exit) if (exists(stateDir)) rmdirRecurse(stateDir);
    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    cfg.paths.versions_dir = stateDir ~ "/versions";
    auto store = new TelemetryCacheStore(cfg, "hikari:completion-meta");
    auto entry = store.groups[ProbeGroup.fast];
    entry.hasSuccess = true;
    entry.lastSuccessMonoNs = 10_000_000_000L;
    entry.lastSuccessWallTs = 100;
    entry.workerAlive = true;
    entry.inFlight = false;
    store.groups[ProbeGroup.fast] = entry;
    assert(store.buildGroupMeta(ProbeGroup.fast, 10_000_000_000L, 100).status == GroupStatus.fresh);
    entry.lastError = "probe_timeout";
    entry.consecutiveFailures = 1;
    store.groups[ProbeGroup.fast] = entry;
    assert(store.buildGroupMeta(ProbeGroup.fast, 10_000_000_000L, 100).error == "probe_hung");
}

unittest {
    // Fresh hit does NOT invoke probes; stale triggers async single-flight; /status NEVER scans hardware; /info NEVER probes
    auto stateDir = makeTempStateDir("ttl");
    scope (exit) { if (exists(stateDir)) rmdirRecurse(stateDir); }

    long fakeMono = 10_000_000_000L; // 10s
    long fakeWall = 1_794_945_600L;
    ClockSource clocks;
    clocks.monoNs = () => fakeMono;
    clocks.wallTs = () => fakeWall;
    clocks.bootNs = () => fakeMono;

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    cfg.paths.versions_dir = stateDir ~ "/versions";
    cfg.collection.cold_wait_ms = 500;
    auto fake = new FakePlatformBackend("desktop-x86_64");
    auto store = new TelemetryCacheStore(cfg, "hikari:test-node-1");
    auto coord = new RefreshCoordinator(fake, store, clocks);

    // /info before any status request must NOT trigger telemetry or hardware probes
    auto info0 = coord.getInfo();
    assert(info0.app == "hikari");
    assert(fake.counts.cpuCalls == 0);
    assert(fake.counts.hardwareCalls == 0);

    // Cold /status executes each status probe group once, NEVER hardware
    auto st1 = coord.getStatus();
    assert(st1.httpStatus == 200);
    assert(fake.counts.cpuCalls == 1);
    assert(fake.counts.processCalls == 1);
    assert(fake.counts.filesystemCalls == 1);
    assert(fake.counts.hardwareCalls == 0, "/status must NEVER scan hardware");
    assert(st1.payload.groups["fast"].status == GroupStatus.fresh);
    assert(st1.payload.drift.hikari_version == AGENT_VERSION);
    assert(st1.payload.drift.caddy_version == "2.11.9");
    assert(st1.payload.drift.tailscale_version == "1.78.1");

    // Subsequent /info reflects cached maintenance versions without invoking probes
    auto infoAfterStatus = coord.getInfo();
    assert(infoAfterStatus.hikari_version == AGENT_VERSION);
    assert(infoAfterStatus.caddy_version == "2.11.9");
    assert(infoAfterStatus.tailscale_version == "1.78.1");

    // Second request at +5s (< fast TTL 10s) -> ZERO additional probes!
    fakeMono += 5_000_000_000L;
    fakeWall += 5;
    auto st2 = coord.getStatus();
    assert(st2.httpStatus == 200);
    assert(fake.counts.cpuCalls == 1, "Fresh cache hit must not invoke CPU probe");
    assert(fake.counts.processCalls == 1);
    assert(fake.counts.filesystemCalls == 1);

    // Advance +12s (total 17s: fast stale [10..60], processes fresh [17<20]) -> returns stale immediately & refreshes fast once
    fakeMono += 12_000_000_000L;
    fakeWall += 12;
    fake.advanceTick();
    auto st3 = coord.getStatus();
    assert(st3.httpStatus == 200);
    assert(st3.payload.groups["fast"].status == GroupStatus.stale);
    // Allow background single-flight refresh to finish
    Thread.sleep(core.time.msecs(40));
    assert(fake.counts.cpuCalls == 2);
    assert(fake.counts.processCalls == 1, "Processes still fresh at 17s < 20s TTL");
    assert(fake.counts.hardwareCalls == 0);

    // Now request /hardware lazily -> scans once, persists to disk, exposes hardware_summary
    auto hw1 = coord.getHardware();
    assert(hw1.httpStatus == 200);
    assert(fake.counts.hardwareCalls == 1);
    auto hw2 = coord.getHardware();
    assert(hw2.httpStatus == 200);
    assert(fake.counts.hardwareCalls == 1, "Repeated hardware open within 7d TTL must not rescan");

    // Simulate process restart loading persisted hardware_cache.json -> still fresh without scanning!
    auto store2 = new TelemetryCacheStore(cfg, "hikari:test-node-1");
    auto fake2 = new FakePlatformBackend("desktop-x86_64");
    auto coord2 = new RefreshCoordinator(fake2, store2, clocks);
    auto infoAfterRestart = coord2.getInfo();
    assert(!infoAfterRestart.hardware_summary.isNull);
    assert(infoAfterRestart.hardware_summary.get.cpu == "AMD Ryzen 9 5900X");
    auto hwAfterRestart = coord2.getHardware();
    assert(hwAfterRestart.httpStatus == 200);
    assert(fake2.counts.hardwareCalls == 0, "Persisted hardware within 7d TTL must not rescan on restart");
}

unittest {
    // 20 concurrent cold requests coalesce into AT MOST 1 probe execution
    auto stateDir = makeTempStateDir("singleflight");
    scope (exit) { if (exists(stateDir)) rmdirRecurse(stateDir); }

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    cfg.paths.versions_dir = stateDir ~ "/versions";
    cfg.collection.cold_wait_ms = 2000;
    auto fake = new FakePlatformBackend("desktop-x86_64");
    fake.sleepHardwareMs = 50;
    auto store = new TelemetryCacheStore(cfg, "hikari:sf-node");
    auto coord = new RefreshCoordinator(fake, store);

    Thread[] threads;
    int[20] statuses;
    void spawnReq(size_t idx) {
        auto t = new Thread({
            statuses[idx] = coord.getStatus().httpStatus;
        });
        t.start();
        threads ~= t;
    }
    foreach (i; 0 .. 20) {
        spawnReq(i);
    }
    foreach (t; threads) t.join();

    import std.format : format;
    foreach (st; statuses) assert(st == 200);
    assert(fake.counts.cpuCalls == 1, format!"Expected cpuCalls=1, got %u"(fake.counts.cpuCalls));
    assert(fake.counts.filesystemCalls == 1, format!"Expected filesystemCalls=1, got %u"(fake.counts.filesystemCalls));
}

unittest {
    // Cold slow probe returns 202 collecting; failed fast probe returns 503; failed mount probe does NOT block CPU status
    auto stateDir = makeTempStateDir("202-503");
    scope (exit) { if (exists(stateDir)) rmdirRecurse(stateDir); }

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    cfg.paths.versions_dir = stateDir ~ "/versions";
    cfg.collection.cold_wait_ms = 60;
    cfg.collection.probe_timeout_ms = 200;

    // 1. Failing cold fast probe -> 503
    auto fakeFail = new FakePlatformBackend("desktop-x86_64");
    fakeFail.failCpu = true;
    auto storeFail = new TelemetryCacheStore(cfg, "hikari:fail-node");
    auto coordFail = new RefreshCoordinator(fakeFail, storeFail);
    auto res503 = coordFail.getStatus();
    assert(res503.httpStatus == 503, "Cold failing fast probe must return 503");

    // 2. Slow cold hardware probe (> cold_wait_ms) -> 202 collecting
    auto fakeSlowHw = new FakePlatformBackend("desktop-x86_64");
    fakeSlowHw.sleepHardwareMs = 150;
    auto store202 = new TelemetryCacheStore(cfg, "hikari:slow-hw");
    auto coord202 = new RefreshCoordinator(fakeSlowHw, store202);
    auto res202 = coord202.getHardware();
    assert(res202.httpStatus == 202 && res202.retryAfterS >= 1);
    Thread.sleep(core.time.msecs(180));
    auto res200 = coord202.getHardware();
    assert(res200.httpStatus == 200);

    // 3. Hung/failed filesystems & GPU probes MUST NOT block fast CPU status!
    auto fakeSlowMount = new FakePlatformBackend("failing-probes");
    fakeSlowMount.sleepFilesystemsMs = 300;
    auto storeMount = new TelemetryCacheStore(cfg, "hikari:slow-mount");
    auto coordMount = new RefreshCoordinator(fakeSlowMount, storeMount);
    auto resFast = coordMount.getStatus();
    assert(resFast.httpStatus == 200, "Hung mount/GPU must not prevent 200 fast CPU telemetry");
    assert(resFast.payload.groups["fast"].status == GroupStatus.fresh);
    assert(resFast.payload.groups["device_dynamic"].status == GroupStatus.error);
}

unittest {
    // A failed network refresh must not redate previously cached traffic as fresh.
    auto stateDir = makeTempStateDir("network-error");
    scope (exit) if (exists(stateDir)) rmdirRecurse(stateDir);
    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    cfg.paths.versions_dir = stateDir ~ "/versions";
    auto fake = new FakePlatformBackend;
    auto coord = new RefreshCoordinator(fake, new TelemetryCacheStore(cfg, "hikari:network-error"));
    auto first = coord.getStatus();
    assert(first.httpStatus == 200 && first.payload.network.length);
    auto sampled = first.payload.groups["fast"].sampled_at;
    fake.failNetwork = true;
    coord.getStatus(true);
    Thread.sleep(core.time.msecs(50));
    auto failed = coord.getStatus();
    assert(failed.payload.groups["fast"].status == GroupStatus.stale);
    assert(failed.payload.groups["fast"].error == "simulated_network_permission_failure");
    assert(failed.payload.groups["fast"].sampled_at == sampled);
    assert(failed.payload.network.length == first.payload.network.length);
}

unittest {
    class RestrictedBattery : FakePlatformBackend {
        this() { super("arm64-sbc"); }
        override RawBatteryResult sampleBatteries() {
            return RawBatteryResult(CapabilityState.permission_denied, "battery_access_denied", null);
        }
    }
    auto stateDir = makeTempStateDir("battery-permission");
    scope (exit) if (exists(stateDir)) rmdirRecurse(stateDir);
    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    cfg.paths.versions_dir = stateDir ~ "/versions";
    auto coord = new RefreshCoordinator(new RestrictedBattery,
        new TelemetryCacheStore(cfg, "hikari:battery-permission"));
    auto status = coord.getStatus();
    assert(status.httpStatus == 200);
    assert(status.payload.groups["device_dynamic"].status == GroupStatus.error);
    assert(status.payload.groups["device_dynamic"].error == "battery_access_denied");
    assert(status.payload.batteries.length == 0);
}

unittest {
    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = makeTempStateDir("stale-ceilings");
    scope(exit) rmdirRecurse(cfg.paths.state_dir);
    auto store = new TelemetryCacheStore(cfg, "hikari:test");
    foreach (g; [ProbeGroup.fast, ProbeGroup.processes, ProbeGroup.filesystems,
            ProbeGroup.device_dynamic, ProbeGroup.maintenance]) {
        store.groups[g].hasSuccess = true;
        store.groups[g].lastSuccessMonoNs = 0;
    }
    store.config = cfg;
    store.cachedCpu.pct = 50;
    store.cachedTopCpu = [ProcessStatus.init];
    store.cachedTopMem = [ProcessStatus.init];
    store.cachedMounts = [MountStatus.init];
    store.cachedGpus = [GpuDynamicStatus.init];
    store.cachedBatteries = [BatteryStatus.init];
    store.cachedDrift.reboot_required = true;
    auto fresh = store.snapshotStatusResponse(1_000_000_000L, 1);
    assert(fresh.mounts.length == 1 && fresh.top_cpu.length == 1);
    auto expired = store.snapshotStatusResponse(700_000_000_000_000L, 700000);
    assert(expired.cpu.pct.isNull && expired.drift.reboot_required.isNull);
    assert(!expired.top_cpu.length && !expired.top_mem.length && !expired.mounts.length);
    assert(!expired.gpus.length && !expired.batteries.length);
    assert(expired.groups["filesystems"].sampled_at.get == 0);
}

private class SlowPersistenceStore : TelemetryCacheStore {
    import core.sync.semaphore : Semaphore;
    Semaphore entered;
    Semaphore releaseWrite;
    Semaphore finished;
    this(HikariConfig cfg) {
        super(cfg, "hikari:slow-disk");
        entered = new Semaphore;
        releaseWrite = new Semaphore;
        finished = new Semaphore;
    }
    override void persistHardware(const ref HardwareInventory hw) {
        entered.notify();
        releaseWrite.wait();
        finished.notify();
    }
}

unittest {
    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = makeTempStateDir("slow-disk");
    cfg.paths.versions_dir = cfg.paths.state_dir ~ "/versions";
    cfg.collection.cold_wait_ms = 20;
    scope(exit) rmdirRecurse(cfg.paths.state_dir);
    auto store = new SlowPersistenceStore(cfg);
    auto fake = new FakePlatformBackend("desktop-x86_64");
    auto coord = new RefreshCoordinator(fake, store);
    // Persistence deliberately cannot finish until after all of these calls.
    assert(coord.getHardware().httpStatus == 202);
    store.entered.wait();
    scope(exit) { store.releaseWrite.notify(); store.finished.wait(); }
    assert(coord.getInfo().node_id == "hikari:slow-disk");
    assert(coord.getHealth().node_id == "hikari:slow-disk");
    assert(coord.getStatus().httpStatus == 200);
    assert(coord.getHardware(true).httpStatus == 202);
    assert(fake.counts.hardwareCalls == 1, "No overlapping persistence workers");
}

unittest {
    // queryLocalTailscaleVersion extracts Version from fixture files safely
    import platform.command : queryLocalTailscaleVersion;
    import std.file : write;
    import std.typecons : Nullable;
    auto stateDir = makeTempStateDir("ts-ver-fixture");
    scope (exit) if (exists(stateDir)) rmdirRecurse(stateDir);
    auto fix = stateDir ~ "/ts.json";
    write(fix, `{"Version":"1.78.1-t123456-g789","MagicDNSSuffix":"tail.ts.net"}`);
    assert(queryLocalTailscaleVersion(fix) == "1.78.1");
}

unittest {
    // Regression: getInfo() and getStatus() return owned string/slice data unaffected by
    // later store updates, and tailscale_fixture overrides backend tailscale_version.
    import std.file : write;
    import std.typecons : Nullable;
    auto stateDir = makeTempStateDir("owned-snapshots");
    scope (exit) if (exists(stateDir)) rmdirRecurse(stateDir);

    auto tsFix = stateDir ~ "/ts-override.json";
    write(tsFix, `{"Version":"9.9.9-t123-g456","MagicDNSSuffix":"tail.ts.net"}`);

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    cfg.paths.versions_dir = stateDir ~ "/versions";
    cfg.tailscale_fixture = tsFix;
    cfg.collection.cold_wait_ms = 500;

    auto fake = new FakePlatformBackend("desktop-x86_64");
    auto store = new TelemetryCacheStore(cfg, "hikari:owned-test");
    auto coord = new RefreshCoordinator(fake, store);
    coord.updateFqdn("box-one.tail.ts.net");

    auto st1 = coord.getStatus();
    assert(st1.httpStatus == 200);
    assert(st1.payload.drift.tailscale_version == "9.9.9", "tailscale_fixture must override backend tailscale_version");
    assert(st1.payload.host == "workstation-linux");
    assert(st1.payload.fqdn == "box-one.tail.ts.net");
    assert(st1.payload.network.length > 0);
    auto savedIfName = st1.payload.network[0].name.idup;
    auto savedHost = st1.payload.host.idup;
    auto savedFqdn = st1.payload.fqdn.idup;

    auto info1 = coord.getInfo();
    assert(info1.host == savedHost);
    assert(info1.fqdn == savedFqdn);
    assert(info1.tailscale_version == "9.9.9");

    // Mutate underlying FixedString stores inside TelemetryCacheStore
    auto mutId = PlatformIdentity("mutated-host", "darwin", "arm64", "boot-mutated", Nullable!long(1));
    store.setIdentity(mutId);
    store.setFqdn("mutated-fqdn.tail.ts.net");
    store.setNetwork([NetworkInterfaceStatus("ifindex:99", "mutated0", "virtual")]);
    DriftStatus mutDrift;
    mutDrift.tailscale_version = "0.0.0";
    store.setDrift(mutDrift);

    assert(st1.payload.host == savedHost, "getStatus() payload host must be owned");
    assert(st1.payload.fqdn == savedFqdn, "getStatus() payload fqdn must be owned");
    assert(st1.payload.network[0].name == savedIfName, "getStatus() payload network must be owned");
    assert(st1.payload.drift.tailscale_version == "9.9.9", "getStatus() payload drift must be owned");
    assert(info1.host == savedHost, "getInfo() host must be owned");
    assert(info1.fqdn == savedFqdn, "getInfo() fqdn must be owned");
    assert(info1.tailscale_version == "9.9.9", "getInfo() tailscale_version must be owned");
}
