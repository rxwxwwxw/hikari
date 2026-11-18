module tests.core.test_log;

import core.log;
import core.thread : Thread;
import std.algorithm : canFind, count;
import std.datetime.systime : SysTime;
import std.datetime.date : DateTime;
import std.datetime.timezone : UTC;
import std.file : exists, getSize, mkdirRecurse, readText, rmdirRecurse, tempDir;
import std.path : buildPath;

unittest {
    auto t = SysTime(DateTime(2026, 11, 17, 23, 45, 52), UTC());
    auto line = formatLogLine(t, LogLevel.info, "listening on 127.0.0.1:19100");
    assert(line == "2026-11-17T23:45:52Z INFO listening on 127.0.0.1:19100");
    // Control characters (forged newlines) are stripped from messages.
    auto evil = formatLogLine(t, LogLevel.warn, "name\n2026-01-01T00:00:00Z ERROR fake");
    assert(!evil.canFind('\n'));
}

unittest {
    auto dir = buildPath(tempDir(), "hikari-test-log");
    if (exists(dir)) rmdirRecurse(dir);
    scope (exit) { if (exists(dir)) rmdirRecurse(dir); }

    auto path = buildPath(dir, "logs", "hikari.log"); // parent dirs are created
    auto log = new Logger(path, 4096, 2);
    foreach (i; 0 .. 400) log.info("line with some padding to fill the file quickly ...........");
    log.close();

    assert(exists(path));
    assert(exists(path ~ ".1"));
    assert(exists(path ~ ".2"));
    assert(!exists(path ~ ".3"), "keepFiles bounds the number of rotated files");
    assert(getSize(path) <= 4096);
    assert(getSize(path ~ ".1") <= 4096);

    // Concurrent writers never interleave partial lines.
    auto path2 = buildPath(dir, "concurrent.log");
    auto log2 = new Logger(path2, 1024 * 1024, 1);
    Thread[] ts;
    foreach (n; 0 .. 4) {
        ts ~= new Thread({ foreach (i; 0 .. 200) log2.info("worker-line-payload"); });
        ts[$ - 1].start();
    }
    foreach (t; ts) t.join();
    log2.close();
    auto text = readText(path2);
    assert(text.count("worker-line-payload\r\n") == 800);
}
