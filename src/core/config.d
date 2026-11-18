module core.config;

import core.model : ProbeGroup, SCHEMA_VERSION;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, rename, write;
import std.json : JSONException, JSONOptions, JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.random : unpredictableSeed, Mt19937;
import std.format : format;
import std.string : strip, startsWith, endsWith;

enum UpdateMode : string {
    manual = "manual",
    on_dashboard_open = "on_dashboard_open",
    scheduled = "scheduled",
}

struct ListenConfig {
    ushort tailnet_port = 9100;
    ushort loopback_port = 19100;
    string loopback_bind = "127.0.0.1";
    string base_path = "/";
    string[] allowed_origins;
}

struct GroupTtlMap {
    long fast = 10;
    long processes = 20;
    long device_dynamic = 60;
    long filesystems = 120;
    long tailnet = 300;
    long maintenance = 43200;
    long hardware = 604800;

    long get(ProbeGroup g) const pure nothrow @safe {
        final switch (g) {
            case ProbeGroup.fast: return fast;
            case ProbeGroup.processes: return processes;
            case ProbeGroup.device_dynamic: return device_dynamic;
            case ProbeGroup.filesystems: return filesystems;
            case ProbeGroup.tailnet: return tailnet;
            case ProbeGroup.maintenance: return maintenance;
            case ProbeGroup.hardware: return hardware;
        }
    }
}

struct GroupMaxStaleMap {
    long fast = 60;
    long processes = 120;
    long device_dynamic = 600;
    long filesystems = 1200;
    long tailnet = 3600;
    long maintenance = 604800;
    long hardware = 2592000;

    long get(ProbeGroup g) const pure nothrow @safe {
        final switch (g) {
            case ProbeGroup.fast: return fast;
            case ProbeGroup.processes: return processes;
            case ProbeGroup.device_dynamic: return device_dynamic;
            case ProbeGroup.filesystems: return filesystems;
            case ProbeGroup.tailnet: return tailnet;
            case ProbeGroup.maintenance: return maintenance;
            case ProbeGroup.hardware: return hardware;
        }
    }
}

struct CollectionConfig {
    GroupTtlMap ttl_seconds;
    GroupMaxStaleMap max_stale_seconds;
    uint cold_wait_ms = 2000;
    uint probe_timeout_ms = 5000;
}

struct DiscoveryConfig {
    bool enabled_on_dashboard_open = true;
    uint max_concurrent_probes = 4;
    uint probe_timeout_ms = 3000;
}

struct UpdatesConfig {
    string repo = "OWNER/REPO";
    UpdateMode mode = UpdateMode.on_dashboard_open;
    bool auto_install_verified = true;
    uint check_interval_hours = 24;
    string public_key = "";
    string channel = "stable";

    bool isTrustConfigured() const pure @safe {
        if (repo.length == 0 || repo == "OWNER/REPO") return false;
        if (!repo.canFind('/')) return false;
        if (public_key.length == 0) return false;
        return true;
    }
}

struct PrivacyConfig {
    bool expose_serials = false;
    bool expose_mac_addresses = false;
}

/// How hikari serves its dashboard over HTTPS. `auto` joins an existing Caddy when every
/// safety check passes and otherwise runs the isolated hikari-caddy; `integrate` requires
/// joining; `isolated` never touches an existing Caddy; `snippet` only writes a snippet.
struct CaddyConfig {
    string mode = "auto";
    bool reload = false; // reload an existing Caddy after integrating (otherwise print the command)
}

struct PathsConfig {
    version (Windows) {
        string state_dir = `C:\ProgramData\hikari\state`;
        string config_dir = `C:\ProgramData\hikari\config`;
        string versions_dir = `C:\ProgramData\hikari\versions`;
    } else version (OSX) {
        string state_dir = "/Library/Application Support/hikari/state";
        string config_dir = "/Library/Application Support/hikari";
        string versions_dir = "/opt/hikari/versions";
    } else {
        string state_dir = "/var/lib/hikari";
        string config_dir = "/etc/hikari";
        string versions_dir = "/opt/hikari/versions";
    }
    string web_dir = "web";
}

