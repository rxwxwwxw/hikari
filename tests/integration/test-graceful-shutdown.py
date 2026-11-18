#!/usr/bin/env python3
"""A service stop must drain an accepted HTTP request before process exit."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

if os.name != "posix":
    raise SystemExit("Use the SCM lifecycle test on Windows")
repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="hikari-drain-") as directory:
    root = Path(directory)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    (root / "config.json").write_text(json.dumps({
        "listen": {"loopback_port": port},
        "paths": {"state_dir": str(root / "state")},
    }))
    child = subprocess.Popen([
        str(repo / "bin/hikari"), "serve", "--config", str(root / "config.json"),
        "--fixture", "desktop-x86_64", "--tailscale-fixture",
        str(repo / "tests/fixtures/tailscale/online_fleet.json"),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 5
        while True:
            try:
                pending = socket.create_connection(("127.0.0.1", port), timeout=2)
                break
            except OSError:
                if child.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError(child.stderr.read().decode())
                time.sleep(0.02)
        with pending:
            pending.sendall(b"GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n")
            # A second connection completing proves accept() reached the first.
            with socket.create_connection(("127.0.0.1", port), timeout=2) as ready:
                ready.sendall(b"GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                assert b"200 OK" in ready.recv(8192)
            child.send_signal(signal.SIGTERM)
            time.sleep(0.05)
            assert child.poll() is None, "SIGTERM discarded an accepted request"
            pending.sendall(b"\r\n")
            response = b""
            while chunk := pending.recv(8192):
                response += chunk
            assert b"200 OK" in response and b'"status":"ok"' in response
        assert child.wait(timeout=5) == 0
        print("Graceful SIGTERM drained the accepted response and exited successfully.")
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
        child.stderr.close()
