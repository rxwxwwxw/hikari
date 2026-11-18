#!/usr/bin/env python3
"""A blocked local Tailscale CLI must not delay health or info availability."""
import json
import os
from pathlib import Path
import socket
import signal
import subprocess
import tempfile
import time
import urllib.request

repo = Path(__file__).resolve().parents[3]
with tempfile.TemporaryDirectory(prefix="hikari-startup-") as directory:
    root = Path(directory)
    (root / "bin").mkdir()
    (root / "bin/tailscale").write_text('#!/bin/sh\nprintf started > "$HIKARI_TEST_STARTUP_MARKER"\nexec /bin/sleep 5\n')
    (root / "bin/tailscale").chmod(0o755)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    config = {"schema_version": 1, "listen": {"loopback_bind": "127.0.0.1", "loopback_port": port},
              "paths": {"state_dir": str(root / "state")}}
    (root / "config.json").write_text(json.dumps(config))
    environment = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                       HIKARI_TEST_STARTUP_MARKER=str(root / "lookup-started"))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with (root / "output").open("w+") as output:
        started = time.monotonic()
        child = subprocess.Popen([str(repo / "bin/hikari"), "serve", "--config", str(root / "config.json")],
                                 env=environment, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = started + 3
            while time.monotonic() < deadline:
                try:
                    with opener.open(f"http://127.0.0.1:{port}/healthz", timeout=0.25) as response:
                        assert response.status == 200
                    break
                except OSError:
                    if child.poll() is not None:
                        raise RuntimeError((root / "output").read_text())
                    time.sleep(0.025)
            else:
                raise AssertionError("loopback health waited for the Tailscale CLI")
            while not (root / "lookup-started").exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            assert (root / "lookup-started").exists(), "slow Tailscale fixture did not start"
            with opener.open(f"http://127.0.0.1:{port}/api/v1/info", timeout=0.5) as response:
                info = json.loads(response.read())
            assert info["app"] == "hikari" and info["hardware_summary"] is None
            assert time.monotonic() - started < 3
            print("Loopback health/info became available before a blocked Tailscale CLI completed.")
        finally:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
