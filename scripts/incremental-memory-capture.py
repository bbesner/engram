#!/usr/bin/env python3
"""
Incremental Memory Capture Service

Mem0-style behavior on top of an update-safe local memory architecture.

What it does:
- Scans recently updated session files
- Reads only the most recent meaningful conversational window
- Skips automation/cron/heartbeat sessions
- Uses GPT-5.4 Nano to extract durable facts from fresh context
- Routes extracted facts into structured memory files
- Maintains lightweight session-scoped cache files
- Tracks processed state to avoid duplicate processing

This is the PRIMARY memory intake path.
Longer-term consolidation and promotion are handled by built-in memory-core Dreaming.
The older memory-writer.py is retained only for manual backfill or historical reference.
"""

import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone, timedelta
from pathlib import Path

WORKSPACE = Path("{{WORKSPACE}}")
SESSION_DIRS = [
    WORKSPACE / "agents/main/sessions",
    WORKSPACE / "agents/{{SESSION_SOURCE}}/sessions",
]
MEMORY_DIR = WORKSPACE / "memory"
SESSION_CACHE_DIR = MEMORY_DIR / "session-cache"
STATE_FILE = MEMORY_DIR / "incremental-capture-state.json"
LOOKBACK_MINUTES = 480
SKIP_RECENT_SECONDS = 15
MAX_RECENT_TURNS = 12
MAX_TRANSCRIPT_CHARS = 32000
# Uses OpenAI GPT-5.4 Nano by default — purpose-built for classification/extraction,
# faster and cheaper than general-purpose models.
MODEL = "gpt-5.4-nano"
PROVIDER = "openai"  # "openai" or "anthropic"

EXTRACTION_PROMPT = """You are the agent's incremental memory capture engine.

You are given only the most recent meaningful turn window from a live user/agent session.
Your job is to extract ONLY durable facts worth preserving across sessions.

Prioritize:
- decisions that change future behavior
- user preferences and rules
- infrastructure/configuration facts
- project continuity facts
- durable technical discoveries
- business rules or client/account context
- changes to agent or system behavior

Do NOT extract:
- greetings or filler
- transient progress chatter
- automation/cron noise
- things that were proposed but not adopted
- anything reversed later in the same window

Output one fact per line only, exactly like:
[CATEGORY] fact text

Allowed categories:
[DECISION]
[PREFERENCE]
[PERSON]
[PROJECT]
[TECHNICAL]
[BUSINESS]
[RULE]

If no durable facts exist, return exactly:
NO_NEW_FACTS

Recent session window:
"""


def load_env(path: Path):
    if not path.exists():
        return
    for line in path.read_text(errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k, v)


def get_anthropic_key():
    load_env(WORKSPACE / ".env")
    return os.environ.get("MEMORY_WRITER_ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_API_KEY", "")


def get_openai_key():
    load_env(WORKSPACE / ".env")
    return os.environ.get("MEMORY_WRITER_OPENAI_API_KEY") or os.environ.get("OPENAI_API_KEY", "")


def load_state():
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return {"processed": {}, "last_run": None}


def save_state(state):
    state["last_run"] = datetime.now(timezone.utc).isoformat()
    MEMORY_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2))


def recent_session_files(lookback_minutes=LOOKBACK_MINUTES, skip_active=True):
    cutoff = time.time() - (lookback_minutes * 60)
    skip_after = time.time() - SKIP_RECENT_SECONDS if skip_active else time.time() + 9999999
    items = []
    for sessions_dir in SESSION_DIRS:
        if not sessions_dir.exists():
            continue
        for f in sessions_dir.glob("*.jsonl"):
            if f.name.endswith(".lock"):
                continue
            try:
                mtime = f.stat().st_mtime
                size = f.stat().st_size
            except FileNotFoundError:
                continue
            if cutoff <= mtime <= skip_after:
                items.append((f, mtime, size))
    # Prefer larger/more substantive sessions first, then recency
    items.sort(key=lambda x: (x[2], x[1]), reverse=True)
    return items


