module tests.http.test_http_tailnet;

import core.cache;
import core.config;
import core.coordinator;
import core.model;
import core.serializer;
import http.caddy : renderCaddyfile, renderCaddySnippet;
import http.routes;
import http.security;
import http.server;
import platform.api;
import std.algorithm : canFind;
import std.conv : to;
import std.exception : assertThrown;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir;
import std.json : JSONType, parseJSON;
import std.socket;
import tailnet.discovery;
import tailnet.registry;

unittest {
    // 1. CORS & Origin checks
    HikariConfig cfg;
    string[] known = ["nas-box.tail1234.ts.net"];
    auto okLoop = validateRequestOrigin("http://127.0.0.1:19100", cfg, "workstation.tail1234.ts.net", "tail1234.ts.net", known);
    assert(okLoop.allowed && okLoop.echoOrigin == "http://127.0.0.1:19100");

    auto okPeer = validateRequestOrigin("https://other.tail1234.ts.net:9100", cfg, "workstation.tail1234.ts.net", "tail1234.ts.net", known);
    assert(okPeer.allowed && okPeer.echoOrigin == "https://other.tail1234.ts.net:9100");

    auto badEvil = validateRequestOrigin("https://evil.other.ts.net", cfg, "workstation.tail1234.ts.net", "tail1234.ts.net", known);
    assert(!badEvil.allowed, "Cross-tailnet origin must be rejected");

    auto badLookalike = validateRequestOrigin("https://sub.evil.tail1234.ts.net", cfg, "workstation.tail1234.ts.net", "tail1234.ts.net", known);
    assert(!badLookalike.allowed, "Multi-label lookalike subdomain must be rejected");

    auto badPlaintext = validateRequestOrigin("http://nas-box.tail1234.ts.net:9100", cfg, "workstation.tail1234.ts.net", "tail1234.ts.net", known);
    assert(!badPlaintext.allowed, "Plaintext HTTP tailnet origin must be rejected");

    assert(isValidHostHeader("127.0.0.1:19100", "workstation.tail1234.ts.net"));
    assert(isValidHostHeader("workstation.tail1234.ts.net:9100", "workstation.tail1234.ts.net"));
    assert(!isValidHostHeader("attacker.example.com", "workstation.tail1234.ts.net"));
}

unittest {
    // 2. Tailscale discovery, MagicDNS trailing dot, malformed JSON, rename preserving alias, >30d offline retention
    auto stateDir = tempDir() ~ "/hikari-test-tailnet";
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    scope (exit) { if (exists(stateDir)) rmdirRecurse(stateDir); }

    auto malformed = parseTailscaleStatusJson(readText("tests/fixtures/tailscale/malformed.json"));
    assert(!malformed.available && malformed.error.length > 0);

    auto noDns = parseTailscaleStatusJson(readText("tests/fixtures/tailscale/no_magicdns.json"));
    assert(noDns.available && !noDns.magic_dns_enabled && noDns.peers[0].fqdn == "");

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    auto reg = new NodeRegistry(stateDir);

    long fakeMono = 10_000_000_000L;
    long fakeWall = 1_794_945_600L;
    ClockSource clocks;
    clocks.monoNs = () => fakeMono;
    clocks.wallTs = () => fakeWall;
    clocks.bootNs = () => fakeMono;

    string tsFixture = readText("tests/fixtures/tailscale/online_fleet.json");
    auto disc = new TailnetDiscoveryService(
        cfg,
        reg,
        clocks,
        () => tsFixture,
        (string infoUrl, string expectedFqdn, uint timeoutMs) {
            PeerValidationResult r;
            if (expectedFqdn == "nas-box.tail1234.ts.net" || expectedFqdn == "storage-renamed.tail1234.ts.net") {
                r.ok = true;
                r.info.app = "hikari";
                r.info.schema_version = 1;
                r.info.node_id = "hikari:nas-uuid-001";
                r.info.host = expectedFqdn == "nas-box.tail1234.ts.net" ? "nas-box" : "storage-renamed";
                r.info.fqdn = expectedFqdn;
                r.info.os = "linux";
                r.info.arch = "x86_64";
            } else if (expectedFqdn == "printer-unrelated.tail1234.ts.net") {
                r.incompatible = true;
                r.error = "not_a_hikari_endpoint";
            } else {
                r.tls_error = true;
                r.error = "tls_verification_failed";
            }
            return r;
        }
    );

    InfoResponse selfInfo;
    selfInfo.node_id = "hikari:self-001";
    selfInfo.host = "workstation-linux";
    selfInfo.os = "linux";
    selfInfo.arch = "x86_64";

    auto nr1 = disc.listAndDiscoverNodes("hikari:self-001", selfInfo, true, true);
    assert(nr1.nodes.length == 2, "Only self + validated nas-box should be confirmed; printer & sleeping unconfirmed excluded");
    assert(reg.setAlias("hikari:nas-uuid-001", "Home NAS"));
    assert(reg.setCustomEndpoint("hikari:nas-uuid-001", 9443, "/monitor"));

    // Simulate 35 days later AND nas-box renamed to storage-renamed, and now unreachable
    fakeMono += 600_000_000_000L;
    fakeWall += 35 * 86400;
    tsFixture = readText("tests/fixtures/tailscale/renamed_peer.json");
    auto nr2 = disc.listAndDiscoverNodes("hikari:self-001", selfInfo, true, true);
    bool foundNas = false;
    foreach (n; nr2.nodes) {
        if (n.node_id == "hikari:nas-uuid-001") {
            foundNas = true;
            assert(n.alias_name == "Home NAS", "Rename must NEVER erase operator alias");
            assert(n.tailnet_port == 9443 && n.base_path == "/monitor", "Rename must preserve custom port & base_path");
            assert(n.fqdn == "storage-renamed.tail1234.ts.net");
            assert(n.status_url == "https://storage-renamed.tail1234.ts.net:9443/monitor/api/v1/status");
        }
    }
    assert(foundNas, "Confirmed nodes must be retained even after >30 days");
}

