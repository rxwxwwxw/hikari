module update.maintenance;

import core.config;
import core.model : AGENT_VERSION;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, seconds;
import platform.command : runLocalCommand;
import std.algorithm : all, canFind;
import std.ascii : isAlphaNum;
import std.conv : to;
import std.datetime.systime : Clock;
import std.file;
import std.random : uniform;
import std.string : split, strip;
import std.uuid : randomUUID;
import update.verify;
import update.stage;
import update.activate;

// The agent can request work, but cannot choose executable paths or release
// inputs for the privileged, short-lived OS maintenance job.
class DashboardUpdateRequest {
    private HikariConfig config;
    private Mutex mutex;
    private long nextRequest;
    private void delegate() trigger;
    this(HikariConfig config, void delegate() trigger = null) {
        this.config = config;
        this.trigger = trigger;
        mutex = new Mutex;
    }
    private static long requestClockSeconds() {
        import platform.clock : continuousBootNanoseconds;
        auto continuous = continuousBootNanoseconds();
        return continuous >= 0 ? continuous / 1_000_000_000L
            : MonoTime.currTime.ticks / MonoTime.ticksPerSecond;
    }
    void completedRequest() {
        if (config.updates.mode != UpdateMode.on_dashboard_open || !config.updates.isTrustConfigured()) return;
        synchronized (mutex) {
            auto now = requestClockSeconds();
            if (now < nextRequest) return;
            // The privileged job may start up to 120 seconds after this signal.
            // Include that dispatch allowance so the next daily signal does not
            // arrive just before its persisted interval and get skipped for a day.
            nextRequest = now + cast(long) config.updates.check_interval_hours * 3600 + 120;
            auto worker = new Thread({
                try {
                    auto path = config.paths.state_dir ~ "/update-request";
                    // A timestamp is the entire request. No URL, command or path
                    // supplied by the telemetry account is executed by maintenance.
                    write(path ~ ".tmp", to!string(Clock.currTime.toUnixTime()));
                    rename(path ~ ".tmp", path);
                    if (trigger !is null) trigger();
                    else version (Windows) {
                        // Installer grants the service identity read/execute on
                        // this fixed task only, never permission to edit its action.
                        auto trigger = runLocalCommand(["schtasks.exe", "/Run", "/TN", "hikari-maintenance"], 5000, 4096);
                        if (trigger.status != 0) throw new Exception("Maintenance task could not start");
                    }
                } catch (Exception) {
                    synchronized (mutex) nextRequest = requestClockSeconds() + 60;
                }
            });
            worker.isDaemon = true;
            worker.start();
        }
    }
}

alias DownloadFn = void delegate(string url, string destination, ulong limit);

void downloadHttps(string url, string destination, ulong limit) {
    if (url.length < 8 || url.length > 2048 || url[0 .. 8] != "https://") throw new Exception("HTTPS download required");
    // Retained memory, duration, redirects and protocol are all bounded. --silent
    // prevents diagnostics from becoming archive bytes on the merged output pipe.
    auto result = runLocalCommand(["curl", "--silent", "--fail", "--location",
        "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "5",
        "--connect-timeout", "10", "--max-time", "120", "--retry", "2",
        "--retry-max-time", "150", "--max-filesize", to!string(limit), url], 180000, cast(size_t) limit);
    if (result.status != 0 || result.timedOut || result.outputTruncated)
        throw new Exception("Release download failed or exceeded bounds");
    write(destination, result.output);
}

void validateRepository(string repo) {
    auto parts = repo.split('/');
    if (parts.length != 2) throw new Exception("Expected pinned owner/repository");
    foreach (part; parts) {
        if (!part.length || part == "." || part == ".." ||
            !part.all!(c => isAlphaNum(c) || c == '-' || c == '_' || c == '.'))
            throw new Exception("Invalid pinned repository");
    }
}

struct DownloadedRelease {
    ReleaseManifest manifest;
    ManifestArtifact artifact;
    string manifestPath;
    string signaturePath;
    bool newer;
}

DownloadedRelease checkRelease(const ref HikariConfig cfg, string directory,
    string currentVersion, string targetOs, string targetArch, DownloadFn download = null,
    SignatureVerifierFn verify = null) {
    import std.functional : toDelegate;
    if (!cfg.updates.isTrustConfigured()) throw new Exception("Update trust is not configured");
    validateRepository(cfg.updates.repo);
    if (cfg.updates.channel != "stable") throw new Exception("Automatic release discovery currently requires the stable channel");
    if (download is null) download = toDelegate(&downloadHttps);
    if (verify is null) verify = toDelegate(&verifySignatureWithOpenSsl);
    DownloadedRelease release;
    release.manifestPath = directory ~ "/manifest.json";
    release.signaturePath = directory ~ "/manifest.sig";
    auto base = "https://github.com/" ~ cfg.updates.repo ~ "/releases/latest/download/";
    download(base ~ "manifest.json", release.manifestPath, 1024 * 1024);
    download(base ~ "manifest.sig", release.signaturePath, 4096);
    if (!verify(release.manifestPath, release.signaturePath, cfg.updates.public_key))
        throw new Exception("Release signature verification failed");
    release.manifest = parseReleaseManifest(readText(release.manifestPath));
    if (release.manifest.repo != cfg.updates.repo || release.manifest.channel != cfg.updates.channel)
        throw new Exception("Signed release repository or channel mismatch");
    validateReleaseDirectoryName(release.manifest.version_str);
    if (!release.manifest.findArtifact(targetOs, targetArch, release.artifact))
        throw new Exception("Release has no artifact for this platform");
    release.newer = release.manifest.version_parsed > SemVer.parse(currentVersion);
    return release;
}

