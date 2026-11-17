module http.caddy;

import core.config : normalizeBasePath;
import std.conv : to;
import std.file : exists, readText;
import std.string : replace;

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
        : "{\n\tadmin off\n\tauto_https disable_redirects\n\tstorage file_system __STATE_DIR__/caddy\n}\n\nhttps://__MAGIC_DNS_FQDN__:__PORT__ {\n\tbind __TAILSCALE_IP__\n\n\thandle __BASE_PATH_API__ {\n\t\treverse_proxy 127.0.0.1:__LOCAL_PORT__\n\t}\n\n\thandle {\n\t\troot * __WEB_DIR__\n\t\tfile_server\n\t}\n}\n";

    auto bp = normalizeBasePath(basePath);
    string apiPattern = (bp == "/") ? "/api/v1/*" : (bp ~ "/api/v1/*");

    auto rendered = tmpl
        .replace("__STATE_DIR__", stateDir)
        .replace("__MAGIC_DNS_FQDN__", fqdn)
        .replace("__PORT__", to!string(tailnetPort))
        .replace("__TAILSCALE_IP__", tailscaleIp)
        .replace("__BASE_PATH_API__", apiPattern)
        .replace("__LOCAL_PORT__", to!string(loopbackPort))
        .replace("__WEB_DIR__", webDir);

    if (bp != "/") {
        rendered = rendered.replace(
            "\thandle {\n\t\troot * " ~ webDir ~ "\n\t\tfile_server\n\t}",
            "\thandle_path " ~ bp ~ "/* {\n\t\troot * " ~ webDir ~ "\n\t\tfile_server\n\t}"
        );
    }
    return rendered;
}

string renderCaddySnippet(
    string tmplPath,
    ushort loopbackPort,
    string basePath,
    string webDir
) {
    string tmpl = exists(tmplPath)
        ? readText(tmplPath)
        : "handle_path __BASE_PATH_PREFIX__/* {\n\thandle /api/v1/* {\n\t\treverse_proxy 127.0.0.1:__LOCAL_PORT__\n\t}\n\n\thandle {\n\t\troot * __WEB_DIR__\n\t\tfile_server\n\t}\n}\n";

    auto bp = normalizeBasePath(basePath);
    string prefix = (bp == "/") ? "/hikari" : bp;
    return tmpl
        .replace("__BASE_PATH_PREFIX__", prefix)
        .replace("__LOCAL_PORT__", to!string(loopbackPort))
        .replace("__WEB_DIR__", webDir);
}
