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
import update.maintenance;

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
    // Use the same selection as production, so a Mac whose PATH starts with
    // LibreSSL still exercises real Ed25519 signing via Homebrew OpenSSL 3.
    import platform.openssl : selectEd25519OpenSsl;
    auto opensslSelection = selectEd25519OpenSsl();
    assert(opensslSelection.ok, opensslSelection.error);
    auto openssl = opensslSelection.executable;
    auto privKey = root ~ "/keys/priv.pem";
    auto pubKey = root ~ "/keys/pub.pem";
    assert(execute([openssl, "genpkey", "-algorithm", "Ed25519", "-out", privKey], null, Config.none, 4096).status == 0);
    assert(execute([openssl, "pkey", "-in", privKey, "-pubout", "-out", pubKey], null, Config.none, 4096).status == 0);

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
    assert(execute([openssl, "pkeyutl", "-sign", "-inkey", privKey, "-rawin", "-in", manifestPath, "-out", sigPath], null, Config.none, 4096).status == 0);

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

    // Automatic maintenance: closed dashboard/manual never downloads; check-only
    // verifies without activation; a later due activity downloads and activates.
    import std.file : copy;
    auto autoCfg = cfg;
    autoCfg.paths.versions_dir = root ~ "/auto-versions";
    autoCfg.paths.state_dir = root ~ "/auto-state";
    mkdirRecurse(autoCfg.paths.versions_dir ~ "/0.1.0");
    mkdirRecurse(autoCfg.paths.state_dir);
    copy(root ~ "/versions/0.1.0/hikari", autoCfg.paths.versions_dir ~ "/0.1.0/hikari");
    atomicSetSymlink(autoCfg.paths.versions_dir ~ "/0.1.0", autoCfg.paths.versions_dir ~ "/current");
    long now = 100_000;
    int downloads, restarts;
    bool invalidSignature;
    MaintenanceHooks hooks;
    hooks.now = () => now;
    hooks.jitter = () {};
    hooks.download = (string url, string destination, ulong limit) {
        assert(url.canFind("https://github.com/example/hikari/releases/"));
        auto source = url.canFind("manifest.json") ? manifestPath : url.canFind("manifest.sig") ? sigPath : archive;
        assert(getSize(source) <= limit);
        if (invalidSignature && url.canFind("manifest.sig")) write(destination, "invalid signature");
        else copy(source, destination);
        downloads++;
    };
    hooks.restart = (string _) {
        assertThrown!Exception(new UpdateLock(autoCfg.paths.versions_dir));
        restarts++;
        return true;
    };
    hooks.health = (string _) => true;
    // Dashboard-triggered mode (an opt-in since `scheduled` became the default).
    autoCfg.updates.mode = UpdateMode.on_dashboard_open;
    assert(maintainRelease(autoCfg, "linux", "x86_64", hooks) == 0);
    assert(downloads == 0);
    write(autoCfg.paths.state_dir ~ "/update-request", to!string(now));
    autoCfg.updates.mode = UpdateMode.manual;
    maintainRelease(autoCfg, "linux", "x86_64", hooks);
    assert(downloads == 0);
    autoCfg.updates.mode = UpdateMode.on_dashboard_open;
    autoCfg.updates.auto_install_verified = false;
    maintainRelease(autoCfg, "linux", "x86_64", hooks);
    assert(downloads == 2 && restarts == 0);
    autoCfg.updates.auto_install_verified = true;
    maintainRelease(autoCfg, "linux", "x86_64", hooks);
    assert(downloads == 2, "Persisted interval prevents repeated checks");
    now += 86400;
    maintainRelease(autoCfg, "linux", "x86_64", hooks);
    assert(downloads == 2, "Expired viewer activity must not permit an idle check");
    write(autoCfg.paths.state_dir ~ "/update-request", to!string(now));
    maintainRelease(autoCfg, "linux", "x86_64", hooks);
    assert(downloads == 5 && restarts == 1);
    assert(readVersionSymlink(autoCfg.paths.versions_dir ~ "/current") == "0.2.0");

    // Invalid signed input fails closed and persists failure backoff.
    now += 86400;
    autoCfg.updates.mode = UpdateMode.scheduled;
    invalidSignature = true;
    assertThrown!Exception(maintainRelease(autoCfg, "linux", "x86_64", hooks));
    assert(downloads == 7 && restarts == 1);
    assert(readVersionSymlink(autoCfg.paths.versions_dir ~ "/current") == "0.2.0");
    maintainRelease(autoCfg, "linux", "x86_64", hooks);
    assert(downloads == 7);
    invalidSignature = false;

    // A failed automatic health check rolls back while the supervisor survives.
    autoCfg.paths.versions_dir = root ~ "/auto-failure";
    mkdirRecurse(autoCfg.paths.versions_dir ~ "/0.1.0");
    copy(root ~ "/versions/0.1.0/hikari", autoCfg.paths.versions_dir ~ "/0.1.0/hikari");
    atomicSetSymlink(autoCfg.paths.versions_dir ~ "/0.1.0", autoCfg.paths.versions_dir ~ "/current");
    hooks.health = (string v) => v == "0.1.0";
    assertThrown!Exception(maintainRelease(autoCfg, "linux", "x86_64", hooks));
    assert(readVersionSymlink(autoCfg.paths.versions_dir ~ "/current") == "0.1.0");
    assert(!exists(autoCfg.paths.versions_dir ~ "/.activation-previous"));
    assert(exists(autoCfg.paths.versions_dir ~ "/0.2.0"));

    // A later due maintenance run cleans up the unactivated 0.2.0 directory and succeeds.
    now += 86400;
    hooks.health = (string _) => true;
    assert(maintainRelease(autoCfg, "linux", "x86_64", hooks) == 0);
    assert(readVersionSymlink(autoCfg.paths.versions_dir ~ "/current") == "0.2.0");

    // Simulate a newer installer finishing while an old supervisor downloads.
    autoCfg.paths.versions_dir = root ~ "/auto-race";
    mkdirRecurse(autoCfg.paths.versions_dir ~ "/0.1.0");
    mkdirRecurse(autoCfg.paths.versions_dir ~ "/0.3.0");
    copy(root ~ "/versions/0.1.0/hikari", autoCfg.paths.versions_dir ~ "/0.1.0/hikari");
    write(autoCfg.paths.versions_dir ~ "/0.3.0/hikari", "newer installed release");
    atomicSetSymlink(autoCfg.paths.versions_dir ~ "/0.1.0", autoCfg.paths.versions_dir ~ "/current");
    auto previousDownload = hooks.download;
    hooks.download = (string url, string destination, ulong limit) {
        previousDownload(url, destination, limit);
        if (url.canFind(".tar.gz"))
            atomicSetSymlink(autoCfg.paths.versions_dir ~ "/0.3.0", autoCfg.paths.versions_dir ~ "/current");
    };
    auto restartsBeforeRace = restarts;
    maintainRelease(autoCfg, "linux", "x86_64", hooks);
    assert(restarts == restartsBeforeRace);
    assert(readVersionSymlink(autoCfg.paths.versions_dir ~ "/current") == "0.3.0");
    assert(!exists(autoCfg.paths.versions_dir ~ "/0.2.0"));

    // Stage verified archive under a strict UMask=0077 (matches hikari-maintenance.service)
    {
        import core.sys.posix.sys.stat : umask;
        import std.file : getAttributes;
        auto umaskVersions = root ~ "/umask-versions";
        mkdirRecurse(umaskVersions ~ "/0.1.0");
        auto oldMask = umask(0x3f); // 0077
        scope (exit) umask(oldMask);
        auto umaskRel = stageSignedRelease(cfg, manifestPath, sigPath, archive,
            umaskVersions, "0.1.0", "linux", "x86_64");
        assert((getAttributes(umaskRel.directory) & 0x1ff) == 0x1ed);
        assert((getAttributes(umaskRel.directory ~ "/web") & 0x1ff) == 0x1ed);
        assert((getAttributes(umaskRel.directory ~ "/hikari") & 0x1ff) == 0x1ed);
        assert((getAttributes(umaskRel.directory ~ "/web/index.html") & 0x1ff) == 0x1a4);
    }

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


