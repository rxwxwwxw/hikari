module http.security;

import core.config : HikariConfig;
import std.algorithm : canFind, endsWith, startsWith;
import std.conv : to;
import std.string : indexOf, strip, toLower;

enum size_t MAX_REQUEST_BYTES = 16384;
enum size_t MAX_URI_LENGTH = 2048;

struct OriginValidation {
    bool allowed = false;
    bool hasOrigin = false;
    string echoOrigin;
}

string extractAuthorityHost(string urlOrHost) pure @safe {
    auto s = urlOrHost.strip().toLower();
    if (s.startsWith("https://")) s = s[8 .. $];
    else if (s.startsWith("http://")) s = s[7 .. $];

    auto slash = s.indexOf('/');
    if (slash >= 0) s = s[0 .. slash];

    if (s.startsWith("[")) {
        auto close = s.indexOf(']');
        if (close > 1) return s[0 .. close + 1];
        return s;
    }
    auto colon = s.indexOf(':');
    if (colon >= 0) return s[0 .. colon];
    return s;
}

bool isLoopbackHostHeader(string hostHeader) pure @safe {
    auto h = extractAuthorityHost(hostHeader);
    return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]";
}

bool isValidHostHeader(string hostHeader, string localFqdn) pure @safe {
    if (hostHeader.length == 0) return false;
    auto h = extractAuthorityHost(hostHeader);
    if (h == "127.0.0.1" || h == "localhost" || h == "[::1]" || h == "::1") return true;
    if (localFqdn.length > 0 && h == localFqdn.toLower()) return true;
    return false;
}

OriginValidation validateRequestOrigin(
    string originHeader,
    const ref HikariConfig cfg,
    string localFqdn,
    string magicDnsSuffix,
    const string[] knownFqdns
) pure @safe {
    OriginValidation ov;
    auto orig = originHeader.strip();
    if (orig.length == 0) {
        ov.allowed = true;
        ov.hasOrigin = false;
        return ov;
    }

    ov.hasOrigin = true;
    auto origLow = orig.toLower();

    // 1. Explicit allowlist
    foreach (allowed; cfg.listen.allowed_origins) {
        if (origLow == allowed.strip().toLower()) {
            ov.allowed = true;
            ov.echoOrigin = orig;
            return ov;
        }
    }

    // 2. Same-host loopback browser origin (local development / direct loopback)
    if (origLow.startsWith("http://127.0.0.1:") || origLow == "http://127.0.0.1"
        || origLow.startsWith("http://localhost:") || origLow == "http://localhost"
        || origLow.startsWith("http://[::1]:") || origLow == "http://[::1]") {
        ov.allowed = true;
        ov.echoOrigin = orig;
        return ov;
    }

    // 3. Tailnet HTTPS origins ONLY (never plaintext HTTP for tailnet FQDNs!)
    if (!origLow.startsWith("https://")) {
        ov.allowed = false;
        return ov;
    }

    auto origHost = extractAuthorityHost(origLow);
    if (origHost.length == 0) {
        ov.allowed = false;
        return ov;
    }

    if (localFqdn.length > 0 && origHost == localFqdn.toLower()) {
        ov.allowed = true;
        ov.echoOrigin = orig;
        return ov;
    }

    foreach (kf; knownFqdns) {
        if (kf.length > 0 && origHost == kf.toLower()) {
            ov.allowed = true;
            ov.echoOrigin = orig;
            return ov;
        }
    }

    // Same tailnet MagicDNS suffix (must be strict subdomain ".<magicDnsSuffix>", avoiding cross-tailnet lookalikes!)
    if (magicDnsSuffix.length > 0) {
        auto suf = "." ~ magicDnsSuffix.toLower();
        if (origHost.endsWith(suf) && origHost.length > suf.length) {
            auto labelPart = origHost[0 .. $ - suf.length];
            if (!labelPart.canFind('.')) {
                ov.allowed = true;
                ov.echoOrigin = orig;
                return ov;
            }
        }
    }

    ov.allowed = false;
    return ov;
}