string defaultConfigPath() pure nothrow @safe {
    version (Windows) {
        return PathsConfig.init.config_dir ~ `\config.json`;
    } else {
        return PathsConfig.init.config_dir ~ "/config.json";
    }
}

struct HikariConfig {
    int schema_version = SCHEMA_VERSION;
    ListenConfig listen;
    CollectionConfig collection;
    DiscoveryConfig discovery;
    UpdatesConfig updates;
    PrivacyConfig privacy;
    PathsConfig paths;
    CaddyConfig caddy;
    string tailscale_fixture;
    // Preserves unknown operator keys across config round-trips
    JSONValue[string] extra_top_level;
}

bool isLoopbackBindAddress(string addr) pure nothrow @safe {
    return addr == "127.0.0.1" || addr == "::1" || addr == "localhost";
}

string normalizeBasePath(string bp) pure nothrow @safe {
    auto s = bp.strip();
    if (s.length == 0 || s == "/") return "/";
    if (!s.startsWith("/")) s = "/" ~ s;
    while (s.length > 1 && s.endsWith("/")) {
        s = s[0 .. $ - 1];
    }
    return s;
}

void validateConfig(const ref HikariConfig cfg) {
    if (cfg.schema_version != SCHEMA_VERSION) {
        throw new Exception("Unsupported config schema_version: " ~ to!string(cfg.schema_version));
    }
    if (!isLoopbackBindAddress(cfg.listen.loopback_bind)) {
        throw new Exception("Security violation: loopback_bind must be 127.0.0.1 or ::1, got: " ~ cfg.listen.loopback_bind);
    }
    if (cfg.listen.loopback_port == 0 || cfg.listen.tailnet_port == 0) {
        throw new Exception("Ports must be non-zero");
    }
    if (!["auto", "integrate", "isolated", "snippet"].canFind(cfg.caddy.mode)) {
        throw new Exception("caddy.mode must be one of auto, integrate, isolated, snippet; got: " ~ cfg.caddy.mode);
    }
    if (cfg.updates.check_interval_hours == 0 || cfg.updates.check_interval_hours > 8760)
        throw new Exception("updates.check_interval_hours must be between 1 and 8760");
    if (cfg.discovery.max_concurrent_probes == 0 || cfg.discovery.max_concurrent_probes > 32) {
        throw new Exception("discovery.max_concurrent_probes must be between 1 and 32");
    }
    if (cfg.collection.ttl_seconds.fast <= 0 || cfg.collection.max_stale_seconds.fast < cfg.collection.ttl_seconds.fast) {
        throw new Exception("Invalid collection TTL/max_stale for fast group");
    }
}

private long readLongField(const ref JSONValue obj, string key, long fallback) {
    if (obj.type != JSONType.object) return fallback;
    if (auto p = key in obj.object) {
        if (p.type == JSONType.integer) return p.integer;
        if (p.type == JSONType.uinteger) return cast(long) p.uinteger;
    }
    return fallback;
}

private string readStringField(const ref JSONValue obj, string key, string fallback) {
    if (obj.type != JSONType.object) return fallback;
    if (auto p = key in obj.object) {
        if (p.type == JSONType.string) return p.str;
    }
    return fallback;
}

private bool readBoolField(const ref JSONValue obj, string key, bool fallback) {
    if (obj.type != JSONType.object) return fallback;
    if (auto p = key in obj.object) {
        if (p.type == JSONType.true_) return true;
        if (p.type == JSONType.false_) return false;
    }
    return fallback;
}

