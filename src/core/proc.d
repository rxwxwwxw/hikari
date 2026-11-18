module core.proc;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.process : kill, pipe, spawnProcess, tryWait, wait, Config, Pid;
import std.stdio : File;

/// Result of a bounded subprocess run. `output` holds at most `maxOutput` bytes
/// of stdout; stderr is discarded.
struct BoundedProcResult {
    bool started = false;
    bool timedOut = false;
    bool truncated = false;
    int status = -1;
    string output;
}

version (Windows) private enum string NULL_DEVICE = "NUL";
else private enum string NULL_DEVICE = "/dev/null";

/// Runs `args` with stdin/stderr attached to the null device and stdout captured,
/// killing the child if it has not exited within `timeoutMs`. Unlike
/// std.process.execute this never blocks a caller indefinitely on a wedged tool
/// (e.g. `tailscale status` while tailscaled is hung).
BoundedProcResult executeBounded(const string[] args, uint timeoutMs, size_t maxOutput) {
    BoundedProcResult r;
    Pid pid;
    File readEnd;
    try {
        auto p = pipe();
        readEnd = p.readEnd;
        auto nullIn = File(NULL_DEVICE, "r");
        auto nullErr = File(NULL_DEVICE, "w");
        // spawnProcess closes the passed (non-standard) handles in the parent.
        pid = spawnProcess(args, nullIn, p.writeEnd, nullErr, null, Config.none);
    } catch (Exception) {
        return r;
    }
    r.started = true;

    // Drain stdout on a helper thread so a chatty child never blocks on a full pipe.
    shared bool readerDone = false;
    char[] buf;
    bool truncated = false;
    auto reader = new Thread({
        try {
            ubyte[4096] chunk;
            while (true) {
                auto got = readEnd.rawRead(chunk[]);
                if (got.length == 0) break;
                if (buf.length < maxOutput) {
                    auto take = got.length;
                    if (buf.length + take > maxOutput) {
                        take = maxOutput - buf.length;
                        truncated = true;
                    }
                    buf ~= cast(const(char)[]) got[0 .. take];
                } else {
                    truncated = true;
                }
            }
        } catch (Exception) {}
        atomicStore(readerDone, true);
    });
    reader.isDaemon = true;
    reader.start();

    auto deadline = MonoTime.currTime + msecs(timeoutMs);
    bool exited = false;
    while (true) {
        try {
            auto tw = tryWait(pid);
            if (tw.terminated) {
                r.status = tw.status;
                exited = true;
                break;
            }
        } catch (Exception) {
            break;
        }
        if (MonoTime.currTime >= deadline) break;
        Thread.sleep(msecs(10));
    }

    if (!exited) {
        r.timedOut = true;
        try { kill(pid); } catch (Exception) {}
        try { r.status = wait(pid); } catch (Exception) {}
    }

    // The pipe reaches EOF once the child is gone; never wait on it unboundedly
    // (a grandchild could inherit the handle).
    auto readerDeadline = MonoTime.currTime + msecs(1000);
    while (!atomicLoad(readerDone) && MonoTime.currTime < readerDeadline) {
        Thread.sleep(msecs(5));
    }
    if (atomicLoad(readerDone)) {
        r.output = buf.idup;
        r.truncated = truncated;
        try { readEnd.close(); } catch (Exception) {}
    } else {
        r.truncated = true;
    }
    return r;
}
