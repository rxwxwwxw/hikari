module update.activate;

import core.thread : Thread;
import core.time : msecs;
import std.algorithm : canFind;
import std.file : exists, mkdirRecurse, readText, remove, rename, write, isSymlink, FileException;
version (Posix) {
    import std.file : readLink, symlink;
}
import std.path : baseName;
import std.process : Config, execute;
import std.string : strip;
import update.stage;
import update.verify;
import platform.command : runLocalCommand;
import platform.durable : syncUpdatePath;
import std.path : dirName;

alias ServiceRestartFn = bool delegate(string action); // "restart"
alias HealthCheckFn = bool delegate(string expectedVersion);

struct ActivationOutcome {
    bool ok = false;
    bool rolledBack = false;
    string activeVersion;
    string previousVersion;
    string message;
}

void atomicSetSymlink(string target, string linkPath) {
    version (Posix) {
        auto tmpLink = linkPath ~ ".tmp";
        bool danglingLink;
        try { danglingLink = isSymlink(tmpLink); } catch (FileException) {}
        if (exists(tmpLink) || danglingLink) remove(tmpLink);
        symlink(target, tmpLink);
        rename(tmpLink, linkPath);
        syncUpdatePath(dirName(linkPath), true);
    } else version (Windows) {
        // Store target path atomically and update directory junction without overwriting running .exe
        auto txtPath = linkPath ~ ".txt";
        auto tmpTxt = txtPath ~ ".tmp";
        write(tmpTxt, baseName(target) ~ "\n");
        rename(tmpTxt, txtPath);
        execute(["cmd", "/c", "rmdir", "/q", linkPath], null, Config.none, 4096);
        execute(["cmd", "/c", "mklink", "/J", linkPath, target], null, Config.none, 4096);
    }
}

string readVersionSymlink(string linkPath) {
    version (Posix) {
        if (!exists(linkPath)) return "";
        try {
            return baseName(readLink(linkPath));
        } catch (Exception) {
            return "";
        }
    } else version (Windows) {
        auto txtPath = linkPath ~ ".txt";
        if (exists(txtPath)) {
            try { return readText(txtPath).strip(); } catch (Exception) {}
        }
        return "";
    }
}

bool defaultRestartHikariServices(string action) {
    version (linux) {
        auto r1 = execute(["systemctl", action, "hikari.service"], null, Config.none, 4096);
        if (r1.status != 0) return false;
        auto r2chk = execute(["systemctl", "list-unit-files", "hikari-caddy.service"], null, Config.none, 4096);
        if (r2chk.status == 0 && r2chk.output.canFind("hikari-caddy.service")) {
            auto r2 = execute(["systemctl", action, "hikari-caddy.service"], null, Config.none, 4096);
            if (r2.status != 0) return false;
        }
        return true;
    } else version (OSX) {
        auto r1 = runLocalCommand(["/bin/launchctl", "kickstart", "-k", "system/io.hikari.agent"], 10000, 4096);
        if (r1.status != 0) return false;
        if (exists("/Library/LaunchDaemons/io.hikari.caddy.plist")) {
            auto r2 = runLocalCommand(["/bin/launchctl", "kickstart", "-k", "system/io.hikari.caddy"], 10000, 4096);
            if (r2.status != 0) return false;
        }
        return true;
    } else version (Windows) {
        execute(["sc.exe", "stop", "hikari"], null, Config.none, 4096);
        Thread.sleep(msecs(1000));
        auto r1 = execute(["sc.exe", "start", "hikari"], null, Config.none, 4096);
        if (r1.status != 0) return false;
        auto q2 = execute(["sc.exe", "query", "hikari-caddy"], null, Config.none, 4096);
        if (q2.status == 0) {
            execute(["sc.exe", "stop", "hikari-caddy"], null, Config.none, 4096);
            Thread.sleep(msecs(500));
            execute(["sc.exe", "start", "hikari-caddy"], null, Config.none, 4096);
        }
        return true;
    } else {
        return false;
    }
}

HealthCheckFn makeLoopbackHealthChecker(string loopbackBind, ushort loopbackPort, uint attempts = 10, uint sleepMs = 200) {
    import std.conv : to;
    string host = loopbackBind == "::1" ? "[::1]" : "127.0.0.1";
    string url = "http://" ~ host ~ ":" ~ to!string(loopbackPort) ~ "/healthz";
    string infoUrl = "http://" ~ host ~ ":" ~ to!string(loopbackPort) ~ "/api/v1/info";
    return (string expectedVersion) {
        foreach (_; 0 .. attempts) {
            auto r1 = execute(["curl", "-fsS", "--max-time", "2", url], null, Config.none, 4096);
            auto r2 = execute(["curl", "-fsS", "--max-time", "2", infoUrl], null, Config.none, 8192);
            if (r1.status == 0 && r2.status == 0 && r2.output.canFind(`"agent_version":"` ~ expectedVersion ~ `"`)) {
                return true;
            }
            Thread.sleep(msecs(sleepMs));
        }
        return false;
    };
}

private string versionBinaryPath(string dir) pure nothrow @safe {
    version (Windows) {
        return dir ~ "/hikari.exe";
    } else {
        return dir ~ "/hikari";
    }
}

