module tailnet.registry;

import core.config : normalizeBasePath;
import core.limits : MAX_FLEET_NODES;
import core.model;
import core.serializer : parseHardwareSummary, sanitizeOsString, serializeNodesResponse;
import std.file : exists, mkdirRecurse, readText, rename, write;
import std.format : format;
import std.json : JSONOptions, JSONType, parseJSON;
import std.path : dirName;
import std.typecons : Nullable;

string buildHttpsUrl(string fqdn, ushort port, string basePath, string suffix) pure @safe {
    if (fqdn.length == 0) return "";
    auto bp = normalizeBasePath(basePath);
    string prefix = (bp == "/") ? "" : bp;
    return format!"https://%s:%u%s%s"(fqdn, port, prefix, suffix);
}

private struct NodesHashSink {
    ulong h1 = 14695981039346656037UL;
    ulong h2 = 5381UL;
    size_t byteLen = 0;

    @nogc nothrow pure @safe:

    void putChar(char c) {
        ubyte b = cast(ubyte) c;
        h1 ^= b;
        h1 *= 1099511628211UL;
        h2 = ((h2 << 5) + h2) ^ (b + 0x9e3779b97f4a7c15UL);
        h2 *= 0xbf58476d1ce4e5b9UL;
        byteLen++;
    }

    void putRaw(const(char)[] s) {
        foreach (char c; s) putChar(c);
    }

    void putUlongVal(ulong u) {
        foreach (i; 0 .. 8) {
            putChar(cast(char)((u >> (i * 8)) & 0xFF));
        }
    }

    void putStrField(const(char)[] s) {
        putUlongVal(cast(ulong) s.length);
        putRaw(s);
    }

    void putBoolField(bool b) {
        putChar(b ? '1' : '0');
    }

    void putNullableBoolField(Nullable!bool v) {
        if (v.isNull) putChar('N');
        else putChar(v.get ? 'T' : 'F');
    }

    void putNullableLongField(Nullable!long v) {
        if (v.isNull) putChar('N');
        else {
            putChar('L');
            putUlongVal(cast(ulong) v.get);
        }
    }

    void putNullableUlongField(Nullable!ulong v) {
        if (v.isNull) putChar('N');
        else {
            putChar('U');
            putUlongVal(v.get);
        }
    }

    bool opEquals(const ref NodesHashSink other) const {
        return h1 == other.h1 && h2 == other.h2 && byteLen == other.byteLen;
    }
}

private NodesHashSink computeNodesDigest(const NodeRecord[] list, bool withTimestamps) @nogc nothrow pure @safe {
    NodesHashSink s;
    s.putUlongVal(cast(ulong) list.length);
    foreach (const ref n; list) {
        s.putStrField(n.node_id);
        s.putStrField(n.tailscale_node_id);
        s.putStrField(n.name);
        s.putStrField(n.alias_name);
        s.putStrField(n.fqdn);
        s.putStrField(n.status_url);
        s.putStrField(n.hardware_url);
        s.putStrField(n.info_url);
        s.putUlongVal(n.tailnet_port);
        s.putStrField(n.base_path.length ? n.base_path : "/");
        s.putStrField(n.os);
        s.putStrField(n.arch);
        s.putBoolField(n.is_self);
        s.putNullableBoolField(n.tailscale_online);
        s.putStrField(n.discovery_state);
        if (withTimestamps) {
            s.putNullableLongField(n.last_seen_ts);
            s.putNullableLongField(n.last_success_ts);
        } else {
            s.putNullableLongField(Nullable!long.init);
            s.putNullableLongField(Nullable!long.init);
        }
        if (n.last_known_hardware_summary.isNull) {
            s.putChar('N');
        } else {
            auto hs = n.last_known_hardware_summary.get;
            s.putChar('H');
            s.putStrField(hs.cpu);
            s.putNullableUlongField(hs.ram_bytes);
            s.putStrField(hs.system_model);
        }
        s.putBoolField(n.hidden);
    }
    return s;
}

class NodeRegistry {
    string filePath;
    NodeRecord[] nodes;
    private string[MAX_FLEET_NODES] knownFqdnsBuf;
    private size_t knownFqdnsCount = 0;

    private void rebuildKnownFqdns() @nogc nothrow @safe {
        size_t count = 0;
        foreach (const ref n; nodes) {
            if (n.fqdn.length > 0) {
                if (count >= MAX_FLEET_NODES) break;
                knownFqdnsBuf[count++] = n.fqdn;
            }
        }
        knownFqdnsCount = count;
    }

    this(string stateDir) {
        this.filePath = stateDir ~ "/nodes.json";
        this.nodes.reserve(MAX_FLEET_NODES);
        load();
    }

