module update.verify;

import core.config : HikariConfig;
import std.algorithm : canFind, startsWith;
import std.conv : to;
import std.digest.sha : sha256Of, toHexString;
import std.file : exists, getSize, read, tempDir, write, remove, mkdirRecurse, rmdirRecurse;
import std.uuid : randomUUID;
import platform.command : runLocalCommand;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.process : Config, execute;
import std.string : indexOf, split, strip, toLower;

struct SemVer {
    uint major;
    uint minor;
    uint patch;
    string prerelease;

    static SemVer parse(string raw) {
        auto s = raw.strip();
        if (s.startsWith("v") || s.startsWith("V")) s = s[1 .. $];
        if (s.length == 0) throw new Exception("Empty version string");

        string pre;
        auto plus = s.indexOf('+');
        if (plus >= 0) s = s[0 .. plus];
        auto dash = s.indexOf('-');
        if (dash >= 0) {
            pre = s[dash + 1 .. $];
            s = s[0 .. dash];
        }
        auto parts = s.split('.');
        if (parts.length != 3) throw new Exception("Invalid semver (expected major.minor.patch): " ~ raw);
        SemVer v;
        v.major = to!uint(parts[0]);
        v.minor = to!uint(parts[1]);
        v.patch = to!uint(parts[2]);
        v.prerelease = pre;
        return v;
    }

    int opCmp(const SemVer other) const pure nothrow @safe {
        if (major != other.major) return major < other.major ? -1 : 1;
        if (minor != other.minor) return minor < other.minor ? -1 : 1;
        if (patch != other.patch) return patch < other.patch ? -1 : 1;
        if (prerelease.length == 0 && other.prerelease.length == 0) return 0;
        if (prerelease.length == 0) return 1; // release > prerelease
        if (other.prerelease.length == 0) return -1;
        if (prerelease < other.prerelease) return -1;
        if (prerelease > other.prerelease) return 1;
        return 0;
    }

    string toString() const pure @safe {
        auto base = format!"%u.%u.%u"(major, minor, patch);
        return prerelease.length > 0 ? (base ~ "-" ~ prerelease) : base;
    }
}

struct ManifestArtifact {
    string os;
    string arch;
    string filename;
    string sha256;
    ulong size_bytes;
    string url;
}

struct ReleaseManifest {
    int schema_version = 1;
    string repo;
    string version_str;
    SemVer version_parsed;
    string channel = "stable";
    ManifestArtifact[] artifacts;

    bool findArtifact(string osName, string archName, out ManifestArtifact found) const pure nothrow @safe {
        foreach (a; artifacts) {
            if (a.os == osName && a.arch == archName) {
                found = a;
                return true;
            }
        }
        return false;
    }
}

ReleaseManifest parseReleaseManifest(string jsonText) {
    auto j = parseJSON(jsonText);
    if (j.type != JSONType.object) throw new Exception("Manifest must be a JSON object");

    ReleaseManifest m;
    if (auto p = "schema_version" in j.object) {
        if (p.type != JSONType.integer || p.integer != 1) {
            throw new Exception("Unsupported manifest schema_version");
        }
        m.schema_version = cast(int) p.integer;
    }
    if (auto p = "repo" in j.object) if (p.type == JSONType.string) m.repo = p.str;
    if (auto p = "version" in j.object) if (p.type == JSONType.string) m.version_str = p.str;
    if (auto p = "channel" in j.object) if (p.type == JSONType.string) m.channel = p.str;

    if (m.repo.length == 0 || m.version_str.length == 0) {
        throw new Exception("Manifest missing repo or version");
    }
    m.version_parsed = SemVer.parse(m.version_str);

    if (auto pArts = "artifacts" in j.object) {
        if (pArts.type == JSONType.array) {
            foreach (el; pArts.array) {
                if (el.type != JSONType.object) continue;
                ManifestArtifact a;
                if (auto p = "os" in el.object) if (p.type == JSONType.string) a.os = p.str;
                if (auto p = "arch" in el.object) if (p.type == JSONType.string) a.arch = p.str;
                if (auto p = "filename" in el.object) if (p.type == JSONType.string) a.filename = p.str;
                if (auto p = "sha256" in el.object) if (p.type == JSONType.string) a.sha256 = p.str.toLower();
                if (auto p = "url" in el.object) if (p.type == JSONType.string) a.url = p.str;
                if (auto p = "size_bytes" in el.object) {
                    if (p.type == JSONType.integer && p.integer >= 0) a.size_bytes = cast(ulong) p.integer;
                    else if (p.type == JSONType.uinteger) a.size_bytes = p.uinteger;
                }
                if (a.os.length > 0 && a.arch.length > 0 && a.sha256.length == 64) {
                    m.artifacts ~= a;
                }
            }
        }
    }
    if (m.artifacts.length == 0) throw new Exception("Manifest contains no valid artifacts");
    return m;
}

