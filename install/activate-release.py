#!/usr/bin/env python3
"""Commit an installer release under locked-run.py's update lock."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request
import uuid


def canonical_version(value):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?", value):
        raise ValueError("Invalid release version")
    return value


def sync(path, directory=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
        if sys.platform == "darwin" and not directory:
            fcntl.fcntl(fd, 51)  # F_FULLFSYNC
    finally:
        os.close(fd)


def replace_link(target, link):
    temporary = link.parent / (".pointer-" + uuid.uuid4().hex)
    try:
        temporary.symlink_to(target)
        os.replace(temporary, link)
        sync(link.parent, directory=True)
    finally:
        temporary.unlink(missing_ok=True)


def begin(versions, version):
    target = versions / canonical_version(version)
    binary = target / "hikari"
    result = subprocess.run([str(binary), "version"], capture_output=True, text=True, timeout=5, check=True)
    if result.stdout.split()[:2] != ["hikari", version]:
        raise ValueError("Installed binary does not match release version")
    current = versions / "current"
    pending = versions / ".activation-previous"
    if pending.exists():
        raise ValueError("Interrupted activation requires recovery before installation")
    if current.is_symlink() and current.resolve() == target.resolve():
        return
    previous = None
    if current.is_symlink():
        previous = current.resolve(strict=True)
        if previous.parent != versions.resolve() or not (previous / "hikari").is_file():
            raise ValueError("Existing activation is outside the versioned release layout")
        canonical_version(previous.name)
    elif current.exists():
        raise ValueError("Existing current path is not a hikari activation symlink")
    # Persist the whole new release before recording or changing activation.
    paths = list(target.rglob("*"))
    for path in paths:
        if path.is_symlink():
            raise ValueError("A release cannot contain symlinks")
        if path.is_file():
            sync(path)
    for path in reversed(paths):
        if path.is_dir():
            sync(path, directory=True)
    sync(target, directory=True)
    if previous:
        replace_link(previous, versions / "previous")
        temporary = versions / (".activation-" + uuid.uuid4().hex)
        try:
            fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(previous.name + "\n")
            sync(temporary)
            os.replace(temporary, pending)
            sync(versions, directory=True)
        finally:
            temporary.unlink(missing_ok=True)
    replace_link(target, current)


def confirm(versions, version):
    target = versions / canonical_version(version)
    if (versions / "current").resolve(strict=True) != target.resolve(strict=True):
        raise ValueError("Activation changed before health confirmation")
    pending = versions / ".activation-previous"
    pending.unlink(missing_ok=True)
    sync(versions, directory=True)


def health_confirm(versions, version, config_path):
    config = json.loads(Path(config_path).read_text())
    listen = config.get("listen", {})
    bind = listen.get("loopback_bind", "127.0.0.1")
    if bind not in ("127.0.0.1", "::1", "localhost"):
        raise ValueError("Health check refuses a non-loopback address")
    host = "[::1]" if bind == "::1" else "127.0.0.1"
    port = int(listen.get("loopback_port", 19100))
    if not 1 <= port <= 65535:
        raise ValueError("Invalid loopback port")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            with opener.open(f"http://{host}:{port}/healthz", timeout=2) as response:
                if response.status != 200:
                    raise ValueError("Health check failed")
            with opener.open(f"http://{host}:{port}/api/v1/info", timeout=2) as response:
                info = json.loads(response.read(65537))
            if info.get("app") == "hikari" and info.get("agent_version") == version:
                confirm(versions, version)
                return
        except (OSError, ValueError):
            pass
        time.sleep(0.25)
    raise ValueError("Local health/version check failed; prior activation remains recorded for recovery")


def recover(versions):
    pending = versions / ".activation-previous"
    if not pending.exists():
        return ""
    prev = canonical_version(pending.read_text(encoding="utf-8").strip())
    target = versions / prev
    binary = target / "hikari"
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"Prior release executable missing for interrupted activation: {binary}")
    replace_link(target, versions / "current")
    print(prev)
    return prev


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("begin", "confirm", "health-confirm", "recover"))
    parser.add_argument("versions")
    parser.add_argument("version", nargs="?")
    parser.add_argument("config", nargs="?")
    args = parser.parse_args()
    try:
        versions = Path(args.versions).resolve(strict=True)
        if args.action == "recover":
            recover(versions)
        else:
            if not args.version:
                raise ValueError("Release version is required")
            if args.action == "begin":
                begin(versions, args.version)
            elif args.action == "confirm":
                confirm(versions, args.version)
            else:
                if not args.config:
                    raise ValueError("Configuration path is required")
                health_confirm(versions, args.version, args.config)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Release activation failed: {error}\n")


if __name__ == "__main__":
    main()
