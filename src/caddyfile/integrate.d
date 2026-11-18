module caddyfile.integrate;

// Orchestrates adding hikari's site to an existing Caddy and removing it again.
// Order of operations for a real run:
//   1. analyse (read-only) and refuse anything uncertain;
//   2. `caddy adapt` the original; it must succeed (never touch a broken config);
//   3. build candidate files beside the Caddyfile and `caddy adapt` them;
//   4. require the original config to be preserved exactly (checkPreservation);
//   5. back up, write atomically, adapt the real result again, roll back on any doubt;
//   6. reload only when asked, rolling back and reloading again if that fails.

import caddyfile.analyze;
import caddyfile.caddybin;
import caddyfile.edit;
import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, isSymlink, readText, remove, write;
import std.path : baseName, buildNormalizedPath, dirName;
import std.string : join, strip;

/// What an integration actually did, persisted in hikari's state directory so repair,
/// mode switches and uninstall act on exactly that (even if the Caddy service is renamed).
struct IntegrationRecord {
    string mode;       // append_import | drop_in
    string caddyfile;
    string siteFile;
    string service;
    string manager;
    string caddyBin;
    long integratedAt;
}

enum INTEGRATION_RECORD_FILE = "caddy-integration.json";

string integrationRecordPath(string stateDir) pure @safe {
    import std.path : buildPath;
    return buildPath(stateDir, INTEGRATION_RECORD_FILE);
}

void saveIntegrationRecord(string stateDir, const IntegrationRecord r) @safe {
    import std.file : mkdirRecurse;
    import std.json : JSONOptions, JSONValue;
    if (!exists(stateDir)) mkdirRecurse(stateDir);
    JSONValue j = JSONValue.emptyObject;
    j["mode"] = r.mode;
    j["caddyfile"] = r.caddyfile;
    j["site_file"] = r.siteFile;
    j["service"] = r.service;
    j["manager"] = r.manager;
    j["caddy_bin"] = r.caddyBin;
    j["integrated_at"] = r.integratedAt;
    atomicReplace(integrationRecordPath(stateDir), j.toPrettyString(JSONOptions.doNotEscapeSlashes) ~ "\n");
}

bool loadIntegrationRecord(string stateDir, out IntegrationRecord r) @trusted {
    import std.json : JSONType, parseJSON;
    auto p = integrationRecordPath(stateDir);
    if (!exists(p)) return false;
    try {
        auto j = parseJSON(readText(p));
        string str(string k) { auto v = k in j.object; return v !is null && v.type == JSONType.string ? v.str : ""; }
        r.mode = str("mode");
        r.caddyfile = str("caddyfile");
        r.siteFile = str("site_file");
        r.service = str("service");
        r.manager = str("manager");
        r.caddyBin = str("caddy_bin");
        if (auto v = "integrated_at" in j.object) if (v.type == JSONType.integer) r.integratedAt = v.integer;
        return r.caddyfile.length > 0;
    } catch (Exception) {
        return false;
    }
}

void removeIntegrationRecord(string stateDir) @safe {
    removeIfExists(integrationRecordPath(stateDir));
}

struct IntegrateOptions {
    string caddyfile;
    string caddyBin;
    string fqdn;
    string ip;
    ushort port = 9100;
    ushort loopbackPort = 19100;
    string basePath = "/";
    string webDir;
    bool dryRun;
    bool reload;
    string service;   // existing Caddy service (for reload via its manager)
    string manager;   // systemd | launchd | scm | ""
}

struct IntegrateOutcome {
    bool ok;
    bool changed;
    string mode;          // append_import | drop_in | removed | none
    string message;
    string diff;
    string backup;
    string siteFile;
    string[] problems;
    bool verified;        // adapt-based preservation check ran and passed
    string reloadNote;
}

private string readOr(string path, string fallback) @safe {
    try { return readText(path); } catch (Exception) { return fallback; }
}

private void removeIfExists(string path) @safe nothrow {
    try { if (exists(path)) remove(path); } catch (Exception) {}
}