def extract_text_from_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, dict):
        return content.get("text") or content.get("value") or ""
    if isinstance(content, list):
        parts = []
        for part in content:
            if not isinstance(part, dict):
                continue
            ptype = part.get("type")
            if ptype == "text":
                t = part.get("text")
                if isinstance(t, str):
                    parts.append(t)
                elif isinstance(t, dict):
                    parts.append(t.get("value", ""))
            elif ptype == "toolCall":
                continue
            elif ptype == "thinking":
                continue
            elif isinstance(part.get("text"), str):
                parts.append(part.get("text", ""))
            elif isinstance(part.get("content"), str):
                parts.append(part.get("content", ""))
        return " ".join(p for p in parts if p)
    return ""


def extract_recent_window(session_path: Path, max_turns=MAX_RECENT_TURNS):
    messages = []
    session_id = session_path.stem
    pending_assistant = []

    def flush_assistant():
        nonlocal pending_assistant
        if pending_assistant:
            merged = "\n".join(x for x in pending_assistant if x).strip()
            if merged:
                messages.append(f"[AGENT]: {merged}")
            pending_assistant = []

    with open(session_path, errors="ignore") as f:
        for line in f:
            try:
                entry = json.loads(line)
            except Exception:
                continue
            if entry.get("type") != "message":
                continue
            msg = entry.get("message", {})
            role = msg.get("role") or entry.get("role")

            # Skip raw tool results entirely; we care about user/agent conversational turns
            if role == "toolResult":
                continue
            if role not in ("user", "assistant"):
                continue

            text = extract_text_from_content(msg.get("content", ""))
            if not text or len(text.strip()) < 5:
                continue
            if text.startswith("Pre-compaction checkpoint"):
                continue
            if text.strip() == "HEARTBEAT_OK":
                continue

            text = text.strip()
            if role == "user":
                flush_assistant()
                messages.append(f"[USER]: {text}")
            else:
                pending_assistant.append(text)

    flush_assistant()
    if not messages:
        return session_id, []
    return session_id, messages[-max_turns:]


def classify_window(messages):
    if not messages:
        return {"kind": "skip", "reason": "no messages", "score": -999}
    joined = "\n".join(messages).lower()
    brad_turns = sum(1 for m in messages if m.startswith("[USER]:"))
    ari_turns = sum(1 for m in messages if m.startswith("[AGENT]:"))

    automation_markers = [
        "[cron:",
        "heartbeat_ok",
        "daily-report-task",
        "monitoring-task",
        "automated-email-task",
        "automated-status-check",
    ]

    score = 0
    score += min(brad_turns, 6) * 4
    score += min(ari_turns, 6) * 2
    score += min(len(joined) // 3000, 8)
    if "conversation info (untrusted metadata)" in joined:
        score += 2
    if any(term in joined for term in ["memory", "maintenance", "config", "server", "api key", "agent", "deploy", "task"]):
        score += 2

    if brad_turns <= 1 and any(marker in joined for marker in automation_markers):
        return {"kind": "skip", "reason": "automation/cron", "score": score - 20}
    if score < 8:
        return {"kind": "skip", "reason": "low-value session", "score": score}
    return {"kind": "extract", "reason": "human/high-value session", "score": score}


def call_openai(prompt, api_key):
    """Call OpenAI Chat Completions API (GPT-5.4 Nano default)."""
    data = json.dumps({
        "model": MODEL,
        "max_completion_tokens": 1800,
        "temperature": 0.1,
        "messages": [{"role": "user", "content": prompt}]
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}"
        }
    )
    resp = urllib.request.urlopen(req, timeout=120)
    result = json.loads(resp.read())
    text = result.get("choices", [{}])[0].get("message", {}).get("content", "").strip()
    usage = result.get("usage", {})
    return text, usage


def call_anthropic(prompt, api_key):
    """Call Anthropic Messages API (legacy fallback)."""
    data = json.dumps({
        "model": "claude-sonnet-4-6",
        "max_tokens": 1800,
        "temperature": 0.1,
        "messages": [{"role": "user", "content": prompt}]
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01"
        }
    )
    resp = urllib.request.urlopen(req, timeout=120)
    result = json.loads(resp.read())
    text = "\n".join(part.get("text", "") for part in result.get("content", []) if part.get("type") == "text").strip()
    return text, result.get("usage", {})


