module tests.core.test_config_serializer;

import core.config;
import core.model;
import core.serializer;
import platform.command : parseCaddyVersionOutput, parseTailscaleVersionOutput;
import std.algorithm : canFind;
import std.exception : assertThrown;
import std.json : JSONType, parseJSON;

unittest {
    // Reject non-loopback bind addresses
    assertThrown!Exception(parseConfigJson(`{"schema_version":1,"listen":{"loopback_bind":"0.0.0.0"}}`));
    assertThrown!Exception(parseConfigJson(`{"schema_version":1,"listen":{"loopback_bind":"::"}}`));
    assertThrown!Exception(parseConfigJson(`{"schema_version":1,"listen":{"loopback_bind":"192.168.1.50"}}`));

    // Preserve unknown operator keys and enforce updates trust check
    auto cfg = parseConfigJson(`{
        "schema_version": 1,
        "listen": {"tailnet_port": 9443, "loopback_port": 19105, "base_path": "/hikari/"},
        "operator_notes": "keep me across upgrades",
        "updates": {"repo": "OWNER/REPO", "mode": "on_dashboard_open"}
    }`);
    assert(cfg.listen.tailnet_port == 9443);
    assert(cfg.listen.base_path == "/hikari");
    assert(!cfg.updates.isTrustConfigured(), "Placeholder OWNER/REPO must not pass trust verification");

    auto savedJson = configToJson(cfg);
    assert("operator_notes" in savedJson.object);
    assert(savedJson["operator_notes"].str == "keep me across upgrades");
}

unittest {
    // Sanitize OS strings & verify nullable JSON contract rules
    assert(sanitizeOsString("  Evil\x1b[31m\nProcess\tName\x07  ") == "Evil[31m Process Name");

    StatusResponse resp;
    resp.node_id = "hikari:1111";
    resp.host = "test-host\n";
    resp.os = "linux";
    resp.arch = "x86_64";
    resp.server_ts = 1794945600;
    resp.drift.hikari_version = AGENT_VERSION;
    resp.drift.caddy_version = "2.11.9";
    resp.drift.tailscale_version = "1.78.1";
    // cpu.pct, load_1m, temp_c left uninitialized (null)
    // gpus, batteries left empty arrays []

    auto j = serializeStatusResponse(resp);
    assert(j["schema_version"].integer == 1);
    assert(j["cpu"]["pct"].type == JSONType.null_, "Unknown CPU rate must serialize as JSON null, never 0");
    assert(j["cpu"]["temp_c"].type == JSONType.null_);
    assert(j["gpus"].type == JSONType.array && j["gpus"].array.length == 0);
    assert(j["batteries"].type == JSONType.array && j["batteries"].array.length == 0);
    assert(j["host"].str == "test-host");
    assert(j["drift"]["hikari_version"].str == AGENT_VERSION);
    assert(j["drift"]["caddy_version"].str == "2.11.9");
    assert(j["drift"]["tailscale_version"].str == "1.78.1");

    InfoResponse ir;
    ir.node_id = "hikari:1111";
    ir.host = "test-host";
    ir.os = "linux";
    ir.arch = "x86_64";
    ir.caddy_version = "2.11.9";
    auto ij = serializeInfoResponse(ir);
    assert(ij["hikari_version"].str == AGENT_VERSION);
    assert(ij["caddy_version"].str == "2.11.9");
    assert(ij["tailscale_version"].type == JSONType.null_);

    // Version output parsers
    assert(parseCaddyVersionOutput("v2.11.9 h1:abcdef123456\n") == "2.11.9");
    assert(parseCaddyVersionOutput("2.10.0\n") == "2.10.0");
    assert(parseCaddyVersionOutput("(devel)\n") == "");
    assert(parseCaddyVersionOutput("") == "");

    assert(parseTailscaleVersionOutput("1.76.6-t5f3e2a1b4-g123\n  tailscale commit: abc\n") == "1.76.6");
    assert(parseTailscaleVersionOutput("1.78.1\n  go version: go1.23\n") == "1.78.1");
    assert(parseTailscaleVersionOutput("1.78.1-ERR-BuildInfo\n") == "1.78.1");
    assert(parseTailscaleVersionOutput("tailscale version v1.80.0\n") == "1.80.0");
    assert(parseTailscaleVersionOutput("unknown") == "");
}

