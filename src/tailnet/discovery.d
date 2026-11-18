module tailnet.discovery;

import core.config;
import core.coordinator : ClockSource;
import core.model;
import core.serializer : parseHardwareSummary, sanitizeOsString;
import core.sync.mutex;
import core.thread;
import std.algorithm : canFind, endsWith, startsWith;
import std.file : exists, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.process : Config, execute;
import std.string : indexOf, strip;
import std.typecons : Nullable;
import tailnet.registry;
import platform.command : runLocalCommand, tailscaleExecutable;

struct TailscalePeerCandidate {
    string tailscale_node_id;
    string host_name;
    string fqdn; // MagicDNS trimmed of trailing '.'
    string[] tailscale_ips;
    string os;
    Nullable!bool online;
    bool is_self = false;
}

struct TailscaleSnapshot {
    bool available = false;
    bool magic_dns_enabled = false;
    string magic_dns_suffix;
    string error;
    TailscalePeerCandidate selfNode;
    TailscalePeerCandidate[] peers;
}

struct PeerValidationResult {
    bool ok = false;
    bool tls_error = false;
    bool incompatible = false;
    string error;
    InfoResponse info;
}

alias TailscaleStatusProvider = string delegate();
alias PeerInfoFetcher = PeerValidationResult delegate(string infoUrl, string expectedFqdn, uint timeoutMs);

string trimTrailingDot(string s) pure @safe {
    auto t = s.strip();
    while (t.endsWith(".")) t = t[0 .. $ - 1];
    return t;
}

TailscaleSnapshot parseTailscaleStatusJson(string rawJson) {
    TailscaleSnapshot snap;
    if (rawJson.strip().length == 0) {
        snap.error = "empty_tailscale_status";
        return snap;
    }

    JSONValue root;
    try {
        root = parseJSON(rawJson);
    } catch (Exception e) {
        snap.error = "malformed_tailscale_json";
        return snap;
    }
    if (root.type != JSONType.object) {
        snap.error = "invalid_tailscale_json_root";
        return snap;
    }

    if (auto pSuffix = "MagicDNSSuffix" in root.object) {
        if (pSuffix.type == JSONType.string && pSuffix.str.length > 0) {
            snap.magic_dns_suffix = trimTrailingDot(pSuffix.str);
            snap.magic_dns_enabled = true;
        }
    }

    TailscalePeerCandidate parseNode(const ref JSONValue obj, bool isSelf) {
        TailscalePeerCandidate c;
        c.is_self = isSelf;
        if (obj.type != JSONType.object) return c;
        if (auto p = "ID" in obj.object) if (p.type == JSONType.string) c.tailscale_node_id = p.str;
        if (auto p = "HostName" in obj.object) if (p.type == JSONType.string) c.host_name = sanitizeOsString(p.str, 128);
        if (auto p = "DNSName" in obj.object) if (p.type == JSONType.string) c.fqdn = trimTrailingDot(p.str);
        if (auto p = "OS" in obj.object) if (p.type == JSONType.string) c.os = p.str;
        if (auto p = "Online" in obj.object) {
            if (p.type == JSONType.true_) c.online = true;
            else if (p.type == JSONType.false_) c.online = false;
        }
        if (auto p = "TailscaleIPs" in obj.object) {
            if (p.type == JSONType.array) {
                foreach (ip; p.array) {
                    if (ip.type == JSONType.string && ip.str.length > 0) c.tailscale_ips ~= ip.str;
                }
            }
        }
        return c;
    }

    if (auto pSelf = "Self" in root.object) {
        snap.selfNode = parseNode(*pSelf, true);
        if (snap.selfNode.fqdn.length > 0 && !snap.magic_dns_enabled) {
            auto dot = snap.selfNode.fqdn.indexOf('.');
            if (dot > 0 && dot + 1 < snap.selfNode.fqdn.length) {
                snap.magic_dns_enabled = true;
                snap.magic_dns_suffix = snap.selfNode.fqdn[dot + 1 .. $];
            }
        }
        snap.available = true;
    }

    if (auto pPeers = "Peer" in root.object) {
        if (pPeers.type == JSONType.object) {
            foreach (_, pVal; pPeers.object) {
                auto pc = parseNode(pVal, false);
                if (pc.tailscale_node_id.length > 0 || pc.host_name.length > 0 || pc.fqdn.length > 0) {
                    snap.peers ~= pc;
                }
            }
        }
    }

    return snap;
}

