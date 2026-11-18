module tests.core.test_bounded_work;

// Regression tests for bounded, non-blocking request handling:
//  - a hung probe never gets a second concurrent worker (no thread accumulation)
//  - GET /api/v1/nodes never blocks on peer validation; discovery is rate-limited
//  - Host validation survives a failed `tailscale status` (sticky / persisted FQDN)
//  - nodes.json is not rewritten for contact timestamps on every request
//  - GET ?refresh=1 cannot force probes
//  - bounded subprocess execution kills a wedged child

import core.atomic : atomicLoad, atomicOp;
import core.cache;
import core.config;
import core.coordinator;
import core.model;
import core.proc : executeBounded;
import core.thread : Thread;
import core.time : msecs, MonoTime;
import http.routes;
import platform.api;
import std.algorithm : canFind;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, timeLastModified, write;
import tailnet.discovery;
import tailnet.registry;

private string freshDir(string suffix) {
    auto p = tempDir() ~ "/hikari-test-bounded-" ~ suffix;
    if (exists(p)) rmdirRecurse(p);
    mkdirRecurse(p);
    return p;
}

private long realMonoNs() {
    return (MonoTime.currTime - MonoTime.zero).total!"nsecs";
}

unittest {
    // A probe stuck past probe_timeout_ms is reaped (reported as hung), and no new
    // worker for that group starts until the stuck one actually returns.
    auto stateDir = freshDir("hung");
    scope (exit) { if (exists(stateDir)) rmdirRecurse(stateDir); }

    shared long offsetNs = 0;
    ClockSource clocks;
    clocks.monoNs = () => realMonoNs() + atomicLoad(offsetNs);
    clocks.wallTs = () => 1_794_945_600L + atomicLoad(offsetNs) / 1_000_000_000L;
    clocks.bootNs = () => realMonoNs() + atomicLoad(offsetNs);

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    cfg.collection.cold_wait_ms = 50;
    cfg.collection.probe_timeout_ms = 100;
    auto fake = new FakePlatformBackend("desktop-x86_64");
    fake.sleepFilesystemsMs = 700;
    auto coord = new RefreshCoordinator(fake, new TelemetryCacheStore(cfg, "hikari:hung"), clocks);

    auto st1 = coord.getStatus();
    assert(st1.httpStatus == 200, "fast group must not wait for a slow filesystem probe");
    assert(fake.counts.filesystemCalls == 1);

    Thread.sleep(msecs(150)); // past probe_timeout_ms; worker still sleeping
    auto st2 = coord.getStatus();
    assert(st2.httpStatus == 200);
    assert(st2.payload.groups["filesystems"].status == GroupStatus.error);
    assert(st2.payload.groups["filesystems"].error == "probe_hung");

    // Jump past the failure backoff: the old worker is still alive, so no new one.
    atomicOp!"+="(offsetNs, 5_000_000_000L);
    coord.getStatus();
    Thread.sleep(msecs(20));
    assert(fake.counts.filesystemCalls == 1, "a hung probe must not get a second concurrent worker");

    // Once the stuck worker exits, the group may be retried.
    Thread.sleep(msecs(700));
    atomicOp!"+="(offsetNs, 5_000_000_000L);
    coord.getStatus();
    Thread.sleep(msecs(20));
    assert(fake.counts.filesystemCalls == 2, "group must be retried after the stuck worker returns");
}