unittest {
    // Compile-time @nogc verification of hot-path request parsing, CORS validation, rate tracking, cache snapshot, and JSON writer
    import core.cache : TelemetryCacheStore;
    import core.limits : HTTP_RESPONSE_BUF_SIZE;
    import core.tracker : SystemRateState;
    import http.routes : HttpRequest;
    import http.security : isValidHostHeader, validateRequestOrigin;
    import http.server : parseHttpRequestInPlace;
    import std.typecons : Nullable;

    HikariConfig cfg;
    auto rateState = new SystemRateState();
    auto store = new TelemetryCacheStore(cfg, "hikari:nogc-test");
    store.setFqdn("workstation.tail1234.ts.net");
    PlatformIdentity id = PlatformIdentity("workstation", "linux", "x86_64", "boot-1", Nullable!long(1200));
    store.setIdentity(id);

    RawNetworkInterface[1] rawNets = [
        RawNetworkInterface("ifindex:2", "eth0", "physical", 1000, 500, Nullable!bool(true), Nullable!ulong(1_000_000_000UL)),
    ];
    RawProcess[2] rawProcs = [
        RawProcess(101, "1001", "hikari", 150, 4096 * 1024, "rss"),
        RawProcess(202, "1002", "caddy", 80, 2048 * 1024, "rss"),
    ];
    RawProcessResult procRes;
    procRes.total_cpu_ticks = 10000;
    procRes.logical_cores = 4;
    procRes.processes = rawProcs[];

    auto jsonBuf = new char[HTTP_RESPONSE_BUF_SIZE];
    static immutable string[1] knownFqdns = ["peer.tail1234.ts.net"];
    static immutable string rawReq = "GET /api/v1/status?probe=0 HTTP/1.1\r\nHost: 127.0.0.1:19100\r\nOrigin: https://peer.tail1234.ts.net:9100\r\n\r\n";

    void runHotPathNoGc() @nogc nothrow @safe {
        auto cpuPct = rateState.computeAggregateCpuPct("boot-1", 10000, 8000, 1_000_000_000L, 1_000_000_000L);
        cast(void) cpuPct;
        auto netOut = rateState.computeNetworkRates("boot-1", rawNets[], 1_000_000_000L, 1_000_000_000L);
        store.setNetwork(netOut);
        auto procRates = rateState.computeProcessRates("boot-1", procRes, 1_000_000_000L, 1_000_000_000L);
        ProcessStatus[] topCpu, topMem;
        rateState.selectTopProcesses(procRates, topCpu, topMem);
        store.setTopCpu(topCpu);
        store.setTopMem(topMem);

        StatusResponse snap;
        store.snapshotStatusInto(snap, 2_000_000_000L, 1794945600L);
        auto w1 = JsonBufferWriter(jsonBuf);
        writeStatusResponseJson(w1, snap);
        assert(!w1.overflow && w1.pos > 0);

        auto ir = store.buildInfoResponse(1794945600L);
        auto w2 = JsonBufferWriter(jsonBuf);
        writeInfoResponseJson(w2, ir);
        assert(!w2.overflow && w2.pos > 0);

        HealthResponse hr;
        hr.node_id = "hikari:nogc-test";
        hr.server_ts = 1794945600L;
        auto w3 = JsonBufferWriter(jsonBuf);
        writeHealthResponseJson(w3, hr);
        assert(!w3.overflow && w3.pos > 0);

        NodesResponse nr;
        nr.generated_at = 1794945600L;
        auto w4 = JsonBufferWriter(jsonBuf);
        writeNodesResponseJson(w4, nr);
        assert(!w4.overflow && w4.pos > 0);

        HttpRequest req;
        assert(parseHttpRequestInPlace(rawReq, req));
        assert(isValidHostHeader(req.getHostHeader(), "workstation.tail1234.ts.net"));
        auto ov = validateRequestOrigin(req.getOriginHeader(), cfg, "workstation.tail1234.ts.net", "tail1234.ts.net", knownFqdns[]);
        assert(ov.allowed && ov.hasOrigin);
    }

    runHotPathNoGc();
}