/// Reloads the operator's Caddy: via its own systemd unit when known, otherwise through
/// `caddy reload` against the config's admin endpoint. Never restarts the server.
string reloadExistingCaddy(const IntegrateOptions o, const CaddyfileReport r, out bool ok, out bool attempted) @safe {
    ok = false;
    attempted = true;
    if (o.manager == "systemd" && o.service.length > 0) {
        auto res = runIsolated(["systemctl", "reload", o.service], 60_000, false);
        ok = res.status == 0;
        return ok ? "reloaded " ~ o.service ~ " via systemd" : "systemctl reload " ~ o.service ~ " failed: " ~ res.stderr_.strip();
    }
    if (r.globals.admin == "off") {
        attempted = false;
        return "the existing Caddy has `admin off`, so it cannot be reloaded without a restart; restart it yourself when convenient";
    }
    if (o.caddyBin.length == 0) {
        attempted = false;
        return "no caddy binary available to run `caddy reload`";
    }
    auto res = runIsolated([o.caddyBin, "reload", "--config", o.caddyfile, "--adapter", "caddyfile"], 60_000, false);
    ok = res.status == 0;
    return ok ? "reloaded via `caddy reload`" : "`caddy reload` failed: " ~ (res.stderr_.length > 0 ? res.stderr_ : res.stdout_).strip();
}

string manualReloadHint(const IntegrateOptions o) pure @safe {
    if (o.manager == "systemd" && o.service.length > 0) return "sudo systemctl reload " ~ o.service;
    return "caddy reload --config \"" ~ o.caddyfile ~ "\" --adapter caddyfile";
}

