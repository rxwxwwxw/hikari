module main;

import core.cache;
import core.config;
import core.coordinator;
import core.log : Logger;
import core.model;
import core.serializer;
import core.thread;
import core.time : msecs;
import http.caddy;
import http.routes;
import http.server;
import platform.api;
import platform.command : runLocalCommand;
import platform.linux;
import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, remove, tempDir, write;
import std.format : format;
import std.json : JSONOptions, JSONValue, parseJSON;
import std.process : Config, environment, execute;
import std.stdio : stderr, stdout, writefln, writeln;
import std.string : indexOf, replace, split, strip;
import std.typecons : Nullable;
import tailnet.discovery;
import tailnet.registry;
import update.activate;
import update.stage;
import update.verify;

private string getFlagValue(string[] args, string flag, string fallback = "") {
    foreach (i, a; args) {
        if (a == flag && i + 1 < args.length) return args[i + 1];
        if (a.startsWith(flag ~ "=")) return a[flag.length + 1 .. $];
    }
    return fallback;
}

private bool hasFlag(string[] args, string flag) {
    foreach (a; args) {
        if (a == flag) return true;
    }
    return false;
}

private PlatformBackend makeBackend(string fixtureProfile, const ref HikariConfig cfg) {
    if (fixtureProfile.length > 0) {
        return new FakePlatformBackend(fixtureProfile);
    }
    version (linux) {
        return new LinuxPlatformBackend("/proc", "/sys", "/etc", "/var", "/lib/modules", cfg.privacy.expose_mac_addresses);
    } else version (OSX) {
        import platform.darwin : DarwinPlatformBackend;
        return new DarwinPlatformBackend(cfg.privacy.expose_mac_addresses);
    } else version (Windows) {
        import platform.windows : WindowsPlatformBackend;
        return new WindowsPlatformBackend(cfg.privacy.expose_mac_addresses);
    } else {
        return new FakePlatformBackend("desktop-x86_64");
    }
}

private void writeOutput(string outPath, string content) {
    if (outPath.length == 0 || outPath == "-") {
        stdout.write(content);
        stdout.flush();
    } else {
        write(outPath, content);
    }
}

private string findWebIndexPath(const ref HikariConfig cfg) {
    string[] candidates = [
        cfg.paths.web_dir ~ "/index.html",
        "web/index.html",
        "/opt/hikari/versions/current/web/index.html",
        "/opt/hikari/current/web/index.html",
        `C:\ProgramData\hikari\versions\current\web\index.html`,
    ];
    foreach (c; candidates) {
        if (exists(c)) return c;
    }
    return "";
}

private int cmdVersion() {
    writeln(format!"hikari %s (schema_version=%d)"(AGENT_VERSION, SCHEMA_VERSION));
    return 0;
}

private int cmdSnapshot(string[] args) {
    auto cfgPath = getFlagValue(args, "--config", defaultConfigPath());
    auto cfg = loadConfig(cfgPath);
    auto fixture = getFlagValue(args, "--fixture", "");
    auto outPath = getFlagValue(args, "--out", "-");
    bool sampleTwice = hasFlag(args, "--sample-twice");

    auto backend = makeBackend(fixture, cfg);
    auto stateDir = getFlagValue(args, "--state-dir", cfg.paths.state_dir);
    cfg.paths.state_dir = stateDir;
    auto nodeId = loadOrCreateNodeId(stateDir);
    auto store = new TelemetryCacheStore(cfg, nodeId);
    auto coord = new RefreshCoordinator(backend, store);

    auto res = coord.getStatus(true);
    if (sampleTwice && res.kind == EndpointOutcomeKind.ok) {
        if (auto fb = cast(FakePlatformBackend) backend) {
            fb.advanceTick();
        } else {
            Thread.sleep(msecs(150));
        }
        res = coord.getStatus(true);
    }

    if (res.kind == EndpointOutcomeKind.ok) {
        writeOutput(outPath, toJsonText(serializeStatusResponse(res.payload), true));
        return 0;
    }
    stderr.writeln("snapshot failed: ", res.errorCode, " ", res.errorMessage);
    return 1;
}