version (Posix) unittest {
    // Runtime zero-GC-allocation verification in steady state across Linux probes and HTTP routing
    import core.cache : TelemetryCacheStore;
    import core.coordinator : ClockSource, EndpointOutcomeKind, RefreshCoordinator;
    import core.limits : HTTP_RESPONSE_BUF_SIZE;
    import core.memory : GC;
    import http.routes : HikariRouter, HttpRequest;
    import http.server : parseHttpRequestInPlace;
    import platform.linux : LinuxPlatformBackend;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import tailnet.discovery : TailnetDiscoveryService;
    import tailnet.registry : NodeRegistry;

    auto root = tempDir() ~ "/hikari-zero-alloc-test";
    mkdirRecurse(root ~ "/proc/123");
    mkdirRecurse(root ~ "/proc/net");
    mkdirRecurse(root ~ "/proc/sys/kernel/random");
    mkdirRecurse(root ~ "/proc/self");
    mkdirRecurse(root ~ "/sys/class/net/eth0");
    mkdirRecurse(root ~ "/sys/class/net/eth0/device");
    mkdirRecurse(root ~ "/sys/class/hwmon/hwmon0");
    mkdirRecurse(root ~ "/sys/class/power_supply/BAT0");
    mkdirRecurse(root ~ "/sys/class/drm/card0/device");
    mkdirRecurse(root ~ "/state");
    scope (exit) rmdirRecurse(root);

    write(root ~ "/proc/sys/kernel/hostname", "zero-host\n");
    write(root ~ "/proc/sys/kernel/random/boot_id", "11111111-2222-3333-4444-555555555555\n");
    write(root ~ "/proc/uptime", "12345.67 9999.00\n");
    write(root ~ "/proc/loadavg", "0.25 0.10 0.05 1/120 123\n");
    write(root ~ "/proc/stat", "cpu  1000 10 200 8000 50 0 0 0 0 0\ncpu0 500 5 100 4000 25 0 0 0 0 0\n");
    write(root ~ "/proc/meminfo", "MemTotal:       16384000 kB\nMemAvailable:   12000000 kB\nSwapTotal:      2097152 kB\nSwapFree:       2097152 kB\n");
    write(root ~ "/proc/net/dev", "Inter-|   Receive |  Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n  eth0: 100000 100 0 0 0 0 0 0 50000 50 0 0 0 0 0 0\n");
    write(root ~ "/sys/class/net/eth0/ifindex", "2\n");
    write(root ~ "/sys/class/net/eth0/operstate", "up\n");
    write(root ~ "/sys/class/net/eth0/speed", "1000\n");
    write(root ~ "/proc/123/stat", "123 (worker) S 1 123 123 0 -1 4194304 10 0 0 0 120 30 0 0 20 0 1 0 500 1048576 256 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0\n");
    write(root ~ "/proc/self/mountinfo", "22 1 259:1 / / rw,relatime - ext4 /dev/nvme0n1p1 rw\n");
    write(root ~ "/sys/class/hwmon/hwmon0/name", "k10temp\n");
    write(root ~ "/sys/class/hwmon/hwmon0/temp1_input", "42500\n");
    write(root ~ "/sys/class/power_supply/BAT0/type", "Battery\n");
    write(root ~ "/sys/class/power_supply/BAT0/status", "Discharging\n");
    write(root ~ "/sys/class/power_supply/BAT0/capacity", "85\n");
    write(root ~ "/sys/class/drm/card0/device/vendor", "0x1002\n");
    write(root ~ "/sys/class/drm/card0/device/gpu_busy_percent", "15\n");

    auto backend = new LinuxPlatformBackend(
        root ~ "/proc", root ~ "/sys", root ~ "/etc", root ~ "/var", root ~ "/lib/modules",
        false,
        (string mountPath, out ulong totalB, out ulong usedB) {
            totalB = 100_000_000UL;
            usedB = 25_000_000UL;
            return true;
        }
    );

    HikariConfig cfg;
    cfg.paths.state_dir = root ~ "/state";
    cfg.tailscale_fixture = "tests/fixtures/tailscale/online_fleet.json";
    auto store = new TelemetryCacheStore(cfg, "hikari:zero-test");
    auto coord = new RefreshCoordinator(backend, store);
    auto reg = new NodeRegistry(cfg.paths.state_dir);
    auto disc = new TailnetDiscoveryService(cfg, reg);
    assert(disc.getLocalTailscaleSnapshot().available);

    auto router = new HikariRouter(cfg, coord, disc, reg);
    auto bodyBuf = new char[HTTP_RESPONSE_BUF_SIZE];

    // Warmup pass so initial identity strings and caches are populated
    cast(void) backend.identity();
    cast(void) backend.sampleCpu();
    cast(void) backend.sampleMemory();
    cast(void) backend.sampleNetwork();
    cast(void) backend.sampleProcesses();
    cast(void) backend.sampleFilesystems();
    cast(void) backend.sampleGpus();
    cast(void) backend.sampleBatteries();
    cast(void) coord.getStatus(true);
    {
        import core.thread : Thread;
        import core.time : MonoTime, msecs;
        auto dl = MonoTime.currTime + msecs(2000);
        while (MonoTime.currTime < dl) {
            auto st = coord.getStatus(false);
            bool anyRefreshing = st.kind != EndpointOutcomeKind.ok;
            if (st.kind == EndpointOutcomeKind.ok) {
                foreach (_, gm; st.payload.groups) {
                    if (gm.refreshing) anyRefreshing = true;
                }
            }
            if (!anyRefreshing) break;
            Thread.sleep(msecs(5));
        }
    }
    HttpRequest warmReq;
    parseHttpRequestInPlace("GET /api/v1/nodes?probe=0 HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://nas-box.tail1234.ts.net:9100\r\n\r\n", warmReq);
    size_t blen = 0;
    cast(void) router.handleIntoBuffer(warmReq, bodyBuf, blen);
    parseHttpRequestInPlace("GET /api/v1/status HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://nas-box.tail1234.ts.net:9100\r\n\r\n", warmReq);
    cast(void) router.handleIntoBuffer(warmReq, bodyBuf, blen);

    immutable string[] reqs = [
        "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "GET /api/v1/info HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://nas-box.tail1234.ts.net:9100\r\n\r\n",
        "GET /api/v1/status HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://nas-box.tail1234.ts.net:9100\r\n\r\n",
        "GET /api/v1/nodes?probe=0 HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://nas-box.tail1234.ts.net:9100\r\n\r\n",
    ];

    import std.format : format;
    auto allocBefore = GC.stats().allocatedInCurrentThread;
    foreach (_; 0 .. 100) {
        auto b0 = GC.stats().allocatedInCurrentThread;
        cast(void) backend.identity();
        cast(void) backend.sampleCpu();
        cast(void) backend.sampleMemory();
        cast(void) backend.sampleNetwork();
        cast(void) backend.sampleProcesses();
        cast(void) backend.sampleFilesystems();
        cast(void) backend.sampleGpus();
        cast(void) backend.sampleBatteries();
        auto b1 = GC.stats().allocatedInCurrentThread;
        assert(b1 == b0, format!"Backend probe allocated %u bytes"(b1 - b0));

        foreach (ri, raw; reqs) {
            auto r0 = GC.stats().allocatedInCurrentThread;
            HttpRequest r;
            assert(parseHttpRequestInPlace(raw, r));
            auto hr = router.handleIntoBuffer(r, bodyBuf, blen);
            assert(hr.statusCode == 200);
            assert(hr.bodyText.length == 0 && blen > 0);
            auto r1 = GC.stats().allocatedInCurrentThread;
            assert(r1 == r0, format!"HTTP route %u allocated %u bytes"(ri, r1 - r0));
        }
    }
    auto allocAfter = GC.stats().allocatedInCurrentThread;
    assert(allocAfter == allocBefore, format!"Expected 0 bytes GC-allocated in steady state, saw %u"(allocAfter - allocBefore));
}
