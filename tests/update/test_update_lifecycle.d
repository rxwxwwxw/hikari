module tests.update.test_update_lifecycle;

import core.config;
import std.algorithm : canFind;
import std.conv : to;
import std.exception : assertThrown;
import std.file : exists, getSize, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.format : format;
import std.path : baseName;
import std.process : Config, execute;
import update.activate;
import update.stage;
import update.verify;

unittest {
    // 1. SemVer comparison (never lexicographic!)
    assert(SemVer.parse("v0.10.0") > SemVer.parse("0.2.0"));
    assert(SemVer.parse("1.0.0") > SemVer.parse("1.0.0-rc.1"));
    assert(SemVer.parse("0.1.0") == SemVer.parse("0.1.0"));

    // 2. Archive entry traversal & symlink rejection
    assertThrown!Exception(validateArchiveEntryName("../etc/passwd"));
    assertThrown!Exception(validateArchiveEntryName("/etc/shadow"));
    assertThrown!Exception(validateArchiveEntryName("web/index.html", true));
    validateArchiveEntryName("hikari");
    validateArchiveEntryName("web/index.html");
}

unittest {
    // 3. Full OpenSSL Ed25519 sign/verify, fail-closed tamper check, staging, lock, activation, & automatic rollback
    version (Posix) {
    auto root = tempDir() ~ "/hikari-test-update";
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root ~ "/keys");
    mkdirRecurse(root ~ "/pkg/web");
    mkdirRecurse(root ~ "/pkg/caddy");
    mkdirRecurse(root ~ "/state");
    mkdirRecurse(root ~ "/versions/0.1.0/web");
    scope (exit) { if (exists(root)) rmdirRecurse(root); }

    // Generate Ed25519 test keypair via openssl
    auto privKey = root ~ "/keys/priv.pem";
    auto pubKey = root ~ "/keys/pub.pem";
    assert(execute(["openssl", "genpkey", "-algorithm", "Ed25519", "-out", privKey], null, Config.none, 4096).status == 0);
    assert(execute(["openssl", "pkey", "-in", privKey, "-pubout", "-out", pubKey], null, Config.none, 4096).status == 0);

    // Seed existing v0.1.0 release & user config/state
    write(root ~ "/versions/0.1.0/hikari", "#!/bin/sh\necho 'hikari 0.1.0'\n");
    execute(["chmod", "+x", root ~ "/versions/0.1.0/hikari"]);
    write(root ~ "/versions/0.1.0/web/index.html", "<html>v0.1.0</html>");
    atomicSetSymlink(root ~ "/versions/0.1.0", root ~ "/versions/current");
    write(root ~ "/state/nodes.json", `{"schema_version":1,"nodes":[]}`);

    // Build mock v0.2.0 tarball
    write(root ~ "/pkg/hikari", "#!/bin/sh\necho 'hikari 0.2.0 (schema_version=1)'\n");
    execute(["chmod", "+x", root ~ "/pkg/hikari"]);
    write(root ~ "/pkg/web/index.html", "<html>v0.2.0</html>");
    write(root ~ "/pkg/VERSION", "0.2.0\n");

    auto archive = root ~ "/hikari-linux-x86_64.tar.gz";
    assert(execute(["tar", "-czf", archive, "-C", root ~ "/pkg", "."], null, Config.none, 4096).status == 0);

    auto sha = computeFileSha256Hex(archive);
    auto sz = getSize(archive);

    auto manifestPath = root ~ "/manifest.json";
    auto sigPath = root ~ "/manifest.sig";
    write(manifestPath, format!`{
        "schema_version": 1,
        "repo": "example/hikari",
        "version": "0.2.0",
        "channel": "stable",
        "artifacts": [
            {"os": "linux", "arch": "x86_64", "filename": "hikari-linux-x86_64.tar.gz", "sha256": "%s", "size_bytes": %u}
        ]
    }`(sha, sz));
    assert(execute(["openssl", "pkeyutl", "-sign", "-inkey", privKey, "-rawin", "-in", manifestPath, "-out", sigPath], null, Config.none, 4096).status == 0);

    HikariConfig cfg;
    cfg.updates.repo = "example/hikari";
    cfg.updates.public_key = readText(pubKey);

    // Valid signature + hash passes
    verifyVerifiedReleasePackage(cfg, manifestPath, sigPath, archive, "0.1.0", "linux", "x86_64");

    // Tampered archive fails hash check before extraction
    write(root ~ "/bad.tar.gz", "corrupted");
    assertThrown!Exception(verifyVerifiedReleasePackage(cfg, manifestPath, sigPath, root ~ "/bad.tar.gz", "0.1.0", "linux", "x86_64"));

    // Tampered manifest fails signature check
    auto badManifest = root ~ "/bad-manifest.json";
    write(badManifest, readText(manifestPath) ~ " ");
    assertThrown!Exception(verifyVerifiedReleasePackage(cfg, badManifest, sigPath, archive, "0.1.0", "linux", "x86_64"));

    // Stage verified archive
    auto release = stageSignedRelease(cfg, manifestPath, sigPath, archive,
        root ~ "/versions", "0.1.0", "linux", "x86_64");
    assert(release.versionString == "0.2.0");
    auto staged = release.directory;
    assert(exists(staged ~ "/hikari"));

    assertThrown!Exception(stageVerifiedArchive(archive, root ~ "/versions", "0.2.0"));
    assertThrown!Exception(validateReleaseDirectoryName("../escape"));
    assertThrown!Exception(validateReleaseDirectoryName("current"));

    // Lock contention check
    auto lck = new UpdateLock(root ~ "/state");
    assertThrown!Exception(new UpdateLock(root ~ "/state"));
    lck.release();

    // Simulated failed health check triggers AUTOMATIC ROLLBACK to 0.1.0 while preserving state!
    auto failOutcome = activateAndVerifyRelease(
        root ~ "/versions",
        root ~ "/state",
        "0.2.0",
        (string _) => true,
        (string v) => v == "0.1.0" // bad new release; prior version remains healthy
    );
    assert(!failOutcome.ok && failOutcome.rolledBack);
    assert(readVersionSymlink(root ~ "/versions/current") == "0.1.0", "Must automatically roll back to 0.1.0");
    assert(exists(root ~ "/state/nodes.json"), "User state must survive rollback");

    // Healthy activation flips current -> 0.2.0 and sets previous -> 0.1.0
    auto okOutcome = activateAndVerifyRelease(
        root ~ "/versions",
        root ~ "/state",
        "0.2.0",
        (string _) => true,
        (string v) => v == "0.2.0"
    );
    assert(okOutcome.ok && !okOutcome.rolledBack);
    assert(readVersionSymlink(root ~ "/versions/current") == "0.2.0");
    assert(readVersionSymlink(root ~ "/versions/previous") == "0.1.0");
    auto failedRollback = rollbackToPrevious(root ~ "/versions", root ~ "/state",
        (string _) => true, (string v) => v == "0.2.0");
    assert(!failedRollback.ok);
    assert(readVersionSymlink(root ~ "/versions/current") == "0.2.0");
    assert(!exists(root ~ "/versions/.activation-previous"));
    // Model power loss after pointer switch but before health confirmation.
    write(root ~ "/versions/.activation-previous", "0.1.0\n");
    auto recovered = recoverInterruptedActivation(root ~ "/versions", root ~ "/state",
        (string _) => true, (string v) => v == "0.1.0");
    assert(recovered.ok && recovered.rolledBack);
    assert(readVersionSymlink(root ~ "/versions/current") == "0.1.0");
    assert(!exists(root ~ "/versions/.activation-previous"));
    }
}