HikariConfig parseConfigJson(string content) {
    HikariConfig cfg;
    JSONValue root;
    try {
        root = parseJSON(content);
    } catch (JSONException e) {
        throw new Exception("Invalid JSON in config: " ~ e.msg);
    }
    if (root.type != JSONType.object) {
        throw new Exception("Config root must be a JSON object");
    }

    cfg.schema_version = cast(int) readLongField(root, "schema_version", SCHEMA_VERSION);

    if (auto pListen = "listen" in root.object) {
        if (pListen.type == JSONType.object) {
            cfg.listen.tailnet_port = cast(ushort) readLongField(*pListen, "tailnet_port", cfg.listen.tailnet_port);
            cfg.listen.loopback_port = cast(ushort) readLongField(*pListen, "loopback_port", cfg.listen.loopback_port);
            cfg.listen.loopback_bind = readStringField(*pListen, "loopback_bind", cfg.listen.loopback_bind);
            cfg.listen.base_path = normalizeBasePath(readStringField(*pListen, "base_path", cfg.listen.base_path));
            if (auto pOrig = "allowed_origins" in pListen.object) {
                if (pOrig.type == JSONType.array) {
                    foreach (el; pOrig.array) {
                        if (el.type == JSONType.string && el.str.length > 0) {
                            cfg.listen.allowed_origins ~= el.str;
                        }
                    }
                }
            }
        }
    }

    if (auto pCol = "collection" in root.object) {
        if (pCol.type == JSONType.object) {
            cfg.collection.cold_wait_ms = cast(uint) readLongField(*pCol, "cold_wait_ms", cfg.collection.cold_wait_ms);
            cfg.collection.probe_timeout_ms = cast(uint) readLongField(*pCol, "probe_timeout_ms", cfg.collection.probe_timeout_ms);
            if (auto pTtl = "ttl_seconds" in pCol.object) {
                cfg.collection.ttl_seconds.fast = readLongField(*pTtl, "fast", cfg.collection.ttl_seconds.fast);
                cfg.collection.ttl_seconds.processes = readLongField(*pTtl, "processes", cfg.collection.ttl_seconds.processes);
                cfg.collection.ttl_seconds.device_dynamic = readLongField(*pTtl, "device_dynamic", cfg.collection.ttl_seconds.device_dynamic);
                cfg.collection.ttl_seconds.filesystems = readLongField(*pTtl, "filesystems", cfg.collection.ttl_seconds.filesystems);
                cfg.collection.ttl_seconds.tailnet = readLongField(*pTtl, "tailnet", cfg.collection.ttl_seconds.tailnet);
                cfg.collection.ttl_seconds.maintenance = readLongField(*pTtl, "maintenance", cfg.collection.ttl_seconds.maintenance);
                cfg.collection.ttl_seconds.hardware = readLongField(*pTtl, "hardware", cfg.collection.ttl_seconds.hardware);
            }
            if (auto pMax = "max_stale_seconds" in pCol.object) {
                cfg.collection.max_stale_seconds.fast = readLongField(*pMax, "fast", cfg.collection.max_stale_seconds.fast);
                cfg.collection.max_stale_seconds.processes = readLongField(*pMax, "processes", cfg.collection.max_stale_seconds.processes);
                cfg.collection.max_stale_seconds.device_dynamic = readLongField(*pMax, "device_dynamic", cfg.collection.max_stale_seconds.device_dynamic);
                cfg.collection.max_stale_seconds.filesystems = readLongField(*pMax, "filesystems", cfg.collection.max_stale_seconds.filesystems);
                cfg.collection.max_stale_seconds.tailnet = readLongField(*pMax, "tailnet", cfg.collection.max_stale_seconds.tailnet);
                cfg.collection.max_stale_seconds.maintenance = readLongField(*pMax, "maintenance", cfg.collection.max_stale_seconds.maintenance);
                cfg.collection.max_stale_seconds.hardware = readLongField(*pMax, "hardware", cfg.collection.max_stale_seconds.hardware);
            }
        }
    }

    if (auto pDisc = "discovery" in root.object) {
        if (pDisc.type == JSONType.object) {
            cfg.discovery.enabled_on_dashboard_open = readBoolField(*pDisc, "enabled_on_dashboard_open", cfg.discovery.enabled_on_dashboard_open);
            cfg.discovery.max_concurrent_probes = cast(uint) readLongField(*pDisc, "max_concurrent_probes", cfg.discovery.max_concurrent_probes);
            cfg.discovery.probe_timeout_ms = cast(uint) readLongField(*pDisc, "probe_timeout_ms", cfg.discovery.probe_timeout_ms);
        }
    }

    if (auto pUpd = "updates" in root.object) {
        if (pUpd.type == JSONType.object) {
            cfg.updates.repo = readStringField(*pUpd, "repo", cfg.updates.repo);
            string m = readStringField(*pUpd, "mode", cast(string) cfg.updates.mode);
            if (m == "manual") cfg.updates.mode = UpdateMode.manual;
            else if (m == "scheduled") cfg.updates.mode = UpdateMode.scheduled;
            else cfg.updates.mode = UpdateMode.on_dashboard_open;
            cfg.updates.auto_install_verified = readBoolField(*pUpd, "auto_install_verified", cfg.updates.auto_install_verified);
            cfg.updates.check_interval_hours = cast(uint) readLongField(*pUpd, "check_interval_hours", cfg.updates.check_interval_hours);
            cfg.updates.public_key = readStringField(*pUpd, "public_key", cfg.updates.public_key);
            cfg.updates.channel = readStringField(*pUpd, "channel", cfg.updates.channel);
        }
    }

    if (auto pPriv = "privacy" in root.object) {
        if (pPriv.type == JSONType.object) {
            cfg.privacy.expose_serials = readBoolField(*pPriv, "expose_serials", cfg.privacy.expose_serials);
            cfg.privacy.expose_mac_addresses = readBoolField(*pPriv, "expose_mac_addresses", cfg.privacy.expose_mac_addresses);
        }
    }

    if (auto pPaths = "paths" in root.object) {
        if (pPaths.type == JSONType.object) {
            cfg.paths.state_dir = readStringField(*pPaths, "state_dir", cfg.paths.state_dir);
            cfg.paths.config_dir = readStringField(*pPaths, "config_dir", cfg.paths.config_dir);
            cfg.paths.versions_dir = readStringField(*pPaths, "versions_dir", cfg.paths.versions_dir);
            cfg.paths.web_dir = readStringField(*pPaths, "web_dir", cfg.paths.web_dir);
        }
    }

    if (auto pCaddy = "caddy" in root.object) {
        if (pCaddy.type == JSONType.object) {
            cfg.caddy.mode = readStringField(*pCaddy, "mode", cfg.caddy.mode);
            cfg.caddy.reload = readBoolField(*pCaddy, "reload", cfg.caddy.reload);
        }
    }

    cfg.tailscale_fixture = readStringField(root, "tailscale_fixture", "");

    enum knownTop = ["schema_version", "listen", "collection", "discovery", "updates", "privacy", "paths", "caddy", "tailscale_fixture"];
    foreach (k, v; root.object) {
        if (!knownTop.canFind(k)) {
            cfg.extra_top_level[k] = v;
        }
    }

    validateConfig(cfg);
    return cfg;
}