IntegrateOutcome integrate(IntegrateOptions o) @safe {
    import http.caddy : renderIntegratedSite;
    IntegrateOutcome out_;

    version (Windows) {
        if (exists(o.caddyfile) && isSymlink(o.caddyfile)) {
            out_.message = "refusing to edit a symlinked Caddyfile on Windows: " ~ o.caddyfile;
            return out_;
        }
    }
    o.caddyfile = resolveRealPath(o.caddyfile);
    if (!exists(o.caddyfile)) {
        out_.message = "Caddyfile not found: " ~ o.caddyfile;
        return out_;
    }

    auto report = analyzeCaddyfile(o.caddyfile);
    auto verdict = integrationVerdict(report, o.fqdn, o.ip, o.port);
    if (!verdict.integrable) {
        out_.message = "not integrating: " ~ verdict.reason;
        return out_;
    }

    if (o.caddyBin.length > 0) {
        auto ver = caddyVersion(o.caddyBin);
        if (!versionAtLeast(ver, 2, 6)) {
            out_.message = "not integrating: Caddy 2.6 or newer is required (found " ~ (ver.length > 0 ? to!string(ver) : "unknown") ~ ")";
            return out_;
        }
    } else if (!o.dryRun) {
        out_.message = "not integrating: a caddy binary is required to verify the change (`caddy adapt`)";
        return out_;
    }

    auto mainSrc = readText(o.caddyfile);
    string siteText;
    try {
        siteText = renderIntegratedSite(o.fqdn, o.port, o.ip, o.loopbackPort, o.basePath, o.webDir);
    } catch (Exception e) {
        out_.message = "not integrating: " ~ e.msg;
        return out_;
    }

    IntegrationPlan plan;
    try {
        plan = planIntegration(report, mainSrc, siteText);
    } catch (IntegrationError e) {
        out_.message = "not integrating: " ~ e.msg;
        return out_;
    }
    out_.mode = plan.mode == PlanMode.dropIn ? "drop_in" : "append_import";
    out_.siteFile = plan.siteFilePath;

    // Never overwrite a file at our site path that hikari did not write.
    bool siteExisted = exists(plan.siteFilePath);
    string oldSite = siteExisted ? readOr(plan.siteFilePath, "") : null;
    if (siteExisted && !isHikariSiteFile(oldSite)) {
        out_.message = "not integrating: " ~ plan.siteFilePath ~ " exists and was not written by hikari";
        return out_;
    }

    out_.diff = describeAppend(plan.mainOriginal, plan.mainNew, plan.mainPath);
    if (plan.mode == PlanMode.dropIn) out_.diff ~= "(new file " ~ plan.siteFilePath ~ "; main Caddyfile unchanged)\n";
    out_.changed = plan.mainChanged() || oldSite != siteText;

    // ---- verification with the real Caddy ----
    if (o.caddyBin.length > 0) {
        auto before = caddyAdapt(o.caddyBin, o.caddyfile);
        if (!before.ok) {
            out_.message = "not integrating: the existing Caddyfile does not adapt cleanly, so hikari will not touch it (" ~ before.error ~ ")";
            return out_;
        }
        auto dir = dirName(o.caddyfile);
        AdaptResult after;
        string[2][] aliases;
        if (plan.mode == PlanMode.appendImport) {
            auto candSite = buildNormalizedPath(dir, ".hikari-candidate-site");
            auto candMain = buildNormalizedPath(dir, "." ~ baseName(o.caddyfile) ~ ".hikari-candidate");
            scope (exit) { removeIfExists(candSite); removeIfExists(candMain); }
            write(candSite, siteText);
            write(candMain, appendImportBlock(removeImportBlock(mainSrc), ".hikari-candidate-site"));
            after = caddyAdapt(o.caddyBin, candMain);
            aliases = [[candMain, o.caddyfile], [candSite, plan.siteFilePath]];
        } else {
            // Drop-in: the glob picks the file up by name, so stage it at its final path and
            // put the previous content (or absence) back unless this is a real, verified run.
            write(plan.siteFilePath, siteText);
            after = caddyAdapt(o.caddyBin, o.caddyfile);
            if (siteExisted) write(plan.siteFilePath, oldSite); else removeIfExists(plan.siteFilePath);
        }
        if (!after.ok) {
            out_.message = "not integrating: Caddy rejected the candidate configuration (" ~ after.error ~ ")";
            return out_;
        }
        auto check = checkPreservation(before.json, after.json, o.ip, o.port, o.fqdn, aliases);
        if (!check.ok) {
            out_.problems = check.problems;
            out_.message = "not integrating: the change would alter the existing configuration (" ~ check.problems.join("; ") ~ ")";
            return out_;
        }
        out_.verified = true;

        if (o.dryRun) {
            out_.ok = true;
            out_.message = out_.changed ? "dry run: change verified, nothing written" : "dry run: already integrated, nothing to do";
            return out_;
        }

        if (!out_.changed) {
            out_.ok = true;
            out_.message = "already integrated; nothing changed";
            return out_;
        }

        // ---- apply ----
        string backup;
        try {
            if (plan.mainChanged()) backup = backupFile(o.caddyfile);
            atomicReplace(plan.siteFilePath, siteText);
            if (plan.mainChanged()) atomicReplace(o.caddyfile, plan.mainNew);
        } catch (Exception e) {
            rollback(o.caddyfile, backup, plan.siteFilePath, siteExisted, oldSite);
            out_.message = "write failed, restored original: " ~ e.msg;
            return out_;
        }
        out_.backup = backup;

        // ---- post-check on the real files ----
        auto final_ = caddyAdapt(o.caddyBin, o.caddyfile);
        auto post = final_.ok ? checkPreservation(before.json, final_.json, o.ip, o.port, o.fqdn) : PreservationCheck.init;
        if (!final_.ok || !post.ok) {
            rollback(o.caddyfile, backup, plan.siteFilePath, siteExisted, oldSite);
            out_.message = "post-write verification failed, restored original: " ~ (final_.ok ? post.problems.join("; ") : final_.error);
            return out_;
        }

        out_.ok = true;
        out_.message = "integrated into " ~ o.caddyfile ~ " (" ~ out_.mode ~ ")";
        if (o.reload) {
            bool rok, attempted;
            out_.reloadNote = reloadExistingCaddy(o, report, rok, attempted);
            if (attempted && !rok) {
                // Reload attempted and failed: put everything back and reload again.
                rollback(o.caddyfile, backup, plan.siteFilePath, siteExisted, oldSite);
                bool again, att2;
                auto note2 = reloadExistingCaddy(o, report, again, att2);
                out_.ok = false;
                out_.message = "reload failed, restored original configuration (" ~ out_.reloadNote ~ "; second reload: " ~ note2 ~ ")";
            }
        } else {
            out_.reloadNote = "not reloaded; apply with: " ~ manualReloadHint(o);
        }
        return out_;
    }

    // Dry run without a caddy binary: structural plan only.
    out_.ok = true;
    out_.message = "dry run (unverified: no caddy binary given): this is the change hikari would make";
    return out_;
}