private int cmdHardware(string[] args) {
    auto cfgPath = getFlagValue(args, "--config", defaultConfigPath());
    auto cfg = loadConfig(cfgPath);
    auto fixture = getFlagValue(args, "--fixture", "");
    auto outPath = getFlagValue(args, "--out", "-");
    bool refresh = hasFlag(args, "--refresh");

    auto stateDir = getFlagValue(args, "--state-dir", cfg.paths.state_dir);
    cfg.paths.state_dir = stateDir;
    auto backend = makeBackend(fixture, cfg);
    auto nodeId = loadOrCreateNodeId(stateDir);
    auto store = new TelemetryCacheStore(cfg, nodeId);
    auto coord = new RefreshCoordinator(backend, store);

    auto res = coord.getHardware(refresh);
    if (res.kind == EndpointOutcomeKind.ok) {
        writeOutput(outPath, toJsonText(serializeHardwareInventory(res.payload), true));
        return 0;
    }
    stderr.writeln("hardware failed: ", res.errorCode, " ", res.errorMessage);
    return 1;
}

private int cmdServe(string[] args) {
    if (hasFlag(args, "--service")) {
        version (Windows) {
            import platform.winservice : runAsService, ServiceHooks;
            auto log = new Logger(serviceLogPath(args));
            ServiceHooks hooks;
            hooks.log = log;
            hooks.requestStop = &hikariRequestStop;
            hooks.onResume = &noteSystemResume;
            hooks.body_ = (void delegate() reportRunning) => serveMain(args, log, reportRunning);
            auto rc = runAsService("hikari", hooks);
            log.close();
            return rc;
        } else {
            stderr.writeln("hikari: --service is only used by the Windows Service Control Manager; use `hikari serve`.");
            return 2;
        }
    }
    return serveMain(args, new Logger(), null);
}

/// Default service log: <ProgramData>\hikari\logs\hikari.log (sibling of the state dir).
private string serviceLogPath(string[] args) {
    import std.path : buildPath, dirName;
    auto explicit = getFlagValue(args, "--log-file", "");
    if (explicit.length > 0) return explicit;
    string stateDir = PathsConfig.init.state_dir;
    try {
        auto cfg = loadConfig(getFlagValue(args, "--config", defaultConfigPath()));
        stateDir = getFlagValue(args, "--state-dir", cfg.paths.state_dir);
    } catch (Exception) {}
    return buildPath(dirName(stateDir), "logs", "hikari.log");
}

/// Makes a relative web_dir independent of the working directory (services start in
/// C:\Windows\System32): prefer <exe dir>/<web_dir> when it exists.
private void resolveRelativePaths(ref HikariConfig cfg) {
    import std.file : thisExePath;
    import std.path : absolutePath, buildNormalizedPath, dirName, isAbsolute;
    if (cfg.paths.web_dir.length > 0 && !isAbsolute(cfg.paths.web_dir)) {
        try {
            auto besideExe = buildNormalizedPath(dirName(thisExePath()), cfg.paths.web_dir);
            if (exists(besideExe)) cfg.paths.web_dir = besideExe;
        } catch (Exception) {}
    }
}

