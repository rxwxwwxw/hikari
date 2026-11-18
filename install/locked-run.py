#!/usr/bin/env python3
"""Hold the same POSIX lock as the updater while the Unix installer executes."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys

versions = Path(sys.argv[1])
versions.mkdir(parents=True, exist_ok=True)
fd = os.open(versions / "update.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
try:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit("Another hikari install/update operation is in progress")
    environment = dict(os.environ, HIKARI_INSTALL_LOCKED="1")
    # The child keeps the lock even if this wrapper is interrupted.
    result = subprocess.run(sys.argv[2:], env=environment, pass_fds=(fd,))
    sys.exit(result.returncode)
finally:
    os.close(fd)