ActivationOutcome activateAndVerifyRelease(
    string versionsDir,
    string stateDir,
    string targetVersion,
    ServiceRestartFn serviceHook = null,
    HealthCheckFn healthHook = null
) {
    ActivationOutcome outc;
    validateReleaseDirectoryName(targetVersion);
    auto targetDir = versionsDir ~ "/" ~ targetVersion;
    if (!exists(versionBinaryPath(targetDir))) {
        outc.message = "Target version directory is incomplete: " ~ targetDir;
        return outc;
    }

    auto lock = new UpdateLock(versionsDir);
    scope (exit) lock.release();

    auto pendingPath = versionsDir ~ "/.activation-previous";
    if (exists(pendingPath)) {
        outc.message = "An interrupted activation requires `hikari update recover` first";
        return outc;
    }

    auto currentLink = versionsDir ~ "/current";
    auto prevLink = versionsDir ~ "/previous";

    string oldVersion = readVersionSymlink(currentLink);
    outc.previousVersion = oldVersion;

    if (oldVersion.length > 0 && oldVersion != targetVersion && exists(versionsDir ~ "/" ~ oldVersion)) {
        atomicSetSymlink(versionsDir ~ "/" ~ oldVersion, prevLink);
    }

    if (oldVersion.length > 0 && oldVersion != targetVersion) {
        write(pendingPath ~ ".tmp", oldVersion ~ "\n");
        syncUpdatePath(pendingPath ~ ".tmp");
        rename(pendingPath ~ ".tmp", pendingPath);
        syncUpdatePath(versionsDir, true);
    }
    atomicSetSymlink(targetDir, currentLink);

    import std.functional : toDelegate;
    auto restartFn = serviceHook !is null ? serviceHook : toDelegate(&defaultRestartHikariServices);
    bool restarted = restartFn("restart");
    bool healthy = restarted && (healthHook is null || healthHook(targetVersion));

    if (healthy) {
        if (exists(pendingPath)) { remove(pendingPath); syncUpdatePath(versionsDir, true); }
        outc.ok = true;
        outc.activeVersion = targetVersion;
        outc.message = "Activated version " ~ targetVersion;
        return outc;
    }

    // Automatic rollback to previous known-good release
    if (oldVersion.length > 0 && exists(versionsDir ~ "/" ~ oldVersion)) {
        atomicSetSymlink(versionsDir ~ "/" ~ oldVersion, currentLink);
        bool recovered = restartFn("restart") && (healthHook is null || healthHook(oldVersion));
        if (recovered && exists(pendingPath)) { remove(pendingPath); syncUpdatePath(versionsDir, true); }
        outc.rolledBack = true;
        outc.activeVersion = oldVersion;
        outc.message = "Health check or service restart failed for " ~ targetVersion ~ "; automatically rolled back to " ~ oldVersion;
    } else {
        outc.message = "Activation failed for " ~ targetVersion ~ " and no previous release available";
    }
    return outc;
}

ActivationOutcome recoverInterruptedActivation(
    string versionsDir, string stateDir,
    ServiceRestartFn serviceHook = null, HealthCheckFn healthHook = null
) {
    ActivationOutcome outc;
    auto lock = new UpdateLock(versionsDir);
    scope (exit) lock.release();
    auto pendingPath = versionsDir ~ "/.activation-previous";
    if (!exists(pendingPath)) {
        outc.ok = true;
        outc.message = "No interrupted activation";
        return outc;
    }
    auto previous = readText(pendingPath).strip();
    validateReleaseDirectoryName(previous);
    if (!exists(versionBinaryPath(versionsDir ~ "/" ~ previous))) {
        outc.message = "Interrupted activation has no usable prior release";
        return outc;
    }
    atomicSetSymlink(versionsDir ~ "/" ~ previous, versionsDir ~ "/current");
    import std.functional : toDelegate;
    auto restartFn = serviceHook !is null ? serviceHook : toDelegate(&defaultRestartHikariServices);
    outc.ok = restartFn("restart") && (healthHook is null || healthHook(previous));
    outc.rolledBack = true;
    outc.activeVersion = previous;
    if (outc.ok) { remove(pendingPath); syncUpdatePath(versionsDir, true); }
    outc.message = outc.ok ? "Recovered interrupted activation to " ~ previous
        : "Prior release restored; service recovery still requires attention";
    return outc;
}

ActivationOutcome rollbackToPrevious(
    string versionsDir,
    string stateDir,
    ServiceRestartFn serviceHook = null,
    HealthCheckFn healthHook = null
) {
    ActivationOutcome outc;
    auto prevVer = readVersionSymlink(versionsDir ~ "/previous");
    if (prevVer.length == 0 || !exists(versionBinaryPath(versionsDir ~ "/" ~ prevVer))) {
        outc.message = "No valid previous version available for rollback";
        return outc;
    }
    // Rollback is itself a transaction: a broken previous version must not strand
    // the operator on an unhealthy release or lose interrupted-operation recovery.
    outc = activateAndVerifyRelease(versionsDir, stateDir, prevVer, serviceHook, healthHook);
    if (outc.ok) {
        outc.rolledBack = true;
        outc.message = "Rolled back to " ~ prevVer;
    }
    return outc;
}