unittest {
    // 3. Caddyfile safety & live LoopbackHttpServer round-trip
    assertThrown!Exception(renderCaddyfile("caddy/Caddyfile.tmpl", "box.tail.ts.net", 9100, "", 19100, "/", "/var/lib/hikari", "/opt/hikari/web"));
    auto cf = renderCaddyfile("caddy/Caddyfile.tmpl", "box.tail.ts.net", 9100, "100.64.0.10", 19100, "/hikari", "/var/lib/hikari", "/opt/hikari/web");
    assert(cf.canFind("admin off") && cf.canFind("bind 100.64.0.10") && cf.canFind("/hikari/api/v1/*"));
    auto snip = renderCaddySnippet("caddy/snippet.caddy.tmpl", 19100, "/", "/opt/hikari/web");
    assert(snip.canFind("handle_path /hikari/*"));

    auto stateDir = tempDir() ~ "/hikari-test-http";
    if (exists(stateDir)) rmdirRecurse(stateDir);
    mkdirRecurse(stateDir);
    scope (exit) { if (exists(stateDir)) rmdirRecurse(stateDir); }

    auto cfg = HikariConfig.init;
    cfg.paths.state_dir = stateDir;
    cfg.tailscale_fixture = "tests/fixtures/tailscale/online_fleet.json";
    cfg.listen.loopback_port = 0; // ephemeral port

    auto fake = new FakePlatformBackend("desktop-x86_64");
    auto store = new TelemetryCacheStore(cfg, "hikari:http-test");
    auto coord = new RefreshCoordinator(fake, store);
    auto reg = new NodeRegistry(stateDir);
    auto disc = new TailnetDiscoveryService(cfg, reg);
    auto router = new HikariRouter(cfg, coord, disc, reg, "web/index.html");
    auto srv = new LoopbackHttpServer("127.0.0.1", 0, router);
    srv.startBackground();
    scope (exit) srv.stop();

    string sendHttp(string raw) {
        auto sock = new TcpSocket();
        scope (exit) sock.close();
        sock.connect(new InternetAddress("127.0.0.1", srv.actualPort()));
        sock.send(raw);
        char[65536] buf;
        string all;
        while (true) {
            auto n = sock.receive(buf[]);
            if (n <= 0) break;
            all ~= cast(string) buf[0 .. n];
        }
        return all;
    }

    auto rHealth = sendHttp("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    assert(rHealth.canFind("200 OK") && rHealth.canFind(`"status":"ok"`));

    auto rBadOrig = sendHttp("GET /api/v1/status HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://evil.other.ts.net\r\n\r\n");
    assert(rBadOrig.canFind("403 Forbidden"));
    assert(!rBadOrig.canFind("Access-Control-Allow-Origin: *"));

    auto rStatus = sendHttp("GET /api/v1/status HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://nas-box.tail1234.ts.net:9100\r\n\r\n");
    assert(rStatus.canFind("200 OK"), "Expected 200 OK, got:\n" ~ rStatus);
    assert(rStatus.canFind("Access-Control-Allow-Origin: https://nas-box.tail1234.ts.net:9100"));
    assert(rStatus.canFind("Cache-Control: no-store"));
}
