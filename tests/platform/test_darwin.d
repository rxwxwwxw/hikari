module tests.platform.test_darwin;

version (OSX):

import core.model;
import core.tracker;
import core.time : MonoTime, msecs;
import platform.darwin;
import std.algorithm : canFind;
import std.process : thisProcessID;
import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
import core.sys.posix.unistd : sysconf, _SC_CLK_TCK;

private long selfCpuMicroseconds() {
    rusage usage;
    assert(getrusage(RUSAGE_SELF, &usage) == 0);
    return (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000L
        + usage.ru_utime.tv_usec + usage.ru_stime.tv_usec;
}

unittest {
    auto backend = new DarwinPlatformBackend;
    auto identity = backend.identity();
    import platform.clock : continuousBootNanoseconds;
    assert(continuousBootNanoseconds() > 0);
    assert(identity.os == "darwin");
    assert(identity.host.length && identity.boot_id.length);
    assert(!identity.uptime_s.isNull && identity.uptime_s.get > 0);
    auto memory = backend.sampleMemory();
    assert(memory.state == CapabilityState.ok);
    assert(!memory.total_bytes.isNull && !memory.used_bytes.isNull);
    assert(memory.used_bytes.get <= memory.total_bytes.get);
    auto cpuBefore = selfCpuMicroseconds();
    auto first = backend.sampleProcesses();
    assert(first.state == CapabilityState.ok);
    assert(first.processes.canFind!(p => p.pid == thisProcessID));
    auto deadline = MonoTime.currTime + msecs(3000);
    while (selfCpuMicroseconds() - cpuBefore < 100_000 && MonoTime.currTime < deadline) {}
    auto second = backend.sampleProcesses();
    auto cpuAfter = selfCpuMicroseconds();
    ulong oldTicks, newTicks;
    string start;
    foreach (p; first.processes) if (p.pid == thisProcessID) {
        oldTicks = p.cpu_ticks;
        start = p.start_id;
    }
    foreach (p; second.processes) if (p.pid == thisProcessID) {
        newTicks = p.cpu_ticks;
        assert(p.start_id == start);
        assert(p.rss_bytes > 0 && p.memory_kind == "rss");
    }
    auto expected = (cpuAfter - cpuBefore) * sysconf(_SC_CLK_TCK) / 1_000_000.0;
    assert(expected >= 3, "Insufficient measured CPU work for the process-time check");
    double actual = newTicks - oldTicks;
    assert(actual >= expected * 0.5 && actual <= expected * 2 + 2,
        "libproc scheduler ticks must agree with independently measured getrusage CPU time");
    auto mounts = backend.sampleFilesystems();
    assert(mounts.state == CapabilityState.ok);
    assert(mounts.mounts.canFind!(m => m.mount == "/"));
    auto gpu = backend.sampleGpus();
    assert(gpu.state == CapabilityState.unsupported);
    auto batteries = backend.sampleBatteries();
    assert(batteries.state == CapabilityState.ok);
    foreach (b; batteries.batteries) {
        assert(b.id.length);
        assert(b.pct.isNull || (b.pct.get >= 0 && b.pct.get <= 100));
    }
}

unittest {
    import platform.command : runLocalCommand;
    auto result = runLocalCommand(["/usr/bin/printf", "%s", "literal $(not-a-command)"], 1000, 128);
    assert(result.status == 0 && result.output == "literal $(not-a-command)");
    auto capped = runLocalCommand(["/usr/bin/printf", "1234567890"], 1000, 4);
    assert(capped.status == 0 && capped.output == "1234");
    auto start = MonoTime.currTime;
    auto slow = runLocalCommand(["/bin/sleep", "5"], 80);
    assert(slow.timedOut);
    assert(MonoTime.currTime - start < msecs(2000), "local tool deadline must terminate and reap");
}