unittest {
    // /api/v1/nodes returns immediately while peers are validated in the background;
    // discovery is rate-limited; offline and non-hikari peers are not re-probed.
    auto stateDir = freshDir("nodes");
    scope (exit) { if (exists(stateDir)) rmdirRecurse(stateDir); }

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    auto reg = new NodeRegistry(stateDir);
    string tsFixture = readText("tests/fixtures/tailscale/online_fleet.json");

    shared int fetches = 0;
    shared int sleepingProbed = 0;
    auto disc = new TailnetDiscoveryService(cfg, reg, ClockSource.system(), () => tsFixture,
        (string infoUrl, string expectedFqdn, uint timeoutMs) {
            atomicOp!"+="(fetches, 1);
            if (expectedFqdn.canFind("laptop-sleeping")) atomicOp!"+="(sleepingProbed, 1);
            Thread.sleep(msecs(300)); // slow peer
            PeerValidationResult r;
            if (expectedFqdn == "nas-box.tail1234.ts.net") {
                r.ok = true;
                r.info.app = "hikari";
                r.info.schema_version = 1;
                r.info.node_id = "hikari:nas";
                r.info.fqdn = expectedFqdn;
            } else {
                r.incompatible = true;
                r.error = "not_a_hikari_endpoint";
            }
            return r;
        });
    // Prime the local view (as serveMain does at startup).
    disc.getLocalTailscaleSnapshot(false);

    InfoResponse selfInfo;
    selfInfo.host = "workstation-linux";
    auto t0 = MonoTime.currTime;
    auto r1 = disc.listNodesAndScheduleDiscovery("hikari:self", selfInfo, true, false);
    assert((MonoTime.currTime - t0) < msecs(200), "/nodes must not wait for peer validation");
    assert(!r1.discovery.isNull && r1.discovery.get.running);
    assert(r1.nodes.length == 1, "only self is known before validation completes");

    // A second request while running (or within the TTL) starts no new run.
    disc.listNodesAndScheduleDiscovery("hikari:self", selfInfo, true, false);
    assert(disc.waitForDiscoveryIdle(3000));
    assert(atomicLoad(fetches) == 2, "nas-box and printer probed once; sleeping laptop skipped");
    assert(atomicLoad(sleepingProbed) == 0, "peers Tailscale reports offline are not probed");

    auto r2 = disc.listNodesAndScheduleDiscovery("hikari:self", selfInfo, true, false);
    assert(!r2.discovery.get.running, "within the tailnet TTL no new discovery starts");
    assert(r2.nodes.length == 2);

    // A forced scan (rate-limited to 30 s) is refused right after a run...
    disc.listNodesAndScheduleDiscovery("hikari:self", selfInfo, true, true);
    assert(disc.waitForDiscoveryIdle(3000));
    assert(atomicLoad(fetches) == 2);
}

unittest {
    // Host validation keeps working when `tailscale status` later fails, and after a
    // restart while it is still failing (persisted local_fqdn).
    auto stateDir = freshDir("fqdn");
    scope (exit) { if (exists(stateDir)) rmdirRecurse(stateDir); }

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    string tsJson = readText("tests/fixtures/tailscale/online_fleet.json");
    long mono = 10_000_000_000L;
    ClockSource clocks;
    clocks.monoNs = () => mono;
    clocks.wallTs = () => 1_794_945_600L;
    clocks.bootNs = () => mono;

    auto disc = new TailnetDiscoveryService(cfg, new NodeRegistry(stateDir), clocks, () => tsJson);
    disc.getLocalTailscaleSnapshot(false);
    assert(disc.localFqdn() == "workstation-linux.tail1234.ts.net");
    assert(readText(stateDir ~ "/local_fqdn").canFind("workstation-linux.tail1234.ts.net"));

    // Status starts failing; a failed read is retried quickly, not cached for 5 min.
    tsJson = "";
    mono += 400_000_000_000L;
    auto failed = disc.getLocalTailscaleSnapshot(false);
    assert(!failed.available);
    assert(disc.localFqdn() == "workstation-linux.tail1234.ts.net", "last learned FQDN is sticky");
    tsJson = readText("tests/fixtures/tailscale/online_fleet.json");
    mono += 11_000_000_000L;
    assert(disc.getLocalTailscaleSnapshot(false).available, "failure must be retried after ~10 s");

    // Restart with Tailscale unreadable: FQDN comes from state.
    auto disc2 = new TailnetDiscoveryService(cfg, new NodeRegistry(stateDir), clocks, () => "");
    disc2.getLocalTailscaleSnapshot(false);
    assert(disc2.localFqdn() == "workstation-linux.tail1234.ts.net");
    assert(disc2.magicDnsSuffix() == "tail1234.ts.net");
}