    void load() {
        nodes = null;
        nodes.reserve(MAX_FLEET_NODES);
        persistedKnown = false;
        if (!exists(filePath)) return;
        try {
            auto j = parseJSON(readText(filePath));
            if (j.type != JSONType.object) return;
            auto pNodes = "nodes" in j.object;
            if (pNodes is null || pNodes.type != JSONType.array) return;
            foreach (el; pNodes.array) {
                if (nodes.length >= MAX_FLEET_NODES) break;
                if (el.type != JSONType.object) continue;
                NodeRecord nr;
                if (auto p = "node_id" in el.object) if (p.type == JSONType.string) nr.node_id = p.str.idup;
                if (nr.node_id.length == 0) continue;
                if (auto p = "tailscale_node_id" in el.object) if (p.type == JSONType.string) nr.tailscale_node_id = p.str.idup;
                if (auto p = "name" in el.object) if (p.type == JSONType.string) nr.name = sanitizeOsString(p.str, 128);
                if (auto p = "alias" in el.object) if (p.type == JSONType.string) nr.alias_name = sanitizeOsString(p.str, 128);
                if (auto p = "fqdn" in el.object) if (p.type == JSONType.string) nr.fqdn = sanitizeOsString(p.str, 253);
                if (auto p = "status_url" in el.object) if (p.type == JSONType.string) nr.status_url = p.str.idup;
                if (auto p = "hardware_url" in el.object) if (p.type == JSONType.string) nr.hardware_url = p.str.idup;
                if (auto p = "info_url" in el.object) if (p.type == JSONType.string) nr.info_url = p.str.idup;
                if (auto p = "tailnet_port" in el.object) if (p.type == JSONType.integer && p.integer > 0) nr.tailnet_port = cast(ushort) p.integer;
                if (auto p = "base_path" in el.object) if (p.type == JSONType.string) nr.base_path = normalizeBasePath(p.str);
                if (auto p = "os" in el.object) if (p.type == JSONType.string) nr.os = p.str.idup;
                if (auto p = "arch" in el.object) if (p.type == JSONType.string) nr.arch = p.str.idup;
                if (auto p = "is_self" in el.object) nr.is_self = (p.type == JSONType.true_);
                if (auto p = "tailscale_online" in el.object) {
                    if (p.type == JSONType.true_) nr.tailscale_online = true;
                    else if (p.type == JSONType.false_) nr.tailscale_online = false;
                }
                if (auto p = "discovery_state" in el.object) if (p.type == JSONType.string) nr.discovery_state = p.str.idup;
                if (auto p = "last_seen_ts" in el.object) if (p.type == JSONType.integer) nr.last_seen_ts = p.integer;
                if (auto p = "last_success_ts" in el.object) if (p.type == JSONType.integer) nr.last_success_ts = p.integer;
                if (auto p = "last_known_hardware_summary" in el.object) if (p.type == JSONType.object) {
                    nr.last_known_hardware_summary = parseHardwareSummary(*p);
                }
                if (auto p = "hidden" in el.object) nr.hidden = (p.type == JSONType.true_);
                nodes ~= nr;
            }
            long genAt = 0;
            if (auto g = "generated_at" in j.object) if (g.type == JSONType.integer) genAt = g.integer;
            rebuildKnownFqdns();
            notePersisted(genAt);
        } catch (Exception) {
            nodes = null;
            knownFqdnsCount = 0;
            persistedKnown = false;
        }
    }

    /// Contact timestamps (last_seen_ts / last_success_ts) change on every dashboard
    /// request; persisting them each time would rewrite nodes.json every poll. They
    /// are written only when something else changed or at most this often.
    enum long TIMESTAMP_PERSIST_INTERVAL_S = 3600;

    private bool persistedKnown = false;
    private NodesHashSink persistedStableHash; // digest without contact timestamps
    private NodesHashSink persistedFullHash;   // digest as last written/loaded
    private long persistedAtWall = 0;

    private void notePersisted(long atWall) @nogc nothrow pure @safe {
        persistedStableHash = computeNodesDigest(nodes, false);
        persistedFullHash = computeNodesDigest(nodes, true);
        persistedAtWall = atWall;
        persistedKnown = true;
    }

    /// Writes nodes.json only when operator-relevant state changed, or when contact
    /// timestamps are older on disk than TIMESTAMP_PERSIST_INTERVAL_S. Returns true
    /// if the file was written.
    bool saveIfChanged(long generatedAt) {
        auto stable = computeNodesDigest(nodes, false);
        auto full = computeNodesDigest(nodes, true);
        if (persistedKnown) {
            if (full == persistedFullHash) return false;
            if (stable == persistedStableHash && generatedAt - persistedAtWall < TIMESTAMP_PERSIST_INTERVAL_S
                && generatedAt >= persistedAtWall) {
                return false;
            }
        }

        NodesResponse resp;
        resp.generated_at = generatedAt;
        resp.nodes = nodes;
        auto newText = serializeNodesResponse(resp).toPrettyString(JSONOptions.doNotEscapeSlashes) ~ "\n";
        try {
            auto parent = dirName(filePath);
            if (!exists(parent)) mkdirRecurse(parent);
            auto tmp = filePath ~ ".tmp";
            write(tmp, newText);
            rename(tmp, filePath);
            persistedStableHash = stable;
            persistedFullHash = full;
            persistedAtWall = generatedAt;
            persistedKnown = true;
            return true;
        } catch (Exception) {
            return false;
        }
    }