private int serveMain(string[] args, Logger log, void delegate() reportRunning) {
    auto cfgPath = getFlagValue(args, "--config", defaultConfigPath());
    HikariConfig cfg;
    try {
        cfg = loadConfig(cfgPath);
    } catch (Exception e) {
        log.error("invalid configuration " ~ cfgPath ~ ": " ~ e.msg);
        return 3;
    }
    auto fixture = getFlagValue(args, "--fixture", "");
    auto tsFixture = getFlagValue(args, "--tailscale-fixture", "");
    if (tsFixture.length > 0) cfg.tailscale_fixture = tsFixture;

    auto portStr = getFlagValue(args, "--port", "");
    if (portStr.length > 0) cfg.listen.loopback_port = to!ushort(portStr);

    auto stateDirFlag = getFlagValue(args, "--state-dir", "");
    if (stateDirFlag.length > 0) cfg.paths.state_dir = stateDirFlag;

    resolveRelativePaths(cfg);
    try {
        validateConfig(cfg);
    } catch (Exception e) {
        log.error("invalid configuration " ~ cfgPath ~ ": " ~ e.msg);
        return 3;
    }

    auto nodeId = loadOrCreateNodeId(cfg.paths.state_dir);
    auto backend = makeBackend(fixture, cfg);
    auto store = new TelemetryCacheStore(cfg, nodeId);
    auto coord = new RefreshCoordinator(backend, store);
    auto reg = new NodeRegistry(cfg.paths.state_dir);
    auto disc = new TailnetDiscoveryService(cfg, reg);


    string webIndex = hasFlag(args, "--serve-web") || fixture.length > 0 || tsFixture.length > 0
        ? findWebIndexPath(cfg)
        : "";

    auto router = new HikariRouter(cfg, coord, disc, reg, webIndex);
    auto server = new LoopbackHttpServer(cfg.listen.loopback_bind, cfg.listen.loopback_port, router);
    try {
        server.startListening();
    } catch (Exception e) {
        // Never take over or share a port owned by another process.
        log.error(format!"cannot listen on %s:%u (%s). Another process owns this port; choose a different listen.loopback_port."(
            server.bindAddr, cfg.listen.loopback_port, e.msg));
        return 1;
    }

    installStopHandlers(server);
    if (reportRunning !is null) reportRunning();
    log.info(format!"hikari %s listening on http://%s:%u%s (node_id=%s, config=%s, state=%s, web=%s)"(
        AGENT_VERSION, server.bindAddr, server.actualPort(),
        cfg.listen.base_path == "/" ? "" : cfg.listen.base_path, nodeId, cfgPath, cfg.paths.state_dir, cfg.paths.web_dir));

    // Local identity lookup is bounded, but Tailscale may be disconnected or
    // inaccessible to this service account. Never delay loopback health on it.
    auto identityInit = new Thread({
        try {
            auto snap = disc.getLocalTailscaleSnapshot(false);
            if (snap.available && snap.selfNode.fqdn.length > 0)
                coord.updateFqdn(snap.selfNode.fqdn);
            else
                log.warn("local Tailscale status unavailable to this account (" ~ snap.error ~ "); peer discovery and Host validation are degraded");
        } catch (Exception) {
            log.warn("local Tailscale identity initialization failed");
        }
    });
    identityInit.isDaemon = true;
    identityInit.start();

    server.serveLoop();
    log.info("hikari stopped");
    return 0;
}

private __gshared LoopbackHttpServer gStopTarget;
private shared bool gStopRequested = false;

/// Stop entry point shared by the SCM control handler and the console handler.
/// Safe to call from any thread, before or after the listener exists.
private void hikariRequestStop() nothrow @nogc {
    import core.atomic : atomicStore;
    atomicStore(gStopRequested, true);
    if (gStopTarget !is null) gStopTarget.requestStop();
}

version (Windows) {
    import core.sys.windows.windef : BOOL, DWORD, FALSE, TRUE;

    private extern (Windows) BOOL hikariConsoleCtrlHandler(DWORD ctrlType) nothrow @nogc {
        enum : DWORD { CTRL_C = 0, CTRL_BREAK = 1, CTRL_CLOSE = 2, CTRL_LOGOFF = 5, CTRL_SHUTDOWN = 6 }
        switch (ctrlType) {
            case CTRL_LOGOFF:
                // Delivered to service processes whenever ANY user signs out; the C runtime's
                // default handler would exit. hikari must survive sign-out, so swallow it.
                return TRUE;
            case CTRL_C, CTRL_BREAK, CTRL_CLOSE, CTRL_SHUTDOWN:
                hikariRequestStop();
                return TRUE;
            default:
                return FALSE;
        }
    }
}

private void installStopHandlers(LoopbackHttpServer server) {
    import core.atomic : atomicLoad;
    gStopTarget = server;
    version (Windows) {
        import core.sys.windows.wincon : SetConsoleCtrlHandler;
        SetConsoleCtrlHandler(&hikariConsoleCtrlHandler, TRUE);
    }
    // A stop that arrived during startup must not be lost.
    if (atomicLoad(gStopRequested)) server.requestStop();
}

