module platform.clock;

// A clock that includes suspend is paired with monotonic scheduling so rate
// trackers can discard samples that span sleep, without trusting wall time.
long continuousBootNanoseconds() {
    version (linux) {
        import core.sys.posix.time : clock_gettime, timespec;
        timespec ts;
        if (clock_gettime(7 /* CLOCK_BOOTTIME */, &ts) == 0)
            return cast(long) ts.tv_sec * 1_000_000_000L + cast(long) ts.tv_nsec;
    } else version (OSX) {
        Timebase scale;
        if (mach_timebase_info(&scale) == 0 && scale.denom != 0) {
            ulong ticks = mach_continuous_time();
            ulong whole = ticks / scale.denom;
            if (scale.numer != 0 && whole <= long.max / scale.numer) {
                ulong ns = whole * scale.numer + (ticks % scale.denom) * scale.numer / scale.denom;
                if (ns <= long.max) return cast(long) ns;
            }
        }
    } else version (Windows) {
        auto ms = GetTickCount64();
        if (ms <= long.max / 1_000_000) return cast(long) ms * 1_000_000L;
    }
    return -1;
}

version (Windows) private extern (Windows) ulong GetTickCount64() nothrow @nogc;

version (OSX) {
    private struct Timebase { uint numer, denom; }
    private extern (C) nothrow @nogc {
        int mach_timebase_info(Timebase* info);
        ulong mach_continuous_time();
    }
}