    private size_t findIndex(string nodeId, string tailscaleNodeId, string fqdn) const pure nothrow @safe {
        foreach (i, const ref n; nodes) {
            if (nodeId.length > 0 && n.node_id == nodeId) return i;
        }
        if (tailscaleNodeId.length > 0) {
            foreach (i, const ref n; nodes) {
                if (n.tailscale_node_id == tailscaleNodeId) return i;
            }
        }
        if (fqdn.length > 0) {
            foreach (i, const ref n; nodes) {
                if (n.fqdn == fqdn) return i;
            }
        }
        return size_t.max;
    }

    private size_t findEvictionCandidateLocked() const pure nothrow @safe {
        size_t bestIdx = size_t.max;
        long oldestTs = long.max;
        foreach (i, const ref n; nodes) {
            if (n.is_self) continue;
            if (n.discovery_state == "confirmed") continue;
            long ts = !n.last_success_ts.isNull ? n.last_success_ts.get
                : (!n.last_seen_ts.isNull ? n.last_seen_ts.get : long.min);
            if (bestIdx == size_t.max || ts < oldestTs) {
                oldestTs = ts;
                bestIdx = i;
            }
        }
        return bestIdx;
    }

    void upsertConfirmedNode(const ref NodeRecord incoming) {
        size_t idx = findIndex(incoming.node_id, incoming.tailscale_node_id, incoming.fqdn);
        if (idx == size_t.max) {
            NodeRecord copy = incoming;
            copy.node_id = copy.node_id.length > 0 ? copy.node_id.idup : "";
            copy.tailscale_node_id = copy.tailscale_node_id.length > 0 ? copy.tailscale_node_id.idup : "";
            copy.name = copy.name.length > 0 ? copy.name.idup : "";
            copy.alias_name = copy.alias_name.length > 0 ? copy.alias_name.idup : "";
            copy.fqdn = copy.fqdn.length > 0 ? copy.fqdn.idup : "";
            copy.status_url = copy.status_url.length > 0 ? copy.status_url.idup : "";
            copy.hardware_url = copy.hardware_url.length > 0 ? copy.hardware_url.idup : "";
            copy.info_url = copy.info_url.length > 0 ? copy.info_url.idup : "";
            copy.base_path = copy.base_path.length > 0 ? copy.base_path.idup : "/";
            copy.os = copy.os.length > 0 ? copy.os.idup : "";
            copy.arch = copy.arch.length > 0 ? copy.arch.idup : "";
            copy.discovery_state = copy.discovery_state.length > 0 ? copy.discovery_state.idup : "confirmed";
            if (copy.fqdn.length > 0) {
                ushort p = copy.tailnet_port > 0 ? copy.tailnet_port : 9100;
                auto bp = copy.base_path.length > 0 ? copy.base_path : "/";
                if (copy.status_url.length == 0) copy.status_url = buildHttpsUrl(copy.fqdn, p, bp, "/api/v1/status");
                if (copy.hardware_url.length == 0) copy.hardware_url = buildHttpsUrl(copy.fqdn, p, bp, "/api/v1/hardware");
                if (copy.info_url.length == 0) copy.info_url = buildHttpsUrl(copy.fqdn, p, bp, "/api/v1/info");
            }
            if (nodes.length >= MAX_FLEET_NODES) {
                auto evictIdx = findEvictionCandidateLocked();
                if (evictIdx == size_t.max) return;
                nodes[evictIdx] = copy;
                rebuildKnownFqdns();
                return;
            }
            nodes ~= copy;
            rebuildKnownFqdns();
            return;
        }

        // Preserve operator-owned fields: alias_name, tailnet_port, base_path, hidden
        auto existing = nodes[idx];
        auto prevFqdn = existing.fqdn;
        if (existing.node_id != incoming.node_id) existing.node_id = incoming.node_id.length > 0 ? incoming.node_id.idup : "";
        if (incoming.tailscale_node_id.length > 0 && existing.tailscale_node_id != incoming.tailscale_node_id) existing.tailscale_node_id = incoming.tailscale_node_id.idup;
        if (incoming.name.length > 0 && existing.name != incoming.name) existing.name = incoming.name.idup;
        if (incoming.fqdn.length > 0 && existing.fqdn != incoming.fqdn) existing.fqdn = incoming.fqdn.idup;
        if (incoming.os.length > 0 && existing.os != incoming.os) existing.os = incoming.os.idup;
        if (incoming.arch.length > 0 && existing.arch != incoming.arch) existing.arch = incoming.arch.idup;
        existing.is_self = incoming.is_self || existing.is_self;
        if (!incoming.tailscale_online.isNull) existing.tailscale_online = incoming.tailscale_online;
        if (existing.discovery_state != incoming.discovery_state) existing.discovery_state = incoming.discovery_state.length > 0 ? incoming.discovery_state.idup : "";
        if (!incoming.last_seen_ts.isNull) existing.last_seen_ts = incoming.last_seen_ts;
        if (!incoming.last_success_ts.isNull) existing.last_success_ts = incoming.last_success_ts;
        if (!incoming.last_known_hardware_summary.isNull) {
            existing.last_known_hardware_summary = incoming.last_known_hardware_summary;
        }
        // Recompute URLs only when FQDN changed or any URL is missing
        if (existing.fqdn.length > 0 && (existing.fqdn != prevFqdn
            || existing.status_url.length == 0 || existing.hardware_url.length == 0 || existing.info_url.length == 0)) {
            ushort port = existing.tailnet_port > 0 ? existing.tailnet_port : 9100;
            auto bp = existing.base_path.length > 0 ? existing.base_path : "/";
            existing.status_url = buildHttpsUrl(existing.fqdn, port, bp, "/api/v1/status");
            existing.hardware_url = buildHttpsUrl(existing.fqdn, port, bp, "/api/v1/hardware");
            existing.info_url = buildHttpsUrl(existing.fqdn, port, bp, "/api/v1/info");
        }
        nodes[idx] = existing;
        if (existing.fqdn != prevFqdn) rebuildKnownFqdns();
    }

