#!/usr/bin/env python3
"""Verify a pinned Ed25519 manifest and extract a bounded, regular-file-only tar."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile

MAX_BYTES = 512 * 1024 * 1024


def verify(args):
    # All verification and extraction use a private snapshot. Replacing a source
    # path after its digest was checked cannot change the bytes we extract.
    with tempfile.TemporaryDirectory(prefix="hikari-verify-") as directory:
        snapshot = argparse.Namespace(**vars(args))
        for field, limit in (("archive", MAX_BYTES), ("manifest", 1024 * 1024),
                             ("signature", 4096), ("public_key", 65536)):
            destination = Path(directory) / field
            total = 0
            with Path(getattr(args, field)).open("rb") as source, destination.open("xb") as output:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    total += len(chunk)
                    if total > limit:
                        raise ValueError(f"{field} exceeds size limit")
                    output.write(chunk)
            setattr(snapshot, field, str(destination))
        return verify_snapshot(snapshot)


def verify_snapshot(args):
    archive = Path(args.archive)
    manifest = Path(args.manifest)
    signature = Path(args.signature)
    if manifest.stat().st_size > 1024 * 1024 or signature.stat().st_size > 4096:
        raise ValueError("Manifest or signature exceeds size limit")
    subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", args.public_key,
                    "-rawin", "-in", str(manifest), "-sigfile", str(signature)],
                   check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data = json.loads(manifest.read_text())
    if not isinstance(data, dict):
        raise ValueError("Manifest must be an object")
    if data.get("schema_version") != 1 or data.get("repo") != args.repo:
        raise ValueError("Manifest schema or pinned repository mismatch")
    version = data.get("version", "")
    # Directory names must be canonical numeric versions (optional safe prerelease).
    import re
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?", version):
        raise ValueError("Invalid release version")
    candidates = [a for a in data.get("artifacts", []) if isinstance(a, dict) and a.get("os") == args.os and a.get("arch") == args.arch]
    if len(candidates) != 1:
        raise ValueError("Manifest must contain exactly one matching artifact")
    artifact = candidates[0]
    size = archive.stat().st_size
    if not 0 < size <= MAX_BYTES or size != artifact.get("size_bytes"):
        raise ValueError("Archive size mismatch or size limit exceeded")
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != artifact.get("sha256"):
        raise ValueError("Archive digest mismatch")
    with tarfile.open(archive, "r:gz") as tar:
        members = []
        total = 0
        seen = set()
        for member in tar:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or "\\" in member.name:
                raise ValueError("Unsafe archive path")
            if not member.isdir() and not member.isfile():
                raise ValueError("Archive contains a link or special file")
            if str(path) in seen:
                raise ValueError("Duplicate archive path")
            seen.add(str(path))
            total += member.size
            members.append(member)
            if total > MAX_BYTES or len(members) > 4096:
                raise ValueError("Expanded archive exceeds limits")
        if "hikari" not in seen or "web/index.html" not in seen:
            raise ValueError("Release is missing required files")
        if args.extract_dir:
            destination = Path(args.extract_dir)
            destination.mkdir(parents=True, exist_ok=True)
            for member in members:
                target = destination.joinpath(*PurePosixPath(member.name).parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    target.chmod(0o755)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(member) as source, target.open("xb") as output:
                        shutil.copyfileobj(source, output, 1024 * 1024)
                    target.chmod(0o755 if member.mode & 0o111 else 0o644)
    return version


def main():
    parser = argparse.ArgumentParser()
    for field in ("archive", "manifest", "signature", "public-key", "repo", "os", "arch"):
        parser.add_argument("--" + field, required=True)
    parser.add_argument("--extract-dir")
    args = parser.parse_args()
    try:
        print(verify(args))
    except (ValueError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Release verification failed: {error}\n")


if __name__ == "__main__":
    main()