private int cmdNodes(string[] args) {
    if (args.length == 0) {
        stderr.writeln("Usage: hikari nodes <list|discover> [options]");
        return 2;
    }
    string sub = args[0];
    auto cfgPath = getFlagValue(args, "--config", defaultConfigPath());
    auto cfg = loadConfig(cfgPath);
    auto tsFixture = getFlagValue(args, "--tailscale-fixture", "");
    if (tsFixture.length > 0) cfg.tailscale_fixture = tsFixture;
    auto stateDirFlag = getFlagValue(args, "--state-dir", "");
    if (stateDirFlag.length > 0) cfg.paths.state_dir = stateDirFlag;
    auto outPath = getFlagValue(args, "--out", "-");

    auto nodeId = loadOrCreateNodeId(cfg.paths.state_dir);
    auto backend = makeBackend(getFlagValue(args, "--fixture", ""), cfg);
    auto store = new TelemetryCacheStore(cfg, nodeId);
    auto coord = new RefreshCoordinator(backend, store);
    auto reg = new NodeRegistry(cfg.paths.state_dir);
    auto disc = new TailnetDiscoveryService(cfg, reg);

    bool discover = (sub == "discover");
    if (!discover && sub != "list") {
        stderr.writeln("Unknown nodes subcommand: ", sub);
        return 2;
    }

    auto info = coord.getInfo();
    auto resp = disc.listAndDiscoverNodes(nodeId, info, discover, discover);
    writeOutput(outPath, toJsonText(serializeNodesResponse(resp), true));
    return 0;
}

private int cmdCaddy(string[] args) {
    if (args.length == 0) {
        stderr.writeln("Usage: hikari caddy <render|snippet> [options]");
        return 2;
    }
    string sub = args[0];
    auto cfgPath = getFlagValue(args, "--config", defaultConfigPath());
    auto cfg = loadConfig(cfgPath);
    auto tsFixture = getFlagValue(args, "--tailscale-fixture", "");
    if (tsFixture.length > 0) cfg.tailscale_fixture = tsFixture;
    auto outPath = getFlagValue(args, "--out", "-");

    if (sub == "validate") {
        auto binary = getFlagValue(args, "--caddy-bin", "caddy");
        auto path = getFlagValue(args, "--caddyfile", "");
        if (!path.length) { stderr.writeln("Missing --caddyfile"); return 2; }
        auto result = runLocalCommand([binary, "validate", "--adapter", "caddyfile", "--config", path], 10000, 65536);
        if (result.status != 0 || result.outputTruncated) {
            stderr.writeln(result.timedOut ? "Caddy validation timed out" : "Caddy validation failed");
            return 1;
        }
        return 0;
    }

    if (sub == "snippet") {
        cfg.listen.base_path = getFlagValue(args, "--base-path", cfg.listen.base_path);
        cfg.paths.web_dir = getFlagValue(args, "--web-dir", cfg.paths.web_dir);
        auto tmpl = getFlagValue(args, "--template", "caddy/snippet.caddy.tmpl");
        auto text = renderCaddySnippet(tmpl, cfg.listen.loopback_port, cfg.listen.base_path, cfg.paths.web_dir);
        writeOutput(outPath, text);
        return 0;
    }

    if (sub == "render") {
        auto tmpl = getFlagValue(args, "--template", "caddy/Caddyfile.tmpl");
        string fqdn = getFlagValue(args, "--fqdn", "");
        string tsIp = getFlagValue(args, "--tailscale-ip", "");

        if (fqdn.length == 0 || tsIp.length == 0) {
            auto disc = new TailnetDiscoveryService(cfg, null);
            auto snap = disc.getLocalTailscaleSnapshot(true);
            if (!snap.available) {
                stderr.writeln("Tailscale status unavailable; cannot determine MagicDNS FQDN and Tailscale IP");
                return 1;
            }
            if (fqdn.length == 0) fqdn = snap.selfNode.fqdn;
            if (tsIp.length == 0 && snap.selfNode.tailscale_ips.length > 0) {
                tsIp = snap.selfNode.tailscale_ips[0];
            }
        }

        auto text = renderCaddyfile(
            tmpl,
            fqdn,
            cfg.listen.tailnet_port,
            tsIp,
            cfg.listen.loopback_port,
            cfg.listen.base_path,
            cfg.paths.state_dir,
            cfg.paths.web_dir
        );
        writeOutput(outPath, text);
        return 0;
    }

    stderr.writeln("Unknown caddy subcommand: ", sub);
    return 2;
}

