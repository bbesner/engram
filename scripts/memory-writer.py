#!/usr/bin/env python3
"""
Memory Writer — RETIRED (v3.0.0, 2026-04-09)

Superseded by memory-core Dreaming (built-in OpenClaw 2026.4.9+).
Dreaming handles consolidation, dedup, and MEMORY.md promotion via recall-tracking.
Incremental-memory-capture.py remains the primary intake path.

This script is kept for manual backfill use only. Its cron job should not be created
on new installs. To run manually: python3 memory-writer.py --dry-run

Original description:
Extracts durable facts from session transcripts into markdown memory files.

Usage:
    python3 memory-writer.py              # Run extraction and write to memory files
    python3 memory-writer.py --dry-run    # Preview what would be extracted
    python3 memory-writer.py --hours 12   # Look back 12 hours instead of default 6
"""

import json
import os
import sys
import time
import urllib.request
import hashlib
import subprocess
from datetime import datetime, timezone, timedelta
from pathlib import Path

# ─── Configuration ───────────────────────────────────────────────────────────

WORKSPACE = Path("{{WORKSPACE}}")
SESSIONS_DIR = WORKSPACE / "agents/main/sessions"
MEMORY_DIR = WORKSPACE / "memory"
STATE_FILE = MEMORY_DIR / "memory-writer-state.json"
LOOKBACK_HOURS = 6
SKIP_RECENT_MINUTES = 5  # Don't process files modified very recently (active session)
MAX_TRANSCRIPT_CHARS = 80000  # Trim transcripts longer than this
MODEL = "claude-sonnet-4-6"
# Rationale: prioritize extraction quality, cross-project continuity judgment,
# and durable-memory selection over raw speed or token cost.
GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta"

# ─── Extraction Prompt ───────────────────────────────────────────────────────

EXTRACTION_PROMPT = """You are a high-precision memory extraction agent for an AI assistant.

Your job is to read a conversation transcript and extract ONLY durable, reusable memories that will improve the agent's future continuity across projects, businesses, systems, people, and technical work.

Be conservative but not timid: prefer fewer high-value facts over many weak ones.

## Extract ONLY these kinds of durable memories
- **DECISION**: final decisions about architecture, workflow, tooling, business direction, reporting, or operations
- **PREFERENCE**: the user's preferences, dislikes, working style, communication expectations, approval preferences
- **PERSON**: new or clarified people, roles, relationships, contact details, stakeholder preferences
- **PROJECT**: significant status changes, milestones, blockers, ownership changes, production-impacting outcomes
- **TECHNICAL**: infrastructure facts, server locations, integration details, model/provider choices, config behavior, bug root causes, durable implementation patterns
- **BUSINESS**: business rules, pricing rules, client/account context, compliance requirements, operational procedures
- **RULE**: standing instructions, policy constraints, safety/approval boundaries, recurring operating rules

## Prioritize these especially highly
- anything the user will expect the agent to remember later without being reminded
- cross-session continuity facts
- server / agent / API / environment setup facts
- durable lessons from debugging that prevent repeated mistakes
- changes to how the agent or any sub-agents should behave going forward
- important facts that would otherwise be lost if trapped only in transcript history

## Do NOT extract
- greetings, acknowledgments, or filler
- ephemeral progress narration
- one-off tool outputs with no durable lesson
- temporary plans that were not approved
- speculative ideas that were not adopted
- facts already obvious from the agent's core identity
- anything later reversed in the same transcript; keep only the final state

## Compression rule
Write each fact as a compact, standalone memory bullet that will still make sense weeks later.
Include key identifiers, file paths, IDs, dates, or system names when they materially improve future retrieval.

## Output format
Return one fact per line only, exactly like this:
[CATEGORY] fact text

Allowed categories only:
[DECISION]
[PREFERENCE]
[PERSON]
[PROJECT]
[TECHNICAL]
[BUSINESS]
[RULE]

If there are no strong durable memories, return exactly:
NO_NEW_FACTS

## Transcript
"""

# ─── Helper Functions ────────────────────────────────────────────────────────

def get_anthropic_key():
    """Get Anthropic API key from environment or config."""
    key = os.environ.get("MEMORY_WRITER_ANTHROPIC_API_KEY", "") or os.environ.get("ANTHROPIC_API_KEY", "")
    if key:
        return key
    config_path = WORKSPACE / "openclaw.json"
    if config_path.exists():
        try:
            with open(config_path) as f:
                config = json.load(f)
            key = config.get("models", {}).get("providers", {}).get("anthropic", {}).get("apiKey", "")
            if key:
                return key
        except Exception:
            pass
    return ""


