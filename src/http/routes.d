module http.routes;

import core.config;
import core.coordinator;
import core.model;
import core.serializer;
import http.security;
import std.algorithm : startsWith;
import std.file : exists, readText;
import std.string : indexOf, strip, toLower;
import tailnet.discovery;
import tailnet.registry;

struct HttpRequest {
    string method;
    string path;
    string query;
    string[string] headers; // lowercase keys
}

struct HttpResponse {
    int statusCode = 200;
    string statusText = "OK";
    string contentType = "application/json; charset=utf-8";
    string[string] headers;
    string bodyText;
}

string stripConfiguredBasePath(string rawPath, string basePath) pure @safe {
    auto bp = normalizeBasePath(basePath);
    if (bp == "/") return rawPath;
    if (rawPath == bp) return "/";
    if (rawPath.startsWith(bp ~ "/")) return rawPath[bp.length .. $];
    return rawPath;
}

class HikariRouter {
    HikariConfig config;
    RefreshCoordinator coordinator;
    TailnetDiscoveryService discovery;
    NodeRegistry registry;
    string webIndexPath;

    this(
        HikariConfig config,
        RefreshCoordinator coordinator,
        TailnetDiscoveryService discovery,
        NodeRegistry registry,
        string webIndexPath = ""
    ) {
        this.config = config;
        this.coordinator = coordinator;
        this.discovery = discovery;
        this.registry = registry;
        this.webIndexPath = webIndexPath;
    }