HikariConfig loadConfig(string path) {
    if (!exists(path)) {
        HikariConfig cfg;
        validateConfig(cfg);
        return cfg;
    }
    return parseConfigJson(readText(path));
}

JSONValue configToJson(const ref HikariConfig cfg) {
    JSONValue root = JSONValue.emptyObject;
    foreach (k, v; cfg.extra_top_level) {
        root[k] = v;
    }
    root["schema_version"] = cfg.schema_version;

    JSONValue listen = JSONValue.emptyObject;
    listen["tailnet_port"] = cfg.listen.tailnet_port;
    listen["loopback_port"] = cfg.listen.loopback_port;
    listen["loopback_bind"] = cfg.listen.loopback_bind;
    listen["base_path"] = normalizeBasePath(cfg.listen.base_path);
    if (cfg.listen.allowed_origins.length > 0) {
        JSONValue[] origs;
        foreach (o; cfg.listen.allowed_origins) origs ~= JSONValue(o);
        listen["allowed_origins"] = JSONValue(origs);
    }
    root["listen"] = listen;

    JSONValue ttl = JSONValue.emptyObject;
    ttl["fast"] = cfg.collection.ttl_seconds.fast;
    ttl["processes"] = cfg.collection.ttl_seconds.processes;
    ttl["device_dynamic"] = cfg.collection.ttl_seconds.device_dynamic;
    ttl["filesystems"] = cfg.collection.ttl_seconds.filesystems;
    ttl["tailnet"] = cfg.collection.ttl_seconds.tailnet;
    ttl["maintenance"] = cfg.collection.ttl_seconds.maintenance;
    ttl["hardware"] = cfg.collection.ttl_seconds.hardware;

    JSONValue maxStale = JSONValue.emptyObject;
    maxStale["fast"] = cfg.collection.max_stale_seconds.fast;
    maxStale["processes"] = cfg.collection.max_stale_seconds.processes;
    maxStale["device_dynamic"] = cfg.collection.max_stale_seconds.device_dynamic;
    maxStale["filesystems"] = cfg.collection.max_stale_seconds.filesystems;
    maxStale["tailnet"] = cfg.collection.max_stale_seconds.tailnet;
    maxStale["maintenance"] = cfg.collection.max_stale_seconds.maintenance;
    maxStale["hardware"] = cfg.collection.max_stale_seconds.hardware;

    JSONValue col = JSONValue.emptyObject;
    col["ttl_seconds"] = ttl;
    col["max_stale_seconds"] = maxStale;
    col["cold_wait_ms"] = cfg.collection.cold_wait_ms;
    col["probe_timeout_ms"] = cfg.collection.probe_timeout_ms;
    root["collection"] = col;

    JSONValue disc = JSONValue.emptyObject;
    disc["enabled_on_dashboard_open"] = cfg.discovery.enabled_on_dashboard_open;
    disc["max_concurrent_probes"] = cfg.discovery.max_concurrent_probes;
    disc["probe_timeout_ms"] = cfg.discovery.probe_timeout_ms;
    root["discovery"] = disc;

    JSONValue upd = JSONValue.emptyObject;
    upd["repo"] = cfg.updates.repo;
    upd["mode"] = cast(string) cfg.updates.mode;
    upd["auto_install_verified"] = cfg.updates.auto_install_verified;
    upd["check_interval_hours"] = cfg.updates.check_interval_hours;
    upd["public_key"] = cfg.updates.public_key;
    upd["channel"] = cfg.updates.channel;
    root["updates"] = upd;

    JSONValue priv = JSONValue.emptyObject;
    priv["expose_serials"] = cfg.privacy.expose_serials;
    priv["expose_mac_addresses"] = cfg.privacy.expose_mac_addresses;
    root["privacy"] = priv;

    JSONValue paths = JSONValue.emptyObject;
    paths["state_dir"] = cfg.paths.state_dir;
    paths["config_dir"] = cfg.paths.config_dir;
    paths["versions_dir"] = cfg.paths.versions_dir;
    paths["web_dir"] = cfg.paths.web_dir;
    root["paths"] = paths;

    JSONValue caddy = JSONValue.emptyObject;
    caddy["mode"] = cfg.caddy.mode;
    caddy["reload"] = cfg.caddy.reload;
    root["caddy"] = caddy;

    return root;
}