def call_llm(prompt):
    """Route to the configured provider. Falls back to Anthropic if OpenAI fails."""
    if PROVIDER == "openai":
        api_key = get_openai_key()
        if api_key:
            try:
                return call_openai(prompt, api_key)
            except Exception as e:
                print(f"WARNING: OpenAI call failed ({e}), falling back to Anthropic")
        # Fallback to Anthropic
        api_key = get_anthropic_key()
        if api_key:
            return call_anthropic(prompt, api_key)
        raise RuntimeError("No API keys available for memory writer")
    else:
        api_key = get_anthropic_key()
        if not api_key:
            raise RuntimeError("Missing ANTHROPIC_API_KEY")
        return call_anthropic(prompt, api_key)


def parse_facts(raw_output):
    facts = []
    for line in raw_output.strip().splitlines():
        line = line.strip()
        if not line or line == "NO_NEW_FACTS":
            continue
        if line.startswith("[") and "]" in line:
            i = line.index("]")
            cat = line[1:i].strip().upper()
            text = line[i+1:].strip()
            if text:
                facts.append({"category": cat, "text": text})
    return facts


def detect_source(session_path: Path):
    """Detect if a session came from Claude Code based on its directory."""
    if "agents/claude-code/" in str(session_path):
        return "claude-code"
    return "openclaw"


def load_existing_facts(days=3):
    """Load recent daily log facts + MEMORY.md for echo detection."""
    existing = set()
    # Load MEMORY.md
    memory_path = WORKSPACE / "MEMORY.md"
    if memory_path.exists():
        for line in memory_path.read_text(errors="ignore").splitlines():
            line = line.strip().lower()
            if line and len(line) > 20:
                existing.add(line)
    # Load recent daily logs
    for i in range(days):
        day = (datetime.now(timezone.utc) - timedelta(days=i)).strftime("%Y-%m-%d")
        day_path = MEMORY_DIR / f"{day}.md"
        if day_path.exists():
            for line in day_path.read_text(errors="ignore").splitlines():
                line = line.strip()
                if line.startswith("- [") and "]" in line:
                    # Extract just the fact text after the category tag(s)
                    fact_text = line.split("]", 1)[-1].strip()
                    # Handle [src:...] tag if present
                    if fact_text.startswith("[") and "]" in fact_text:
                        fact_text = fact_text.split("]", 1)[-1].strip()
                    if fact_text and len(fact_text) > 20:
                        existing.add(fact_text.lower())
    return existing


def is_echo(fact_text, existing_facts):
    """Check if a fact is an echo of something already captured."""
    normalized = fact_text.strip().lower()
    if normalized in existing_facts:
        return True
    # Fuzzy: check if 90%+ of the words overlap with any existing fact
    fact_words = set(normalized.split())
    if len(fact_words) < 5:
        return False
    for existing in existing_facts:
        existing_words = set(existing.split())
        if not existing_words:
            continue
        overlap = len(fact_words & existing_words) / max(len(fact_words), 1)
        if overlap > 0.9:
            return True
    return False


def route_file(category):
    mapping = {
        "DECISION": "decisions.md",
        "PREFERENCE": "lessons-learned.md",
        "PERSON": "people.md",
        "PROJECT": None,
        "TECHNICAL": "infrastructure.md",
        "BUSINESS": "business-context.md",
        "RULE": "lessons-learned.md",
    }
    return mapping.get(category)


def append_to_file(path: Path, header: str, bullets):
    if not bullets:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as f:
        f.write(f"\n## {header}\n")
        for b in bullets:
            f.write(f"- {b}\n")


def write_session_cache(session_id, messages, facts):
    SESSION_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_path = SESSION_CACHE_DIR / f"{session_id}.md"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [f"# Session Cache — {session_id}", "", f"Updated: {now}", "", "## Recent Context"]
    for m in messages[-8:]:
        lines.append(f"- {m[:500]}")
    if facts:
        lines += ["", "## Captured Durable Facts"]
        for fact in facts:
            lines.append(f"- [{fact['category']}] {fact['text']}")
    cache_path.write_text("\n".join(lines) + "\n")


