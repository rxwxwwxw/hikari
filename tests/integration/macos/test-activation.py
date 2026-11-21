#!/usr/bin/env python3
"""Installer activation ordering and its native updater recovery contract."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import unittest

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("activate", REPO / "install/activate-release.py")
activate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activate)


class Activation(unittest.TestCase):
    def test_ordering_health_and_native_recovery(self):
        with tempfile.TemporaryDirectory(prefix="hikari-activation-") as directory:
            root = Path(directory).resolve()
            versions = root / "versions"
            versions.mkdir()

            def release(version, reported=None):
                target = versions / version
                target.mkdir()
                binary = target / "hikari"
                binary.write_text(f"#!/bin/sh\necho 'hikari {reported or version} (schema_version=1)'\n")
                binary.chmod(0o755)
                return target

            old = release("0.1.0")
            new = release("0.2.0")
            (versions / "current").symlink_to(old)
            activate.begin(versions, "0.2.0")
            self.assertEqual((versions / "current").resolve(), new)
            self.assertEqual((versions / "previous").resolve(), old)
            self.assertEqual((versions / ".activation-previous").read_text(), "0.1.0\n")
            seen = []

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    seen.append(self.path)
                    value = {"app": "hikari", "agent_version": "0.2.0"} if self.path.endswith("/info") else {"status": "ok"}
                    payload = json.dumps(value).encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)

                def log_message(self, *args):
                    pass

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            config = root / "config.json"
            config.write_text(json.dumps({"listen": {"loopback_bind": "127.0.0.1", "loopback_port": server.server_port}}))
            try:
                activate.health_confirm(versions, "0.2.0", config)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()
            self.assertEqual(seen, ["/healthz", "/api/v1/info"])
            self.assertFalse((versions / ".activation-previous").exists())
            release("0.3.0", "9.9.9")
            with self.assertRaises(ValueError): activate.begin(versions, "0.3.0")
            self.assertEqual((versions / "current").resolve(), new)
            self.assertFalse((versions / ".activation-previous").exists())
            release("0.4.0")
            activate.begin(versions, "0.4.0")
            # Model installer interruption after the atomic switch. The shipped
            # D recovery command must understand the installer's marker.
            subprocess.run([str(REPO / "bin/hikari"), "update", "recover", "--no-restart",
                            "--config", str(config),
                            "--versions-dir", str(versions), "--state-dir", str(root / "state")], check=True,
                           capture_output=True, text=True)
            self.assertEqual((versions / "current").resolve(), new)
            self.assertFalse((versions / ".activation-previous").exists())
            release("0.5.0")
            activate.begin(versions, "0.5.0")
            self.assertEqual(activate.recover(versions), "0.2.0")
            self.assertEqual((versions / "current").resolve(), new)
            self.assertTrue((versions / ".activation-previous").exists())
            activate.confirm(versions, "0.2.0")
            self.assertFalse((versions / ".activation-previous").exists())


if __name__ == "__main__": unittest.main()