string createMaintenanceDirectory(string parent) {
    auto path = parent ~ "/.download-" ~ randomUUID().toString();
    version (Posix) {
        // Create privately from the first instant, rather than chmod after creation.
        import core.sys.posix.sys.stat : mkdir;
        import std.string : toStringz;
        if (mkdir(path.toStringz, 0x1c0) != 0) throw new Exception("Cannot create private update directory");
    } else mkdir(path);
    return path;
}

bool maintenanceDue(const ref HikariConfig cfg, long now, long lastAttempt, long activity) {
    if (!cfg.updates.isTrustConfigured() || cfg.updates.mode == UpdateMode.manual) return false;
    auto interval = cast(long) cfg.updates.check_interval_hours * 3600;
    if (lastAttempt > 0 && now >= lastAttempt && now - lastAttempt < interval) return false;
    if (cfg.updates.mode == UpdateMode.scheduled) return true;
    // Activity requests expire: a machine never updates days after its last viewer.
    return activity > lastAttempt && activity <= now && now - activity <= 120;
}

private long readTimestamp(string path) {
    import platform.update_request : readUpdateTimestampFile;
    try { return readUpdateTimestampFile(path).strip.to!long; } catch (Exception) {}
    return 0;
}

struct MaintenanceHooks {
    long delegate() now;
    void delegate() jitter;
    DownloadFn download;
    ServiceRestartFn restart;
    HealthCheckFn health;
}

// Invoked by an installer-owned OS job, outside the telemetry service's process
// and security identity. Restarting hikari cannot kill its rollback supervisor.
int maintainRelease(HikariConfig cfg, string targetOs, string targetArch, MaintenanceHooks hooks = MaintenanceHooks.init) {
    import std.functional : toDelegate;
    if (hooks.download is null) hooks.download = toDelegate(&downloadHttps);
    if (hooks.health is null) hooks.health = makeLoopbackHealthChecker(cfg.listen.loopback_bind, cfg.listen.loopback_port);
    auto controlDir = cfg.paths.versions_dir ~ "/.maintenance";
    if (!exists(controlDir)) mkdir(controlDir);
    auto lock = new UpdateLock(controlDir);
    scope(exit) lock.release();
    if (exists(cfg.paths.versions_dir ~ "/.activation-previous")) {
        auto recovery = recoverInterruptedActivation(cfg.paths.versions_dir, cfg.paths.state_dir, hooks.restart, hooks.health);
        if (!recovery.ok) throw new Exception(recovery.message);
    }
    auto now = hooks.now is null ? Clock.currTime.toUnixTime() : hooks.now();
    auto attemptPath = controlDir ~ "/last-attempt";
    if (!maintenanceDue(cfg, now, readTimestamp(attemptPath),
        readTimestamp(cfg.paths.state_dir ~ "/update-request"))) return 0;
    // Bound retries across failures and process restarts, using privileged state.
    write(attemptPath ~ ".tmp", to!string(now));
    rename(attemptPath ~ ".tmp", attemptPath);
    if (hooks.jitter is null) Thread.sleep(seconds(uniform(0, 61)));
    else hooks.jitter();
    auto temporary = createMaintenanceDirectory(controlDir);
    scope(exit) rmdirRecurse(temporary);
    auto release = checkRelease(cfg, temporary, AGENT_VERSION, targetOs, targetArch, hooks.download);
    write(controlDir ~ "/verified-version", release.manifest.version_str);
    if (!release.newer || !cfg.updates.auto_install_verified) return 0;
    auto artifact = release.artifact;
    if (!artifact.size_bytes || artifact.size_bytes > 150UL * 1024 * 1024)
        throw new Exception("Release archive size outside bounds");
    // Construct the asset URL from the pinned repo and signed version/filename;
    // ignore any arbitrary URL embedded in the manifest.
    if (!artifact.filename.length || artifact.filename.canFind('/') || artifact.filename.canFind('\\') ||
        !artifact.filename.all!(c => isAlphaNum(c) || c == '-' || c == '_' || c == '.'))
        throw new Exception("Invalid release artifact filename");
    auto archive = temporary ~ "/" ~ artifact.filename;
    hooks.download("https://github.com/" ~ cfg.updates.repo ~ "/releases/download/v" ~
        release.manifest.version_str ~ "/" ~ artifact.filename, archive, artifact.size_bytes);
    auto transaction = new UpdateLock(cfg.paths.versions_dir);
    scope(exit) transaction.release();
    // Another installer may have completed while downloads were in progress.
    // Compare the active pointer under the same lock held through staging and
    // health-checked activation, so an older supervisor cannot downgrade it.
    auto current = readVersionSymlink(cfg.paths.versions_dir ~ "/current");
    if (!current.length) throw new Exception("Automatic activation requires a known-good current release");
    if (release.manifest.version_parsed <= SemVer.parse(current)) return 0;
    auto staged = stageSignedRelease(cfg, release.manifestPath, release.signaturePath, archive,
        cfg.paths.versions_dir, current, targetOs, targetArch);
    auto outcome = activateAndVerifyRelease(cfg.paths.versions_dir, cfg.paths.state_dir,
        staged.versionString, hooks.restart, hooks.health, transaction);
    if (!outcome.ok) throw new Exception(outcome.message);
    return 0;
}