PeerValidationResult parsePeerInfoPayload(string bodyText, string expectedFqdn) {
    PeerValidationResult res;
    JSONValue j;
    try {
        j = parseJSON(bodyText);
    } catch (Exception) {
        res.incompatible = true;
        res.error = "invalid_peer_json";
        return res;
    }
    if (j.type != JSONType.object) {
        res.incompatible = true;
        res.error = "invalid_peer_json_root";
        return res;
    }

    auto pApp = "app" in j.object;
    auto pSchema = "schema_version" in j.object;
    auto pNode = "node_id" in j.object;
    if (pApp is null || pApp.type != JSONType.string || pApp.str != "hikari") {
        res.incompatible = true;
        res.error = "not_a_hikari_endpoint";
        return res;
    }
    if (pSchema is null || pSchema.type != JSONType.integer || pSchema.integer != SCHEMA_VERSION) {
        res.incompatible = true;
        res.error = "incompatible_schema_version";
        return res;
    }
    if (pNode is null || pNode.type != JSONType.string || pNode.str.length == 0) {
        res.incompatible = true;
        res.error = "missing_node_id";
        return res;
    }

    InfoResponse ir;
    ir.app = "hikari";
    ir.schema_version = cast(int) pSchema.integer;
    ir.node_id = pNode.str;
    if (auto p = "agent_version" in j.object) if (p.type == JSONType.string) ir.agent_version = p.str;
    if (auto p = "host" in j.object) if (p.type == JSONType.string) ir.host = sanitizeOsString(p.str, 128);
    if (auto p = "fqdn" in j.object) if (p.type == JSONType.string) ir.fqdn = trimTrailingDot(p.str);
    if (auto p = "os" in j.object) if (p.type == JSONType.string) ir.os = p.str;
    if (auto p = "arch" in j.object) if (p.type == JSONType.string) ir.arch = p.str;
    if (auto p = "tailnet_port" in j.object) if (p.type == JSONType.integer) ir.tailnet_port = cast(ushort) p.integer;
    if (auto p = "base_path" in j.object) if (p.type == JSONType.string) ir.base_path = normalizeBasePath(p.str);
    if (auto p = "hardware_summary" in j.object) if (p.type == JSONType.object) {
        ir.hardware_summary = parseHardwareSummary(*p);
    }

    if (expectedFqdn.length > 0 && ir.fqdn.length > 0 && ir.fqdn != expectedFqdn) {
        res.incompatible = true;
        res.error = "fqdn_identity_mismatch";
        return res;
    }

    res.ok = true;
    res.info = ir;
    return res;
}

class TailnetDiscoveryService {
    HikariConfig config;
    NodeRegistry registry;
    ClockSource clocks;
    TailscaleStatusProvider statusProvider;
    PeerInfoFetcher peerFetcher;

    private Mutex mtx;
    private TailscaleSnapshot cachedTailnet;
    private long lastTailnetMonoNs = -1;
    private bool hasTailnetCache = false;

    this(
        HikariConfig cfg,
        NodeRegistry registry,
        ClockSource clocks = ClockSource.system(),
        TailscaleStatusProvider statusProvider = null,
        PeerInfoFetcher peerFetcher = null
    ) {
        this.config = cfg;
        this.registry = registry;
        this.clocks = clocks;
        this.mtx = new Mutex();

        if (statusProvider !is null) {
            this.statusProvider = statusProvider;
        } else {
            this.statusProvider = &defaultTailscaleProvider;
        }

        if (peerFetcher !is null) {
            this.peerFetcher = peerFetcher;
        } else {
            import std.functional : toDelegate;
            this.peerFetcher = toDelegate(&defaultHttpsInfoFetcher);
        }
    }