unittest {
    HikariConfig cfg;
    cfg.updates.repo = "example/hikari";
    cfg.updates.public_key = "pinned-test-key";
    assert(cfg.updates.mode == UpdateMode.scheduled, "default: check at boot and daily");
    cfg.updates.mode = UpdateMode.on_dashboard_open;
    assert(!maintenanceDue(cfg, 100000, 0, 0));
    assert(maintenanceDue(cfg, 100000, 0, 99999));
    assert(!maintenanceDue(cfg, 100000, 99999, 100000));
    assert(!maintenanceDue(cfg, 100000, 0, 100001));
    assert(!maintenanceDue(cfg, 100000, 0, 99879));
    // Dashboard mode ignores boots: a reboot is not viewer activity.
    assert(!maintenanceDue(cfg, 100000, 90000, 0, 95000));
    cfg.updates.mode = UpdateMode.scheduled;
    assert(maintenanceDue(cfg, 100000, 0, 0));
    cfg.updates.mode = UpdateMode.manual;
    assert(!maintenanceDue(cfg, 100000, 0, 100000));
    assert(!maintenanceDue(cfg, 100000, 0, 0, 95000), "manual never checks, even after a boot");

    // Scheduled: daily, plus the first eligibility run after each boot.
    cfg.updates.mode = UpdateMode.scheduled;
    immutable day = 86_400;
    immutable last = 1_000_000;
    assert(!maintenanceDue(cfg, last + 7_200, last, 0), "inside the interval, no boot since: wait");
    assert(maintenanceDue(cfg, last + 7_200, last, 0, last + 6_900), "booted after the last check: check now");
    assert(!maintenanceDue(cfg, last + 1_800, last, 0, last + 1_500), "a reboot loop checks at most hourly");
    assert(!maintenanceDue(cfg, last + 7_200, last, 0, last - 60), "booted before the last check: already checked");
    assert(!maintenanceDue(cfg, last + 7_200, last, 0, last + 9_000), "a boot time in the future is ignored");
    assert(!maintenanceDue(cfg, last + 7_200, last, 0, -1), "unknown boot time: interval only");
    assert(maintenanceDue(cfg, last + day, last, 0), "daily check");
    assert(maintenanceDue(cfg, last, 0, 0, last - 300), "never checked before: check after boot");
    assertThrown!Exception(validateRepository("example/hikari/../../other"));
    assertThrown!Exception(validateRepository("example/hikari?redirect=other"));
    assertThrown!Exception(downloadHttps("http://example.invalid", "unused", 10));
}