    HttpResponse handle(const ref HttpRequest req) {
        HttpResponse resp;
        resp.headers["X-Content-Type-Options"] = "nosniff";
        resp.headers["Cache-Control"] = "no-store";

        auto routePath = stripConfiguredBasePath(req.path, config.listen.base_path);

        // Never block a request on the Tailscale CLI: use the cached view (refreshed
        // in the background when due) and the last learned FQDN if the current read
        // failed. /healthz does not even schedule a refresh.
        string localFqdn = "";
        string magicSuffix = "";
        if (discovery !is null) {
            if (routePath != "/healthz") discovery.peekLocalTailscaleSnapshot();
            localFqdn = discovery.localFqdn();
            magicSuffix = discovery.magicDnsSuffix();
        }
        if (localFqdn.length > 0 && coordinator !is null) {
            coordinator.updateFqdn(localFqdn);
        }

        if (auto pHost = "host" in req.headers) {
            if (!isValidHostHeader(*pHost, localFqdn)) {
                return jsonError(403, "Forbidden", "invalid_host", "Host header rejected", resp.headers);
            }
        }

        string originHdr = "";
        if (auto pOrig = "origin" in req.headers) originHdr = *pOrig;

        auto knownFqdns = registry !is null ? registry.knownFqdns() : null;
        auto ov = validateRequestOrigin(originHdr, config, localFqdn, magicSuffix, knownFqdns);
        if (!ov.allowed) {
            return jsonError(403, "Forbidden", "origin_denied", "Origin not authorized for this tailnet node", resp.headers);
        }
        if (ov.hasOrigin) {
            resp.headers["Access-Control-Allow-Origin"] = ov.echoOrigin;
            resp.headers["Vary"] = "Origin";
            resp.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS";
            resp.headers["Access-Control-Allow-Headers"] = "Content-Type";
        }

        if (req.method == "OPTIONS") {
            resp.statusCode = 204;
            resp.statusText = "No Content";
            resp.contentType = "text/plain; charset=utf-8";
            resp.bodyText = "";
            return resp;
        }

        if (req.method != "GET" && req.method != "HEAD") {
            return jsonError(405, "Method Not Allowed", "method_not_allowed", "Only GET/HEAD/OPTIONS permitted", resp.headers);
        }

        if (routePath == "/healthz") {
            auto hr = coordinator.getHealth();
            resp.statusCode = 200;
            resp.statusText = "OK";
            resp.bodyText = toJsonText(serializeHealthResponse(hr));
            return resp;
        }

        if (routePath == "/api/v1/info") {
            auto ir = coordinator.getInfo();
            resp.statusCode = 200;
            resp.statusText = "OK";
            resp.bodyText = toJsonText(serializeInfoResponse(ir));
            return resp;
        }

        if (routePath == "/api/v1/status") {
            // Forced refresh is an administrative action (CLI only, AGENTS.md section 5): a
            // GET from any tailnet member must never bypass TTLs or failure backoff.
            auto sr = coordinator.getStatus(false);
            final switch (sr.kind) {
                case EndpointOutcomeKind.ok:
                    resp.statusCode = 200;
                    resp.statusText = "OK";
                    resp.bodyText = toJsonText(serializeStatusResponse(sr.payload));
                    return resp;
                case EndpointOutcomeKind.collecting:
                    CollectingResponse cr;
                    cr.retry_after_s = sr.retryAfterS;
                    resp.statusCode = 202;
                    resp.statusText = "Accepted";
                    resp.headers["Retry-After"] = toStringUint(sr.retryAfterS);
                    resp.bodyText = toJsonText(serializeCollectingResponse(cr));
                    return resp;
                case EndpointOutcomeKind.error:
                    resp.statusCode = 503;
                    resp.statusText = "Service Unavailable";
                    resp.headers["Retry-After"] = "2";
                    resp.bodyText = toJsonText(serializeErrorResponse(sr.errorCode, sr.errorMessage, sr.groups));
                    return resp;
            }
        }

        if (routePath == "/api/v1/hardware") {
            // Forced refresh is an administrative action (CLI only, AGENTS.md section 5): a
            // GET from any tailnet member must never bypass TTLs or failure backoff.
            auto hr = coordinator.getHardware(false);
            final switch (hr.kind) {
                case EndpointOutcomeKind.ok:
                    resp.statusCode = 200;
                    resp.statusText = "OK";
                    resp.bodyText = toJsonText(serializeHardwareInventory(hr.payload));
                    return resp;
                case EndpointOutcomeKind.collecting:
                    CollectingResponse cr;
                    cr.retry_after_s = hr.retryAfterS;
                    resp.statusCode = 202;
                    resp.statusText = "Accepted";
                    resp.headers["Retry-After"] = toStringUint(hr.retryAfterS);
                    resp.bodyText = toJsonText(serializeCollectingResponse(cr));
                    return resp;
                case EndpointOutcomeKind.error:
                    resp.statusCode = 503;
                    resp.statusText = "Service Unavailable";
                    resp.headers["Retry-After"] = "5";
                    resp.bodyText = toJsonText(serializeErrorResponse(hr.errorCode, hr.errorMessage));
                    return resp;
            }
        }

        if (routePath == "/api/v1/nodes") {
            // Returns the registry immediately; peer validation runs in the background
            // when due (tailnet TTL, or a rate-limited operator "Scan peers" request).
            bool probePeers = config.discovery.enabled_on_dashboard_open && !queryHas(req.query, "probe=0");
            bool forced = queryHas(req.query, "refresh=1");
            auto info = coordinator.getInfo();
            auto nr = discovery.listNodesAndScheduleDiscovery(info.node_id, info, probePeers, forced);
            resp.statusCode = 200;
            resp.statusText = "OK";
            resp.bodyText = toJsonText(serializeNodesResponse(nr));
            return resp;
        }

        // Serve single-file self-contained dashboard ONLY when explicitly configured (no arbitrary directory traversal!)
        if ((routePath == "/" || routePath == "/index.html") && webIndexPath.length > 0 && exists(webIndexPath)) {
            resp.statusCode = 200;
            resp.statusText = "OK";
            resp.contentType = "text/html; charset=utf-8";
            resp.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' https:; img-src 'self' data:; frame-ancestors 'none';";
            resp.bodyText = readText(webIndexPath);
            return resp;
        }

        return jsonError(404, "Not Found", "not_found", "Endpoint not found", resp.headers);
    }

    private static bool queryHas(string query, string param) pure @safe {
        import std.algorithm : splitter;
        foreach (part; query.splitter('&')) {
            if (part == param) return true;
        }
        return false;
    }

    private static string toStringUint(uint v) pure @safe {
        import std.conv : to;
        return to!string(v);
    }

    private static HttpResponse jsonError(int code, string statusText, string errCode, string msg, const string[string] baseHeaders) {
        HttpResponse r;
        r.statusCode = code;
        r.statusText = statusText;
        foreach (k, v; baseHeaders) r.headers[k] = v;
        r.bodyText = toJsonText(serializeErrorResponse(errCode, msg));
        return r;
    }
}
