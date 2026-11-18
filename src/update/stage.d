module update.stage;

import std.algorithm : canFind, startsWith, all;
import std.file : exists, mkdirRecurse, rename, rmdirRecurse, write, remove, readText, getSize;
import std.path : buildNormalizedPath, dirName;
import std.process : Config, execute;
import std.string : indexOf, split, strip, toLower;
import std.ascii : isAlphaNum, isDigit;
import std.uuid : randomUUID;
import update.verify : SemVer, verifyVerifiedReleasePackage, parseReleaseManifest;
import core.config : HikariConfig;
import platform.command : runLocalCommand;
import platform.durable : syncUpdatePath;

struct StagedRelease { string versionString; string directory; }

StagedRelease stageSignedRelease(const ref HikariConfig config, string manifestPath,
    string signaturePath, string archivePath, string versionsDir, string currentVersion,
    string osName, string architecture) {
    // Snapshot untrusted input paths before verification; extraction must see the
    // same bytes whose signature and digest were checked, even under a root CLI.
    auto privateDir = versionsDir ~ "/.verified-" ~ randomUUID().toString();
    mkdirRecurse(privateDir);
    version (Posix) {
        import std.file : setAttributes;
        setAttributes(privateDir, 0x1c0); // 0700
    }
    scope (exit) rmdirRecurse(privateDir);
    void snapshot(string source, string destination, ulong limit) {
        import std.stdio : File;
        auto input = File(source, "rb");
        auto output = File(destination, "wb");
        ubyte[65536] buffer;
        ulong total;
        while (!input.eof) {
            auto bytes = input.rawRead(buffer[]);
            total += bytes.length;
            if (total > limit) throw new Exception("Update input exceeds size limit");
            output.rawWrite(bytes);
        }
        output.close();
    }
    snapshot(manifestPath, privateDir ~ "/manifest.json", 1024 * 1024);
    snapshot(signaturePath, privateDir ~ "/manifest.sig", 4096);
    snapshot(archivePath, privateDir ~ "/archive", 150UL * 1024 * 1024);
    HikariConfig cfg;
    cfg.updates = config.updates;
    auto keyPath = privateDir ~ "/key.pem";
    if (cfg.updates.public_key.canFind("BEGIN PUBLIC KEY")) write(keyPath, cfg.updates.public_key);
    else snapshot(cfg.updates.public_key, keyPath, 65536);
    cfg.updates.public_key = keyPath;
    verifyVerifiedReleasePackage(cfg, privateDir ~ "/manifest.json", privateDir ~ "/manifest.sig",
        privateDir ~ "/archive", currentVersion, osName, architecture);
    auto manifest = parseReleaseManifest(readText(privateDir ~ "/manifest.json"));
    return StagedRelease(manifest.version_str,
        stageVerifiedArchive(privateDir ~ "/archive", versionsDir, manifest.version_str));
}

void validateReleaseDirectoryName(string value) {
    if (value.length == 0 || value == "." || value == "..")
        throw new Exception("Invalid release directory name");
    foreach (c; value)
        if (!isAlphaNum(c) && c != '.' && c != '-')
            throw new Exception("Invalid release directory name");
    if (SemVer.parse(value).toString() != value)
        throw new Exception("Release directory must be a canonical version");
}

version (Posix) {
    import core.sys.posix.fcntl : O_CREAT, O_RDWR, O_NOFOLLOW, open;
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
            fd = open(lockPath.toStringz(), O_CREAT | O_RDWR | O_NOFOLLOW, 0x180); // 0600
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

    bool isHeld() const nothrow {
        version (Posix) return fd >= 0;
        else version (Windows) return hLock != INVALID_HANDLE_VALUE;
        else return false;
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
    auto names = runLocalCommand(["tar", "-tf", archivePath], 10000, 1024 * 1024 * 4);
    if (names.status != 0 || names.outputTruncated)
        throw new Exception("Unable to list complete archive paths");
    size_t nameCount;
    foreach (name; names.output.split('\n')) {
        if (!name.length) continue;
        if (++nameCount > 4096) throw new Exception("Archive contains too many entries");
        validateArchiveEntryName(name);
    }
    // GNU and BSD tar have different verbose columns. Never obtain paths by
    // guessing a whitespace column: BSD's column 5 is the month, not the name.
    auto res = runLocalCommand(["tar", "--numeric-owner", "-tvf", archivePath], 10000, 1024 * 1024 * 4);
    if (res.status != 0 || res.outputTruncated)
        throw new Exception("Unable to inspect complete archive metadata");
    ulong expanded;
    size_t metadataCount;
    foreach (line; res.output.split('\n')) {
        auto row = line.strip();
        if (!row.length) continue;
        auto cols = row.split();
        if (cols.length < 6 || (row[0] != '-' && row[0] != 'd'))
            throw new Exception("Archive contains a link, special file or invalid metadata");
        import std.conv : to;
        size_t sizeColumn = cols[1].all!isDigit ? 4 : 2;
        ulong size = to!ulong(cols[sizeColumn]);
        if (size > 512UL * 1024 * 1024 - expanded)
            throw new Exception("Expanded archive exceeds size limit");
        expanded += size;
        metadataCount++;
    }
    if (!nameCount || metadataCount != nameCount)
        throw new Exception("Archive metadata is incomplete or ambiguous");

}

string stageVerifiedArchive(string archivePath, string versionsDir, string targetVersion) {
    validateReleaseDirectoryName(targetVersion);
    inspectTarArchiveSafety(archivePath);

    if (!exists(versionsDir)) mkdirRecurse(versionsDir);
    auto stageDir = versionsDir ~ "/.staging-" ~ targetVersion ~ "-" ~ randomUUID().toString();
    auto finalDir = versionsDir ~ "/" ~ targetVersion;

    // Never replace a version that a running service or rollback pointer uses.
    if (exists(finalDir)) throw new Exception("Release already exists; installed versions are immutable");

    if (exists(stageDir)) rmdirRecurse(stageDir);
    mkdirRecurse(stageDir);

    scope (failure) {
        if (exists(stageDir)) {
            try { rmdirRecurse(stageDir); } catch (Exception) {}
        }
    }

    version (linux) {
        auto ex = runLocalCommand(["tar", "--no-same-owner", "--no-same-permissions", "-xzf", archivePath, "-C", stageDir], 30000, 1024 * 1024);
    } else {
        // macOS and Windows bsdtar support both .tar.gz and .zip via -xf
        auto ex = runLocalCommand(["tar", "-xf", archivePath, "-C", stageDir], 30000, 1024 * 1024);
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
    auto verCheck = runLocalCommand([stageDir ~ binRel, "version"], 5000, 4096);
    if (verCheck.status != 0 || !verCheck.output.canFind(targetVersion)) {
        throw new Exception("Staged hikari binary failed version validation");
    }

    version (Posix) {
        import std.file : dirEntries, SpanMode;
        foreach (entry; dirEntries(stageDir, SpanMode.depth))
            if (entry.isFile) syncUpdatePath(entry.name);
        foreach (entry; dirEntries(stageDir, SpanMode.depth))
            if (entry.isDir) syncUpdatePath(entry.name, true);
        syncUpdatePath(stageDir, true);
    }
    rename(stageDir, finalDir);
    syncUpdatePath(versionsDir, true);
    return finalDir;
}