def load_state():
    """Load processing state (which sessions we've already extracted from)."""
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE) as f:
                return json.load(f)
        except Exception:
            pass
    return {"processed": {}, "last_run": None}


def save_state(state):
    """Save processing state."""
    state["last_run"] = datetime.now(timezone.utc).isoformat()
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def get_recent_sessions(hours=LOOKBACK_HOURS):
    """Find session JSONL files modified within the lookback window."""
    if not SESSIONS_DIR.exists():
        return []

    cutoff = time.time() - (hours * 3600)
    skip_after = time.time() - (SKIP_RECENT_MINUTES * 60)

    sessions = []
    for f in SESSIONS_DIR.glob("*.jsonl"):
        if f.name.endswith(".lock"):
            continue
        mtime = f.stat().st_mtime
        if mtime > cutoff and mtime < skip_after:
            sessions.append((f, mtime))

    # Sort by modification time, newest first
    sessions.sort(key=lambda x: x[1], reverse=True)
    return sessions


def extract_messages(session_path):
    """Extract human/assistant messages from a session JSONL file."""
    messages = []
    session_start = None

    with open(session_path, errors='ignore') as f:
        for line in f:
            # Skip pathological giant lines dominated by tool payloads/results; they add
            # cost/noise and can drown out the actual conversational turns we want.
            if len(line) > 200000 and '"toolResult"' in line:
                continue
            try:
                entry = json.loads(line.strip())
            except json.JSONDecodeError:
                continue
            
            entry_type = entry.get("type", "")
            
            # Get session start time
            if entry_type == "session" and not session_start:
                session_start = entry.get("timestamp", "")
                continue
            
            if entry_type != "message":
                continue
            
            msg = entry.get("message", {})
            role = msg.get("role", "")

            # Support multiple OpenClaw/OpenAI-style content shapes
            if role not in ("user", "assistant"):
                role = entry.get("role", "") or role
            if role not in ("user", "assistant"):
                continue

            # Extract text content from string, array, or nested dict structures
            content = msg.get("content", "") if msg else entry.get("content", "")
            if isinstance(content, list):
                text_parts = []
                for part in content:
                    if isinstance(part, dict):
                        if part.get("type") == "text":
                            if isinstance(part.get("text"), str):
                                text_parts.append(part.get("text", ""))
                            elif isinstance(part.get("text"), dict):
                                text_parts.append(part.get("text", {}).get("value", ""))
                        elif isinstance(part.get("text"), str):
                            text_parts.append(part.get("text", ""))
                        elif isinstance(part.get("content"), str):
                            text_parts.append(part.get("content", ""))
                content = " ".join(tp for tp in text_parts if tp)
            elif isinstance(content, dict):
                content = content.get("text") or content.get("value") or ""
            
            if not isinstance(content, str) or len(content) < 10:
                continue
            
            # Skip system-injected messages (session startup, heartbeats, etc.)
            if content.startswith("Read HEARTBEAT.md"):
                continue
            if "HEARTBEAT_OK" == content.strip():
                continue
            if content.startswith("Pre-compaction checkpoint"):
                continue
            
            # Clean up metadata from user messages
            # Remove the untrusted metadata JSON blocks but keep the actual message
            if role == "user" and "Sender (untrusted metadata)" in content:
                # Extract just the message part after metadata
                parts = content.split("\n\n")
                actual_msg = []
                skip_next = False
                for p in parts:
                    if p.strip().startswith("Conversation info") or p.strip().startswith("Sender (untrusted"):
                        skip_next = True
                        continue
                    if skip_next and p.strip().startswith("```"):
                        skip_next = False
                        continue
                    if not skip_next:
                        actual_msg.append(p)
                content = "\n\n".join(actual_msg).strip()
            
            if len(content) < 10:
                continue
            
            # Truncate very long messages (code outputs, etc.)
            if len(content) > 2000:
                content = content[:2000] + "... [truncated]"
            
            label = "USER" if role == "user" else "AGENT"
            messages.append(f"[{label}]: {content}")
    
    return messages, session_start


