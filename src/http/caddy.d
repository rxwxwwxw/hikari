module http.caddy;

import core.config : normalizeBasePath;
import std.conv : to;
import std.file : exists, readText;
import std.string : replace, split, toLower;
import std.algorithm : endsWith, startsWith, canFind;
import std.ascii : isAlphaNum;
import std.socket : parseAddress;

private string caddyToken(string value) {
    foreach (c; value) if (c < 0x20 || c == 0x7f)
        throw new Exception("Control character in Caddy path");
    if (value.canFind("{$")) throw new Exception("Environment substitution is not allowed in Caddy paths");
    return `"` ~ value.replace(`\`, `\\`).replace(`"`, `\"`) ~ `"`;
}

private string checkedBasePath(string value) {
    auto path = normalizeBasePath(value);
    foreach (c; path) if (!isAlphaNum(c) && c != '/' && c != '-' && c != '_'
        && c != '.' && c != '~' && c != '%')
        throw new Exception("Unsafe endpoint base path");
    return path;
}

private string checkedTailnetAddress(string value) {
    auto address = parseAddress(value).toAddrString().toLower(); // numeric only; never DNS
    auto octets = address.split('.');
    if (octets.length == 4 && octets[0] == "100") {
        auto second = to!uint(octets[1]);
        if (second >= 64 && second <= 127) return address;
    }
    if (address.startsWith("fd7a:115c:a1e0:")) return address;
    throw new Exception("Caddy must bind a Tailscale address");
}

private string checkedMagicDnsName(string value) {
    auto name = value.toLower();
    if (!name.endsWith(".ts.net") || name.length > 253)
        throw new Exception("Expected a MagicDNS .ts.net hostname");
    foreach (label; name.split('.')) {
        if (!label.length || label.length > 63 || label[0] == '-' || label[$-1] == '-')
            throw new Exception("Invalid MagicDNS hostname");
        foreach (c; label) if (!isAlphaNum(c) && c != '-')
            throw new Exception("Invalid MagicDNS hostname");
    }
    return name;
}

string renderCaddyfile(
    string tmplPath,
    string fqdn,
    ushort tailnetPort,
    string tailscaleIp,
    ushort loopbackPort,
    string basePath,
    string stateDir,
    string webDir
) {
    if (tailscaleIp.length == 0) {
        throw new Exception("Refusing to render Caddyfile without a Tailscale IP (never bind 0.0.0.0)");
    }
    if (fqdn.length == 0) {
        throw new Exception("Refusing to render Caddyfile without a MagicDNS FQDN");
    }
    string tmpl = exists(tmplPath)
        ? readText(tmplPath)
        : "{\n\tadmin off\n\tauto_https disable_redirects\n\tstorage file_system __STATE_DIR__/caddy\n__WINDOWS_LOG_BLOCK__}\n\nhttps://__MAGIC_DNS_FQDN__:__PORT__ {\n\tbind __TAILSCALE_IP__\n\n\thandle __BASE_PATH_API__ {\n\t\treverse_proxy 127.0.0.1:__LOCAL_PORT__\n\t}\n\n\thandle {\n\t\troot * __WEB_DIR__\n\t\tfile_server\n\t}\n}\n";

    auto bp = checkedBasePath(basePath);
    fqdn = checkedMagicDnsName(fqdn);
    tailscaleIp = checkedTailnetAddress(tailscaleIp);
    if (!tailnetPort || !loopbackPort) throw new Exception("Caddy ports must be nonzero");
    auto quotedWebDir = caddyToken(webDir);
    string apiPattern = (bp == "/") ? "/api/v1/*" : (bp ~ "/api/v1/*");

    auto rendered = tmpl
        .replace("__STATE_DIR__/caddy", caddyToken(stateDir ~ "/caddy"))
        .replace("__STATE_DIR__", caddyToken(stateDir))
        .replace("__MAGIC_DNS_FQDN__", fqdn)
        .replace("__PORT__", to!string(tailnetPort))
        .replace("__TAILSCALE_IP__", tailscaleIp)
        .replace("__BASE_PATH_API__", apiPattern)
        .replace("__LOCAL_PORT__", to!string(loopbackPort))
        .replace("__WEB_DIR__", caddyToken(webDir))
        .replace("__WINDOWS_LOG_BLOCK__", windowsCaddyLogBlock(stateDir));

    if (bp != "/") {
        rendered = rendered.replace(
            "\thandle {\n\t\troot * " ~ quotedWebDir ~ "\n\t\tfile_server\n\t}",
            "\thandle_path " ~ bp ~ "/* {\n\t\troot * " ~ quotedWebDir ~ "\n\t\tfile_server\n\t}"
        );
    }
    return rendered;
}

/// The site block hikari adds to an *existing* Caddy (written to its own file, imported
/// by the operator's Caddyfile). It relies on none of the operator's global options:
/// explicit bind and Tailscale certificates work even with `auto_https off`.
string renderIntegratedSite(string fqdn, ushort tailnetPort, string tailscaleIp, ushort loopbackPort, string basePath, string webDir) @trusted {
    import caddyfile.edit : SITE_FILE_HEADER;
    if (tailscaleIp.length == 0) throw new Exception("Refusing to render a site without a Tailscale IP (never bind all interfaces)");
    if (fqdn.length == 0) throw new Exception("Refusing to render a site without a MagicDNS FQDN");
    auto bp = normalizeBasePath(basePath);
    string apiPattern = (bp == "/") ? "/api/v1/*" : (bp ~ "/api/v1/*");
    string web = webDir.replace("\\", "/");
    string s = SITE_FILE_HEADER ~ "\n";
    s ~= "https://" ~ fqdn ~ ":" ~ to!string(tailnetPort) ~ " {\n";
    s ~= "\tbind " ~ tailscaleIp ~ "\n";
    s ~= "\ttls {\n\t\tget_certificate tailscale\n\t}\n\n";
    s ~= "\thandle " ~ apiPattern ~ " {\n\t\treverse_proxy 127.0.0.1:" ~ to!string(loopbackPort) ~ "\n\t}\n\n";
    if (bp == "/") s ~= "\thandle {\n";
    else s ~= "\thandle_path " ~ bp ~ "/* {\n";
    s ~= "\t\troot * \"" ~ web ~ "\"\n\t\tfile_server\n\t}\n}\n";
    return s;
}

/// Windows services have no console or journal, so the isolated Caddy writes its own
/// size-rotated log next to hikari's (<ProgramData>/hikari/logs/caddy.log). On Linux and
/// macOS this renders empty and logs keep going to journald/launchd.
string windowsCaddyLogBlock(string stateDir, bool forWindows = isWindowsTarget) pure @safe {
    if (!forWindows) return "";
    import std.path : dirName;
    auto logsDir = dirName(stateDir.replace("\\", "/")) ~ "/logs";
    return "	log {
		output file " ~ logsDir ~ "/caddy.log {
			roll_size 1MiB
			roll_keep 3
		}
	}
";
}

version (Windows) private enum bool isWindowsTarget = true;
else private enum bool isWindowsTarget = false;

string renderCaddySnippet(
    string tmplPath,
    ushort loopbackPort,
    string basePath,
    string webDir
) {
    string tmpl = exists(tmplPath)
        ? readText(tmplPath)
        : "handle_path __BASE_PATH_PREFIX__/* {\n\thandle /api/v1/* {\n\t\treverse_proxy 127.0.0.1:__LOCAL_PORT__\n\t}\n\n\thandle {\n\t\troot * __WEB_DIR__\n\t\tfile_server\n\t}\n}\n";

    auto bp = checkedBasePath(basePath);
    string prefix = (bp == "/") ? "/hikari" : bp;
    return tmpl
        .replace("__BASE_PATH_PREFIX__", prefix)
        .replace("__LOCAL_PORT__", to!string(loopbackPort))
        .replace("__WEB_DIR__", caddyToken(webDir));
}