alias SignatureVerifierFn = bool delegate(string manifestPath, string sigPath, string publicKeyPemOrPath);

private void removeQuietly(string p) nothrow {
    try { remove(p); } catch (Exception) {}
}

private void removeDirectoryQuietly(string p) nothrow {
    try { rmdirRecurse(p); } catch (Exception) {}
}

bool verifySignatureWithOpenSsl(string manifestPath, string sigPath, string publicKeyPemOrPath) {
    if (!exists(manifestPath) || !exists(sigPath) || publicKeyPemOrPath.strip().length == 0) return false;
    string keyPath = publicKeyPemOrPath.strip();
    bool createdTempKey = false;
    if (keyPath.canFind("BEGIN PUBLIC KEY")) {
        auto directory = tempDir() ~ "/hikari-verify-" ~ randomUUID().toString();
        mkdirRecurse(directory);
        version (Posix) {
            import std.file : setAttributes;
            setAttributes(directory, 0x1c0); // 0700
        }
        keyPath = directory ~ "/key.pem";
        write(keyPath, publicKeyPemOrPath);
        createdTempKey = true;
    }
    scope (exit) {
        if (createdTempKey && exists(keyPath)) {
            removeQuietly(keyPath);
            import std.path : dirName;
            removeDirectoryQuietly(dirName(keyPath));
        }
    }
    if (!exists(keyPath)) return false;

    try {
        auto res = runLocalCommand([
            "openssl", "pkeyutl", "-verify",
            "-pubin", "-inkey", keyPath,
            "-rawin", "-in", manifestPath,
            "-sigfile", sigPath,
        ], 10000, 4096);
        return res.status == 0 && !res.outputTruncated;
    } catch (Exception) {
        return false;
    }
}

string computeFileSha256Hex(string filePath) {
    auto bytes = cast(const(ubyte)[]) read(filePath);
    auto digest = sha256Of(bytes);
    return toHexString(digest).idup.toLower();
}

void verifyVerifiedReleasePackage(
    const ref HikariConfig cfg,
    string manifestPath,
    string sigPath,
    string archivePath,
    string currentVersionStr,
    string targetOs,
    string targetArch,
    SignatureVerifierFn sigVerifier = null,
    bool allowSameOrDowngrade = false
) {
    if (!cfg.updates.isTrustConfigured()) {
        throw new Exception("Update trust root is not configured (repo and public_key required)");
    }
    if (!exists(manifestPath) || !exists(sigPath) || !exists(archivePath)) {
        throw new Exception("Missing manifest, signature, or archive file");
    }

    if (getSize(manifestPath) > 1024 * 1024 || getSize(sigPath) > 4096)
        throw new Exception("Manifest or signature exceeds size limit");
    import std.functional : toDelegate;
    auto verifier = sigVerifier !is null ? sigVerifier : toDelegate(&verifySignatureWithOpenSsl);
    if (!verifier(manifestPath, sigPath, cfg.updates.public_key)) {
        throw new Exception("Release manifest signature verification failed (fail closed)");
    }

    auto manifestText = cast(string) read(manifestPath);
    auto manifest = parseReleaseManifest(manifestText);
    if (manifest.repo != cfg.updates.repo) {
        throw new Exception("Manifest repo mismatch: expected " ~ cfg.updates.repo ~ ", got " ~ manifest.repo);
    }
    if (manifest.channel != cfg.updates.channel) {
        throw new Exception("Manifest channel mismatch: expected " ~ cfg.updates.channel ~ ", got " ~ manifest.channel);
    }

    auto curVer = SemVer.parse(currentVersionStr);
    if (!allowSameOrDowngrade && manifest.version_parsed <= curVer) {
        throw new Exception("Update version " ~ manifest.version_str ~ " is not newer than current " ~ currentVersionStr);
    }

    ManifestArtifact art;
    if (!manifest.findArtifact(targetOs, targetArch, art)) {
        throw new Exception("No artifact in manifest for " ~ targetOs ~ "-" ~ targetArch);
    }

    enum ulong MAX_ARCHIVE_BYTES = 150UL * 1024UL * 1024UL;
    ulong actualSize = getSize(archivePath);
    if (actualSize == 0 || actualSize > MAX_ARCHIVE_BYTES) {
        throw new Exception("Archive size out of allowed bounds");
    }
    if (art.size_bytes > 0 && actualSize != art.size_bytes) {
        throw new Exception("Archive size mismatch against signed manifest");
    }

    auto actualSha = computeFileSha256Hex(archivePath);
    if (actualSha != art.sha256) {
        throw new Exception("Archive SHA-256 hash mismatch against signed manifest");
    }
}
