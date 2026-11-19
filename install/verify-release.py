#!/usr/bin/env python3
"""Verify a pinned Ed25519 manifest and extract a bounded, regular-file-only tar."""
import argparse
import hashlib
import json
import os
import platform
import re
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
import stat

MAX_BYTES = 512 * 1024 * 1024

# macOS /usr/bin/openssl is LibreSSL, which cannot verify Ed25519 with
# `pkeyutl -rawin`, and sudo/launchd PATHs often put it first. Probe well-known
# OpenSSL 3 locations before PATH (mirrors src/platform/openssl.d).
DARWIN_OPENSSL_CANDIDATES = (
    "/opt/homebrew/opt/openssl@3/bin/openssl",  # Homebrew, Apple Silicon
    "/usr/local/opt/openssl@3/bin/openssl",     # Homebrew, Intel
    "/opt/local/libexec/openssl3/bin/openssl",  # MacPorts openssl3
)
OPENSSL_INSTALL_HINT = ("Install OpenSSL 3 (macOS: `brew install openssl@3`; it is found at "
                        "/opt/homebrew/opt/openssl@3 or /usr/local/opt/openssl@3 without changing PATH) "
                        "and retry. Release signatures are never skipped.")


def classify_openssl(version_output):
    """Return (capable, first_line, flavor) for `openssl version` output."""
    line = next((l.strip() for l in version_output.splitlines() if l.strip()), "")[:120]
    if line.startswith("LibreSSL"):
        return False, line, "libressl"
    match = re.match(r"OpenSSL (\d+)\.", line)
    if match:
        return int(match.group(1)) >= 3, line, "openssl"
    return False, line, "openssl" if line.startswith("OpenSSL ") else "unknown"


def _openssl_version(executable):
    result = subprocess.run([executable, "version"], capture_output=True, text=True, timeout=5, check=True)
    return result.stdout


def find_openssl(system=None, which=shutil.which, isfile=os.path.isfile, run_version=_openssl_version):
    """Return an Ed25519-capable OpenSSL executable or raise an actionable ValueError."""
    system = system if system is not None else platform.system()
    candidates = list(DARWIN_OPENSSL_CANDIDATES) if system == "Darwin" else []
    candidates.append("openssl")
    rejected = []
    for candidate in candidates:
        if "/" in candidate:
            if not isfile(candidate):
                continue
            executable = candidate
        else:
            executable = which(candidate)
            if not executable:
                rejected.append(f"{candidate} was not found on PATH")
                continue
        try:
            output = run_version(executable)
        except (OSError, subprocess.SubprocessError):
            rejected.append(f"{executable} could not run")
            continue
        capable, line, flavor = classify_openssl(output)
        if capable:
            return executable
        if flavor == "libressl":
            rejected.append(f"{executable} is {line} (LibreSSL cannot verify Ed25519 signatures with pkeyutl -rawin)")
        elif flavor == "openssl":
            rejected.append(f"{executable} is {line} (OpenSSL 3.0 or newer is required)")
        else:
            rejected.append(f"{executable} reported an unrecognized version '{line}'")
    detail = (": " + "; ".join(rejected)) if rejected else ""
    raise ValueError(f"No Ed25519-capable OpenSSL found for release signature verification{detail}. {OPENSSL_INSTALL_HINT}")


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
    openssl = find_openssl()
    subprocess.run([openssl, "pkeyutl", "-verify", "-pubin", "-inkey", args.public_key,
                    "-rawin", "-in", str(manifest), "-sigfile", str(signature)],
                   check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    data = json.loads(manifest.read_text())
    if not isinstance(data, dict):
        raise ValueError("Manifest must be an object")
    if data.get("schema_version") != 1 or data.get("repo") != args.repo:
        raise ValueError("Manifest schema or pinned repository mismatch")
    version = data.get("version", "")
    # Directory names must be canonical numeric versions (optional safe prerelease).
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
    if args.os == "windows":
        extract_zip(archive, args.extract_dir)
        return version
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


def extract_zip(archive, extract_dir):
    """Validate every entry before writing; reject Windows path aliases and links."""
    import re
    with zipfile.ZipFile(archive) as bundle:
        seen = set()
        total = 0
        entries = []
        for entry in bundle.infolist():
            name = entry.filename
            path = PurePosixPath(name)
            parts = path.parts
            mode = entry.external_attr >> 16
            # ZipInfo rewrites os.sep to "/" on Windows; check the raw stored name too.
            raw = getattr(entry, "orig_filename", name)
            if (not parts or path.is_absolute() or "\\" in name or "\\" in raw
                    or any(p in (".", "..") or p.endswith((".", " "))
                           or re.search(r'[<>:"|?*\x00-\x1f]', p)
                           or re.fullmatch(r"(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\..*)?", p)
                           for p in parts)):
                raise ValueError("Unsafe Windows archive path")
            if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError("Archive contains a link or special file")
            key = str(path).casefold()
            if key in seen:
                raise ValueError("Duplicate archive path")
            seen.add(key)
            total += entry.file_size
            entries.append((entry, parts))
            if total > MAX_BYTES or len(entries) > 4096:
                raise ValueError("Expanded archive exceeds limits")
        if not {"hikari.exe", "web/index.html"}.issubset(seen):
            raise ValueError("Release is missing required files")
        if extract_dir:
            destination = Path(extract_dir)
            destination.mkdir(parents=True, exist_ok=True)
            for entry, parts in entries:
                target = destination.joinpath(*parts)
                if entry.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.open(entry) as source, target.open("xb") as output:
                        shutil.copyfileobj(source, output, 1024 * 1024)


def main():
    parser = argparse.ArgumentParser()
    for field in ("archive", "manifest", "signature", "public-key", "repo", "os", "arch"):
        parser.add_argument("--" + field, required=True)
    parser.add_argument("--extract-dir")
    args = parser.parse_args()
    try:
        print(verify(args))
    except (ValueError, OSError, tarfile.TarError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        parser.exit(1, f"Release verification failed: {error}\n")


if __name__ == "__main__":
    main()