unittest {
    import platform.command : CommandResult;
    int prints, kills, starts;
    assert(restartLaunchdJob("system/io.hikari.agent", (const string[] args, uint timeout, size_t limit) {
        CommandResult result;
        result.status = 0;
        if (args[1] == "print") result.output = ++prints == 1 ? "pid = 123\n" : "state = not running\n";
        if (args[1] == "kill") { assert(args[2] == "SIGTERM"); kills++; }
        if (args[1] == "kickstart") { assert(args.length == 3 && prints == 2); starts++; }
        return result;
    }));
    assert(kills == 1 && starts == 1);
    assert(!restartLaunchdJob("system/unrelated-service"));
}

unittest {
    import platform.update_request : readUpdateTimestampFile;
    import core.sync.semaphore : Semaphore;
    import std.uuid : randomUUID;
    auto root = tempDir() ~ "/hikari-update-request-" ~ randomUUID().toString();
    mkdirRecurse(root);
    scope(exit) rmdirRecurse(root);
    auto file = root ~ "/update-request";
    assert(readUpdateTimestampFile(file) == "");
    write(file, "12345");
    assert(readUpdateTimestampFile(file) == "12345");
    write(file, new char[100]);
    assert(readUpdateTimestampFile(file) == "");
    version (Posix) {
        import std.file : remove, symlink;
        import core.sys.posix.sys.stat : mkfifo;
        import std.string : toStringz;
        write(root ~ "/target", "12345");
        remove(file);
        symlink(root ~ "/target", file);
        assert(readUpdateTimestampFile(file) == "");
        remove(file);
        assert(mkfifo(file.toStringz, 0x180) == 0);
        assert(readUpdateTimestampFile(file) == "", "A FIFO must not block maintenance");
        remove(file);
    }
    HikariConfig cfg;
    cfg.paths.state_dir = root;
    cfg.updates.repo = "example/hikari";
    cfg.updates.public_key = "test-key";
    // Viewer activity only signals maintenance in the opt-in dashboard mode.
    cfg.updates.mode = UpdateMode.on_dashboard_open;
    auto completed = new Semaphore;
    auto request = new DashboardUpdateRequest(cfg, () { completed.notify(); });
    foreach (_; 0 .. 20) request.completedRequest();
    completed.wait();
    assert(readUpdateTimestampFile(file).length > 0);
    import core.time : msecs;
    assert(!completed.wait(msecs(20)), "Concurrent responses coalesce into one activity write");
}