    void updateTailscalePresence(string tailscaleNodeId, string fqdn, string hostName, Nullable!bool online) {
        size_t idx = findIndex("", tailscaleNodeId, fqdn);
        if (idx == size_t.max) return;
        if (!online.isNull) nodes[idx].tailscale_online = online;
        if (hostName.length > 0) nodes[idx].name = hostName;
        if (fqdn.length > 0 && fqdn != nodes[idx].fqdn) {
            nodes[idx].fqdn = fqdn;
            ushort port = nodes[idx].tailnet_port > 0 ? nodes[idx].tailnet_port : 9100;
            auto bp = nodes[idx].base_path.length > 0 ? nodes[idx].base_path : "/";
            nodes[idx].status_url = buildHttpsUrl(fqdn, port, bp, "/api/v1/status");
            nodes[idx].hardware_url = buildHttpsUrl(fqdn, port, bp, "/api/v1/hardware");
            nodes[idx].info_url = buildHttpsUrl(fqdn, port, bp, "/api/v1/info");
            rebuildKnownFqdns();
        }
    }

    void markUnreachable(string nodeId, string tailscaleNodeId, string fqdn, string state = "unreachable") {
        size_t idx = findIndex(nodeId, tailscaleNodeId, fqdn);
        if (idx == size_t.max) return;
        nodes[idx].discovery_state = state;
    }

    bool setAlias(string nodeId, string aliasName) {
        foreach (ref n; nodes) {
            if (n.node_id == nodeId) {
                n.alias_name = sanitizeOsString(aliasName, 128);
                return true;
            }
        }
        return false;
    }

    bool setHidden(string nodeId, bool hidden) {
        foreach (ref n; nodes) {
            if (n.node_id == nodeId) {
                n.hidden = hidden;
                return true;
            }
        }
        return false;
    }

    bool setCustomEndpoint(string nodeId, ushort port, string basePath) {
        foreach (ref n; nodes) {
            if (n.node_id == nodeId) {
                n.tailnet_port = port;
                n.base_path = normalizeBasePath(basePath);
                if (n.fqdn.length > 0) {
                    n.status_url = buildHttpsUrl(n.fqdn, n.tailnet_port, n.base_path, "/api/v1/status");
                    n.hardware_url = buildHttpsUrl(n.fqdn, n.tailnet_port, n.base_path, "/api/v1/hardware");
                    n.info_url = buildHttpsUrl(n.fqdn, n.tailnet_port, n.base_path, "/api/v1/info");
                }
                return true;
            }
        }
        return false;
    }

    const(string)[] knownFqdnsSlice() const @nogc nothrow @safe {
        return knownFqdnsBuf[0 .. knownFqdnsCount];
    }

    string[] knownFqdns() const pure @safe {
        string[] res;
        foreach (n; nodes) {
            if (n.fqdn.length > 0) res ~= n.fqdn;
        }
        return res;
    }
}
