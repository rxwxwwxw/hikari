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

string parseCaddyVersionOutput(string raw) pure @safe {
    import std.string : split, strip;
    foreach (line; raw.split('\n')) {
        auto clean = line.strip();
        if (clean.length == 0) continue;
        auto parts = clean.split();
        if (parts.length == 0) return "";
        auto t = parts[0];
        if (t.length > 0 && (t[0] == 'v' || t[0] == 'V')) t = t[1 .. $];
        if (t.length == 0 || t[0] < '0' || t[0] > '9') return "";
        return t.idup;
    }
    return "";
}

string parseTailscaleVersionOutput(string raw) pure @safe {
    import std.string : indexOf, split, strip;
    foreach (line; raw.split('\n')) {
        auto clean = line.strip();
        if (clean.length == 0) continue;
        foreach (tok; clean.split()) {
            auto t = tok;
            if (t.length > 0 && (t[0] == 'v' || t[0] == 'V')) t = t[1 .. $];
            if (t.length == 0 || t[0] < '0' || t[0] > '9') continue;
            size_t cut = t.length;
            foreach (marker; ["-t", "-g", "-ERR"]) {
                auto idx = t.indexOf(marker);
                if (idx >= 0 && cast(size_t) idx < cut) cut = cast(size_t) idx;
            }
            return t[0 .. cut].idup;
        }
        return "";
    }
    return "";
}

string caddyExecutable(string stateDir = "") {
    import caddyfile.integrate : IntegrationRecord, loadIntegrationRecord;
    import std.file : exists, isDir;
    import std.path : buildPath, dirName;
    import std.process : environment;
    import std.string : split;

    static bool isUsableFile(string p) {
        if (p.length == 0 || !exists(p)) return false;
        try { return !isDir(p); } catch (Exception) { return false; }
    }

    if (stateDir.length > 0) {
        IntegrationRecord rec;
        if (loadIntegrationRecord(stateDir, rec) && isUsableFile(rec.caddyBin)) {
            return rec.caddyBin;
        }
    }

    version (Windows) {
        if (stateDir.length > 0) {
            auto sib = buildPath(dirName(stateDir), "bin", "caddy.exe");
            if (isUsableFile(sib)) return sib;
        }
        if (isUsableFile(`C:\ProgramData\hikari\bin\caddy.exe`)) {
            return `C:\ProgramData\hikari\bin\caddy.exe`;
        }
        foreach (dir; environment.get("PATH", "").split(';')) {
            if (!dir.length) continue;
            auto cand = buildPath(dir, "caddy.exe");
            if (isUsableFile(cand)) return cand;
        }
    } else {
        if (stateDir.length > 0) {
            auto sib = buildPath(dirName(stateDir), "bin", "caddy");
            if (isUsableFile(sib)) return sib;
        }
        foreach (cand; ["/opt/hikari/bin/caddy", "/opt/homebrew/bin/caddy", "/usr/local/bin/caddy", "/usr/bin/caddy"]) {
            if (isUsableFile(cand)) return cand;
        }
        foreach (dir; environment.get("PATH", "/usr/local/bin:/usr/bin:/bin").split(':')) {
            if (!dir.length) continue;
            auto cand = buildPath(dir, "caddy");
            if (isUsableFile(cand)) return cand;
        }
    }
    return "";
}

string queryLocalCaddyVersion(string stateDir = "") {
    import core.proc : executeBounded;
    import std.algorithm : canFind;
    import std.file : exists;
    auto bin = caddyExecutable(stateDir);
    if (bin.length == 0) return "";
    if ((bin.canFind('/') || bin.canFind('\\')) && !exists(bin)) return "";
    auto res = executeBounded([bin, "version"], 3000, 4096);
    if (!res.started || res.timedOut || res.status != 0) return "";
    return parseCaddyVersionOutput(res.output);
}

string queryLocalTailscaleVersion(string tailscaleFixture = "") {
    import core.proc : executeBounded;
    import std.file : exists, readText;
    import std.json : JSONType, parseJSON;
    import std.process : environment;

    auto fixture = tailscaleFixture.length > 0
        ? tailscaleFixture
        : environment.get("HIKARI_TAILSCALE_FIXTURE", "");
    if (fixture.length > 0 && exists(fixture)) {
        try {
            auto j = parseJSON(readText(fixture));
            if (j.type == JSONType.object) {
                if (auto pv = "Version" in j.object) {
                    if (pv.type == JSONType.string) return parseTailscaleVersionOutput(pv.str);
                }
            }
        } catch (Exception) {}
        return "";
    }

    string bin;
    version (Windows) {
        foreach (base; [environment.get("ProgramFiles", `C:\Program Files`), environment.get("ProgramW6432", "")]) {
            if (base.length == 0) continue;
            auto cand = base ~ `\Tailscale\tailscale.exe`;
            if (exists(cand)) { bin = cand; break; }
        }
    }
    if (bin.length == 0) bin = tailscaleExecutable();
    if (bin.length == 0) return "";
    auto res = executeBounded([bin, "version"], 3000, 4096);
    if (!res.started || res.timedOut || res.status != 0) return "";
    return parseTailscaleVersionOutput(res.output);
}
