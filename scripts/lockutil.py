"""Simple file-based locking for memory pipeline scripts.

Usage:
    from lockutil import acquire_lock, release_lock

    lock = acquire_lock("skill-extractor")
    if not lock:
        print("Another instance is running")
        sys.exit(0)
    try:
        # do work
    finally:
        release_lock(lock)
"""

import os
import fcntl
import time
from pathlib import Path

LOCK_DIR = Path("/tmp/agent-locks")
LOCK_DIR.mkdir(parents=True, exist_ok=True)

STALE_TIMEOUT = 300  # 5 minutes — assume stale if older


def acquire_lock(name: str, timeout: int = 0) -> object | None:
    lock_path = LOCK_DIR / f"{name}.lock"
    deadline = time.time() + timeout

    while True:
        try:
            if lock_path.exists():
                age = time.time() - lock_path.stat().st_mtime
                if age > STALE_TIMEOUT:
                    lock_path.unlink(missing_ok=True)

            lock_file = open(lock_path, "w")
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            lock_file.write(f"{os.getpid()}\n")
            lock_file.flush()
            return lock_file
        except (IOError, OSError):
            if time.time() >= deadline:
                return None
            time.sleep(1)


def release_lock(lock_file: object):
    if lock_file is None:
        return
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        lock_path = lock_file.name
        lock_file.close()
        Path(lock_path).unlink(missing_ok=True)
    except Exception:
        pass