def process_session(session_path, api_key=None, dry_run=False):
    session_id, messages = extract_recent_window(session_path)
    if len(messages) < 4:
        return {"status": "skip", "reason": f"too few messages ({len(messages)})", "session_id": session_id}

    classification = classify_window(messages)
    if classification["kind"] != "extract":
        return {"status": "skip", "reason": classification["reason"], "score": classification["score"], "session_id": session_id}

    transcript = "\n\n".join(messages)
    if len(transcript) > MAX_TRANSCRIPT_CHARS:
        transcript = transcript[-MAX_TRANSCRIPT_CHARS:]

    raw_output, usage = call_llm(EXTRACTION_PROMPT + transcript)
    facts = parse_facts(raw_output)

    # Echo detection: filter out facts that already exist in recent memory
    existing_facts = load_existing_facts(days=3)
    original_count = len(facts)
    facts = [f for f in facts if not is_echo(f["text"], existing_facts)]
    echo_count = original_count - len(facts)
    if echo_count > 0:
        print(f"  -> filtered {echo_count} echo fact(s)")

    if dry_run:
        return {
            "status": "dry-run",
            "session_id": session_id,
            "score": classification["score"],
            "facts": facts,
            "usage": usage,
            "messages": messages,
        }

    # Detect source for tagging
    source = detect_source(session_path)
    source_suffix = f" ({source})" if source != "openclaw" else ""
    src_tag = f" [src:{source}]" if source != "openclaw" else ""

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    daily_path = MEMORY_DIR / f"{today}.md"
    append_to_file(daily_path, f"Incremental Memory Capture — Session {session_id[:8]}{source_suffix}", [f"[{f['category']}]{src_tag} {f['text']}" for f in facts])

    grouped = {}
    for fact in facts:
        target = route_file(fact["category"])
        if not target:
            continue
        grouped.setdefault(target, []).append(f"[{fact['category']}]{src_tag} {fact['text']}")
    for filename, bullets in grouped.items():
        append_to_file(MEMORY_DIR / filename, f"Incremental Capture — {today}", bullets)

    write_session_cache(session_id, messages, facts)
    return {"status": "done", "session_id": session_id, "score": classification["score"], "facts": facts, "usage": usage}


def main():
    dry_run = "--dry-run" in sys.argv
    # Verify at least one API key is available
    if PROVIDER == "openai":
        if not get_openai_key() and not get_anthropic_key():
            print("ERROR: missing MEMORY_WRITER_OPENAI_API_KEY and ANTHROPIC_API_KEY — need at least one")
            sys.exit(1)
    else:
        if not get_anthropic_key():
            print("ERROR: missing MEMORY_WRITER_ANTHROPIC_API_KEY / ANTHROPIC_API_KEY")
            sys.exit(1)

    MEMORY_DIR.mkdir(parents=True, exist_ok=True)
    SESSION_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    state = load_state()
    sessions = recent_session_files(skip_active="--include-active" not in sys.argv)
    if not sessions:
        print("No recent sessions found.")
        return

    print(f"Found {len(sessions)} candidate session(s).")
    processed_any = 0

    for session_path, mtime, size in sessions:
        session_id = session_path.stem
        prev = state["processed"].get(session_id, {})
        if prev.get("mtime") == mtime and prev.get("status") in ("done", "skip"):
            print(f"Skipping {session_id[:8]}... (already processed)")
            continue

        print(f"Processing {session_id[:8]}... ({size/1024:.0f}KB)")
        result = process_session(session_path, dry_run=dry_run)
        print(f"  -> {result['status']}: {result.get('reason', '')}")
        if result.get("facts"):
            print(f"  -> facts: {len(result['facts'])}")

        state["processed"][session_id] = {
            "mtime": mtime,
            "status": result["status"],
            "reason": result.get("reason"),
            "score": result.get("score"),
            "facts": len(result.get("facts", [])),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        processed_any += 1

    if not dry_run:
        save_state(state)
    print(f"Done. Processed {processed_any} session(s).")


if __name__ == "__main__":
    main()
