module http.security;

import core.config : HikariConfig;
import std.string : toLower;

enum size_t MAX_REQUEST_BYTES = 16384;
enum size_t MAX_URI_LENGTH = 2048;

struct OriginValidation {
    bool allowed = false;
    bool hasOrigin = false;
    string echoOrigin;
}

private pure nothrow @nogc @safe {

bool isAsciiSpace(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
}

char toAsciiLower(char c) {
    return (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
}

string trimAsciiStr(string s) {
    size_t start = 0;
    while (start < s.length && isAsciiSpace(s[start])) start++;
    size_t end = s.length;
    while (end > start && isAsciiSpace(s[end - 1])) end--;
    return s[start .. end];
}

bool equalsIgnoreCase(const(char)[] a, const(char)[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) {
        if (toAsciiLower(a[i]) != toAsciiLower(b[i])) return false;
    }
    return true;
}

bool startsWithIgnoreCase(const(char)[] s, const(char)[] prefix) {
    return s.length >= prefix.length && equalsIgnoreCase(s[0 .. prefix.length], prefix);
}

bool containsChar(const(char)[] s, char needle) {
    foreach (char c; s) {
        if (c == needle) return true;
    }
    return false;
}

string extractAuthorityHostSlice(string urlOrHost) {
    auto s = trimAsciiStr(urlOrHost);
    if (startsWithIgnoreCase(s, "https://")) s = s[8 .. $];
    else if (startsWithIgnoreCase(s, "http://")) s = s[7 .. $];

    foreach (i, char c; s) {
        if (c == '/') {
            s = s[0 .. i];
            break;
        }
    }

    if (s.length > 0 && s[0] == '[') {
        foreach (i, char c; s) {
            if (c == ']' && i > 1) return s[0 .. i + 1];
        }
        return s;
    }
    foreach (i, char c; s) {
        if (c == ':') return s[0 .. i];
    }
    return s;
}

} // private pure nothrow @nogc @safe

public:

string extractAuthorityHost(string urlOrHost) pure @safe {
    return extractAuthorityHostSlice(urlOrHost).toLower();
}

bool isLoopbackHostHeader(string hostHeader) pure nothrow @nogc @safe {
    auto h = extractAuthorityHostSlice(hostHeader);
    return equalsIgnoreCase(h, "127.0.0.1")
        || equalsIgnoreCase(h, "localhost")
        || equalsIgnoreCase(h, "::1")
        || equalsIgnoreCase(h, "[::1]");
}

bool isValidHostHeader(string hostHeader, string localFqdn) pure nothrow @nogc @safe {
    if (hostHeader.length == 0) return false;
    auto h = extractAuthorityHostSlice(hostHeader);
    if (equalsIgnoreCase(h, "127.0.0.1")
        || equalsIgnoreCase(h, "localhost")
        || equalsIgnoreCase(h, "[::1]")
        || equalsIgnoreCase(h, "::1")) {
        return true;
    }
    if (localFqdn.length > 0 && equalsIgnoreCase(h, localFqdn)) return true;
    return false;
}

OriginValidation validateRequestOrigin(
    string originHeader,
    const ref HikariConfig cfg,
    string localFqdn,
    string magicDnsSuffix,
    const(string)[] knownFqdns
) pure nothrow @nogc @safe {
    OriginValidation ov;
    auto orig = trimAsciiStr(originHeader);
    if (orig.length == 0) {
        ov.allowed = true;
        ov.hasOrigin = false;
        return ov;
    }

    ov.hasOrigin = true;

    // 1. Explicit allowlist
    foreach (allowed; cfg.listen.allowed_origins) {
        if (equalsIgnoreCase(orig, trimAsciiStr(allowed))) {
            ov.allowed = true;
            ov.echoOrigin = orig;
            return ov;
        }
    }

    // 2. Same-host loopback browser origin (local development / direct loopback)
    if (startsWithIgnoreCase(orig, "http://127.0.0.1:") || equalsIgnoreCase(orig, "http://127.0.0.1")
        || startsWithIgnoreCase(orig, "http://localhost:") || equalsIgnoreCase(orig, "http://localhost")
        || startsWithIgnoreCase(orig, "http://[::1]:") || equalsIgnoreCase(orig, "http://[::1]")) {
        ov.allowed = true;
        ov.echoOrigin = orig;
        return ov;
    }

    // 3. Tailnet HTTPS origins ONLY (never plaintext HTTP for tailnet FQDNs!)
    if (!startsWithIgnoreCase(orig, "https://")) {
        ov.allowed = false;
        return ov;
    }

    auto origHost = extractAuthorityHostSlice(orig);
    if (origHost.length == 0) {
        ov.allowed = false;
        return ov;
    }

    if (localFqdn.length > 0 && equalsIgnoreCase(origHost, localFqdn)) {
        ov.allowed = true;
        ov.echoOrigin = orig;
        return ov;
    }

    foreach (kf; knownFqdns) {
        if (kf.length > 0 && equalsIgnoreCase(origHost, kf)) {
            ov.allowed = true;
            ov.echoOrigin = orig;
            return ov;
        }
    }

    // Same tailnet MagicDNS suffix (must be strict subdomain ".<magicDnsSuffix>", avoiding cross-tailnet lookalikes!)
    if (magicDnsSuffix.length > 0 && origHost.length > magicDnsSuffix.length + 1) {
        size_t sufStart = origHost.length - magicDnsSuffix.length;
        if (origHost[sufStart - 1] == '.' && equalsIgnoreCase(origHost[sufStart .. $], magicDnsSuffix)) {
            auto labelPart = origHost[0 .. sufStart - 1];
            if (!containsChar(labelPart, '.')) {
                ov.allowed = true;
                ov.echoOrigin = orig;
                return ov;
            }
        }
    }

    ov.allowed = false;
    return ov;
}
