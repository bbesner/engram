#!/usr/bin/env python3
"""
Claude Code → Agent Memory Bridge

Receives session data from Claude Code's SessionEnd hook (JSON on stdin),
converts the session JSONL to the agent's format, and drops it into
agents/claude-code/sessions/ for incremental-memory-capture.py to process.

Designed to be called by Claude Code's SessionEnd hook:
  "hooks": { "SessionEnd": [{ "command": "python3 {{WORKSPACE}}/scripts/claude-code-bridge.py" }] }

The hook sends JSON on stdin with: session_id, transcript_path, cwd, hook_event_name
"""

import json
import os
import subprocess
import sys
import time
import hashlib
from datetime import datetime, timezone, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lockutil import acquire_lock, release_lock

WORKSPACE = Path("{{WORKSPACE}}")
OUTPUT_DIR = WORKSPACE / "agents/claude-code/sessions"
LOG_FILE = WORKSPACE / "logs/claude-code-bridge.jsonl"
STATE_FILE = WORKSPACE / "logs/claude-code-bridge-state.json"
QUEUE_FILE = WORKSPACE / "logs/claude-code-bridge-queue.json"

# Debounce: skip if same session_id was processed within this window
DEBOUNCE_SECONDS = 60

# Rate limit: max captures per hour
MAX_CAPTURES_PER_HOUR = {{RATE_LIMIT}}

# Minimum meaningful turns to bother processing
MIN_USER_TURNS = 1
MIN_TOTAL_TURNS = 4


def log_event(event_type, session_id="", **kwargs):
    """Append a structured log entry."""
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "source": "claude-code-memory-bridge",
        "event": event_type,
        "sessionId": session_id[:8] if session_id else "",
        **kwargs,
    }
    with open(LOG_FILE, "a") as f:
        f.write(json.dumps(entry) + "\n")


def load_state():
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_state(state):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2))


def check_debounce(state, session_id):
    """Return True if this session was processed too recently."""
    last = state.get("sessions", {}).get(session_id, {}).get("last_processed")
    if not last:
        return False
    try:
        last_time = datetime.fromisoformat(last)
        return (datetime.now(timezone.utc) - last_time).total_seconds() < DEBOUNCE_SECONDS
    except Exception:
        return False


def check_rate_limit(state):
    """Return True if we've exceeded the hourly capture limit."""
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    recent = state.get("recent_captures", [])
    recent = [ts for ts in recent if ts > cutoff]
    state["recent_captures"] = recent  # prune old entries
    return len(recent) >= MAX_CAPTURES_PER_HOUR


