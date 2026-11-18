module caddyfile.detect;

// Finds an existing Caddy *service* and the Caddyfile it serves. Parsing of service
// definitions is pure and unit-tested on every platform; the OS probes are read-only.

import std.algorithm : canFind, endsWith, startsWith;
import std.path : baseName;
import std.string : indexOf, split, strip, toLower;

struct CaddyInvocation {
    bool isCaddy;
    string binary;
    string subcommand;  // run, start, ...
    string config;      // --config value ("" = none given)
    string adapter;     // --adapter value ("" = inferred from file name)
    bool resume;        // --resume: config managed via the admin API
}

/// Interprets a Caddy command line (argv[0] = executable).
CaddyInvocation caddyArgsToConfig(const string[] argv) pure @safe {
    CaddyInvocation c;
    if (argv.length == 0) return c;
    auto exe = baseName(argv[0].replace("\\", "/")).toLower();
    c.isCaddy = exe == "caddy" || exe == "caddy.exe";
    if (!c.isCaddy) return c;
    c.binary = argv[0];
    if (argv.length > 1) c.subcommand = argv[1];
    foreach (i, a; argv) {
        string val(string flag) {
            if (a == flag && i + 1 < argv.length) return argv[i + 1];
            if (a.startsWith(flag ~ "=")) return a[flag.length + 1 .. $];
            return null;
        }
        if (auto v = val("--config")) c.config = v;
        if (auto v = val("--adapter")) c.adapter = v;
        if (a == "--resume") c.resume = true;
    }
    return c;
}

private string replace(string s, string from, string to) pure @safe {
    import std.array : replace;
    return s.replace(from, to);
}

/// Extracts argv from `systemctl show -p ExecStart` output:
/// `ExecStart={ path=/usr/bin/caddy ; argv[]=/usr/bin/caddy run --config /etc/caddy/Caddyfile ; ... }`
string[] parseSystemdExecStart(string showOutput) pure @safe {
    foreach (line; showOutput.split("\n")) {
        auto l = line.strip();
        if (!l.startsWith("ExecStart=")) continue;
        auto at = l.indexOf("argv[]=");
        if (at < 0) continue;
        auto rest = l[at + 7 .. $];
        auto semi = rest.indexOf(" ;");
        if (semi >= 0) rest = rest[0 .. semi];
        string[] argv;
        foreach (p; rest.split(" ")) if (p.length > 0) argv ~= p;
        return argv;
    }
    return null;
}

/// Extracts ProgramArguments strings from a launchd plist (XML form).
string[] parseLaunchdProgramArguments(string plist) pure @safe {
    auto k = plist.indexOf("<key>ProgramArguments</key>");
    if (k < 0) return null;
    auto arrStart = plist[k .. $].indexOf("<array>");
    if (arrStart < 0) return null;
    auto body = plist[k + arrStart .. $];
    auto arrEnd = body.indexOf("</array>");
    if (arrEnd < 0) return null;
    body = body[0 .. arrEnd];
    string[] r;
    while (true) {
        auto s = body.indexOf("<string>");
        if (s < 0) break;
        auto e = body[s .. $].indexOf("</string>");
        if (e < 0) break;
        r ~= xmlUnescape(body[s + 8 .. s + e]);
        body = body[s + e + 9 .. $];
    }
    return r;
}

private string xmlUnescape(string s) pure @safe {
    import std.array : replace;
    return s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&");
}

struct DetectedCaddy {
    bool found;
    string service;     // unit / launchd label / SCM name
    string manager;     // systemd, launchd, scm
    string binary;
    string caddyfile;
    string adapter;
    bool resume;
    string state;
    string note;        // why it cannot be integrated, if known up front
}

/// Turns an invocation into a detection result, noting configs hikari must not edit.
DetectedCaddy fromInvocation(CaddyInvocation inv, string service, string manager, string state) pure @safe {
    DetectedCaddy d;
    d.found = true;
    d.service = service;
    d.manager = manager;
    d.binary = inv.binary;
    d.caddyfile = inv.config;
    d.adapter = inv.adapter;
    d.resume = inv.resume;
    d.state = state;
    if (inv.resume) d.note = "config is managed through the Caddy admin API (--resume)";
    else if (inv.config.length == 0) d.note = "service does not pass --config; Caddyfile location is unknown";
    else if (inv.adapter.length > 0 && inv.adapter != "caddyfile") d.note = "config uses the '" ~ inv.adapter ~ "' adapter, not a Caddyfile";
    else if (inv.adapter.length == 0 && inv.config.toLower().endsWith(".json")) d.note = "config is JSON, not a Caddyfile";
    return d;
}

/// Read-only probe of the OS service manager. `skipConfigUnder` excludes hikari's own
/// isolated Caddy (its Caddyfile lives under hikari's config dir).
DetectedCaddy detectExistingCaddy(string skipConfigUnder = "") @trusted {
    DetectedCaddy none;
    bool skipped(const CaddyInvocation inv) {
        return skipConfigUnder.length > 0 && inv.config.toLower().replace("\\", "/").startsWith(skipConfigUnder.toLower().replace("\\", "/"));
    }
    version (linux) {
        import std.process : execute;
        foreach (unit; ["caddy.service", "caddy-api.service"]) {
            try {
                auto r = execute(["systemctl", "show", unit, "-p", "ExecStart", "-p", "LoadState", "-p", "ActiveState", "--no-pager"]);
                if (r.status != 0 || !r.output.canFind("LoadState=loaded")) continue;
                auto inv = caddyArgsToConfig(parseSystemdExecStart(r.output));
                if (!inv.isCaddy || skipped(inv)) continue;
                string state;
                foreach (l; r.output.split("\n")) if (l.startsWith("ActiveState=")) state = l[12 .. $].strip();
                return fromInvocation(inv, unit, "systemd", state);
            } catch (Exception) {}
        }
    } else version (OSX) {
        import std.file : exists, readText;
        foreach (p; ["/Library/LaunchDaemons/homebrew.mxcl.caddy.plist", "/opt/homebrew/opt/caddy/homebrew.mxcl.caddy.plist", "/usr/local/opt/caddy/homebrew.mxcl.caddy.plist"]) {
            try {
                if (!exists(p)) continue;
                auto inv = caddyArgsToConfig(parseLaunchdProgramArguments(readText(p)));
                if (!inv.isCaddy || skipped(inv)) continue;
                return fromInvocation(inv, "homebrew.mxcl.caddy", "launchd", "");
            } catch (Exception) {}
        }
    } else version (Windows) {
        import platform.winservice : listServiceNames, parseWindowsCommandLine, queryService;
        try {
            foreach (name; listServiceNames()) {
                if (name.toLower() == "hikari-caddy") continue;
                auto info = queryService(name);
                if (!info.exists || !info.imagePath.toLower().canFind("caddy")) continue;
                auto inv = caddyArgsToConfig(parseWindowsCommandLine(info.imagePath));
                if (!inv.isCaddy || skipped(inv)) continue;
                return fromInvocation(inv, name, "scm", info.state);
            }
        } catch (Exception) {}
    }
    return none;
}