unittest {
    // nodes.json: contact timestamps alone do not trigger a write within an hour.
    auto stateDir = freshDir("registry");
    scope (exit) { if (exists(stateDir)) rmdirRecurse(stateDir); }

    auto reg = new NodeRegistry(stateDir);
    NodeRecord self;
    self.node_id = "hikari:self";
    self.fqdn = "a.tail1234.ts.net";
    self.is_self = true;
    self.last_seen_ts = 1000L;
    reg.upsertConfirmedNode(self);
    assert(reg.saveIfChanged(1000));
    assert(!reg.saveIfChanged(1000), "unchanged registry is not rewritten");

    self.last_seen_ts = 1015L;
    reg.upsertConfirmedNode(self);
    assert(!reg.saveIfChanged(1015), "timestamp-only change within the hour is not persisted");

    assert(reg.setAlias("hikari:self", "Main"));
    assert(reg.saveIfChanged(1030), "operator-owned change is persisted immediately");

    self.last_seen_ts = 1030L + 3600L;
    reg.upsertConfirmedNode(self);
    assert(reg.saveIfChanged(1030 + 3600), "timestamps are refreshed on disk at most hourly");

    // A restarted registry starts from what is on disk.
    auto reg2 = new NodeRegistry(stateDir);
    assert(!reg2.saveIfChanged(1030 + 3601));
}

unittest {
    // GET ?refresh=1 is not an administrative override: no forced rescans.
    auto stateDir = freshDir("refresh");
    scope (exit) { if (exists(stateDir)) rmdirRecurse(stateDir); }

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    cfg.tailscale_fixture = "tests/fixtures/tailscale/online_fleet.json";
    auto fake = new FakePlatformBackend("desktop-x86_64");
    auto coord = new RefreshCoordinator(fake, new TelemetryCacheStore(cfg, "hikari:refresh"));
    auto reg = new NodeRegistry(stateDir);
    auto disc = new TailnetDiscoveryService(cfg, reg);
    auto router = new HikariRouter(cfg, coord, disc, reg);

    HttpRequest req;
    req.method = "GET";
    req.headers["host"] = "127.0.0.1";
    req.path = "/api/v1/hardware";
    req.query = "refresh=1";
    assert(router.handle(req).statusCode == 200);
    assert(router.handle(req).statusCode == 200);
    assert(fake.counts.hardwareCalls == 1, "refresh=1 must not force a hardware rescan");

    req.path = "/api/v1/status";
    assert(router.handle(req).statusCode == 200);
    assert(router.handle(req).statusCode == 200);
    assert(fake.counts.cpuCalls == 1, "refresh=1 must not bypass the status TTL");
}

unittest {
    // Bounded subprocess: output is captured; a wedged child is killed on deadline.
    version (Windows) {
        auto ok = executeBounded(["cmd", "/c", "echo hikari-ok"], 5000, 1024);
        auto slow = ["ping", "-n", "30", "127.0.0.1"];
    } else {
        auto ok = executeBounded(["sh", "-c", "echo hikari-ok"], 5000, 1024);
        auto slow = ["sleep", "30"];
    }
    assert(ok.started && !ok.timedOut && ok.status == 0 && ok.output.canFind("hikari-ok"));

    auto t0 = MonoTime.currTime;
    auto res = executeBounded(slow, 300, 1024);
    assert(res.started && res.timedOut);
    assert((MonoTime.currTime - t0) < msecs(3000), "timed-out child must be killed promptly");

    auto missing = executeBounded(["hikari-definitely-not-a-command"], 1000, 1024);
    assert(!missing.started);
}
