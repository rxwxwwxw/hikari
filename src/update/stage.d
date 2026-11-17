module update.stage;

import std.algorithm : canFind, startsWith;
import std.file : exists, mkdirRecurse, rename, rmdirRecurse, write, remove;
import std.path : buildNormalizedPath, dirName;
import std.process : Config, execute;
import std.string : indexOf, split, strip, toLower;

version (Posix) {
    import core.sys.posix.fcntl : O_CREAT, O_RDWR, open;
    import core.sys.posix.unistd : close;
    private extern (C) int flock(int fd, int operation) nothrow @nogc;
    private enum int H_LOCK_EX = 2;
    private enum int H_LOCK_NB = 4;
    private enum int H_LOCK_UN = 8;
} else version (Windows) {
    import core.sys.windows.winbase : CloseHandle, CreateFileA, INVALID_HANDLE_VALUE, OPEN_ALWAYS;
    import core.sys.windows.winnt : FILE_ATTRIBUTE_NORMAL, GENERIC_READ, GENERIC_WRITE, HANDLE;
}

class UpdateLock {
    version (Posix) {
        private int fd = -1;
    } else version (Windows) {
        private HANDLE hLock = INVALID_HANDLE_VALUE;
    }
    string lockPath;

    this(string stateDir) {
        if (!exists(stateDir)) mkdirRecurse(stateDir);
        lockPath = stateDir ~ "/update.lock";
        version (Posix) {
            import std.string : toStringz;
            fd = open(lockPath.toStringz(), O_CREAT | O_RDWR, 0x180); // 0600
            if (fd < 0) throw new Exception("Unable to open update lock: " ~ lockPath);
            if (flock(fd, H_LOCK_EX | H_LOCK_NB) != 0) {
                close(fd);
                fd = -1;
                throw new Exception("Another update or installer operation is already in progress");
            }
        } else version (Windows) {
            import std.string : toStringz;
            hLock = CreateFileA(
                lockPath.toStringz(),
                GENERIC_READ | GENERIC_WRITE,
                0, // Exclusive lock: disallow concurrent sharing
                null,
                OPEN_ALWAYS,
                FILE_ATTRIBUTE_NORMAL,
                null
            );
            if (hLock == INVALID_HANDLE_VALUE) {
                throw new Exception("Another update or installer operation is already in progress");
            }
        }
    }

    void release() {
        version (Posix) {
            if (fd >= 0) {
                flock(fd, H_LOCK_UN);
                close(fd);
                fd = -1;
            }
        } else version (Windows) {
            if (hLock != INVALID_HANDLE_VALUE) {
                CloseHandle(hLock);
                hLock = INVALID_HANDLE_VALUE;
            }
        }
    }

    ~this() {
        release();
    }
}

void validateArchiveEntryName(string entryName, bool isSymlinkOrHardlink = false) pure @safe {
    if (isSymlinkOrHardlink) {
        throw new Exception("Security violation: archive contains forbidden symlink or hardlink entry: " ~ entryName);
    }
    auto clean = entryName.strip();
    if (clean.length == 0) return;
    if (clean.startsWith("/")) {
        throw new Exception("Security violation: absolute path in archive: " ~ clean);
    }
    if (clean.canFind("\\")) {
        throw new Exception("Security violation: backslash path in archive: " ~ clean);
    }
    foreach (seg; clean.split('/')) {
        if (seg == "..") {
            throw new Exception("Security violation: path traversal in archive: " ~ clean);
        }
    }
}

void inspectTarArchiveSafety(string archivePath) {
    if (!exists(archivePath)) throw new Exception("Archive not found: " ~ archivePath);
    auto res = execute(["tar", "-tvf", archivePath], null, Config.none, 1024 * 1024 * 4);
    if (res.status != 0) {
        throw new Exception("Failed to inspect archive with tar: " ~ res.output);
    }
    foreach (line; res.output.split('\n')) {
        auto s = line.strip();
        if (s.length == 0) continue;
        // First char of tar -tvf permissions: '-' regular, 'd' dir, 'l' symlink, 'h' hardlink, 'b'/'c'/'p' device
        char ftype = s[0];
        bool unsafeType = (ftype != '-' && ftype != 'd');

        // Extract entry path (after 5+ whitespace fields; symlink lines contain " -> ")
        auto cols = s.split();
        if (cols.length < 6) continue;
        string pathPart = cols[5 .. $].length > 0 ? cols[5] : "";
        // Handle "name -> target" in symlinks/hardlinks
        auto arrow = s.indexOf(" -> ");
        if (arrow > 0) {
            unsafeType = true;
            auto beforeArrow = s[0 .. arrow].split();
            if (beforeArrow.length >= 6) pathPart = beforeArrow[$ - 1];
        }
        validateArchiveEntryName(pathPart, unsafeType);
    }
}

string stageVerifiedArchive(string archivePath, string versionsDir, string targetVersion) {
    inspectTarArchiveSafety(archivePath);

    if (!exists(versionsDir)) mkdirRecurse(versionsDir);
    auto stageDir = versionsDir ~ "/.staging-" ~ targetVersion;
    auto finalDir = versionsDir ~ "/" ~ targetVersion;

    if (exists(stageDir)) rmdirRecurse(stageDir);
    mkdirRecurse(stageDir);

    scope (failure) {
        if (exists(stageDir)) {
            try { rmdirRecurse(stageDir); } catch (Exception) {}
        }
    }

    version (linux) {
        auto ex = execute(["tar", "--no-same-owner", "--no-same-permissions", "-xzf", archivePath, "-C", stageDir], null, Config.none, 1024 * 1024);
    } else {
        // macOS and Windows bsdtar support both .tar.gz and .zip via -xf
        auto ex = execute(["tar", "-xf", archivePath, "-C", stageDir], null, Config.none, 1024 * 1024);
    }
    if (ex.status != 0) {
        throw new Exception("Archive extraction failed: " ~ ex.output);
    }

    version (Windows) {
        enum binRel = "/hikari.exe";
    } else {
        enum binRel = "/hikari";
    }

    // Validate expected layout inside staged release
    if (!exists(stageDir ~ binRel)) {
        throw new Exception("Staged release missing hikari binary");
    }
    if (!exists(stageDir ~ "/web/index.html")) {
        throw new Exception("Staged release missing web/index.html");
    }

    // Verify staged binary executes cleanly and reports expected version
    auto verCheck = execute([stageDir ~ binRel, "version"], null, Config.none, 4096);
    if (verCheck.status != 0 || !verCheck.output.canFind(targetVersion)) {
        throw new Exception("Staged hikari binary failed version validation");
    }

    if (exists(finalDir)) {
        rmdirRecurse(finalDir);
    }
    rename(stageDir, finalDir);
    return finalDir;
}