    private string defaultTailscaleProvider() {
        import std.process : environment;
        auto fixture = config.tailscale_fixture.length > 0
            ? config.tailscale_fixture
            : environment.get("HIKARI_TAILSCALE_FIXTURE", "");
        if (fixture.length > 0 && exists(fixture)) {
            return readText(fixture);
        }
        try {
            auto res = runLocalCommand([tailscaleExecutable(), "status", "--json"], 5000, 1024 * 1024 * 4);
            if (res.status == 0 && !res.outputTruncated) return res.output;
        } catch (Exception) {}
        return "";
    }

    static PeerValidationResult defaultHttpsInfoFetcher(string infoUrl, string expectedFqdn, uint timeoutMs) {
        PeerValidationResult res;
        // Strict HTTPS validation: never use -k / --insecure; enforce TLSv1.2+
        if (!infoUrl.startsWith("https://")) {
            res.error = "insecure_url_rejected";
            return res;
        }
        import std.conv : to;
        double sec = cast(double)(timeoutMs > 0 ? timeoutMs : 3000) / 1000.0;
        if (sec < 1.0) sec = 1.0;
        try {
            auto cmd = [
                "curl",
                "-sS",
                "--fail-with-body",
                "--proto", "=https",
                "--tlsv1.2",
                "--max-time", to!string(cast(int) sec),
                infoUrl,
            ];
            auto ex = execute(cmd, null, Config.none, 1024 * 128);
            if (ex.status != 0) {
                if (ex.status == 60 || ex.status == 35 || ex.status == 51) {
                    res.tls_error = true;
                    res.error = "tls_verification_failed";
                } else {
                    res.error = "peer_unreachable";
                }
                return res;
            }
            return parsePeerInfoPayload(ex.output, expectedFqdn);
        } catch (Exception) {
            res.error = "peer_fetch_exception";
            return res;
        }
    }

    TailscaleSnapshot cachedLocalTailscaleSnapshot() {
        synchronized (mtx) return cachedTailnet;
    }

    TailscaleSnapshot getLocalTailscaleSnapshot(bool forceRefresh = false) {
        long nowMono = clocks.monoNs();
        synchronized (mtx) {
            if (!forceRefresh && hasTailnetCache) {
                long ageS = (nowMono - lastTailnetMonoNs) / 1_000_000_000L;
                if (ageS >= 0 && ageS < config.collection.ttl_seconds.tailnet) {
                    return cachedTailnet;
                }
            }
        }

        string raw = statusProvider();
        auto snap = parseTailscaleStatusJson(raw);

        synchronized (mtx) {
            cachedTailnet = snap;
            lastTailnetMonoNs = clocks.monoNs();
            hasTailnetCache = true;
        }
        return snap;
    }

