module core.proc;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
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
// Held from pipe creation until spawnProcess has closed the parent's copy of the
// child's stdout write end. Windows children inherit every inheritable handle in
// the process, so without this two concurrent calls (parallel peer probes) could
// each give their child the other's write end; that pipe would then not reach
// EOF until the unrelated child exited.
private __gshared Mutex spawnLock;
shared static this() { spawnLock = new Mutex(); }

// Owned by the reader thread, which alone reads and closes `readEnd`. Being a
// GC object, it is never destroyed when executeBounded returns, so a reader
// still blocked in rawRead (child gone but pipe held open elsewhere) can never
// see its FILE closed underneath it. On Windows that is a CRT invalid-parameter
// fail-fast (0xc0000409) that kills the whole agent.
private final class PipeReader {
    File readEnd;
    char[] buf;
    bool truncated;
    shared bool done;
    size_t maxOutput;

    void run() {
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
        try { readEnd.close(); } catch (Exception) {}
        atomicStore(done, true);
    }
}

BoundedProcResult executeBounded(const string[] args, uint timeoutMs, size_t maxOutput) {
    BoundedProcResult r;
    Pid pid;
    auto state = new PipeReader;
    state.maxOutput = maxOutput;
    try {
        synchronized (spawnLock) {
            auto p = pipe();
            state.readEnd = p.readEnd;
            auto nullIn = File(NULL_DEVICE, "r");
            auto nullErr = File(NULL_DEVICE, "w");
            // spawnProcess closes the passed (non-standard) handles in the parent.
            pid = spawnProcess(args, nullIn, p.writeEnd, nullErr, null, Config.none);
        }
    } catch (Exception) {
        try { state.readEnd.close(); } catch (Exception) {}
        return r;
    }
    r.started = true;

    // Drain stdout on a helper thread so a chatty child never blocks on a full pipe.
    auto reader = new Thread(&state.run);
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
    while (!atomicLoad(state.done) && MonoTime.currTime < readerDeadline) {
        Thread.sleep(msecs(5));
    }
    if (atomicLoad(state.done)) {
        r.output = state.buf.idup;
        r.truncated = state.truncated;
    } else {
        // The reader keeps (and eventually closes) its pipe; just report no output.
        r.truncated = true;
    }
    return r;
}