def extract_text_from_content(content):
    """Extract readable text from Claude Code message content."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type", "")
            if btype == "text":
                text = block.get("text", "")
                if isinstance(text, str) and text.strip():
                    parts.append(text.strip())
        return " ".join(parts)
    return ""


def extract_tool_calls_from_content(content):
    """Extract tool call metadata from Claude Code message content."""
    if not isinstance(content, list):
        return []
    calls = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type", "")
        if btype == "tool_use":
            calls.append({
                "type": "toolCall",
                "name": block.get("name", "unknown"),
                "id": block.get("id", ""),
            })
        elif btype == "tool_result":
            calls.append({
                "type": "toolResult",
                "tool_use_id": block.get("tool_use_id", ""),
            })
    return calls


def convert_session(transcript_path, session_id, skip_lines=0):
    """
    Read Claude Code JSONL, extract conversational turns,
    return list of agent-format message strings: [USER]: ... / [AGENT]: ...
    Also return the converted JSONL records for writing to the output file.

    If skip_lines > 0 (resumed session), skips that many lines from the start
    and only processes new content.
    """
    messages = []       # [USER]/[AGENT] format for classify_window
    ari_records = []    # Agent-format JSONL records
    prev_id = None
    msg_count = 0
    user_turns = 0

    # Session header record
    header = {
        "type": "session",
        "version": 3,
        "id": session_id[:8],
        "source": "claude-code",
        "originalSessionId": session_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "cwd": str(WORKSPACE),
    }
    ari_records.append(header)

    total_lines = 0
    try:
        with open(transcript_path, errors="ignore") as f:
            for line in f:
                total_lines += 1

                # Skip already-processed lines for resumed sessions
                if skip_lines > 0 and total_lines <= skip_lines:
                    continue

                try:
                    rec = json.loads(line)
                except Exception:
                    continue

                rec_type = rec.get("type", "")

                # Only process user and assistant message records
                if rec_type not in ("user", "assistant"):
                    continue

                msg = rec.get("message", {})
                role = msg.get("role", "")
                if role not in ("user", "assistant"):
                    continue

                content = msg.get("content", "")
                text = extract_text_from_content(content)
                tool_calls = extract_tool_calls_from_content(content)

                if not text or len(text.strip()) < 5:
                    # Still record if there are tool calls even without text
                    if not tool_calls:
                        continue

                # Skip system/automation noise
                text = (text or "").strip()
                if text.startswith("Pre-compaction checkpoint"):
                    continue

                # Generate 8-char hex ID
                msg_count += 1
                msg_id = hashlib.md5(
                    f"{session_id}:{msg_count}".encode()
                ).hexdigest()[:8]

                timestamp = rec.get("timestamp", datetime.now(timezone.utc).isoformat())

                # Build content blocks — text + tool calls
                content_blocks = []
                if text:
                    content_blocks.append({"type": "text", "text": text})
                for tc in tool_calls:
                    content_blocks.append(tc)

                # Build agent-format record
                ari_rec = {
                    "type": "message",
                    "id": msg_id,
                    "parentId": prev_id,
                    "timestamp": timestamp,
                    "message": {
                        "role": role,
                        "content": content_blocks,
                    },
                }
                ari_records.append(ari_rec)
                prev_id = msg_id

                # Build [USER]/[AGENT] format for classify_window
                tool_str = ""
                if tool_calls:
                    tool_names = [tc["name"] for tc in tool_calls if tc.get("name")]
                    if tool_names:
                        tool_str = f" [tools: {', '.join(tool_names)}]"
                if role == "user":
                    messages.append(f"[USER]:{tool_str} {text}")
                    user_turns += 1
                else:
                    messages.append(f"[AGENT]:{tool_str} {text}")

    except FileNotFoundError:
        log_event("session.error", session_id, error=f"File not found: {transcript_path}")
        return None, None, 0, 0
    except Exception as e:
        log_event("session.error", session_id, error=str(e))
        return None, None, 0, 0

    return messages, ari_records, user_turns, total_lines


def classify_window(messages):
    """
    Replicates the scoring logic from incremental-memory-capture.py.
    Returns dict with kind, reason, score.
    """
    if not messages:
        return {"kind": "skip", "reason": "no messages", "score": -999}

    joined = "\n".join(messages).lower()
    brad_turns = sum(1 for m in messages if m.startswith("[USER]:"))
    ari_turns = sum(1 for m in messages if m.startswith("[AGENT]:"))

    score = 0
    score += min(brad_turns, 6) * 4
    score += min(ari_turns, 6) * 2
    score += min(len(joined) // 3000, 8)

    if any(term in joined for term in [
        "memory", "maintenance", "config", "server", "api key",
        "agent", "deploy", "task",
    ]):
        score += 2

    # Claude Code sessions won't have cron/heartbeat markers,
    # but check anyway for safety
    automation_markers = [
        "[cron:", "heartbeat_ok", "daily-report-task",
        "monitoring-task", "automated-email-task",
        "automated-status-check",
    ]
    if brad_turns <= 1 and any(marker in joined for marker in automation_markers):
        return {"kind": "skip", "reason": "automation/cron", "score": score - 20}

    if score < 8:
        return {"kind": "skip", "reason": "low-value session", "score": score}

    return {"kind": "extract", "reason": "human/high-value session", "score": score}


def write_output(session_id, ari_records, is_resumed=False):
    """Write converted session to output directory.
    For resumed sessions, appends new records to existing file.
    For new sessions, atomically writes a new file."""
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    output_path = OUTPUT_DIR / f"{session_id}.jsonl"

    if is_resumed and output_path.exists():
        # Append new records to existing file
        try:
            with open(output_path, "a") as f:
                for rec in ari_records:
                    f.write(json.dumps(rec) + "\n")
            return True
        except Exception as e:
            log_event("session.error", session_id, error=f"Append failed: {e}")
            return False

    # New session — atomic write
    tmp_path = OUTPUT_DIR / f".{session_id}.tmp"
    try:
        with open(tmp_path, "w") as f:
            for rec in ari_records:
                f.write(json.dumps(rec) + "\n")
        os.rename(str(tmp_path), str(output_path))
        return True
    except Exception as e:
        # Clean up temp file on failure
        try:
            tmp_path.unlink(missing_ok=True)
        except Exception:
            pass
        log_event("session.error", session_id, error=f"Write failed: {e}")
        return False


def main():
    # Acquire lock to prevent concurrent bridge runs
    lock = acquire_lock("claude-code-bridge", timeout=10)
    if not lock:
        print("Bridge: another instance is running, skipping")
        sys.exit(0)

    try:
        _main_inner()
    finally:
        release_lock(lock)


def _main_inner():
    # Read hook input from stdin
    try:
        hook_input = json.loads(sys.stdin.read())
    except Exception as e:
        log_event("session.error", error=f"Failed to parse stdin: {e}")
        sys.exit(1)

    session_id = hook_input.get("session_id", "")
    transcript_path = hook_input.get("transcript_path", "")

    if not session_id or not transcript_path:
        log_event("session.error", error="Missing session_id or transcript_path in hook input")
        sys.exit(1)

    # Load state for debounce/rate-limit checks
    state = load_state()

    # Debounce check
    if check_debounce(state, session_id):
        log_event("session.skip", session_id, reason="debounce")
        sys.exit(0)

    # Resume detection — if session was already captured, only re-process
    # if the transcript has grown meaningfully. Prevents duplicate fact extraction.
    # Uses dual threshold: >10% growth OR >50KB new content (whichever comes first).
    # This catches small follow-ups on large sessions that wouldn't clear a % threshold.
    RESUME_GROWTH_PCT = 0.10     # 10% growth
    RESUME_GROWTH_BYTES = 51200  # 50KB absolute minimum new content
    prev_session = state.get("sessions", {}).get(session_id, {})
    is_resumed = False
    resume_offset = 0
    if prev_session.get("last_processed"):
        prev_size = prev_session.get("transcript_size", 0)
        try:
            current_size = Path(transcript_path).stat().st_size
        except Exception:
            current_size = 0

        if prev_size > 0 and current_size > 0:
            growth_pct = (current_size - prev_size) / prev_size
            growth_bytes = current_size - prev_size
            if growth_pct < RESUME_GROWTH_PCT and growth_bytes < RESUME_GROWTH_BYTES:
                log_event("session.skip", session_id,
                          reason=f"resumed but insufficient growth ({growth_pct:.1%}, {growth_bytes}B)",
                          prevSize=prev_size, currentSize=current_size)
                sys.exit(0)
            else:
                is_resumed = True
                resume_offset = prev_session.get("lines_processed", 0)
                log_event("session.resume", session_id,
                          growthPct=f"{growth_pct:.1%}",
                          growthBytes=growth_bytes,
                          prevSize=prev_size, currentSize=current_size,
                          resumeFromLine=resume_offset)
                print(f"Bridge: resumed session {session_id[:8]} "
                      f"(grew {growth_pct:.0%} / {growth_bytes//1024}KB, "
                      f"processing from line {resume_offset})")

    # Rate limit check — queue instead of discard
    if check_rate_limit(state):
        log_event("session.queued", session_id, reason="rate_limit")
        queue = []
        if QUEUE_FILE.exists():
            try:
                queue = json.loads(QUEUE_FILE.read_text())
            except Exception:
                queue = []
        queue.append({"session_id": session_id, "transcript_path": transcript_path,
                       "queued_at": datetime.now(timezone.utc).isoformat()})
        QUEUE_FILE.parent.mkdir(parents=True, exist_ok=True)
        QUEUE_FILE.write_text(json.dumps(queue, indent=2))
        print(f"Bridge: rate-limited, queued session {session_id[:8]} ({len(queue)} in queue)")
        sys.exit(0)

    # Convert the session
    messages, ari_records, user_turns, total_lines = convert_session(
        transcript_path, session_id, skip_lines=resume_offset if is_resumed else 0)

    if messages is None:
        sys.exit(1)

    # Skip sessions with no human interaction
    if user_turns < MIN_USER_TURNS:
        log_event("session.skip", session_id, reason="no_user_turns", userTurns=user_turns)
        sys.exit(0)

    # Skip sessions that are too short
    if len(messages) < MIN_TOTAL_TURNS:
        log_event("session.skip", session_id,
                  reason=f"too_few_turns ({len(messages)})", messageCount=len(messages))
        sys.exit(0)

    # Classify the session
    classification = classify_window(messages)

    if classification["kind"] != "extract":
        log_event("session.skip", session_id,
                  reason=classification["reason"], score=classification["score"])
        sys.exit(0)

    # Write the converted session
    if not write_output(session_id, ari_records, is_resumed=is_resumed):
        sys.exit(1)

    # Update state
    now = datetime.now(timezone.utc).isoformat()
    # Track size and lines for resume detection
    try:
        transcript_size = Path(transcript_path).stat().st_size
    except Exception:
        transcript_size = 0

    state.setdefault("sessions", {})[session_id] = {
        "last_processed": now,
        "score": classification["score"],
        "messages": len(messages),
        "user_turns": user_turns,
        "transcript_size": transcript_size,
        "lines_processed": total_lines,
        "is_resumed": is_resumed,
    }
    state.setdefault("recent_captures", []).append(now)
    save_state(state)

    log_event("session.capture", session_id,
              score=classification["score"],
              messageCount=len(messages),
              userTurns=user_turns,
              outputFile=str(OUTPUT_DIR / f"{session_id}.jsonl"))

    print(f"Bridge: captured session {session_id[:8]} "
          f"(score={classification['score']}, turns={len(messages)}, user={user_turns})")

    # Trigger auto-skill-capture extractor on the captured session
    extractor = WORKSPACE / "extensions/auto-skill-capture/scripts/skill-extractor.py"
    if extractor.exists():
        try:
            result = subprocess.run(
                ["python3", str(extractor), "--workspace", str(WORKSPACE)],
                cwd=str(WORKSPACE),
                capture_output=True,
                text=True,
                timeout=120,
                env={**os.environ, "PYTHONUNBUFFERED": "1"},
            )
            if result.returncode == 0:
                log_event("skill.extract.ok", session_id, output=result.stdout[-200:] if result.stdout else "")
                print(f"Bridge: skill extractor completed")
            else:
                log_event("skill.extract.fail", session_id,
                          stderr=result.stderr[-300:] if result.stderr else "",
                          returncode=result.returncode)
                print(f"Bridge: skill extractor failed (rc={result.returncode})")
        except subprocess.TimeoutExpired:
            log_event("skill.extract.timeout", session_id)
            print("Bridge: skill extractor timed out (120s)")
        except Exception as e:
            log_event("skill.extract.error", session_id, error=str(e))
            print(f"Bridge: skill extractor error: {e}")


if __name__ == "__main__":
    main()