    NodesResponse listAndDiscoverNodes(
        string selfNodeId,
        InfoResponse selfInfo,
        bool probePeers = false,
        bool forceTailscaleRefresh = false
    ) {
        long nowWall = clocks.wallTs();
        auto snap = getLocalTailscaleSnapshot(forceTailscaleRefresh);

        synchronized (mtx) {
            // Upsert self node
            NodeRecord selfRec;
            selfRec.node_id = selfNodeId;
            selfRec.tailscale_node_id = snap.available ? snap.selfNode.tailscale_node_id : "";
            selfRec.name = selfInfo.host;
            selfRec.fqdn = (snap.available && snap.selfNode.fqdn.length > 0) ? snap.selfNode.fqdn : selfInfo.fqdn;
            selfRec.tailnet_port = config.listen.tailnet_port;
            selfRec.base_path = config.listen.base_path;
            selfRec.os = selfInfo.os;
            selfRec.arch = selfInfo.arch;
            selfRec.is_self = true;
            if (snap.available) selfRec.tailscale_online = snap.selfNode.online;
            selfRec.discovery_state = "confirmed";
            selfRec.last_seen_ts = nowWall;
            selfRec.last_success_ts = nowWall;
            selfRec.last_known_hardware_summary = selfInfo.hardware_summary;
            registry.upsertConfirmedNode(selfRec);

            // Reconcile local Tailscale peer presence with retained registry entries
            if (snap.available) {
                foreach (p; snap.peers) {
                    registry.updateTailscalePresence(p.tailscale_node_id, p.fqdn, p.host_name, p.online);
                }
            }
        }

        // Probe candidates on demand with bounded concurrency (default 4)
        if (probePeers && snap.available && snap.peers.length > 0) {
            struct CandidateJob {
                TailscalePeerCandidate peer;
                ushort port;
                string basePath;
            }

            CandidateJob[] jobs;
            synchronized (mtx) {
                foreach (p; snap.peers) {
                    if (p.fqdn.length == 0) continue; // MagicDNS absent for this peer
                    ushort port = config.listen.tailnet_port;
                    string bp = "/";
                    foreach (const ref existing; registry.nodes) {
                        if ((p.tailscale_node_id.length > 0 && existing.tailscale_node_id == p.tailscale_node_id)
                            || existing.fqdn == p.fqdn) {
                            if (existing.hidden) {
                                port = 0;
                                break;
                            }
                            if (existing.tailnet_port > 0) port = existing.tailnet_port;
                            if (existing.base_path.length > 0) bp = existing.base_path;
                            break;
                        }
                    }
                    if (port == 0) continue; // hidden node
                    jobs ~= CandidateJob(p, port, bp);
                }
            }

            uint maxConc = config.discovery.max_concurrent_probes;
            if (maxConc == 0) maxConc = 1;

            struct JobOutcome {
                CandidateJob job;
                PeerValidationResult res;
            }
            JobOutcome[] outcomes = new JobOutcome[jobs.length];
            size_t nextIdx = 0;
            auto jobMtx = new Mutex();

            void workerFn() {
                while (true) {
                    size_t myIdx;
                    synchronized (jobMtx) {
                        if (nextIdx >= jobs.length) return;
                        myIdx = nextIdx++;
                    }
                    auto jb = jobs[myIdx];
                    auto url = buildHttpsUrl(jb.peer.fqdn, jb.port, jb.basePath, "/api/v1/info");
                    outcomes[myIdx].job = jb;
                    outcomes[myIdx].res = peerFetcher(url, jb.peer.fqdn, config.discovery.probe_timeout_ms);
                }
            }

            uint workerCount = jobs.length < maxConc ? cast(uint) jobs.length : maxConc;
            Thread[] pool;
            foreach (_; 0 .. workerCount) {
                auto t = new Thread(&workerFn);
                t.start();
                pool ~= t;
            }
            foreach (t; pool) t.join();

            synchronized (mtx) {
                foreach (outc; outcomes) {
                    auto p = outc.job.peer;
                    if (outc.res.ok) {
                        NodeRecord nr;
                        nr.node_id = outc.res.info.node_id;
                        nr.tailscale_node_id = p.tailscale_node_id;
                        nr.name = outc.res.info.host.length > 0 ? outc.res.info.host : p.host_name;
                        nr.fqdn = p.fqdn;
                        nr.tailnet_port = outc.job.port;
                        nr.base_path = outc.job.basePath;
                        nr.os = outc.res.info.os;
                        nr.arch = outc.res.info.arch;
                        nr.is_self = false;
                        nr.tailscale_online = p.online;
                        nr.discovery_state = "confirmed";
                        nr.last_seen_ts = nowWall;
                        nr.last_success_ts = nowWall;
                        nr.last_known_hardware_summary = outc.res.info.hardware_summary;
                        registry.upsertConfirmedNode(nr);
                    } else if (outc.res.incompatible) {
                        // Only mark incompatible if previously confirmed; don't add non-hikari hosts to registry
                        registry.markUnreachable("", p.tailscale_node_id, p.fqdn, "incompatible");
                    } else {
                        // Do not add unvalidated peers; if previously confirmed, retain and mark unreachable
                        registry.markUnreachable("", p.tailscale_node_id, p.fqdn, "unreachable");
                    }
                }
            }
        }

        synchronized (mtx) {
            registry.saveIfChanged(nowWall);
            NodesResponse resp;
            resp.generated_at = nowWall;
            foreach (n; registry.nodes) {
                if (!n.hidden) resp.nodes ~= n;
            }
            return resp;
        }
    }
}
