module platform.command;

import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.process : pipeProcess, Redirect, tryWait, wait, kill;

struct CommandResult {
    int status = -1;
    string output;
    bool timedOut;
    bool outputTruncated;
}

// For trusted local tools only. Drain output concurrently, cap retained bytes,
// kill/reap on deadline, and never involve a shell or interpolate arguments.
CommandResult runLocalCommand(const string[] args, uint timeoutMs = 5000,
    size_t maxOutput = 65536) {
    CommandResult result;
    auto pipes = pipeProcess(args, Redirect.stdout | Redirect.stderrToStdout);
    scope (exit) pipes.stdout.close();
    version (Posix) {
        import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
        import core.sys.posix.unistd : read;
        auto fd = pipes.stdout.fileno();
        if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) {
            kill(pipes.pid, 9);
            wait(pipes.pid);
            throw new Exception("Unable to configure bounded command output");
        }
        void drain() {
            char[4096] buffer;
            // Cap each pass too: a noisy process cannot starve the deadline.
            foreach (_; 0 .. 64) {
                auto n = read(fd, buffer.ptr, buffer.length);
                if (n <= 0) break;
                auto remaining = maxOutput - result.output.length;
                if (n > remaining) result.outputTruncated = true;
                if (remaining) result.output ~= buffer[0 .. n < remaining ? n : remaining];
            }
        }
        auto deadline = MonoTime.currTime + msecs(timeoutMs);
        while (true) {
            drain();
            auto state = tryWait(pipes.pid);
            if (state.terminated) {
                result.status = state.status;
                drain();
                break;
            }
            if (MonoTime.currTime >= deadline) {
                result.timedOut = true;
                kill(pipes.pid, 9);
                result.status = wait(pipes.pid);
                drain();
                break;
            }
            Thread.sleep(msecs(10));
        }
    } else {
        auto reader = new Thread({
            char[4096] buffer;
            try {
                while (true) {
                    auto chunk = pipes.stdout.rawRead(buffer[]);
                    if (!chunk.length) break;
                    auto remaining = maxOutput - result.output.length;
                    if (chunk.length > remaining) result.outputTruncated = true;
                    if (remaining) result.output ~= chunk[0 .. chunk.length < remaining ? chunk.length : remaining];
                }
            } catch (Exception) {}
        });
        reader.start();
        auto deadline = MonoTime.currTime + msecs(timeoutMs);
        while (true) {
            auto state = tryWait(pipes.pid);
            if (state.terminated) {
                result.status = state.status;
                break;
            }
            if (MonoTime.currTime >= deadline) {
                result.timedOut = true;
                kill(pipes.pid, 9);
                result.status = wait(pipes.pid);
                break;
            }
            Thread.sleep(msecs(10));
        }
        reader.join();
    }
    return result;
}

string tailscaleExecutable() {
    import std.process : environment;
    import std.file : exists;
    import std.path : buildPath;
    import std.string : split;
    version (Windows) enum separator = ';';
    else enum separator = ':';
    version (Windows) enum binary = "tailscale.exe";
    else enum binary = "tailscale";
    foreach (dir; environment.get("PATH", "").split(separator)) {
        if (!dir.length) continue;
        auto candidate = buildPath(dir, binary);
        if (exists(candidate)) return candidate;
    }
    version (OSX) {
        foreach (candidate; ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/tailscale"])
            if (exists(candidate)) return candidate;
    }
    return binary;
}