private void rollback(string caddyfile, string backup, string siteFile, bool siteExisted, string oldSite) @safe nothrow {
    try {
        if (backup.length > 0 && exists(backup)) atomicReplace(caddyfile, readText(backup));
        if (siteExisted) atomicReplace(siteFile, oldSite);
        else removeIfExists(siteFile);
    } catch (Exception) {}
}

/// Removes hikari's block and site file, leaving the Caddyfile byte-identical to before.
IntegrateOutcome unintegrate(IntegrateOptions o) @safe {
    IntegrateOutcome out_;
    out_.mode = "removed";
    o.caddyfile = resolveRealPath(o.caddyfile);
    if (!exists(o.caddyfile)) {
        out_.message = "Caddyfile not found: " ~ o.caddyfile;
        return out_;
    }
    auto mainSrc = readText(o.caddyfile);
    MarkerRegion m;
    try {
        m = findMarkerRegion(mainSrc);
    } catch (IntegrationError e) {
        out_.message = "not removing: " ~ e.msg;
        return out_;
    }
    string newMain = mainSrc;
    string siteFile;
    if (m.present) {
        newMain = removeImportBlock(mainSrc);
        siteFile = buildNormalizedPath(dirName(o.caddyfile), m.importTarget);
    } else {
        // Drop-in mode: find hikari's file through the main file's glob imports.
        auto report = analyzeCaddyfile(o.caddyfile);
        foreach (imp; report.imports) {
            if (!imp.topLevel || !imp.isGlob || imp.file != report.path) continue;
            auto full = buildNormalizedPath(dirName(o.caddyfile), imp.pattern);
            auto name = dropInFileName(baseName(full));
            if (name.length == 0) continue;
            auto cand = buildNormalizedPath(dirName(full), name);
            if (exists(cand) && isHikariSiteFile(readOr(cand, ""))) siteFile = cand;
        }
    }
    bool siteOurs = siteFile.length > 0 && exists(siteFile) && isHikariSiteFile(readOr(siteFile, ""));
    out_.siteFile = siteFile;
    out_.diff = mainSrc == newMain ? "(main Caddyfile unchanged)\n" : "--- " ~ o.caddyfile ~ "\n(remove hikari block)\n";
    out_.changed = mainSrc != newMain || siteOurs;
    if (!out_.changed) {
        out_.ok = true;
        out_.message = "hikari is not integrated in " ~ o.caddyfile;
        return out_;
    }
    if (o.dryRun) {
        out_.ok = true;
        out_.message = "dry run: would remove hikari's block" ~ (siteOurs ? " and " ~ siteFile : "");
        return out_;
    }
    if (mainSrc != newMain) {
        out_.backup = backupFile(o.caddyfile);
        atomicReplace(o.caddyfile, newMain);
    }
    if (siteOurs) removeIfExists(siteFile);
    out_.ok = true;
    out_.message = "removed hikari from " ~ o.caddyfile;
    if (o.reload) {
        bool rok, attempted;
        out_.reloadNote = reloadExistingCaddy(o, analyzeCaddyfile(o.caddyfile), rok, attempted);
    } else {
        out_.reloadNote = "not reloaded; apply with: " ~ manualReloadHint(o);
    }
    return out_;
}