def classify_session(messages):
    """Classify whether a session is automation noise or a real human work session."""
    if not messages:
        return {"kind": "skip", "score": -999, "reason": "no messages"}

    joined = "\n".join(messages).lower()
    brad_turns = sum(1 for m in messages if m.startswith('[USER]:'))
    ari_turns = sum(1 for m in messages if m.startswith('[AGENT]:'))

    automation_markers = [
        '[cron:',
        'heartbeat_ok',
        'automated-status-check',
        'daily-report-task',
        'if tasks are progressing normally, reply with a brief status summary',
        'monitoring-task',
        'automated-email-task'
    ]

    score = 0
    score += min(brad_turns, 8) * 3
    score += min(ari_turns, 8) * 2
    score += min(len(joined) // 4000, 10)
    if 'conversation info (untrusted metadata)' in joined:
        score += 2
    if any(term in joined for term in ['maintenance.md', 'memory', 'decision', 'config', 'server', 'api key', 'task']):
        score += 2

    if brad_turns <= 1 and any(tag in joined for tag in automation_markers):
        return {"kind": "skip", "score": score - 20, "reason": "automation/cron"}

    if score < 6:
        return {"kind": "skip", "score": score, "reason": "low-value session"}

    return {"kind": "extract", "score": score, "reason": "human/high-value session"}


def build_transcript(messages, max_chars=MAX_TRANSCRIPT_CHARS):
    """Build a transcript string from messages, respecting size limits."""
    transcript = "\n\n".join(messages)
    if len(transcript) > max_chars:
        # Take from the end (most recent messages are usually most valuable)
        transcript = "... [earlier messages trimmed] ...\n\n" + transcript[-max_chars:]
    return transcript


def call_anthropic(prompt, api_key):
    """Call Anthropic Messages API for extraction."""
    data = json.dumps({
        "model": MODEL,
        "max_tokens": 3000,
        "temperature": 0.1,
        "messages": [
            {"role": "user", "content": prompt}
        ]
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

    text_parts = []
    for part in result.get("content", []):
        if part.get("type") == "text":
            text_parts.append(part.get("text", ""))
    text = "\n".join(text_parts).strip()
    usage = result.get("usage", {})

    return text, usage


def parse_facts(raw_output):
    """Parse extracted facts from model output."""
    facts = []
    for line in raw_output.strip().split("\n"):
        line = line.strip()
        if not line or line == "NO_NEW_FACTS":
            continue
        if line.startswith("[") and "]" in line:
            bracket_end = line.index("]")
            category = line[1:bracket_end].strip().upper()
            fact_text = line[bracket_end + 1:].strip()
            if fact_text:
                facts.append({"category": category, "text": fact_text})
    return facts


def check_dedup(facts, memory_dir):
    """Simple dedup: check if a fact's key content already exists in recent memory files."""
    # Load last 7 days of memory files for dedup
    existing_text = ""
    for i in range(7):
        date = (datetime.now(timezone.utc) - timedelta(days=i)).strftime("%Y-%m-%d")
        mem_file = memory_dir / f"{date}.md"
        if mem_file.exists():
            existing_text += open(mem_file).read().lower()
    
    # Also check MEMORY.md plus key structured memory files
    main_mem = memory_dir.parent / "MEMORY.md"
    if main_mem.exists():
        existing_text += open(main_mem).read().lower()

    for extra in [
        "decisions.md",
        "business-context.md",
        "infrastructure.md",
        "people.md",
        "lessons-learned.md",
        "auth-key-registry.md",
        "session-state.md",
    ]:
        p = memory_dir / extra
        if p.exists():
            existing_text += open(p).read().lower()
    
    new_facts = []
    for fact in facts:
        # Simple substring check — if the core fact is already mentioned, skip
        # Extract key phrases (>4 words) for matching
        words = fact["text"].lower().split()
        key_phrase = " ".join(words[:8])  # First 8 words as key
        if key_phrase in existing_text:
            continue
        new_facts.append(fact)
    
    return new_facts


def format_markdown(facts, session_id, session_time):
    """Format facts as markdown for appending to daily memory file."""
    if not facts:
        return ""
    
    lines = []
    lines.append(f"\n## Memory Writer Extract — Session {session_id[:8]} ({session_time or 'unknown time'})\n")
    
    # Group by category
    by_category = {}
    for fact in facts:
        cat = fact["category"]
        if cat not in by_category:
            by_category[cat] = []
        by_category[cat].append(fact["text"])
    
    category_labels = {
        "DECISION": "📋 Decisions",
        "PREFERENCE": "⭐ Preferences",
        "PERSON": "👤 People",
        "PROJECT": "📁 Projects",
        "TECHNICAL": "🔧 Technical",
        "BUSINESS": "💼 Business",
        "RULE": "📏 Rules",
    }
    
    for cat, items in by_category.items():
        label = category_labels.get(cat, f"📌 {cat}")
        lines.append(f"### {label}")
        for item in items:
            lines.append(f"- {item}")
        lines.append("")
    
    return "\n".join(lines)


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    dry_run = "--dry-run" in sys.argv
    hours = LOOKBACK_HOURS
    
    # Parse --hours flag
    for i, arg in enumerate(sys.argv):
        if arg == "--hours" and i + 1 < len(sys.argv):
            hours = int(sys.argv[i + 1])
    
    api_key = get_anthropic_key()
    if not api_key:
        print("ERROR: No Anthropic API key found. Set ANTHROPIC_API_KEY or configure in openclaw.json")
        sys.exit(1)
    
    state = load_state()
    sessions = get_recent_sessions(hours)

    if not sessions:
        print(f"No sessions modified in the last {hours} hours (excluding last {SKIP_RECENT_MINUTES} min).")
        return

    print(f"Found {len(sessions)} recent session(s) to process.")
    
    total_new_facts = 0
    
    for session_path, mtime in sessions:
        session_id = session_path.stem
        
        # Check if already processed at this mtime
        prev = state["processed"].get(session_id, {})
        if prev.get("mtime") == mtime and prev.get("status") == "done":
            print(f"  Skipping {session_id[:8]}... (already processed)")
            continue
        
        print(f"  Processing {session_id[:8]}... ({session_path.stat().st_size / 1024:.0f}KB)")
        
        # Extract messages
        messages, session_time = extract_messages(session_path)
        if len(messages) < 3:
            print(f"    Too few messages ({len(messages)}), skipping.")
            state["processed"][session_id] = {"mtime": mtime, "status": "skipped", "reason": f"too few messages ({len(messages)})"}
            continue

        print(f"    {len(messages)} messages extracted")

        classification = classify_session(messages)
        print(f"    Classification: {classification['kind']} ({classification['reason']}, score={classification['score']})")
        if classification['kind'] != 'extract':
            state["processed"][session_id] = {"mtime": mtime, "status": "skipped", "reason": classification['reason'], "score": classification['score']}
            continue

        # Build transcript
        transcript = build_transcript(messages)
        
        # Call extraction model
        full_prompt = EXTRACTION_PROMPT + transcript
        
        try:
            raw_output, usage = call_anthropic(full_prompt, api_key)
            tokens_in = usage.get("input_tokens", 0)
            tokens_out = usage.get("output_tokens", 0)
            print(f"    LLM response: {tokens_in} in, {tokens_out} out")
        except Exception as e:
            print(f"    ERROR calling Anthropic: {e}")
            state["processed"][session_id] = {"mtime": mtime, "status": "error", "error": str(e)}
            continue
        
        # Parse facts
        facts = parse_facts(raw_output)
        print(f"    Raw facts extracted: {len(facts)}")
        
        if not facts:
            state["processed"][session_id] = {"mtime": mtime, "status": "done", "facts": 0}
            continue
        
        # Dedup
        new_facts = check_dedup(facts, MEMORY_DIR)
        print(f"    After dedup: {new_facts} new facts" if isinstance(new_facts, int) else f"    After dedup: {len(new_facts)} new facts")
        
        if not new_facts:
            state["processed"][session_id] = {"mtime": mtime, "status": "done", "facts": 0}
            continue
        
        # Format markdown
        session_date = datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%Y-%m-%d")
        session_time_str = datetime.fromtimestamp(mtime, tz=timezone.utc).strftime("%H:%M UTC")
        markdown = format_markdown(new_facts, session_id, session_time_str)
        
        if dry_run:
            print(f"\n    === DRY RUN — Would append to memory/{session_date}.md ===")
            print(markdown)
            print(f"    === END DRY RUN ===\n")
        else:
            # Append to daily memory file
            mem_file = MEMORY_DIR / f"{session_date}.md"
            with open(mem_file, "a") as f:
                f.write(markdown)
            print(f"    ✅ Appended {len(new_facts)} facts to memory/{session_date}.md")
        
        total_new_facts += len(new_facts)
        state["processed"][session_id] = {
            "mtime": mtime,
            "status": "done" if not dry_run else "dry-run",
            "facts": len(new_facts),
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
    
    # Save state (unless dry run)
    if not dry_run:
        save_state(state)
    
    print(f"\nDone. {'Would extract' if dry_run else 'Extracted'} {total_new_facts} new facts total.")


if __name__ == "__main__":
    main()