private int cmdDoctor(string[] args) {
    auto cfgPath = getFlagValue(args, "--config", defaultConfigPath());
    auto tsFixture = getFlagValue(args, "--tailscale-fixture", "");
    bool jsonOut = hasFlag(args, "--json");

    DoctorReport rep;
    HikariConfig cfg;

    // 1. Config check
    try {
        cfg = loadConfig(cfgPath);
        if (tsFixture.length > 0) cfg.tailscale_fixture = tsFixture;
        validateConfig(cfg);
        rep.checks ~= DoctorCheck(
            "config",
            "pass",
            exists(cfgPath) ? ("Valid config at " ~ cfgPath) : ("Using safe defaults (no config file at " ~ cfgPath ~ ")"),
            ""
        );
    } catch (Exception e) {
        rep.checks ~= DoctorCheck("config", "fail", "Invalid configuration: " ~ e.msg, "Fix " ~ cfgPath);
        rep.overall = "fail";
    }

    // 2. Loopback bind check
    if (isLoopbackBindAddress(cfg.listen.loopback_bind)) {
        rep.checks ~= DoctorCheck("loopback_security", "pass", "Loopback-only bind: " ~ cfg.listen.loopback_bind ~ ":" ~ to!string(cfg.listen.loopback_port), "");
    } else {
        rep.checks ~= DoctorCheck("loopback_security", "fail", "Non-loopback bind configured", "Set listen.loopback_bind to 127.0.0.1");
        rep.overall = "fail";
    }

    // 3. Local agent health check
    try {
        string host = cfg.listen.loopback_bind == "::1" ? "[::1]" : "127.0.0.1";
        auto h = execute(["curl", "-fsS", "--max-time", "2", "http://" ~ host ~ ":" ~ to!string(cfg.listen.loopback_port) ~ "/healthz"], null, Config.none, 4096);
        if (h.status == 0) {
            rep.checks ~= DoctorCheck("local_agent", "pass", "Loopback agent responded healthy on /healthz", "");
        } else {
            rep.checks ~= DoctorCheck("local_agent", "warn", "Local hikari agent is not currently listening on loopback port " ~ to!string(cfg.listen.loopback_port), "Start the installed hikari agent service or run `hikari serve`");
            if (rep.overall == "pass") rep.overall = "warn";
        }
    } catch (Exception) {
        rep.checks ~= DoctorCheck("local_agent", "warn", "Could not probe local agent", "");
    }

    // 4. Tailscale CLI & MagicDNS / Tailscale IP
    auto reg = new NodeRegistry(cfg.paths.state_dir);
    auto disc = new TailnetDiscoveryService(cfg, reg);
    auto snap = disc.getLocalTailscaleSnapshot(true);
    if (snap.available) {
        string fqdn = snap.selfNode.fqdn;
        string tsIp = snap.selfNode.tailscale_ips.length > 0 ? snap.selfNode.tailscale_ips[0] : "";
        if (fqdn.length > 0 && tsIp.length > 0) {
            rep.checks ~= DoctorCheck("tailscale", "pass", "Tailscale ready: " ~ fqdn ~ " (" ~ tsIp ~ ")", "");
        } else {
            rep.checks ~= DoctorCheck("tailscale", "warn", "Tailscale active, but MagicDNS FQDN or IP missing", "Enable MagicDNS and HTTPS certificates in your tailnet admin console");
            if (rep.overall == "pass") rep.overall = "warn";
        }
    } else {
        rep.checks ~= DoctorCheck("tailscale", "fail", "Tailscale status unavailable (" ~ snap.error ~ ")", "Ensure tailscaled is running and this node is logged into your tailnet");
        rep.overall = "fail";
    }

    version (OSX) {
        import platform.darwin_service : macosServiceChecks;
        auto url = cfg.tailscale_fixture.length == 0 && snap.available
            ? buildHttpsUrl(snap.selfNode.fqdn, cfg.listen.tailnet_port, cfg.listen.base_path, "/api/v1/info") : "";
        auto checks = macosServiceChecks(url, snap.selfNode.fqdn);
        rep.checks ~= checks;
        foreach (check; checks) if (check.status == "warn" && rep.overall == "pass") rep.overall = "warn";
    }

    // 5. Caddy binary & Caddyfile validation
    string caddyBin = getFlagValue(args, "--caddy-bin", "");
    if (caddyBin.length == 0) {
        version (Windows) {
            if (exists(`C:\ProgramData\hikari\bin\caddy.exe`)) caddyBin = `C:\ProgramData\hikari\bin\caddy.exe`;
            else {
                foreach (dir; environment.get("PATH", "").split(';')) {
                    if (dir.length == 0) continue;
                    auto cand = dir ~ `\caddy.exe`;
                    if (exists(cand)) { caddyBin = cand; break; }
                }
            }
        } else {
            string[] extraPaths = ["/opt/hikari/bin/caddy", "/opt/homebrew/bin/caddy", "/usr/local/bin/caddy"];
            foreach (ep; extraPaths) {
                if (exists(ep)) { caddyBin = ep; break; }
            }
            if (caddyBin.length == 0) {
                foreach (dir; environment.get("PATH", "/usr/local/bin:/usr/bin:/bin").split(':')) {
                    if (dir.length == 0) continue;
                    auto cand = dir ~ "/caddy";
                    if (exists(cand)) {
                        caddyBin = cand;
                        break;
                    }
                }
            }
        }
    }
    if (caddyBin.length > 0 && exists(caddyBin)) {
        try {
            auto cv = execute([caddyBin, "version"], null, Config.none, 1024);
            if (cv.status == 0) {
                rep.checks ~= DoctorCheck("caddy_binary", "pass", "Found Caddy (" ~ caddyBin ~ "): " ~ cv.output.strip(), "");
                if (snap.available && snap.selfNode.fqdn.length > 0 && snap.selfNode.tailscale_ips.length > 0) {
                    auto tmpCf = tempDir() ~ "/hikari-doctor-Caddyfile";
                    try {
                        auto templatePath = cfg.paths.versions_dir ~ "/current/caddy/Caddyfile.tmpl";
                        if (!exists(templatePath)) templatePath = "caddy/Caddyfile.tmpl";
                        auto rendered = renderCaddyfile(templatePath, snap.selfNode.fqdn, cfg.listen.tailnet_port, snap.selfNode.tailscale_ips[0], cfg.listen.loopback_port, cfg.listen.base_path, cfg.paths.state_dir, cfg.paths.web_dir);
                        write(tmpCf, rendered);
                        auto val = execute([caddyBin, "validate", "--adapter", "caddyfile", "--config", tmpCf], null, Config.none, 4096);
                        if (val.status == 0) {
                            rep.checks ~= DoctorCheck("caddy_config", "pass", "Generated isolated Caddyfile validated cleanly", "");
                        } else {
                            rep.checks ~= DoctorCheck("caddy_config", "fail", "Caddyfile validation failed: " ~ val.output.strip(), "Inspect Caddy version and Caddyfile.tmpl");
                            rep.overall = "fail";
                        }
                    } catch (Exception e) {
                        rep.checks ~= DoctorCheck("caddy_config", "warn", "Could not validate Caddyfile: " ~ e.msg, "");
                    }
                    if (exists(tmpCf)) {
                        try { remove(tmpCf); } catch (Exception) {}
                    }
                }
            } else {
                rep.checks ~= DoctorCheck("caddy_binary", "warn", "Caddy binary failed version check: " ~ caddyBin, "");
            }
        } catch (Exception e) {
            rep.checks ~= DoctorCheck("caddy_binary", "warn", "Could not execute Caddy binary " ~ caddyBin ~ ": " ~ e.msg, "");
        }
    } else {
        rep.checks ~= DoctorCheck("caddy_binary", "warn", "No Caddy binary found yet (installer will provision private hikari-owned Caddy)", "Run install/install.sh to provision hikari-caddy");
        if (rep.overall == "pass") rep.overall = "warn";
    }

    // 6. Port availability check (tailnet_port)
    if (snap.available && snap.selfNode.tailscale_ips.length > 0) {
        import std.socket;
        try {
            auto s = new TcpSocket();
            scope (exit) s.close();
            s.blocking = false;
            try {
                s.connect(new InternetAddress(snap.selfNode.tailscale_ips[0], cfg.listen.tailnet_port));
            } catch (SocketException) {}
            auto ws = new SocketSet();
            ws.add(s);
            auto es = new SocketSet();
            es.add(s);
            int sel = Socket.select(null, ws, es, msecs(250));
            bool connected = false;
            if (sel > 0 && ws.isSet(s) && !es.isSet(s)) {
                int soErr = 0;
                s.getOption(SocketOptionLevel.SOCKET, SocketOption.ERROR, soErr);
                connected = (soErr == 0);
            }
            if (connected) {
                rep.checks ~= DoctorCheck("port_collision", "pass", "Listener active on " ~ snap.selfNode.tailscale_ips[0] ~ ":" ~ to!string(cfg.listen.tailnet_port) ~ " (verify it is hikari-caddy)", "");
            } else {
                rep.checks ~= DoctorCheck("port_collision", "pass", "Port " ~ to!string(cfg.listen.tailnet_port) ~ " is free on Tailscale IP", "");
            }
        } catch (SocketException) {
            rep.checks ~= DoctorCheck("port_collision", "pass", "Port " ~ to!string(cfg.listen.tailnet_port) ~ " is free on Tailscale IP", "");
        }
    }

    // 7. Update trust root
    if (cfg.updates.isTrustConfigured()) {
        rep.checks ~= DoctorCheck("update_trust", "pass", "Pinned signed updates configured for " ~ cfg.updates.repo, "");
    } else {
        rep.checks ~= DoctorCheck("update_trust", "warn", "Signed update trust root not configured (updates disabled)", "Set updates.repo and updates.public_key in config.json");
        if (rep.overall == "pass") rep.overall = "warn";
    }

    if (jsonOut) {
        stdout.write(toJsonText(serializeDoctorReport(rep), true));
        stdout.flush();
    } else {
        writeln("hikari doctor (", rep.overall, ")");
        foreach (c; rep.checks) {
            writefln("  [%s] %s: %s", c.status, c.name, c.summary);
            if (c.remediation.length > 0) {
                writefln("         -> %s", c.remediation);
            }
        }
    }
    return rep.overall == "fail" ? 1 : 0;
}

