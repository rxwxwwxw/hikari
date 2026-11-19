module platform.openssl;

// Locates an OpenSSL able to verify Ed25519 release signatures with
// `pkeyutl -verify -rawin` (OpenSSL 3.0+). macOS ships LibreSSL as
// /usr/bin/openssl, which cannot, and launchd daemons get a minimal PATH, so on
// Darwin well-known OpenSSL 3 locations are probed before PATH. Windows has no
// system OpenSSL and the SYSTEM maintenance task sees only the machine PATH, so
// standard admin-owned install locations under Program Files are probed first.
// Selection only picks the tool: callers must still fail closed when no
// candidate qualifies.

import std.algorithm : startsWith;
import std.ascii : isDigit;
import std.string : join, lineSplitter, strip;

enum OpenSslFlavor { openssl, libressl, unknown }

struct OpenSslProbe {
    string executable;
    string versionLine;
    OpenSslFlavor flavor = OpenSslFlavor.unknown;
    bool ed25519Rawin;
}

struct OpenSslSelection {
    string executable; // empty when nothing qualified
    string versionLine;
    string error;      // actionable explanation when executable is empty

    bool ok() const pure nothrow @safe @nogc { return executable.length > 0; }
}

alias OpenSslExistsFn = bool delegate(string path);
// Returns the output of `<executable> version`; throws when it cannot be run.
alias OpenSslVersionFn = string delegate(string executable);

enum string OPENSSL_INSTALL_HINT =
    "Install OpenSSL 3 (macOS: `brew install openssl@3`; it is found at "
    ~ "/opt/homebrew/opt/openssl@3 or /usr/local/opt/openssl@3 without changing PATH. "
    ~ "Windows: Git for Windows or a Win64 OpenSSL in its default Program Files folder "
    ~ "is found without changing PATH) and retry. Release signatures are never skipped.";

// Probe order. The bare name resolves through PATH and is always last.
string[] defaultOpenSslCandidates() pure nothrow @safe {
    version (OSX) {
        return [
            "/opt/homebrew/opt/openssl@3/bin/openssl", // Homebrew, Apple Silicon
            "/usr/local/opt/openssl@3/bin/openssl",    // Homebrew, Intel
            "/opt/local/libexec/openssl3/bin/openssl", // MacPorts openssl3
            "openssl",
        ];
    } else version (Windows) {
        // Default per-machine install folders only: writable by administrators,
        // unlike user PATH entries, so SYSTEM never runs a user-planted binary.
        return [
            `C:\Program Files\Git\mingw64\bin\openssl.exe`, // Git for Windows
            `C:\Program Files\OpenSSL-Win64\bin\openssl.exe`, // Shining Light Win64 OpenSSL
            `C:\Program Files\OpenSSL\bin\openssl.exe`,       // FireDaemon and others
            "openssl",
        ];
    } else {
        return ["openssl"];
    }
}

OpenSslProbe classifyOpenSslVersion(string executable, string versionOutput) pure @safe {
    OpenSslProbe probe;
    probe.executable = executable;
    foreach (line; versionOutput.lineSplitter) {
        auto s = line.strip();
        if (s.length) { probe.versionLine = s.length > 120 ? s[0 .. 120] : s; break; }
    }
    auto v = probe.versionLine;
    if (v.startsWith("LibreSSL")) {
        probe.flavor = OpenSslFlavor.libressl;
    } else if (v.startsWith("OpenSSL ")) {
        probe.flavor = OpenSslFlavor.openssl;
        auto rest = v["OpenSSL ".length .. $];
        size_t i;
        while (i < rest.length && isDigit(rest[i])) i++;
        // `pkeyutl -rawin` (needed for Ed25519) first appeared in OpenSSL 3.0.
        if (i > 0 && i < rest.length && rest[i] == '.') {
            uint major;
            foreach (c; rest[0 .. i]) {
                if (major > 1000) break;
                major = major * 10 + (c - '0');
            }
            probe.ed25519Rawin = major >= 3;
        }
    }
    return probe;
}

private string describeRejection(const OpenSslProbe probe) pure @safe {
    final switch (probe.flavor) {
    case OpenSslFlavor.libressl:
        return probe.executable ~ " is " ~ probe.versionLine
            ~ " (LibreSSL cannot verify Ed25519 signatures with pkeyutl -rawin)";
    case OpenSslFlavor.openssl:
        return probe.executable ~ " is " ~ probe.versionLine ~ " (OpenSSL 3.0 or newer is required)";
    case OpenSslFlavor.unknown:
        return probe.executable ~ " reported an unrecognized version"
            ~ (probe.versionLine.length ? " '" ~ probe.versionLine ~ "'" : "");
    }
}

// A candidate with a directory separator names a file; a bare name resolves via PATH.
private bool namesFile(string candidate) pure nothrow @safe @nogc {
    foreach (char c; candidate) if (c == '/' || c == '\\') return true;
    return false;
}

OpenSslSelection selectEd25519OpenSsl(const string[] candidates, OpenSslExistsFn exists,
    OpenSslVersionFn runVersion) {
    string[] rejected;
    foreach (candidate; candidates) {
        if (namesFile(candidate) && !exists(candidate)) continue; // not installed there
        string output;
        try {
            output = runVersion(candidate);
        } catch (Exception) {
            if (!namesFile(candidate)) rejected ~= candidate ~ " was not found on PATH or could not run";
            else rejected ~= candidate ~ " could not run";
            continue;
        }
        auto probe = classifyOpenSslVersion(candidate, output);
        if (probe.ed25519Rawin) return OpenSslSelection(candidate, probe.versionLine, null);
        rejected ~= describeRejection(probe);
    }
    OpenSslSelection none;
    none.error = "No Ed25519-capable OpenSSL found for release signature verification"
        ~ (rejected.length ? ": " ~ rejected.join("; ") : "") ~ ". " ~ OPENSSL_INSTALL_HINT;
    return none;
}

OpenSslSelection selectEd25519OpenSsl() {
    import platform.command : runLocalCommand;
    import std.file : exists, isFile;
    return selectEd25519OpenSsl(defaultOpenSslCandidates(),
        (string path) {
            try { return exists(path) && isFile(path); } catch (Exception) { return false; }
        },
        (string executable) {
            auto res = runLocalCommand([executable, "version"], 5000, 4096);
            if (res.timedOut || res.status != 0) throw new Exception("openssl version failed");
            return res.output;
        });
}
