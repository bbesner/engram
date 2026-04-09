#!/usr/bin/env python3
"""
Claude Code Per-Turn Capture

Called by the Stop hook after every Claude Code response.
Reads the active Claude Code transcript directly (not via the bridge)
and runs incremental memory capture against it.

This mirrors what the memory-bridge plugin does for OpenClaw sessions:
- Reads the most recent turn window from the transcript
- Extracts durable facts via LLM
- Appends to memory/YYYY-MM-DD.md with [src:claude-code] tag

The Stop hook sends JSON on stdin with session_id and other metadata.
We use the session_id to find the active transcript file.
"""

import json
import os
import sys
import glob
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lockutil import acquire_lock, release_lock

WORKSPACE = Path("{{WORKSPACE}}")
CLAUDE_HOME = Path("{{CLAUDE_HOME}}")


def find_active_transcript(session_id=None):
    """Find the active Claude Code transcript file."""
    # If we have a session_id, look for it directly
    if session_id:
        for project_dir in (CLAUDE_HOME / "projects").glob("*"):
            if not project_dir.is_dir():
                continue
            candidate = project_dir / f"{session_id}.jsonl"
            if candidate.exists():
                return candidate

    # Fallback: find the most recently modified JSONL in any project
    best = None
    best_mtime = 0
    for project_dir in (CLAUDE_HOME / "projects").glob("*"):
        if not project_dir.is_dir():
            continue
        for f in project_dir.glob("*.jsonl"):
            if f.stem.startswith("agent-"):
                continue
            try:
                mtime = f.stat().st_mtime
                if mtime > best_mtime:
                    best_mtime = mtime
                    best = f
            except Exception:
                continue
    return best


def main():
    # Try to read hook input from stdin
    session_id = None
    try:
        hook_input = json.loads(sys.stdin.read())
        session_id = hook_input.get("session_id", "")
    except Exception:
        pass  # Stop hook may not always send JSON

    # Acquire lock to prevent concurrent captures
    lock = acquire_lock("claude-code-turn-capture", timeout=2)
    if not lock:
        sys.exit(0)  # Another capture is running, skip this turn

    try:
        transcript = find_active_transcript(session_id)
        if not transcript:
            sys.exit(0)

        # Check file size — skip tiny transcripts
        if transcript.stat().st_size < 2000:
            sys.exit(0)

        # Symlink or copy the transcript temporarily into the session dir
        # so incremental-memory-capture can find it
        session_name = transcript.stem
        link_path = WORKSPACE / f"agents/claude-code/sessions/.active-{session_name}.jsonl"

        try:
            # Create symlink to the active transcript
            link_path.parent.mkdir(parents=True, exist_ok=True)
            if link_path.exists() or link_path.is_symlink():
                link_path.unlink()
            link_path.symlink_to(transcript)

            # Run incremental memory capture with --include-active
            import subprocess
            result = subprocess.run(
                ["python3", str(WORKSPACE / "scripts/incremental-memory-capture.py"),
                 "--include-active"],
                cwd=str(WORKSPACE),
                capture_output=True,
                text=True,
                timeout=30,
                env={**os.environ, "PYTHONUNBUFFERED": "1"},
            )

            if result.returncode == 0 and result.stdout.strip():
                # Only print if something was actually captured
                output = result.stdout.strip()
                if "extracted" in output.lower() or "captured" in output.lower():
                    print(json.dumps({
                        "suppressOutput": True
                    }))
        finally:
            # Clean up symlink
            if link_path.is_symlink():
                link_path.unlink(missing_ok=True)

    finally:
        release_lock(lock)


if __name__ == "__main__":
    main()
