#!/usr/bin/env python3
"""Exercise real reconciliation intervals with disposable CLI/Caddy processes."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

repo = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix="hikari-reconcile-lifecycle-") as directory:
    root = Path(directory)
    release = root / "release"
    release.mkdir()
    (release / "caddy").mkdir()
    runtime = root / "runtime"
    source = root / "source"
    events = root / "events"
    events.write_text("")
    source.write_text("configuration-A")
    common = '''import json, os, pathlib, signal, sys, time
root = pathlib.Path(os.environ["HIKARI_TEST_ROOT"])
def event(kind, **values):
    with (root / "events").open("a") as stream:
        stream.write(json.dumps(dict(kind=kind, **values)) + "\\n")
'''
    (release / "hikari").write_text(f"#!{sys.executable}\n" + common + '''
if sys.argv[2] == "validate":
    event("validate")
    sys.exit(0)
value = (root / "source").read_text()
event("render", value=value)
if value == "offline":
    sys.exit(1)
print(value)
''')
    caddy = root / "caddy"
    caddy.write_text(f"#!{sys.executable}\n" + common + '''
value = pathlib.Path(sys.argv[sys.argv.index("--config") + 1]).read_text().strip()
event("start", pid=os.getpid(), value=value)
def stop(*args):
    event("stop", pid=os.getpid())
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
while True:
    time.sleep(1)
''')
    (release / "hikari").chmod(0o755)
    caddy.chmod(0o755)
    environment = dict(os.environ, HIKARI_NETWORK_RECONCILE_S="15", HIKARI_TEST_ROOT=str(root))
    with (root / "output").open("w+") as output:
        child = subprocess.Popen(["/bin/bash", str(repo / "install/macos-caddy.sh"), str(root / "config.json"),
                                  str(caddy), str(runtime), str(release)], env=environment, stdout=output,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        def observed(kind):
            return [event for event in map(json.loads, events.read_text().splitlines()) if event["kind"] == kind]

        def wait_for(check, message, timeout=22):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if check():
                    return
                if child.poll() is not None:
                    raise AssertionError("reconciler exited: " + (root / "output").read_text())
                time.sleep(0.05)
            raise AssertionError(message + "\n" + (root / "output").read_text())

        def alive(pid):
            try:
                os.kill(pid, 0)
                return True
            except ProcessLookupError:
                return False

        try:
            wait_for(lambda: len(observed("start")) == 1, "initial Caddy process did not start", 5)
            first_pid = observed("start")[0]["pid"]
            before = (runtime / "Caddyfile").stat().st_mtime_ns
            wait_for(lambda: len(observed("render")) >= 2, "unchanged reconciliation did not run")
            assert len(observed("start")) == 1
            assert (runtime / "Caddyfile").stat().st_mtime_ns == before, "unchanged config was rewritten"
            source.write_text("configuration-B")
            wait_for(lambda: len(observed("start")) == 2, "changed binding did not replace Caddy")
            assert observed("start")[-1]["value"] == "configuration-B"
            assert not alive(first_pid), "old Caddy process survived address change"
            second_pid = observed("start")[-1]["pid"]
            source.write_text("offline")
            wait_for(lambda: any(e["pid"] == second_pid for e in observed("stop")), "identity loss did not stop Caddy")
            wait_for(lambda: not alive(second_pid), "stopped Caddy process did not exit", 5)
            assert len(observed("start")) == 2, "unavailable identity spawned another Caddy process"
            source.write_text("configuration-C")
            wait_for(lambda: len(observed("start")) == 3, "Caddy did not recover after identity returned")
            assert observed("start")[-1]["value"] == "configuration-C"
            child.terminate()
            child.wait(timeout=15)
            assert all(not alive(e["pid"]) for e in observed("start")), "Caddy process survived shutdown"
            print("Reconciler retained unchanged config, replaced changed binding, closed on identity loss and recovered.")
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
