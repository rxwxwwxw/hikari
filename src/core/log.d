module core.log;

import core.serializer : sanitizeOsString;
import core.sync.mutex : Mutex;
import std.datetime.systime : Clock, SysTime;
import std.file : exists, getSize, mkdirRecurse, remove, rename;
import std.format : format;
import std.path : dirName;
import std.stdio : File, stderr, stdout;

enum LogLevel { debug_, info, warn, error }

private string levelName(LogLevel l) pure nothrow @safe {
    final switch (l) {
        case LogLevel.debug_: return "DEBUG";
        case LogLevel.info: return "INFO";
        case LogLevel.warn: return "WARN";
        case LogLevel.error: return "ERROR";
    }
}

/// Formats one log line: `2026-11-17T23:45:52Z INFO message`. Messages are sanitized
/// (control characters stripped, length-limited) so OS strings cannot forge log lines.
string formatLogLine(SysTime t, LogLevel level, string msg) @safe {
    auto u = t.toUTC();
    return format!"%04d-%02d-%02dT%02d:%02d:%02dZ %s %s"(
        u.year, cast(int) u.month, u.day, u.hour, u.minute, u.second,
        levelName(level), sanitizeOsString(msg, 2048));
}

/// Small thread-safe logger. Console mode writes to stdout/stderr (journald, launchd and
/// terminals capture it). File mode is for Windows services, which have no console: it
/// appends to a file and rotates by size (`file`, `file.1` … `file.N`), never unbounded.
final class Logger {
    private Mutex mtx;
    private string filePath;
    private ulong maxBytes;
    private uint keepFiles;
    private File fh;
    private ulong written;
    LogLevel minLevel = LogLevel.info;

    /// Console logger.
    this() {
        mtx = new Mutex();
    }

    /// Rotating file logger.
    this(string filePath, ulong maxBytes = 1024 * 1024, uint keepFiles = 3) {
        mtx = new Mutex();
        this.filePath = filePath;
        this.maxBytes = maxBytes < 4096 ? 4096 : maxBytes;
        this.keepFiles = keepFiles < 1 ? 1 : keepFiles;
        auto dir = dirName(filePath);
        if (dir.length > 0 && !exists(dir)) mkdirRecurse(dir);
        openFile();
    }

    bool isFile() const nothrow @safe { return filePath.length > 0; }

    private void openFile() {
        fh = File(filePath, "ab");
        written = exists(filePath) ? getSize(filePath) : 0;
    }

    private void rotate() {
        fh.close();
        auto oldest = filePath ~ "." ~ formatNum(keepFiles);
        if (exists(oldest)) remove(oldest);
        for (uint i = keepFiles; i > 1; i--) {
            auto src = filePath ~ "." ~ formatNum(i - 1);
            if (exists(src)) rename(src, filePath ~ "." ~ formatNum(i));
        }
        if (exists(filePath)) rename(filePath, filePath ~ ".1");
        openFile();
    }

    private static string formatNum(uint n) {
        return format!"%u"(n);
    }

    void log(LogLevel level, string msg) nothrow {
        if (level < minLevel) return;
        try {
            auto line = formatLogLine(Clock.currTime(), level, msg);
            mtx.lock();
            scope (exit) mtx.unlock();
            if (isFile()) {
                if (written + line.length + 2 > maxBytes && written > 0) rotate();
                fh.write(line, "\r\n");
                fh.flush();
                written += line.length + 2;
            } else if (level >= LogLevel.warn) {
                stderr.writeln(line);
                stderr.flush();
            } else {
                stdout.writeln(line);
                stdout.flush();
            }
        } catch (Exception) {
            // Logging must never take the agent down.
        }
    }

    void info(string msg) nothrow { log(LogLevel.info, msg); }
    void warn(string msg) nothrow { log(LogLevel.warn, msg); }
    void error(string msg) nothrow { log(LogLevel.error, msg); }

    void close() nothrow {
        try {
            mtx.lock();
            scope (exit) mtx.unlock();
            if (fh.isOpen) fh.close();
        } catch (Exception) {}
    }
}
