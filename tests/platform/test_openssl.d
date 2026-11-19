module tests.platform.test_openssl;

import platform.openssl;
import std.algorithm : canFind, countUntil;
import std.exception : assertThrown, collectException;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import update.verify : verifySignatureUsing;

private enum LIBRESSL = "LibreSSL 3.3.6\n";
private enum OPENSSL3 = "OpenSSL 3.4.0 22 Oct 2024 (Library: OpenSSL 3.4.0 22 Oct 2024)\n";
private enum HB_ARM = "/opt/homebrew/opt/openssl@3/bin/openssl";
private enum HB_INTEL = "/usr/local/opt/openssl@3/bin/openssl";
private enum GIT_WIN = `C:\Program Files\Git\mingw64\bin\openssl.exe`;

// Fake filesystem + `openssl version` outputs; absent keys are "not installed".
private OpenSslSelection selectWith(const string[] candidates, string[string] outputs,
    ref string[] ran) {
    return selectEd25519OpenSsl(candidates,
        (string path) => (path in outputs) !is null,
        (string exe) {
            ran ~= exe;
            if (auto p = exe in outputs) return *p;
            throw new Exception("not found");
        });
}

unittest {
    // Version classification: only OpenSSL >= 3.0 has `pkeyutl -rawin` for Ed25519.
    auto libre = classifyOpenSslVersion("openssl", LIBRESSL);
    assert(libre.flavor == OpenSslFlavor.libressl && !libre.ed25519Rawin);
    assert(libre.versionLine == "LibreSSL 3.3.6");
    auto three = classifyOpenSslVersion("openssl", OPENSSL3);
    assert(three.flavor == OpenSslFlavor.openssl && three.ed25519Rawin);
    assert(classifyOpenSslVersion("x", "OpenSSL 3.0.13 30 Jan 2024").ed25519Rawin);
    assert(classifyOpenSslVersion("x", "OpenSSL 10.1.0").ed25519Rawin);
    assert(!classifyOpenSslVersion("x", "OpenSSL 1.1.1w  11 Sep 2023").ed25519Rawin);
    assert(!classifyOpenSslVersion("x", "OpenSSL 0.9.8zh").ed25519Rawin);
    assert(!classifyOpenSslVersion("x", "OpenSSL garbage").ed25519Rawin);
    assert(!classifyOpenSslVersion("x", "").ed25519Rawin);
    assert(classifyOpenSslVersion("x", "BoringSSL").flavor == OpenSslFlavor.unknown);
    assert(!classifyOpenSslVersion("x", "\n  \nLibreSSL 2.8.3").ed25519Rawin);
}

unittest {
    // The bare PATH name is always the last resort; Darwin and Windows probe
    // OpenSSL 3 install locations first.
    auto candidates = defaultOpenSslCandidates();
    assert(candidates[$ - 1] == "openssl");
    version (OSX) {
        assert(candidates.countUntil(HB_ARM) == 0);
        assert(candidates.canFind(HB_INTEL));
    } else version (Windows) {
        assert(candidates.countUntil(GIT_WIN) == 0);
        assert(candidates.canFind(`C:\Program Files\OpenSSL-Win64\bin\openssl.exe`));
        foreach (c; candidates[0 .. $ - 1]) assert(c[0 .. 17] == `C:\Program Files\`);
    } else {
        assert(candidates == ["openssl"]);
    }
}

unittest {
    // A backslash Windows path is a file probe: used when installed (no PATH needed,
    // the SYSTEM maintenance case), skipped without running when absent.
    string[] ran;
    auto sel = selectWith([GIT_WIN, "openssl"], [GIT_WIN: OPENSSL3], ran);
    assert(sel.ok && sel.executable == GIT_WIN);
    assert(ran == [GIT_WIN]);
    ran = null;
    sel = selectWith([GIT_WIN, "openssl"], ["openssl": OPENSSL3], ran);
    assert(sel.ok && sel.executable == "openssl");
    assert(ran == ["openssl"]);
}

unittest {
    // Homebrew OpenSSL 3 wins over a LibreSSL-first PATH (the launchd case).
    auto darwin = [HB_ARM, HB_INTEL, "openssl"];
    string[] ran;
    auto sel = selectWith(darwin, [HB_ARM: OPENSSL3, "openssl": LIBRESSL], ran);
    assert(sel.ok && sel.executable == HB_ARM);
    assert(sel.versionLine.canFind("OpenSSL 3.4.0"));
    assert(ran == [HB_ARM]); // stops at the first capable candidate

    // Missing absolute candidates are skipped without running anything.
    ran = null;
    sel = selectWith(darwin, [HB_INTEL: OPENSSL3, "openssl": LIBRESSL], ran);
    assert(sel.ok && sel.executable == HB_INTEL);
    assert(ran == [HB_INTEL]);

    // A capable OpenSSL on PATH is used when no well-known location exists.
    ran = null;
    sel = selectWith(darwin, ["openssl": OPENSSL3], ran);
    assert(sel.ok && sel.executable == "openssl");
    assert(ran == ["openssl"]);

    // An old OpenSSL at a probed location falls through to a capable PATH one.
    ran = null;
    sel = selectWith(darwin, [HB_ARM: "OpenSSL 1.1.1w", "openssl": OPENSSL3], ran);
    assert(sel.ok && sel.executable == "openssl");
}

unittest {
    // Only LibreSSL available: no selection, and an actionable error naming it.
    string[] ran;
    auto sel = selectWith([HB_ARM, HB_INTEL, "openssl"], ["openssl": LIBRESSL], ran);
    assert(!sel.ok && sel.executable.length == 0);
    assert(sel.error.canFind("LibreSSL 3.3.6"));
    assert(sel.error.canFind("cannot verify Ed25519"));
    assert(sel.error.canFind("brew install openssl@3"));

    // Nothing at all: still a clear error, never an empty success.
    ran = null;
    sel = selectWith([HB_ARM, "openssl"], null, ran);
    assert(!sel.ok);
    assert(sel.error.canFind("No Ed25519-capable OpenSSL"));
    assert(sel.error.canFind("not found on PATH"));

    // An unrunnable probed binary is reported, not trusted.
    sel = selectEd25519OpenSsl([HB_ARM], (string) => true,
        (string exe) { throw new Exception("exec format error"); return ""; });
    assert(!sel.ok && sel.error.canFind(HB_ARM ~ " could not run"));
}

unittest {
    // Verification fails closed with the LibreSSL explanation; it never returns
    // true or silently skips the signature check.
    auto root = tempDir() ~ "/hikari-test-openssl-reject";
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);
    write(root ~ "/manifest.json", `{"schema_version":1}`);
    write(root ~ "/manifest.sig", "sig");
    string[] ran;
    auto rejected = selectWith(["openssl"], ["openssl": LIBRESSL], ran);
    auto e = collectException(verifySignatureUsing(rejected, root ~ "/manifest.json",
        root ~ "/manifest.sig", "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"));
    assert(e !is null);
    assert(e.msg.canFind("LibreSSL"));
}