void saveConfig(string path, const ref HikariConfig cfg) {
    validateConfig(cfg);
    auto parent = dirName(path);
    if (!exists(parent)) mkdirRecurse(parent);
    auto tmpPath = path ~ ".tmp";
    auto text = configToJson(cfg).toPrettyString(JSONOptions.doNotEscapeSlashes) ~ "\n";
    write(tmpPath, text);
    rename(tmpPath, path);
}

string loadOrCreateNodeId(string stateDir) {
    auto idFile = stateDir ~ "/node_id";
    if (exists(idFile)) {
        auto existing = readText(idFile).strip();
        if (existing.startsWith("hikari:") && existing.length > 10) {
            return existing;
        }
    }
    auto rng = Mt19937(unpredictableSeed);
    uint[4] parts;
    foreach (ref p; parts) {
        p = rng.front;
        rng.popFront();
    }
    auto uuid = format!"hikari:%08x-%04x-%04x-%04x-%04x%08x"(
        parts[0],
        (parts[1] >> 16) & 0xFFFF,
        ((parts[1] & 0x0FFF) | 0x4000),
        ((parts[2] >> 16) & 0x3FFF) | 0x8000,
        parts[2] & 0xFFFF,
        parts[3]
    );
    try {
        if (!exists(stateDir)) mkdirRecurse(stateDir);
        auto tmp = idFile ~ ".tmp";
        write(tmp, uuid ~ "\n");
        rename(tmp, idFile);
    } catch (Exception) {
        // Return generated ephemeral ID if state dir is read-only
    }
    return uuid;
}