unittest {
    version (Posix) {
        auto root = tempDir() ~ "/hikari-test-archive-metadata";
        if (exists(root)) rmdirRecurse(root);
        mkdirRecurse(root);
        scope (exit) rmdirRecurse(root);
        auto script = root ~ "/make.py";
        write(script, `import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tar:
    info = tarfile.TarInfo(sys.argv[2])
    if sys.argv[3] == "link":
        info.type = tarfile.SYMTYPE
        info.linkname = "/etc/passwd"
    elif sys.argv[3] == "huge":
        info.size = 513 * 1024 * 1024
        class Zeros:
            def read(self, size): return b"\0" * size
        tar.addfile(info, Zeros())
        sys.exit(0)
    tar.addfile(info)
`);
        auto archive = root ~ "/test.tgz";
        assert(execute(["python3", script, archive, "file with spaces", "file"]).status == 0);
        inspectTarArchiveSafety(archive);
        foreach (name; ["../outside", "/absolute", "dir/../../outside"]) {
            assert(execute(["python3", script, archive, name, "file"]).status == 0);
            assertThrown!Exception(inspectTarArchiveSafety(archive));
        }
        foreach (kind; ["link", "huge"]) {
            assert(execute(["python3", script, archive, "entry", kind]).status == 0);
            assertThrown!Exception(inspectTarArchiveSafety(archive));
        }
    }
}
