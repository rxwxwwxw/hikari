#!/usr/bin/env python3
"""Measure an idle native agent with two OS samples; never contact its HTTP API."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


class Usage(ctypes.Structure):
    _fields_ = [("ignored_uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user_ticks", "system_ticks", "package_wakeups", "interrupt_wakeups", "pageins", "wired_bytes",
        "resident_bytes", "footprint_bytes", "start", "exit", "child_user", "child_system",
        "child_package_wakeups", "child_interrupt_wakeups", "child_pageins", "child_elapsed",
        "disk_read_bytes", "disk_write_bytes")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seconds", type=float, default=30)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60:
        parser.error("choose an observation window from 1 to 60 seconds")
    repo = Path(__file__).resolve().parents[3]
    system = ctypes.CDLL(None, use_errno=True)
    frequency = ctypes.c_uint64()
    size = ctypes.c_size_t(ctypes.sizeof(frequency))
    if system.sysctlbyname(b"hw.tbfrequency", ctypes.byref(frequency), ctypes.byref(size), None, 0) != 0 or not frequency.value:
        raise OSError(ctypes.get_errno(), "native Mach timebase unavailable")
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    with tempfile.TemporaryDirectory(prefix="hikari-idle-") as directory:
        root = Path(directory)
        state = root / "state"
        state.mkdir()
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        config = {"schema_version": 1, "listen": {"loopback_port": port, "loopback_bind": "127.0.0.1"},
                  "discovery": {"enabled_on_dashboard_open": False}, "paths": {"state_dir": str(state)}}
        (root / "config.json").write_text(json.dumps(config))
        with (root / "output").open("w+") as output:
            child = subprocess.Popen([str(repo / "bin/hikari"), "serve", "--config", str(root / "config.json"),
                                      "--tailscale-fixture", str(repo / "tests/fixtures/tailscale/online_fleet.json")],
                                     stdout=output, stderr=subprocess.STDOUT)
            try:
                for _ in range(100):
                    if "listening on" in (root / "output").read_text(): break
                    if child.poll() is not None: raise RuntimeError((root / "output").read_text())
                    time.sleep(0.05)
                else: raise RuntimeError("agent did not start")

                def usage():
                    value = Usage()
                    if lib.proc_pid_rusage(child.pid, 2, ctypes.byref(value)) != 0:
                        raise OSError(ctypes.get_errno(), "proc_pid_rusage")
                    return value

                before = usage()
                files_before = {p.name: (p.stat().st_size, p.stat().st_mtime_ns) for p in state.iterdir()}
                started = time.monotonic()
                time.sleep(args.seconds)
                elapsed = time.monotonic() - started
                after = usage()
                connections = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(child.pid), "-i"],
                                             text=True, capture_output=True, timeout=5)
                lines = connections.stdout.splitlines()[1:]
                assert len(lines) == 1 and f"127.0.0.1:{port} (LISTEN)" in lines[0], "unexpected agent network socket"
                files_after = {p.name: (p.stat().st_size, p.stat().st_mtime_ns) for p in state.iterdir()}
                assert files_before == files_after, "idle agent changed persistent state"
                assert not (state / "hardware_cache.json").exists(), "idle agent scanned hardware"
                cpu_ticks = (after.user_ticks + after.system_ticks) - (before.user_ticks + before.system_ticks)
                cpu_ns = cpu_ticks * 1_000_000_000 / frequency.value
                print(json.dumps({"window_s": round(elapsed, 3), "cpu_time_ms": cpu_ns / 1e6,
                                  "average_one_core_cpu_pct": 100 * cpu_ns / (elapsed * 1e9),
                                  "rss_bytes": after.resident_bytes,
                                  "package_wakeups": after.package_wakeups - before.package_wakeups,
                                  "interrupt_wakeups": after.interrupt_wakeups - before.interrupt_wakeups,
                                  "disk_read_bytes": after.disk_read_bytes - before.disk_read_bytes,
                                  "disk_write_bytes": after.disk_write_bytes - before.disk_write_bytes,
                                  "outbound_connections_at_end": 0, "state_unchanged": True}, indent=2))
            finally:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()


if __name__ == "__main__": main()