private int cmdUpdate(string[] args) {
    if (args.length == 0) {
        stderr.writeln("Usage: hikari update <check|apply|rollback> [options]");
        return 2;
    }
    string sub = args[0];
    auto cfgPath = getFlagValue(args, "--config", defaultConfigPath());
    auto cfg = loadConfig(cfgPath);
    auto stateDir = getFlagValue(args, "--state-dir", cfg.paths.state_dir);
    auto versionsDir = getFlagValue(args, "--versions-dir", cfg.paths.versions_dir);

    if (sub == "check") {
        if (!cfg.updates.isTrustConfigured()) {
            stderr.writeln("Signed update trust root not configured (repo and public_key required).");
            return 1;
        }
        auto manifestPath = getFlagValue(args, "--manifest", "");
        auto sigPath = getFlagValue(args, "--sig", "");
        if (manifestPath.length == 0 || sigPath.length == 0) {
            writeln("Trust root configured for ", cfg.updates.repo, " (mode=", cast(string) cfg.updates.mode, "). Pass --manifest and --sig to verify locally.");
            return 0;
        }
        if (!verifySignatureWithOpenSsl(manifestPath, sigPath, cfg.updates.public_key)) {
            stderr.writeln("Signature verification failed!");
            return 1;
        }
        auto m = parseReleaseManifest(readText(manifestPath));
        auto cur = SemVer.parse(AGENT_VERSION);
        writeln("Verified manifest version ", m.version_str, " (current=", AGENT_VERSION, ", newer=", m.version_parsed > cur, ")");
        return 0;
    }

    if (sub == "apply") {
        auto manifestPath = getFlagValue(args, "--manifest", "");
        auto sigPath = getFlagValue(args, "--sig", "");
        auto archivePath = getFlagValue(args, "--archive", "");
        version (Windows) {
            enum defaultTargetOs = "windows";
            enum defaultTargetArch = "x86_64";
        } else version (OSX) {
            enum defaultTargetOs = "darwin";
            version (AArch64) enum defaultTargetArch = "arm64";
            else enum defaultTargetArch = "x86_64";
        } else {
            enum defaultTargetOs = "linux";
            version (AArch64) enum defaultTargetArch = "aarch64";
            else enum defaultTargetArch = "x86_64";
        }
        auto targetOs = getFlagValue(args, "--os", defaultTargetOs);
        auto arch = getFlagValue(args, "--arch", defaultTargetArch);
        if (manifestPath.length == 0 || sigPath.length == 0 || archivePath.length == 0) {
            stderr.writeln("Usage: hikari update apply --manifest <path> --sig <path> --archive <path>");
            return 2;
        }
        auto staged = stageSignedRelease(cfg, manifestPath, sigPath, archivePath,
            versionsDir, AGENT_VERSION, targetOs, arch);
        import std.functional : toDelegate;
        bool noRestartFn(string _) { return true; }
        auto noRestart = toDelegate(&noRestartFn);
        auto outc = activateAndVerifyRelease(
            versionsDir,
            stateDir,
            staged.versionString,
            hasFlag(args, "--no-restart") ? noRestart : null,
            hasFlag(args, "--no-restart") ? noRestart : makeLoopbackHealthChecker(cfg.listen.loopback_bind, cfg.listen.loopback_port)
        );
        writeln(outc.message);
        return outc.ok ? 0 : 1;
    }

    if (sub == "rollback" || sub == "recover") {
        import std.functional : toDelegate;
        bool noRestartFn(string _) { return true; }
        auto noRestart = toDelegate(&noRestartFn);
        auto operation = sub == "recover" ? &recoverInterruptedActivation : &rollbackToPrevious;
        auto outc = operation(
            versionsDir,
            stateDir,
            hasFlag(args, "--no-restart") ? noRestart : null,
            hasFlag(args, "--no-restart") ? noRestart : makeLoopbackHealthChecker(cfg.listen.loopback_bind, cfg.listen.loopback_port)
        );
        writeln(outc.message);
        return outc.ok ? 0 : 1;
    }

    stderr.writeln("Unknown update subcommand: ", sub);
    return 2;
}

int main(string[] args) {
    if (args.length < 2) {
        writeln("hikari ", AGENT_VERSION, " — decentralized tailnet monitor");
        writeln("Commands: version | serve | snapshot | hardware | nodes | caddy | update | doctor | service (Windows)");
        return 0;
    }

    string cmd = args[1];
    string[] rest = args.length > 2 ? args[2 .. $] : null;

    switch (cmd) {
        case "version":
        case "--version":
        case "-V":
            return cmdVersion();
        case "snapshot":
            return cmdSnapshot(rest);
        case "hardware":
            return cmdHardware(rest);
        case "serve":
            return cmdServe(rest);
        case "nodes":
            return cmdNodes(rest);
        case "caddy":
            return cmdCaddy(rest);
        case "update":
            return cmdUpdate(rest);
        case "doctor":
            return cmdDoctor(rest);
        case "service":
            version (Windows) {
                import platform.winservice : cmdService;
                return cmdService(rest);
            } else {
                stderr.writeln("hikari service: Windows only (Linux uses systemd units, macOS uses launchd; see install/)");
                return 2;
            }
        default:
            stderr.writeln("Unknown command: ", cmd);
            return 2;
    }
}
