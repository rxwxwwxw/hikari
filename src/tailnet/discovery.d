module tailnet.discovery;

import core.config;
import core.coordinator : ClockSource;
import core.limits : MAX_FLEET_NODES;
import core.model;
import core.serializer : JsonBufferWriter, parseHardwareSummary, sanitizeOsString, writeNodesResponseJson;
import core.sync.mutex;
import core.thread;
import std.algorithm : canFind, endsWith, startsWith;
import std.file : exists, readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.process : Config, execute;
import core.proc : executeBounded;
import std.string : indexOf, strip;
import std.typecons : Nullable;
import tailnet.registry;
import platform.command : tailscaleExecutable;

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
    return t.length == 0 ? "" : t.idup;
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
        if (auto p = "ID" in obj.object) if (p.type == JSONType.string) c.tailscale_node_id = p.str.idup;
        if (auto p = "HostName" in obj.object) if (p.type == JSONType.string) c.host_name = sanitizeOsString(p.str, 128);
        if (auto p = "DNSName" in obj.object) if (p.type == JSONType.string) c.fqdn = trimTrailingDot(p.str);
        if (auto p = "OS" in obj.object) if (p.type == JSONType.string) c.os = p.str.idup;
        if (auto p = "Online" in obj.object) {
            if (p.type == JSONType.true_) c.online = true;
            else if (p.type == JSONType.false_) c.online = false;
        }
        if (auto p = "TailscaleIPs" in obj.object) {
            if (p.type == JSONType.array) {
                foreach (ip; p.array) {
                    if (ip.type == JSONType.string && ip.str.length > 0) c.tailscale_ips ~= ip.str.idup;
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
    ir.node_id = pNode.str.idup;
    if (auto p = "agent_version" in j.object) if (p.type == JSONType.string) ir.agent_version = p.str.idup;
    if (auto p = "host" in j.object) if (p.type == JSONType.string) ir.host = sanitizeOsString(p.str, 128);
    if (auto p = "fqdn" in j.object) if (p.type == JSONType.string) ir.fqdn = trimTrailingDot(p.str);
    if (auto p = "os" in j.object) if (p.type == JSONType.string) ir.os = p.str.idup;
    if (auto p = "arch" in j.object) if (p.type == JSONType.string) ir.arch = p.str.idup;
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

/// Upper bound for one `tailscale status --json` invocation. A wedged tailscaled
/// must never hang request handling or the updater's health checks.
enum uint TAILSCALE_STATUS_TIMEOUT_MS = 5000;
/// A failed status read is retried after this long instead of being cached for
/// the full tailnet TTL (e.g. hikari started before Tailscale was up).
enum long SNAPSHOT_FAILURE_RETRY_S = 10;
/// Minimum spacing of operator-forced ("Scan peers") discovery runs.
enum long FORCED_DISCOVERY_MIN_INTERVAL_S = 30;
/// Peers that answered but are not hikari are not re-probed for this long.
enum long NON_HIKARI_RETRY_S = 6 * 3600;

class TailnetDiscoveryService {
    HikariConfig config;
    NodeRegistry registry;
    ClockSource clocks;
    TailscaleStatusProvider statusProvider;
    PeerInfoFetcher peerFetcher;

    private Mutex mtx;        // registry, snapshot cache and discovery state
    private Mutex fetchMtx;   // serializes (and so coalesces) tailscale CLI calls
    private TailscaleSnapshot cachedTailnet;
    private long lastTailnetMonoNs = -1;
    private bool hasTailnetCache = false;
    private bool bgSnapshotRunning = false;

    // Last successfully learned identity; survives later status failures.
    private string stickySelfFqdn;
    private string stickyMagicSuffix;
    private string persistedSelfFqdn;

    private bool discoveryRunning = false;
    private bool hasDiscoveryRun = false;
    private long lastDiscoveryStartMonoNs = 0;
    private Nullable!long lastDiscoveryStartWall;
    private Nullable!long lastDiscoveryFinishWall;
    private long[string] nonHikariUntilMono; // keyed by fqdn
    private NodeRecord[MAX_FLEET_NODES] nodesRespBuf;

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
        this.fetchMtx = new Mutex();

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
        loadPersistedSelfFqdn();
    }

    /// Service accounts may not inherit an interactive PATH; on Windows prefer the
    /// standard Tailscale install location before falling back to PATH lookup.
    static string tailscaleCliPath() {
        version (Windows) {
            import std.process : environment;
            foreach (base; [environment.get("ProgramFiles", `C:\Program Files`), environment.get("ProgramW6432", "")]) {
                if (base.length == 0) continue;
                auto cand = base ~ `\Tailscale\tailscale.exe`;
                if (exists(cand)) return cand;
            }
        }
        return tailscaleExecutable();
    }

    private string defaultTailscaleProvider() {
        import std.process : environment;
        auto fixture = config.tailscale_fixture.length > 0
            ? config.tailscale_fixture
            : environment.get("HIKARI_TAILSCALE_FIXTURE", "");
        if (fixture.length > 0 && exists(fixture)) {
            return readText(fixture);
        }
        auto res = executeBounded([tailscaleCliPath(), "status", "--json"], TAILSCALE_STATUS_TIMEOUT_MS, 1024 * 1024 * 4);
        if (res.started && !res.timedOut && !res.truncated && res.status == 0) return res.output;
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
            // curl enforces --max-time itself; the outer bound only guards a stuck curl.
            auto ex = executeBounded(cmd, cast(uint)(sec * 1000) + 2000, 1024 * 128);
            if (!ex.started) {
                res.error = "peer_fetch_exception";
                return res;
            }
            if (ex.timedOut || ex.status != 0) {
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

    // ------------------------------------------------------------------
    // Local Tailscale view
    // ------------------------------------------------------------------

    private string selfFqdnPath() const {
        return config.paths.state_dir ~ "/local_fqdn";
    }

    private void loadPersistedSelfFqdn() {
        try {
            auto p = selfFqdnPath();
            if (!exists(p)) return;
            auto v = trimTrailingDot(readText(p).strip());
            if (isPlausibleFqdn(v)) {
                persistedSelfFqdn = v;
                stickySelfFqdn = v;
                auto dot = v.indexOf('.');
                if (dot > 0) stickyMagicSuffix = v[dot + 1 .. $];
            }
        } catch (Exception) {}
    }

    private static bool isPlausibleFqdn(string v) pure @safe {
        if (v.length < 3 || v.length > 253 || v.indexOf('.') <= 0) return false;
        foreach (ch; v) {
            if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '.')) return false;
        }
        return true;
    }

    /// Records a newly learned self FQDN; persisted (only when it changes) so Host
    /// validation keeps working after a restart while Tailscale is unavailable.
    private void rememberSelfLocked(const ref TailscaleSnapshot snap) {
        if (!snap.available) return;
        if (snap.magic_dns_suffix.length > 0) stickyMagicSuffix = snap.magic_dns_suffix;
        auto f = snap.selfNode.fqdn;
        if (!isPlausibleFqdn(f)) return;
        stickySelfFqdn = f;
        if (f == persistedSelfFqdn) return;
        try {
            import std.file : mkdirRecurse, rename, write;
            if (!exists(config.paths.state_dir)) mkdirRecurse(config.paths.state_dir);
            auto tmp = selfFqdnPath() ~ ".tmp";
            write(tmp, f ~ "\n");
            rename(tmp, selfFqdnPath());
            persistedSelfFqdn = f;
        } catch (Exception) {}
    }

    private bool snapshotFreshLocked(long nowMono) const {
        if (!hasTailnetCache) return false;
        long ageS = (nowMono - lastTailnetMonoNs) / 1_000_000_000L;
        long ttl = cachedTailnet.available ? config.collection.ttl_seconds.tailnet : SNAPSHOT_FAILURE_RETRY_S;
        return ageS >= 0 && ageS < ttl;
    }

    /// Synchronous read of the local Tailscale view (bounded by
    /// TAILSCALE_STATUS_TIMEOUT_MS). Concurrent callers share one CLI invocation.
    TailscaleSnapshot getLocalTailscaleSnapshot(bool forceRefresh = false) {
        long callMono = clocks.monoNs();
        synchronized (mtx) {
            if (!forceRefresh && snapshotFreshLocked(callMono)) return cachedTailnet;
        }
        synchronized (fetchMtx) {
            synchronized (mtx) {
                // Another caller refreshed while we waited for fetchMtx.
                if (hasTailnetCache && lastTailnetMonoNs >= callMono) return cachedTailnet;
                if (!forceRefresh && snapshotFreshLocked(clocks.monoNs())) return cachedTailnet;
            }
            string raw;
            try {
                raw = statusProvider();
            } catch (Exception) {
                raw = "";
            }
            auto snap = parseTailscaleStatusJson(raw);
            synchronized (mtx) {
                cachedTailnet = snap;
                lastTailnetMonoNs = clocks.monoNs();
                hasTailnetCache = true;
                rememberSelfLocked(snap);
            }
            return snap;
        }
    }

    /// Non-blocking: returns the cached view immediately (possibly unavailable) and,
    /// if it is due, refreshes it on a background thread. Used on request paths.
    TailscaleSnapshot peekLocalTailscaleSnapshot() {
        bool start = false;
        TailscaleSnapshot snap;
        synchronized (mtx) {
            snap = cachedTailnet;
            if (!snapshotFreshLocked(clocks.monoNs()) && !bgSnapshotRunning) {
                bgSnapshotRunning = true;
                start = true;
            }
        }
        if (start) {
            spawnBackgroundSnapshotThread();
        }
        return snap;
    }

    private void spawnBackgroundSnapshotThread() {
        auto t = new Thread({
            scope (exit) endBackgroundSnapshot();
            try { getLocalTailscaleSnapshot(false); } catch (Exception) {}
        });
        t.isDaemon = true;
        t.start();
    }

    private void endBackgroundSnapshot() {
        synchronized (mtx) bgSnapshotRunning = false;
    }

    private void endDiscoveryRun() {
        long w = clocks.wallTs();
        synchronized (mtx) {
            discoveryRunning = false;
            lastDiscoveryFinishWall = w;
        }
    }

    /// This node's MagicDNS name: current view, else the last one learned (also
    /// across restarts). Empty only if Tailscale has never been readable.
    string localFqdn() {
        synchronized (mtx) {
            if (cachedTailnet.available && cachedTailnet.selfNode.fqdn.length > 0) return cachedTailnet.selfNode.fqdn;
            return stickySelfFqdn;
        }
    }

    string magicDnsSuffix() {
        synchronized (mtx) {
            if (cachedTailnet.available && cachedTailnet.magic_dns_suffix.length > 0) return cachedTailnet.magic_dns_suffix;
            return stickyMagicSuffix;
        }
    }

    // ------------------------------------------------------------------
    // Registry / discovery
    // ------------------------------------------------------------------

    private void upsertSelfAndPresenceLocked(const ref TailscaleSnapshot snap, string selfNodeId, const ref InfoResponse selfInfo, long nowWall) {
        NodeRecord selfRec;
        selfRec.node_id = selfNodeId;
        selfRec.tailscale_node_id = snap.available ? snap.selfNode.tailscale_node_id : "";
        selfRec.name = selfInfo.host;
        string fqdn = (snap.available && snap.selfNode.fqdn.length > 0) ? snap.selfNode.fqdn : selfInfo.fqdn;
        if (fqdn.length == 0) fqdn = stickySelfFqdn;
        selfRec.fqdn = fqdn;
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

    /// Validates eligible peers through /api/v1/info with bounded concurrency.
    /// Skips peers Tailscale reports offline, hidden nodes, and peers recently
    /// identified as non-hikari endpoints.
    private void validatePeers(TailscaleSnapshot snap, long nowWall) {
        if (!snap.available || snap.peers.length == 0) return;
        struct CandidateJob {
            TailscalePeerCandidate peer;
            ushort port;
            string basePath;
        }

        long nowMono = clocks.monoNs();
        CandidateJob[] jobs;
        synchronized (mtx) {
            string[] expiredNonHikari;
            foreach (k, until; nonHikariUntilMono) {
                if (nowMono >= until) expiredNonHikari ~= k;
            }
            foreach (k; expiredNonHikari) nonHikariUntilMono.remove(k);

            foreach (p; snap.peers) {
                if (p.fqdn.length == 0) continue; // MagicDNS absent for this peer
                if (!p.online.isNull && !p.online.get) continue; // Tailscale: offline
                if (p.fqdn in nonHikariUntilMono) continue;
                ushort port = config.listen.tailnet_port;
                string bp = "/";
                bool hidden = false;
                foreach (const ref existing; registry.nodes) {
                    if ((p.tailscale_node_id.length > 0 && existing.tailscale_node_id == p.tailscale_node_id)
                        || existing.fqdn == p.fqdn) {
                        hidden = existing.hidden;
                        if (existing.tailnet_port > 0) port = existing.tailnet_port;
                        if (existing.base_path.length > 0) bp = existing.base_path;
                        break;
                    }
                }
                if (hidden) continue;
                jobs ~= CandidateJob(p, port, bp);
            }
        }
        if (jobs.length == 0) return;

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
                try {
                    outcomes[myIdx].res = peerFetcher(url, jb.peer.fqdn, config.discovery.probe_timeout_ms);
                } catch (Exception) {
                    outcomes[myIdx].res.error = "peer_fetch_exception";
                }
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

        long doneMono = clocks.monoNs();
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
                    if (outc.res.error == "not_a_hikari_endpoint") {
                        nonHikariUntilMono[p.fqdn] = doneMono + NON_HIKARI_RETRY_S * 1_000_000_000L;
                    }
                } else {
                    // Do not add unvalidated peers; if previously confirmed, retain and mark unreachable
                    registry.markUnreachable("", p.tailscale_node_id, p.fqdn, "unreachable");
                }
            }
        }
    }

    private NodesResponse buildResponseLocked(long nowWall) {
        NodesResponse resp;
        resp.generated_at = nowWall;
        foreach (n; registry.nodes) {
            if (!n.hidden) resp.nodes ~= n;
        }
        return resp;
    }

    private NodesResponse buildResponseIntoLocked(long nowWall) nothrow @safe {
        NodesResponse resp;
        resp.generated_at = nowWall;
        size_t count = 0;
        foreach (const ref n; registry.nodes) {
            if (!n.hidden) {
                if (count >= MAX_FLEET_NODES) break;
                nodesRespBuf[count++] = n;
            }
        }
        resp.nodes = nodesRespBuf[0 .. count];
        return resp;
    }

    /// Synchronous list (+ optional synchronous peer validation). Used by the CLI
    /// (`hikari nodes list|discover`) where blocking is expected.
    NodesResponse listAndDiscoverNodes(
        string selfNodeId,
        InfoResponse selfInfo,
        bool probePeers = false,
        bool forceTailscaleRefresh = false
    ) {
        long nowWall = clocks.wallTs();
        auto snap = getLocalTailscaleSnapshot(forceTailscaleRefresh);
        synchronized (mtx) upsertSelfAndPresenceLocked(snap, selfNodeId, selfInfo, nowWall);
        if (probePeers) validatePeers(snap, nowWall);
        synchronized (mtx) {
            registry.saveIfChanged(nowWall);
            return buildResponseLocked(nowWall);
        }
    }

    /// Request-path variant for GET /api/v1/nodes: never blocks on Tailscale or
    /// peers. Returns the registry immediately and, when `allowDiscovery` is set
    /// and a run is due (tailnet TTL since the last one, or FORCED_DISCOVERY_MIN_INTERVAL_S
    /// when `forced`), validates peers on a single background thread.
    private void spawnDiscoveryThread(bool forced) {
        auto t = new Thread({
            scope (exit) endDiscoveryRun();
            try {
                auto s2 = getLocalTailscaleSnapshot(forced);
                long w = clocks.wallTs();
                validatePeers(s2, w);
                synchronized (mtx) registry.saveIfChanged(w);
            } catch (Exception) {}
        });
        t.isDaemon = true;
        t.start();
    }

    NodesResponse listNodesAndScheduleDiscovery(string selfNodeId, InfoResponse selfInfo, bool allowDiscovery, bool forced) {
        long nowWall = clocks.wallTs();
        long nowMono = clocks.monoNs();
        auto snap = peekLocalTailscaleSnapshot();

        bool startDiscovery = false;
        NodesResponse resp;
        synchronized (mtx) {
            upsertSelfAndPresenceLocked(snap, selfNodeId, selfInfo, nowWall);
            if (allowDiscovery && !discoveryRunning) {
                long sinceS = hasDiscoveryRun ? (nowMono - lastDiscoveryStartMonoNs) / 1_000_000_000L : long.max;
                long minGap = forced ? FORCED_DISCOVERY_MIN_INTERVAL_S : config.collection.ttl_seconds.tailnet;
                if (sinceS < 0 || sinceS >= minGap) {
                    startDiscovery = true;
                    discoveryRunning = true;
                    hasDiscoveryRun = true;
                    lastDiscoveryStartMonoNs = nowMono;
                    lastDiscoveryStartWall = nowWall;
                }
            }
            registry.saveIfChanged(nowWall);
            resp = buildResponseLocked(nowWall);
            DiscoveryMeta dm;
            dm.running = discoveryRunning;
            dm.last_started_at = lastDiscoveryStartWall;
            dm.last_finished_at = lastDiscoveryFinishWall;
            dm.tailscale_available = snap.available;
            resp.discovery = dm;
        }

        if (startDiscovery) {
            spawnDiscoveryThread(forced);
        }
        return resp;
    }

    bool listNodesAndScheduleDiscoveryJson(
        string selfNodeId,
        InfoResponse selfInfo,
        bool allowDiscovery,
        bool forced,
        char[] jsonBuf,
        out size_t jsonLen
    ) {
        long nowWall = clocks.wallTs();
        long nowMono = clocks.monoNs();
        auto snap = peekLocalTailscaleSnapshot();

        bool startDiscovery = false;
        bool ok = false;
        synchronized (mtx) {
            upsertSelfAndPresenceLocked(snap, selfNodeId, selfInfo, nowWall);
            if (allowDiscovery && !discoveryRunning) {
                long sinceS = hasDiscoveryRun ? (nowMono - lastDiscoveryStartMonoNs) / 1_000_000_000L : long.max;
                long minGap = forced ? FORCED_DISCOVERY_MIN_INTERVAL_S : config.collection.ttl_seconds.tailnet;
                if (sinceS < 0 || sinceS >= minGap) {
                    startDiscovery = true;
                    discoveryRunning = true;
                    hasDiscoveryRun = true;
                    lastDiscoveryStartMonoNs = nowMono;
                    lastDiscoveryStartWall = nowWall;
                }
            }
            registry.saveIfChanged(nowWall);
            auto resp = buildResponseIntoLocked(nowWall);
            DiscoveryMeta dm;
            dm.running = discoveryRunning;
            dm.last_started_at = lastDiscoveryStartWall;
            dm.last_finished_at = lastDiscoveryFinishWall;
            dm.tailscale_available = snap.available;
            resp.discovery = dm;

            auto w = JsonBufferWriter(jsonBuf);
            writeNodesResponseJson(w, resp);
            jsonLen = w.overflow ? size_t.max : w.pos;
            ok = !w.overflow;
        }

        if (startDiscovery) {
            spawnDiscoveryThread(forced);
        }
        return ok;
    }

    /// Blocks until a background discovery run (if any) completes. Tests only.
    bool waitForDiscoveryIdle(uint timeoutMs) {
        import core.time : MonoTime, msecs;
        auto deadline = MonoTime.currTime + msecs(timeoutMs);
        while (MonoTime.currTime < deadline) {
            synchronized (mtx) {
                if (!discoveryRunning) return true;
            }
            Thread.sleep(msecs(5));
        }
        return false;
    }
}
