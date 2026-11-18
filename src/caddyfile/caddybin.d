module caddyfile.caddybin;

// Talks to a real Caddy binary for ground truth: `caddy version`, `caddy adapt` (pure:
// Caddyfile -> JSON, no network, no servers, no storage writes) and `caddy reload`.
// Also implements the "original config is unchanged" comparison used before any edit.

import std.algorithm : canFind, sort;
import std.array : array, join, replace;
import std.conv : to;
import std.json;
import std.string : indexOf, split, startsWith, strip;

struct RunResult {
    int status = -1;
    bool timedOut;
    string stdout_;
    string stderr_;
}

/// Runs a command with a hard timeout. Output goes through temp files (no pipe deadlocks).
/// Storage-related environment variables point at a throwaway directory so even a
/// misbehaving Caddy subcommand cannot write into the user's real Caddy data.
RunResult runIsolated(string[] argv, uint timeoutMs = 20_000, bool isolateStorage = true) @trusted {
    import core.thread : Thread;
    import core.time : msecs;
    import std.file : exists, mkdirRecurse, readText, remove, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : Config, kill, spawnProcess, tryWait;
    import std.stdio : File;
    import std.uuid : randomUUID;

    RunResult r;
    auto work = buildPath(tempDir(), "hikari-caddy-run-" ~ randomUUID().toString()[0 .. 8]);
    mkdirRecurse(work);
    scope (exit) removeQuietly(work);
    auto outPath = buildPath(work, "out");
    auto errPath = buildPath(work, "err");
    string[string] env;
    if (isolateStorage) {
        auto home = buildPath(work, "home");
        mkdirRecurse(home);
        foreach (k; ["HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "APPDATA", "LOCALAPPDATA", "USERPROFILE"]) env[k] = home;
    }
    try {
        auto outF = File(outPath, "wb");
        auto errF = File(errPath, "wb");
        auto pid = spawnProcess(argv, File.init, outF, errF, env, Config.none);
        outF.close();
        errF.close();
        uint waited = 0;
        while (true) {
            auto w = tryWait(pid);
            if (w.terminated) {
                r.status = w.status;
                break;
            }
            if (waited >= timeoutMs) {
                kill(pid);
                r.timedOut = true;
                break;
            }
            Thread.sleep(msecs(50));
            waited += 50;
        }
        if (exists(outPath)) r.stdout_ = readText(outPath);
        if (exists(errPath)) r.stderr_ = readText(errPath);
    } catch (Exception e) {
        r.stderr_ = e.msg;
    }
    return r;
}

private void removeQuietly(string dir) nothrow @trusted {
    import std.file : rmdirRecurse;
    try { rmdirRecurse(dir); } catch (Exception) {}
}

/// Parses `caddy version` output like "v2.9.1 h1:..." into [2, 9, 1]; empty on failure.
uint[] parseCaddyVersion(string s) pure @safe {
    auto t = s.strip();
    if (t.startsWith("v")) t = t[1 .. $];
    auto sp = t.indexOf(' ');
    if (sp >= 0) t = t[0 .. sp];
    auto dash = t.indexOf('-');
    if (dash >= 0) t = t[0 .. dash];
    uint[] parts;
    foreach (p; t.split(".")) {
        try { parts ~= to!uint(p); } catch (Exception) { return null; }
    }
    return parts.length >= 2 ? parts : null;
}

bool versionAtLeast(const uint[] v, uint major, uint minor) pure nothrow @safe {
    if (v.length < 2) return false;
    return v[0] > major || (v[0] == major && v[1] >= minor);
}

uint[] caddyVersion(string bin) @safe {
    auto r = runIsolated([bin, "version"], 10_000);
    return r.status == 0 ? parseCaddyVersion(r.stdout_) : null;
}

struct AdaptResult {
    bool ok;
    string json;
    string error;
}

AdaptResult caddyAdapt(string bin, string caddyfile) @safe {
    AdaptResult a;
    auto r = runIsolated([bin, "adapt", "--config", caddyfile, "--adapter", "caddyfile"], 30_000);
    if (r.timedOut) { a.error = "caddy adapt timed out"; return a; }
    if (r.status != 0) { a.error = (r.stderr_.length > 0 ? r.stderr_ : r.stdout_).strip(); return a; }
    a.ok = true;
    a.json = r.stdout_;
    return a;
}

// ---------------------------------------------------------------------------
// JSON comparison: is the original configuration fully preserved?
// ---------------------------------------------------------------------------

/// Canonical JSON text with sorted object keys (std.json's key order is unspecified).
string canonicalJson(const JSONValue v) @safe {
    final switch (v.type) {
        case JSONType.object: {
            auto obj = v.objectNoRef;
            auto keys = obj.keys.dup;
            sort(keys);
            string s = "{";
            foreach (i, k; keys) {
                if (i > 0) s ~= ",";
                s ~= JSONValue(k).toString() ~ ":" ~ canonicalJson(obj[k]);
            }
            return s ~ "}";
        }
        case JSONType.array: {
            string s = "[";
            foreach (i, e; v.arrayNoRef) {
                if (i > 0) s ~= ",";
                s ~= canonicalJson(e);
            }
            return s ~ "]";
        }
        case JSONType.string: return JSONValue(v.str).toString();
        case JSONType.integer: return to!string(v.integer);
        case JSONType.uinteger: return to!string(v.uinteger);
        case JSONType.float_: return to!string(v.floating);
        case JSONType.true_: return "true";
        case JSONType.false_: return "false";
        case JSONType.null_: return "null";
    }
}

private string normListen(string l) pure @safe {
    if (l.startsWith("tcp/")) return l[4 .. $];
    return l;
}

/// Listen addresses of every HTTP server in an adapted config, normalized.
string[] adaptedListeners(string adaptedJson) @safe {
    string[] r;
    auto j = parseJSON(adaptedJson);
    if (j.type != JSONType.object) return r;
    auto apps = "apps" in j.objectNoRef;
    if (apps is null || apps.type != JSONType.object) return r;
    auto http = "http" in apps.objectNoRef;
    if (http is null || http.type != JSONType.object) return r;
    auto servers = "servers" in http.objectNoRef;
    if (servers is null || servers.type != JSONType.object) return r;
    foreach (name, srv; servers.objectNoRef) {
        if (auto l = "listen" in srv.objectNoRef) {
            foreach (e; l.arrayNoRef) r ~= normListen(e.str);
        }
    }
    sort(r);
    return r;
}

struct PreservationCheck {
    bool ok;
    string[] problems;
    string[] addedListeners;
}

private JSONValue[string] objOrEmpty(const JSONValue* v) @trusted {
    if (v is null || v.type != JSONType.object) return null;
    return cast(JSONValue[string]) v.objectNoRef;
}

private string serverKey(const JSONValue srv) @safe {
    string[] ls;
    if (srv.type == JSONType.object) {
        if (auto l = "listen" in srv.objectNoRef) {
            foreach (e; l.arrayNoRef) ls ~= normListen(e.str);
        }
    }
    sort(ls);
    return ls.join(",");
}

/// Verifies that `after` keeps everything in `before` unchanged. The only permitted
/// differences are hikari's own: exactly one HTTP server listening on ip:port (new or
/// updated) and TLS automation policies whose subjects are only `fqdn`.
PreservationCheck checkPreservation(string beforeJson, string afterJson, string ip, ushort port, string fqdn,
        const string[2][] pathAliases = null) @safe {
    PreservationCheck c;
    JSONValue b, a;
    try {
        b = parseJSON(beforeJson.length > 0 ? beforeJson : "{}");
        // Candidate files have different names than the real ones; Caddy embeds the config
        // path (e.g. file_server's auto "hide" list), so map candidate paths back first.
        string at = afterJson.length > 0 ? afterJson : "{}";
        foreach (al; pathAliases) at = at.replace(jsonInner(al[0]), jsonInner(al[1]));
        a = parseJSON(at);
    } catch (Exception e) {
        c.problems ~= "unparseable adapt output: " ~ e.msg;
        return c;
    }
    auto bo = b.type == JSONType.object ? cast(JSONValue[string]) b.objectNoRef : null;
    auto ao = a.type == JSONType.object ? cast(JSONValue[string]) a.objectNoRef : null;

    // Top level (admin, logging, storage, ...) must be identical apart from "apps".
    foreach (k, v; bo) {
        if (k == "apps") continue;
        auto av = k in ao;
        if (av is null || canonicalJson(*av) != canonicalJson(v)) c.problems ~= "top-level `" ~ k ~ "` changed";
    }
    foreach (k, v; ao) if (k != "apps" && (k in bo) is null) c.problems ~= "top-level `" ~ k ~ "` added";

    auto bApps = objOrEmpty(k_in(bo, "apps"));
    auto aApps = objOrEmpty(k_in(ao, "apps"));
    foreach (k, v; bApps) {
        if (k == "http" || k == "tls") continue;
        auto av = k in aApps;
        if (av is null || canonicalJson(*av) != canonicalJson(v)) c.problems ~= "app `" ~ k ~ "` changed";
    }
    foreach (k, v; aApps) if (k != "http" && k != "tls" && (k in bApps) is null) c.problems ~= "app `" ~ k ~ "` added";

    // HTTP servers, keyed by listen addresses (server names like srv0 may be renumbered).
    auto bHttp = objOrEmpty(k_in(bApps, "http"));
    auto aHttp = objOrEmpty(k_in(aApps, "http"));
    foreach (k, v; bHttp) {
        if (k == "servers") continue;
        auto av = k in aHttp;
        if (av is null || canonicalJson(*av) != canonicalJson(v)) c.problems ~= "http option `" ~ k ~ "` changed";
    }
    auto expected = ip ~ ":" ~ to!string(port);
    auto expected6 = "[" ~ ip ~ "]:" ~ to!string(port);
    bool isOurs(string key) { return key == expected || key == expected6; }
    string[string] bServers, aServers;
    foreach (name, srv; objOrEmpty(k_in(bHttp, "servers"))) bServers[serverKey(srv)] = canonicalJson(renumberGroups(srv));
    foreach (name, srv; objOrEmpty(k_in(aHttp, "servers"))) aServers[serverKey(srv)] = canonicalJson(renumberGroups(srv));
    foreach (key, txt; bServers) {
        if (isOurs(key)) continue; // hikari's own site from an earlier integration may change
        auto av = key in aServers;
        if (av is null) c.problems ~= "server listening on [" ~ key ~ "] disappeared";
        else if (*av != txt) c.problems ~= "server listening on [" ~ key ~ "] changed";
    }
    size_t ours = 0;
    foreach (key, txt; aServers) {
        if (isOurs(key)) {
            ours++;
            c.addedListeners ~= key;
            continue;
        }
        if ((key in bServers) is null) c.problems ~= "unexpected new server listening on [" ~ key ~ "]";
    }
    if (ours != 1) c.problems ~= "expected exactly one hikari server on " ~ expected ~ ", found " ~ to!string(ours);

    // TLS: every original policy kept verbatim; new policies may only name our FQDN.
    auto bTls = objOrEmpty(k_in(bApps, "tls"));
    auto aTls = objOrEmpty(k_in(aApps, "tls"));
    foreach (k, v; bTls) {
        if (k == "automation") continue;
        auto av = k in aTls;
        if (av is null || canonicalJson(*av) != canonicalJson(v)) c.problems ~= "tls `" ~ k ~ "` changed";
    }
    string[] bPol, aPol;
    JSONValue[] aPolRaw, bPolRaw;
    if (auto ba = k_in(bTls, "automation")) {
        foreach (k, v; objOrEmpty(ba)) {
            if (k == "policies") foreach (p; v.arrayNoRef) { bPol ~= canonicalJson(p); bPolRaw ~= p; }
            else {
                auto aa = objOrEmpty(k_in(aTls, "automation"));
                auto av = k in aa;
                if (av is null || canonicalJson(*av) != canonicalJson(v)) c.problems ~= "tls automation `" ~ k ~ "` changed";
            }
        }
    }
    if (auto aa = k_in(aTls, "automation")) {
        if (auto pp = "policies" in objOrEmpty(aa)) {
            foreach (p; pp.arrayNoRef) {
                aPol ~= canonicalJson(p);
                aPolRaw ~= p;
            }
        }
    }
    bool[string] beforeHosts;
    collectHosts(b, beforeHosts);
    string catchAll = "{}";
    foreach (i, raw; bPolRaw) {
        if (raw.type == JSONType.object && ("subjects" in raw.objectNoRef) is null) catchAll = canonicalJson(raw);
    }
    foreach (i, p; bPol) {
        if (onlySubject(bPolRaw[i], fqdn)) continue; // hikari's own policy may change
        if (!aPol.canFind(p)) c.problems ~= "a TLS automation policy changed or disappeared";
    }
    foreach (i, p; aPol) {
        if (bPol.canFind(p)) continue;
        if (onlySubject(aPolRaw[i], fqdn)) continue;
        // Once any explicit policy exists, Caddy lists the other sites' names in policies of
        // their own. That is harmless only if the policy behaves exactly like the original
        // catch-all (or like having no policy at all), i.e. same settings minus subjects.
        if (withoutSubjects(aPolRaw[i]) == catchAll && subjectsWithin(aPolRaw[i], beforeHosts)) continue;
        c.problems ~= "new TLS policy for other names differs from the original default behaviour";
    }

    c.ok = c.problems.length == 0;
    return c;
}

/// JSON string contents (without quotes) of `s`, as it appears inside adapt output.
private string jsonInner(string s) @safe {
    // Caddy (Go) does not escape '/', std.json does by default: match Caddy's output.
    auto t = JSONValue(s).toString(JSONOptions.doNotEscapeSlashes);
    return t[1 .. $ - 1];
}

/// Caddy names `handle` groups globally ("group0", "group1", ...), so adding a site can
/// renumber groups in unrelated servers. Groups are only labels for mutual exclusion; rename
/// them per server in order of first appearance so equal configs compare equal.
JSONValue renumberGroups(const JSONValue srv) @trusted {
    string[string] map;
    // Object key iteration order is unspecified; number groups by a deterministic
    // traversal: route arrays are ordered, and "group" sits directly inside route objects.
    return walkOrdered(srv, map);
}

private JSONValue walkOrdered(const JSONValue v, ref string[string] map) @trusted {
    switch (v.type) {
        case JSONType.object: {
            JSONValue[string] o;
            auto keys = v.objectNoRef.keys.dup;
            sort(keys);
            foreach (k; keys) {
                auto e = v.objectNoRef[k];
                if (k == "group" && e.type == JSONType.string) {
                    if ((e.str in map) is null) map[e.str] = "g" ~ to!string(map.length);
                    o[k] = JSONValue(map[e.str]);
                } else {
                    o[k] = walkOrdered(e, map);
                }
            }
            return JSONValue(o);
        }
        case JSONType.array: {
            JSONValue[] arr;
            foreach (e; v.arrayNoRef) arr ~= walkOrdered(e, map);
            return JSONValue(arr);
        }
        default:
            return cast(JSONValue) v;
    }
}

/// Every string under a "host" matcher anywhere in the config.
private void collectHosts(const JSONValue v, ref bool[string] hosts) @trusted {
    if (v.type == JSONType.object) {
        foreach (k, e; v.objectNoRef) {
            if (k == "host" && e.type == JSONType.array) {
                foreach (h; e.arrayNoRef) if (h.type == JSONType.string) hosts[h.str] = true;
            } else {
                collectHosts(e, hosts);
            }
        }
    } else if (v.type == JSONType.array) {
        foreach (e; v.arrayNoRef) collectHosts(e, hosts);
    }
}

private bool subjectsWithin(const JSONValue pol, const bool[string] hosts) @trusted {
    if (pol.type != JSONType.object) return false;
    auto subj = "subjects" in pol.objectNoRef;
    if (subj is null) return true; // catch-all; the caller already required it to equal the original default
    if (subj.type != JSONType.array) return false;
    foreach (s; subj.arrayNoRef) if (s.type != JSONType.string || (s.str in hosts) is null) return false;
    return true;
}

private string withoutSubjects(const JSONValue pol) @safe {
    if (pol.type != JSONType.object) return canonicalJson(pol);
    JSONValue[string] o;
    foreach (k, e; pol.objectNoRef) if (k != "subjects") o[k] = cast(JSONValue) e;
    return canonicalJson(JSONValue(o));
}

private bool onlySubject(const JSONValue pol, string fqdn) @safe {
    if (pol.type != JSONType.object) return false;
    auto subj = "subjects" in pol.objectNoRef;
    if (subj is null || subj.type != JSONType.array || subj.arrayNoRef.length == 0) return false;
    foreach (s; subj.arrayNoRef) if (s.type != JSONType.string || s.str != fqdn) return false;
    return true;
}

private const(JSONValue)* k_in(JSONValue[string] o, string k) @safe {
    if (o is null) return null;
    return k in o;
}
