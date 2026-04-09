#!/usr/bin/env python3
"""
Claude Code Session Sweep

Secondary sweep that catches sessions the SessionEnd hook missed
(crashes, force-kills, network drops). Scans Claude Code's transcript
directory for sessions not yet in the agent's agents/claude-code/sessions/.

Designed to run via cron every few hours.
"""

import json
import os
import sys
import hashlib
from datetime import datetime, timezone, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lockutil import acquire_lock, release_lock

WORKSPACE = Path("{{WORKSPACE}}")
OUTPUT_DIR = WORKSPACE / "agents/claude-code/sessions"
LOG_FILE = WORKSPACE / "logs/claude-code-bridge.jsonl"
CLAUDE_HOME = Path("{{CLAUDE_HOME}}")
CLAUDE_CODE_SESSIONS = Path.home() / ".claude/projects/-home-ubuntu/sessions"
LOOKBACK_HOURS = 24


def log_event(event_type, session_id="", **kwargs):
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "source": "claude-code-sweep",
        "event": event_type,
        "sessionId": session_id[:8] if session_id else "",
        **kwargs,
    }
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(entry) + "\n")


def find_missed_sessions():
    """Find Claude Code sessions not yet captured by the bridge."""
    cutoff = datetime.now(timezone.utc) - timedelta(hours=LOOKBACK_HOURS)
    already_captured = set()

    # Build set of already-captured session IDs
    if OUTPUT_DIR.exists():
        for f in OUTPUT_DIR.glob("*.jsonl"):
            already_captured.add(f.stem)

    # Check bridge state — but allow re-processing if transcript grew significantly
    RESUME_GROWTH_PCT = 0.10
    RESUME_GROWTH_BYTES = 51200
    state_file = WORKSPACE / "logs/claude-code-bridge-state.json"
    bridge_state = {}
    if state_file.exists():
        try:
            bridge_state = json.loads(state_file.read_text())
        except Exception:
            pass

    # Sessions that were captured and haven't grown enough are skipped
    for sid, info in bridge_state.get("sessions", {}).items():
        already_captured.add(sid)  # default: skip
    # We'll un-skip sessions that have grown significantly (checked per-file below)

    missed = []

    # Scan all Claude Code project directories for transcript files
    projects_dir = CLAUDE_HOME / "projects"
    if not projects_dir.exists():
        return []

    for project_dir in projects_dir.iterdir():
        if not project_dir.is_dir():
            continue

        # Claude Code stores transcripts as {session_id}.jsonl directly in the project dir
        for transcript in project_dir.glob("*.jsonl"):
            # Skip agent sub-sessions and prompt suggestions
            if transcript.stem.startswith("agent-"):
                continue

            try:
                mtime = datetime.fromtimestamp(transcript.stat().st_mtime, tz=timezone.utc)
                if mtime < cutoff:
                    continue
                # Skip very recent (might still be active)
                if (datetime.now(timezone.utc) - mtime).total_seconds() < 3600:  # 1 hour
                    continue
                size = transcript.stat().st_size
                if size < 1000:
                    continue
            except Exception:
                continue

            session_id = transcript.stem
            if session_id in already_captured:
                # Check if it grew significantly (resumed session)
                prev_info = bridge_state.get("sessions", {}).get(session_id, {})
                prev_size = prev_info.get("transcript_size", 0)
                if prev_size > 0:
                    try:
                        current_size = transcript.stat().st_size
                        growth_pct = (current_size - prev_size) / prev_size
                        growth_bytes = current_size - prev_size
                        if growth_pct >= RESUME_GROWTH_PCT or growth_bytes >= RESUME_GROWTH_BYTES:
                            # Session resumed and grew — re-process
                            missed.append((session_id, str(transcript)))
                        # else: not enough growth, skip
                    except Exception:
                        pass
                continue

            missed.append((session_id, str(transcript)))

        # Also check subdirectory pattern (some versions use session_id/transcript.jsonl)
        for session_dir in project_dir.iterdir():
            if not session_dir.is_dir():
                continue
            transcript = session_dir / "transcript.jsonl"
            if not transcript.exists():
                continue
            try:
                mtime = datetime.fromtimestamp(transcript.stat().st_mtime, tz=timezone.utc)
                if mtime < cutoff:
                    continue
                if (datetime.now(timezone.utc) - mtime).total_seconds() < 3600:  # 1 hour
                    continue
                if transcript.stat().st_size < 1000:
                    continue
            except Exception:
                continue

            session_id = session_dir.name
            if session_id in already_captured:
                prev_info = bridge_state.get("sessions", {}).get(session_id, {})
                prev_size = prev_info.get("transcript_size", 0)
                if prev_size > 0:
                    try:
                        current_size = transcript.stat().st_size
                        growth_pct = (current_size - prev_size) / prev_size
                        growth_bytes = current_size - prev_size
                        if growth_pct >= RESUME_GROWTH_PCT or growth_bytes >= RESUME_GROWTH_BYTES:
                            missed.append((session_id, str(transcript)))
                    except Exception:
                        pass
                continue
            missed.append((session_id, str(transcript)))

    return missed


def main():
    lock = acquire_lock("claude-code-sweep", timeout=5)
    if not lock:
        print("Sweep: another instance running, skipping")
        return

    try:
        missed = find_missed_sessions()
        if not missed:
            print("Sweep: no missed sessions found")
            return

        print(f"Sweep: found {len(missed)} missed session(s)")

        for session_id, transcript_path in missed:
            print(f"  Processing missed session: {session_id[:8]}")
            # Feed it through the bridge by simulating hook input
            hook_input = json.dumps({
                "session_id": session_id,
                "transcript_path": transcript_path,
            })

            try:
                import subprocess
                result = subprocess.run(
                    ["python3", str(WORKSPACE / "scripts/claude-code-bridge.py")],
                    input=hook_input,
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                if result.returncode == 0:
                    log_event("sweep.captured", session_id)
                    print(f"    Captured: {result.stdout.strip()}")
                else:
                    log_event("sweep.failed", session_id, stderr=result.stderr[-200:])
                    print(f"    Failed: {result.stderr[-100:]}")
            except Exception as e:
                log_event("sweep.error", session_id, error=str(e))
                print(f"    Error: {e}")
    finally:
        release_lock(lock)


if __name__ == "__main__":
    main()
