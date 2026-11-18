#!/usr/bin/env python3
"""Exercise the actual bootstrap verifier with signed benign/malicious archives."""
import hashlib
import importlib.util
import io
import os
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import types
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("verifier", REPO / "install/verify-release.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class ReleaseVerification(unittest.TestCase):
    def test_windows_paths_and_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "release.zip"
            def package(name=None, link=False):
                with zipfile.ZipFile(archive, "w") as bundle:
                    bundle.writestr("hikari.exe", b"binary")
                    bundle.writestr("web/index.html", b"dashboard")
                    if name:
                        entry = zipfile.ZipInfo(name)
                        if link:
                            entry.create_system = 3
                            entry.external_attr = 0o120777 << 16
                        bundle.writestr(entry, b"target")
            package()
            verifier.extract_zip(archive, root / "stage")
            self.assertEqual((root / "stage/hikari.exe").read_bytes(), b"binary")
            for name in ("../outside", "/absolute", "C:/outside", "web\\evil", "file:stream",
                         "NUL.txt", "COM1", "trailing.", "trailing ", "HIKARI.EXE"):
                package(name)
                with self.subTest(name=name), self.assertRaises(ValueError):
                    verifier.extract_zip(archive, None)
            package("link", True)
            with self.assertRaises(ValueError):
                verifier.extract_zip(archive, None)

    def test_signed_archive_and_failures(self):
        with tempfile.TemporaryDirectory(prefix="hikari-trust-") as directory:
            root = Path(directory)
            private, public = root / "private.pem", root / "public.pem"
            subprocess.run(["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(private)], check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)], check=True, capture_output=True)
            args = types.SimpleNamespace(archive=str(root / "release.tar.gz"), manifest=str(root / "manifest.json"),
                                         signature=str(root / "manifest.sig"), public_key=str(public), repo="example/hikari",
                                         os="darwin", arch="arm64", extract_dir=None)

            def package(extra=None):
                with tarfile.open(args.archive, "w:gz") as tar:
                    for name in ("hikari", "web/index.html"):
                        data = b"test release\n"
                        info = tarfile.TarInfo(name)
                        info.size = len(data)
                        info.mode = 0o755 if name == "hikari" else 0o644
                        tar.addfile(info, io.BytesIO(data))
                    if extra:
                        tar.addfile(extra)
                data = Path(args.archive).read_bytes()
                manifest = {"schema_version": 1, "repo": args.repo, "version": "0.2.0", "artifacts": [
                    {"os": "darwin", "arch": "arm64", "sha256": hashlib.sha256(data).hexdigest(), "size_bytes": len(data)}]}
                Path(args.manifest).write_text(json.dumps(manifest))
                subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(private), "-rawin", "-in", args.manifest,
                                "-out", args.signature], check=True, capture_output=True)

            package()
            self.assertEqual(verifier.verify(args), "0.2.0")
            args.extract_dir = str(root / "stage")
            verifier.verify(args)
            if os.name != "nt":
                self.assertEqual((root / "stage/hikari").stat().st_mode & 0o777, 0o755)
            args.extract_dir = None
            Path(args.archive).write_bytes(b"tampered")
            with self.assertRaises(ValueError): verifier.verify(args)
            package()
            args.arch = "x86_64"
            with self.assertRaises(ValueError): verifier.verify(args)
            args.arch = "arm64"
            Path(args.manifest).write_text(Path(args.manifest).read_text() + " ")
            with self.assertRaises(subprocess.CalledProcessError): verifier.verify(args)
            for name, kind in (("../outside", tarfile.REGTYPE), ("link", tarfile.SYMTYPE), ("hard", tarfile.LNKTYPE)):
                info = tarfile.TarInfo(name)
                info.type = kind
                info.linkname = "hikari"
                package(info)
                with self.assertRaises(ValueError): verifier.verify(args)
            self.assertFalse((root / "outside").exists())


if __name__ == "__main__": unittest.main()
