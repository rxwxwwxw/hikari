module tailnet.registry;

import core.config : normalizeBasePath;
import core.model;
import core.serializer : jsonNull, jsonNullableBool, jsonNullableLong, jsonStringOrNull, parseHardwareSummary, sanitizeOsString, serializeHardwareSummary, serializeNodesResponse;
import std.algorithm : startsWith;
import std.file : exists, mkdirRecurse, readText, rename, write;
import std.format : format;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.typecons : Nullable;

string buildHttpsUrl(string fqdn, ushort port, string basePath, string suffix) pure @safe {
    if (fqdn.length == 0) return "";
    auto bp = normalizeBasePath(basePath);
    string prefix = (bp == "/") ? "" : bp;
    return format!"https://%s:%u%s%s"(fqdn, port, prefix, suffix);
}

class NodeRegistry {
    string filePath;
    NodeRecord[] nodes;

    this(string stateDir) {
        this.filePath = stateDir ~ "/nodes.json";
        load();
    }

    void load() {
        nodes = null;
        persistedKnown = false;
        if (!exists(filePath)) return;
        try {
            auto j = parseJSON(readText(filePath));
            if (j.type != JSONType.object) return;
            auto pNodes = "nodes" in j.object;
            if (pNodes is null || pNodes.type != JSONType.array) return;
            foreach (el; pNodes.array) {
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
            notePersisted(genAt);
        } catch (Exception) {
            nodes = null;
            persistedKnown = false;
        }
    }

    /// Contact timestamps (last_seen_ts / last_success_ts) change on every dashboard
    /// request; persisting them each time would rewrite nodes.json every poll. They
    /// are written only when something else changed or at most this often.
    enum long TIMESTAMP_PERSIST_INTERVAL_S = 3600;

    private bool persistedKnown = false;
    private string persistedStable;   // nodes JSON without contact timestamps
    private string persistedFull;     // nodes JSON as last written/loaded
    private long persistedAtWall = 0;

    private static JSONValue nodesJson(const NodeRecord[] list, bool withTimestamps) {
        NodesResponse resp;
        foreach (const ref src; list) {
            NodeRecord n = src;
            if (!withTimestamps) {
                n.last_seen_ts.nullify();
                n.last_success_ts.nullify();
            }
            resp.nodes ~= n;
        }
        return serializeNodesResponse(resp)["nodes"];
    }

    private void notePersisted(long atWall) {
        persistedStable = nodesJson(nodes, false).toString();
        persistedFull = nodesJson(nodes, true).toString();
        persistedAtWall = atWall;
        persistedKnown = true;
    }

    /// Writes nodes.json only when operator-relevant state changed, or when contact
    /// timestamps are older on disk than TIMESTAMP_PERSIST_INTERVAL_S. Returns true
    /// if the file was written.
    bool saveIfChanged(long generatedAt) {
        auto stable = nodesJson(nodes, false).toString();
        auto full = nodesJson(nodes, true).toString();
        if (persistedKnown) {
            if (full == persistedFull) return false;
            if (stable == persistedStable && generatedAt - persistedAtWall < TIMESTAMP_PERSIST_INTERVAL_S
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
            notePersisted(generatedAt);
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

    void upsertConfirmedNode(const ref NodeRecord incoming) {
        size_t idx = findIndex(incoming.node_id, incoming.tailscale_node_id, incoming.fqdn);
        if (idx == size_t.max) {
            NodeRecord copy = incoming;
            if (copy.fqdn.length > 0) {
                ushort p = copy.tailnet_port > 0 ? copy.tailnet_port : 9100;
                auto bp = copy.base_path.length > 0 ? copy.base_path : "/";
                if (copy.status_url.length == 0) copy.status_url = buildHttpsUrl(copy.fqdn, p, bp, "/api/v1/status");
                if (copy.hardware_url.length == 0) copy.hardware_url = buildHttpsUrl(copy.fqdn, p, bp, "/api/v1/hardware");
                if (copy.info_url.length == 0) copy.info_url = buildHttpsUrl(copy.fqdn, p, bp, "/api/v1/info");
            }
            nodes ~= copy;
            return;
        }

        // Preserve operator-owned fields: alias_name, tailnet_port, base_path, hidden
        auto existing = nodes[idx];
        existing.node_id = incoming.node_id;
        if (incoming.tailscale_node_id.length > 0) existing.tailscale_node_id = incoming.tailscale_node_id;
        if (incoming.name.length > 0) existing.name = incoming.name;
        if (incoming.fqdn.length > 0) existing.fqdn = incoming.fqdn;
        if (incoming.os.length > 0) existing.os = incoming.os;
        if (incoming.arch.length > 0) existing.arch = incoming.arch;
        existing.is_self = incoming.is_self || existing.is_self;
        if (!incoming.tailscale_online.isNull) existing.tailscale_online = incoming.tailscale_online;
        existing.discovery_state = incoming.discovery_state;
        if (!incoming.last_seen_ts.isNull) existing.last_seen_ts = incoming.last_seen_ts;
        if (!incoming.last_success_ts.isNull) existing.last_success_ts = incoming.last_success_ts;
        if (!incoming.last_known_hardware_summary.isNull) {
            existing.last_known_hardware_summary = incoming.last_known_hardware_summary;
        }
        // Recompute URLs using operator-preserved port/base_path and updated FQDN
        if (existing.fqdn.length > 0) {
            ushort port = existing.tailnet_port > 0 ? existing.tailnet_port : 9100;
            auto bp = existing.base_path.length > 0 ? existing.base_path : "/";
            existing.status_url = buildHttpsUrl(existing.fqdn, port, bp, "/api/v1/status");
            existing.hardware_url = buildHttpsUrl(existing.fqdn, port, bp, "/api/v1/hardware");
            existing.info_url = buildHttpsUrl(existing.fqdn, port, bp, "/api/v1/info");
        }
        nodes[idx] = existing;
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

    string[] knownFqdns() const pure @safe {
        string[] res;
        foreach (n; nodes) {
            if (n.fqdn.length > 0) res ~= n.fqdn;
        }
        return res;
    }
}
