#!/usr/bin/env python3
"""
Auto Skill Capture — Extraction Pipeline

Post-session skill extraction for OpenClaw. Evaluates completed agent sessions
and captures reusable multi-step procedures as skill documents.

Pipeline:
  1. Find the most recently ended session transcript (JSONL)
  2. Gate 1: Local heuristics (tool count, complexity score, skip cron/heartbeat)
  3. Gate 2: Nano LLM classification (is this a reusable skill?)
  4. Skill generation via mini LLM
  5. Deduplication check against existing skills
  6. Write SKILL.md + _meta.json + update INDEX.md
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request

sys.path.insert(0, "{{WORKSPACE}}/scripts")
try:
    from lockutil import acquire_lock, release_lock
except ImportError:
    def acquire_lock(name, timeout=0): return True
    def release_lock(lock): pass
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Configuration defaults (overridden by config/defaults.json if present)
# ---------------------------------------------------------------------------

DEFAULTS = {
    "extractionModel": "gpt-5.4-mini",
    "generationModel": "gpt-5.4-mini",
    "provider": "openai",
    "outputDir": "skills/auto-captured",
    "complexity": {
        "minToolCalls": 5,
        "minUserTurns": 2,
        "minAssistantTurns": 3,
        "minTranscriptChars": 3000,
        "maxTranscriptChars": 80000,
        "scoreThreshold": 30,
    },
    "skipSessionPatterns": ["^cron:", "^heartbeat", "^hook:"],
}

# Markers that indicate automation/cron sessions (skip immediately)
AUTOMATION_MARKERS = [
    "[cron:",
    "heartbeat_ok",
    "daily-report-task",
    "monitoring-task",
    "automated-email-task",
    "automated-status-check",
]

# ---------------------------------------------------------------------------
# Environment / API keys
# ---------------------------------------------------------------------------


def load_env(path: Path):
    """Load .env file into os.environ (setdefault, won't overwrite existing)."""
    if not path.exists():
        return
    for line in path.read_text(errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())


def get_openai_key(workspace: Path) -> str:
    load_env(workspace / ".env")
    return os.environ.get("MEMORY_WRITER_OPENAI_API_KEY") or os.environ.get("OPENAI_API_KEY", "")


def get_anthropic_key(workspace: Path) -> str:
    load_env(workspace / ".env")
    return os.environ.get("MEMORY_WRITER_ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_API_KEY", "")


# ---------------------------------------------------------------------------
# State management — track which sessions have been evaluated
# ---------------------------------------------------------------------------


STATE_DIR = ".auto-skill-capture"  # Hidden dir inside skills/ for state files


def load_state(workspace: Path) -> dict:
    state_file = workspace / f"skills/{STATE_DIR}/state.json"
    if state_file.exists():
        try:
            return json.loads(state_file.read_text())
        except Exception:
            pass
    # Migrate from old location if it exists
    old_state = workspace / "skills/auto-captured/.skill-capture-state.json"
    if old_state.exists():
        try:
            return json.loads(old_state.read_text())
        except Exception:
            pass
    return {"processed": {}, "lastRun": None}


def save_state(workspace: Path, state: dict):
    state["lastRun"] = datetime.now(timezone.utc).isoformat()
    state_dir = workspace / f"skills/{STATE_DIR}"
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / "state.json"
    state_file.write_text(json.dumps(state, indent=2))


# ---------------------------------------------------------------------------
# Session discovery — find all agent session directories dynamically
# ---------------------------------------------------------------------------


def discover_session_dirs(workspace: Path) -> list[Path]:
    """
    Find all session directories in the workspace.
    Main agent sessions: agents/main/sessions/
    Sub-agent sessions: agents/{agentId}/sessions/
    """
    agents_dir = workspace / "agents"
    if not agents_dir.exists():
        return []
    dirs = []
    for agent_dir in agents_dir.iterdir():
        if not agent_dir.is_dir():
            continue
        sessions_dir = agent_dir / "sessions"
        if sessions_dir.exists() and sessions_dir.is_dir():
            dirs.append(sessions_dir)
    return dirs


def find_most_recent_session(workspace: Path, skip_recent_seconds: int = 15) -> tuple[Path | None, str]:
    """
    Find the most recently modified session JSONL file across all agent directories.
    Skips files modified within skip_recent_seconds (likely still active).
    Returns (session_path, agent_id) or (None, "").
    """
    sessions = find_unprocessed_sessions(workspace, skip_recent_seconds, limit=1)
    if sessions:
        return sessions[0]
    return None, ""


def _quick_session_check(path: Path) -> bool:
    """Fast pre-filter: skip sessions that are obviously trivial (1 user turn, <2000 chars).
    Avoids full parsing — just counts lines and checks size."""
    try:
        size = path.stat().st_size
        if size < 2000:
            return False
        # Quick scan: count user message lines
        user_turns = 0
        with open(path, errors="ignore") as f:
            for line in f:
                if '"role":"user"' in line or '"role": "user"' in line:
                    user_turns += 1
                    if user_turns >= 2:
                        return True
        return False
    except Exception:
        return False


def find_unprocessed_sessions(workspace: Path, skip_recent_seconds: int = 15,
                               limit: int = 20) -> list[tuple[Path, str]]:
    """
    Find all unprocessed session JSONL files across all agent directories.
    Pre-filters trivial sessions (1 user turn, <2000 chars) before counting toward limit.
    Returns list of (session_path, agent_id) sorted by mtime descending, up to limit.
    """
    state = load_state(workspace)
    cutoff = time.time() - skip_recent_seconds
    candidates = []

    for sessions_dir in discover_session_dirs(workspace):
        agent_id = sessions_dir.parent.name
        for f in sessions_dir.glob("*.jsonl"):
            if f.name.endswith(".lock"):
                continue
            try:
                mtime = f.stat().st_mtime
                size = f.stat().st_size
            except FileNotFoundError:
                continue
            # Skip tiny files and files still being written
            if size < 500 or mtime > cutoff:
                continue
            # Skip already processed (same mtime)
            session_id = f.stem
            prev = state.get("processed", {}).get(session_id, {})
            if prev.get("status") in ("done", "skip", "dry-run"):
                if prev.get("mtime", 0) == mtime:
                    continue
            # Pre-filter: skip obviously trivial sessions before counting toward limit
            if not _quick_session_check(f):
                # Mark as skipped so we don't re-check next time
                state.setdefault("processed", {})[session_id] = {
                    "mtime": mtime,
                    "status": "skip",
                    "reason": "pre-filter: trivial session",
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                }
                continue
            candidates.append((mtime, f, agent_id))

    # Save state with pre-filtered skips
    save_state(workspace, state)

    # Sort by most recent first
    candidates.sort(key=lambda x: x[0], reverse=True)
    return [(path, agent) for _, path, agent in candidates[:limit]]


# ---------------------------------------------------------------------------
# JSONL parsing — extract structured data from session transcripts
# ---------------------------------------------------------------------------


def extract_text_from_content(content) -> str:
    """Extract plain text from message content (handles str, dict, list formats)."""
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
            elif ptype in ("toolCall", "thinking"):
                continue
            elif isinstance(part.get("text"), str):
                parts.append(part["text"])
            elif isinstance(part.get("content"), str):
                parts.append(part["content"])
        return " ".join(p for p in parts if p)
    return ""


def extract_tool_calls(content) -> list[dict]:
    """Extract tool call entries from assistant message content."""
    if not isinstance(content, list):
        return []
    calls = []
    for part in content:
        if not isinstance(part, dict):
            continue
        if part.get("type") == "toolCall":
            calls.append({
                "tool": part.get("name") or part.get("toolName", "unknown"),
                "id": part.get("id") or part.get("toolCallId", ""),
            })
    return calls


def parse_session(session_path: Path) -> dict:
    """
    Parse a session JSONL file into structured data for evaluation.
    Returns a dict with messages, tool_calls, metadata, etc.
    """
    messages = []
    tool_calls = []
    all_tool_names = set()
    files_modified = set()
    has_ssh = False
    has_api_calls = False
    user_turns = 0
    assistant_turns = 0
    session_id = session_path.stem
    session_source = ""
    total_chars = 0
    first_user_message = ""
    timestamps = []

    with open(session_path, errors="ignore") as f:
        for line in f:
            try:
                entry = json.loads(line)
            except Exception:
                continue

            # Session metadata
            if entry.get("type") == "session":
                session_id = entry.get("id", session_id)
                session_source = entry.get("source", "")
                continue

            if entry.get("type") != "message":
                continue

            msg = entry.get("message", {})
            role = msg.get("role") or entry.get("role")
            content = msg.get("content", "")
            timestamp = entry.get("timestamp", "")

            if timestamp:
                timestamps.append(timestamp)

            if role == "user":
                text = extract_text_from_content(content)
                if text and len(text.strip()) >= 5:
                    user_turns += 1
                    total_chars += len(text)
                    if not first_user_message:
                        # Skip system-prefixed messages for task description
                        clean = text.strip()
                        if not clean.startswith("System:") and not clean.startswith("Pre-compaction"):
                            first_user_message = clean[:500]
                    messages.append({"role": "user", "text": text[:2000], "timestamp": timestamp})

            elif role == "assistant":
                text = extract_text_from_content(content)
                calls = extract_tool_calls(content)

                if calls:
                    for c in calls:
                        tool_calls.append(c)
                        all_tool_names.add(c["tool"])

                if text and len(text.strip()) >= 5:
                    assistant_turns += 1
                    total_chars += len(text)
                    messages.append({
                        "role": "assistant",
                        "text": text[:2000],
                        "tool_calls": calls,
                        "timestamp": timestamp,
                    })

                    # Detect SSH usage
                    text_lower = text.lower()
                    if "ssh " in text_lower or "rsync " in text_lower or "scp " in text_lower:
                        has_ssh = True
                    # Detect API calls
                    if "api" in text_lower and ("curl" in text_lower or "fetch" in text_lower or "request" in text_lower):
                        has_api_calls = True

            elif role == "toolResult":
                # Check for file modifications in tool results
                text = extract_text_from_content(content)
                if text:
                    # Look for file paths in tool results
                    for match in re.findall(r'(?:wrote|created|modified|edited)\s+["`]?(/[^\s"`]+)', text, re.I):
                        files_modified.add(match)

    # If first_user_message is still empty, try system messages
    if not first_user_message and messages:
        for m in messages:
            if m["role"] == "user":
                first_user_message = m["text"][:500]
                break

    # Detect error recovery patterns: a tool failure followed by a similar success
    error_recoveries = 0
    for i, msg in enumerate(messages):
        if msg["role"] == "assistant" and "error" in msg.get("text", "").lower():
            # Check if next few messages show recovery
            for j in range(i + 1, min(i + 4, len(messages))):
                if messages[j]["role"] == "assistant" and "success" in messages[j].get("text", "").lower():
                    error_recoveries += 1
                    break

    # Detect multi-step verification (did the agent verify its work?)
    multi_step_verification = False
    for msg in messages[-5:]:
        text_lower = msg.get("text", "").lower()
        if any(w in text_lower for w in ["verify", "confirmed", "looks good", "working", "passed", "✅"]):
            multi_step_verification = True
            break

    # Also check tool names for SSH tools
    if any("ssh" in t.lower() or "bash" in t.lower() for t in all_tool_names):
        # Check if any bash commands contained ssh
        for msg in messages:
            if msg["role"] == "assistant":
                for tc in msg.get("tool_calls", []):
                    if tc["tool"].lower() in ("bash", "execute"):
                        has_ssh = True  # Bash tool may have run ssh

    return {
        "session_id": session_id,
        "source": session_source,
        "session_path": str(session_path),
        "messages": messages,
        "tool_calls": tool_calls,
        "tool_call_count": len(tool_calls),
        "unique_tools": list(all_tool_names),
        "unique_tool_count": len(all_tool_names),
        "files_modified": list(files_modified),
        "files_modified_count": len(files_modified),
        "has_ssh": has_ssh,
        "has_api_calls": has_api_calls,
        "user_turns": user_turns,
        "assistant_turns": assistant_turns,
        "total_chars": total_chars,
        "first_user_message": first_user_message,
        "error_recoveries": error_recoveries,
        "multi_step_verification": multi_step_verification,
        "timestamps": timestamps,
    }


# ---------------------------------------------------------------------------
# Gate 1: Local heuristics — cheap filtering before any LLM call
# ---------------------------------------------------------------------------


def is_automation_session(session_data: dict) -> bool:
    """Check if this session is automation/cron/heartbeat (skip immediately)."""
    first_msg = session_data["first_user_message"].lower()
    all_text = " ".join(m.get("text", "")[:200].lower() for m in session_data["messages"][:3])

    for marker in AUTOMATION_MARKERS:
        if marker in first_msg or marker in all_text:
            return True
    return False


def compute_complexity_score(session_data: dict) -> int:
    """
    Compute a complexity score from session metrics.
    Higher score = more likely to contain a reusable skill.
    """
    score = 0
    score += min(session_data["tool_call_count"], 20) * 2       # Up to 40
    score += min(session_data["unique_tool_count"], 8) * 3      # Up to 24
    score += min(session_data["error_recoveries"], 5) * 8       # Up to 40
    score += min(session_data["files_modified_count"], 10) * 2  # Up to 20
    score += min(session_data["user_turns"], 6) * 3             # Up to 18
    score += 10 if session_data["has_ssh"] else 0
    score += 10 if session_data["has_api_calls"] else 0
    score += 10 if session_data["multi_step_verification"] else 0

    # Bridge-converted sessions don't have parsed tool calls; compensate
    # with text volume and assistant turn count as proxy for complexity
    if session_data.get("source") == "claude-code" and session_data["tool_call_count"] == 0:
        score += min(session_data["assistant_turns"], 10) * 3   # Up to 30
        score += min(session_data["total_chars"] // 2000, 10) * 2  # Up to 20

    return score


def check_priority_flag(session_id: str) -> bool:
    """Check if a priority flag file exists for this session."""
    flag_path = Path(f"/tmp/agent-priority-{session_id[:8]}")
    if flag_path.exists():
        flag_path.unlink(missing_ok=True)  # consume the flag
        return True
    # Also check by full session ID
    flag_path2 = Path(f"/tmp/agent-priority-{session_id}")
    if flag_path2.exists():
        flag_path2.unlink(missing_ok=True)
        return True
    return False


def gate1_heuristics(session_data: dict, config: dict) -> dict:
    """
    Gate 1: Fast local heuristic check. No LLM call.
    Returns {"pass": bool, "reason": str, "score": int}.
    """
    complexity_cfg = config.get("complexity", DEFAULTS["complexity"])

    # Check for priority flag — bypass all gates
    if check_priority_flag(session_data["session_id"]):
        print("  PRIORITY FLAG detected — bypassing heuristic gates")
        return {"pass": True, "reason": "priority flag", "score": 999}

    # Skip automation/cron sessions
    if is_automation_session(session_data):
        return {"pass": False, "reason": "automation/cron session", "score": 0}

    # Bridge-converted sessions (claude-code) don't have parsed tool calls
    # because the bridge only preserves text content. Relax tool call requirement
    # for these sessions and rely on text content + turn count instead.
    is_bridge_session = session_data.get("source") == "claude-code"

    # Check minimum thresholds
    if not is_bridge_session and session_data["tool_call_count"] < complexity_cfg.get("minToolCalls", 5):
        return {
            "pass": False,
            "reason": f"too few tool calls ({session_data['tool_call_count']})",
            "score": 0,
        }

    if session_data["user_turns"] < complexity_cfg.get("minUserTurns", 2):
        return {
            "pass": False,
            "reason": f"too few user turns ({session_data['user_turns']})",
            "score": 0,
        }

    if session_data["total_chars"] < complexity_cfg.get("minTranscriptChars", 3000):
        return {
            "pass": False,
            "reason": f"transcript too short ({session_data['total_chars']} chars)",
            "score": 0,
        }

    max_chars = complexity_cfg.get("maxTranscriptChars", 80000)
    if session_data["total_chars"] > max_chars:
        return {
            "pass": False,
            "reason": f"transcript too long ({session_data['total_chars']} chars)",
            "score": 0,
        }

    # Compute complexity score
    score = compute_complexity_score(session_data)
    threshold = complexity_cfg.get("scoreThreshold", 30)

    if score < threshold:
        return {"pass": False, "reason": f"complexity score too low ({score} < {threshold})", "score": score}

    return {"pass": True, "reason": "passed heuristics", "score": score}


# ---------------------------------------------------------------------------
# Gate 2: LLM classification — nano model decides if skill is worth capturing
# ---------------------------------------------------------------------------

CLASSIFICATION_PROMPT = """You are evaluating whether an agent session contains a reusable procedure worth capturing as a skill.

A reusable skill is a multi-step procedure that an agent could follow again in the future for similar tasks.
Examples: deploying a site, debugging a specific system, configuring infrastructure, integrating an API.

NOT reusable: one-off data lookups, simple Q&A, routine status checks, writing a single function.

Session summary:
- Tool calls: {tool_count} ({unique_tools} unique tools)
- Tools used: {tool_list}
- Files touched: {file_list}
- Error recoveries: {error_recoveries}
- User turns: {user_turns}
- Task description: {first_user_message}

Compressed transcript (last 8000 chars):
{transcript_tail}

Answer with exactly one of:
CAPTURE — This contains a reusable multi-step procedure
SKIP — This is routine/one-off work, not worth capturing

If CAPTURE, also provide on separate lines:
TITLE: <short skill title, max 60 chars>
CATEGORY: <one of: infrastructure|deployment|integration|debugging|data|config|automation|development>
CONFIDENCE: <0.0 to 1.0>
REASON: <one sentence why this is reusable>"""


def build_transcript_tail(session_data: dict, max_chars: int = 8000) -> str:
    """Build a compressed transcript from the tail of the session."""
    lines = []
    for msg in session_data["messages"]:
        role_tag = "[USER]" if msg["role"] == "user" else "[AGENT]"
        text = msg.get("text", "")[:600]
        tools = msg.get("tool_calls", [])
        tool_str = ""
        if tools:
            tool_str = f" [tools: {', '.join(t['tool'] for t in tools[:5])}]"
        lines.append(f"{role_tag}{tool_str} {text}")

    full = "\n\n".join(lines)
    if len(full) > max_chars:
        full = full[-max_chars:]
    return full


def call_openai(prompt: str, model: str, api_key: str, max_tokens: int = 1800) -> tuple[str, dict]:
    """Call OpenAI Chat Completions API."""
    data = json.dumps({
        "model": model,
        "max_completion_tokens": max_tokens,
        "temperature": 0.1,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )
    resp = urllib.request.urlopen(req, timeout=120)
    result = json.loads(resp.read())
    text = result.get("choices", [{}])[0].get("message", {}).get("content", "").strip()
    usage = result.get("usage", {})
    return text, usage


def call_anthropic(prompt: str, model: str, api_key: str, max_tokens: int = 1800) -> tuple[str, dict]:
    """Call Anthropic Messages API (fallback)."""
    data = json.dumps({
        "model": model,
        "max_tokens": max_tokens,
        "temperature": 0.1,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        },
    )
    resp = urllib.request.urlopen(req, timeout=120)
    result = json.loads(resp.read())
    text = "\n".join(
        part.get("text", "") for part in result.get("content", []) if part.get("type") == "text"
    ).strip()
    return text, result.get("usage", {})


def call_llm(prompt: str, model: str, workspace: Path, max_tokens: int = 1800) -> tuple[str, dict]:
    """Route to the configured provider. Falls back to Anthropic if OpenAI fails."""
    api_key = get_openai_key(workspace)
    if api_key:
        try:
            return call_openai(prompt, model, api_key, max_tokens)
        except Exception as e:
            print(f"  WARNING: OpenAI call failed ({e}), falling back to Anthropic")

    api_key = get_anthropic_key(workspace)
    if api_key:
        fallback_model = "claude-sonnet-4-6" if "nano" in model else "claude-sonnet-4-6"
        return call_anthropic(prompt, fallback_model, api_key, max_tokens)

    raise RuntimeError("No API keys available (checked OPENAI_API_KEY and ANTHROPIC_API_KEY)")


def gate2_llm_classification(session_data: dict, config: dict, workspace: Path) -> dict:
    """
    Gate 2: LLM classification using nano model.
    Returns {"pass": bool, "title": str, "category": str, "confidence": float, "reason": str}.
    """
    model = config.get("extractionModel", DEFAULTS["extractionModel"])
    transcript_tail = build_transcript_tail(session_data)

    prompt = CLASSIFICATION_PROMPT.format(
        tool_count=session_data["tool_call_count"],
        unique_tools=session_data["unique_tool_count"],
        tool_list=", ".join(session_data["unique_tools"][:15]),
        file_list=", ".join(session_data["files_modified"][:10]) or "(none detected)",
        error_recoveries=session_data["error_recoveries"],
        user_turns=session_data["user_turns"],
        first_user_message=session_data["first_user_message"][:300],
        transcript_tail=transcript_tail,
    )

    text, usage = call_llm(prompt, model, workspace, max_tokens=300)
    print(f"  Gate 2 LLM response ({usage.get('total_tokens', '?')} tokens): {text[:200]}")

    # Parse response
    lines = text.strip().splitlines()
    first_line = lines[0].strip().upper() if lines else ""

    if first_line.startswith("SKIP"):
        return {"pass": False, "reason": "LLM classified as not reusable"}

    if not first_line.startswith("CAPTURE"):
        return {"pass": False, "reason": f"LLM gave unexpected response: {first_line[:50]}"}

    # Parse CAPTURE metadata
    title = ""
    category = "development"
    confidence = 0.7
    reason = ""

    for line in lines[1:]:
        line = line.strip()
        if line.upper().startswith("TITLE:"):
            title = line[6:].strip()
        elif line.upper().startswith("CATEGORY:"):
            category = line[9:].strip().lower()
        elif line.upper().startswith("CONFIDENCE:"):
            try:
                confidence = float(line[11:].strip())
            except ValueError:
                pass
        elif line.upper().startswith("REASON:"):
            reason = line[7:].strip()

    if not title:
        title = session_data["first_user_message"][:60]

    return {
        "pass": True,
        "title": title,
        "category": category,
        "confidence": min(max(confidence, 0.0), 1.0),
        "reason": reason,
        "usage": usage,
    }


# ---------------------------------------------------------------------------
# Skill generation — mini model writes the skill document
# ---------------------------------------------------------------------------

GENERATION_PROMPT = """You are generating a reusable skill document from a completed agent session.

The skill should capture the PROCEDURE — the steps, decisions, verification, and pitfalls — not the specific data.
Generalize specific values (IPs, paths, names) into placeholders like {{server}}, {{file_path}}, {{domain}}.
Keep the procedure actionable — an agent should be able to follow it.
Include the verification step — this is what makes skills trustworthy.
If error recovery happened, document it as a pitfall.
Do NOT include the raw session transcript.
Keep under 200 lines.

Session context:
- Task: {task_description}
- Category: {category}
- Tools used: {tool_summary}
- Key files: {files_touched}
- Error recoveries: {error_points}

Full session timeline:
{formatted_timeline}

Generate a skill document in this EXACT format (including the YAML frontmatter delimiters):

---
name: {slug}
description: "<one-line description>"
---

# <Title>

## When to Use
- [1-3 bullet points describing when this skill applies]

## Prerequisites
- [What must be true before starting — access, tools, config]

## Procedure

### Step 1: <step_name>
[What to do, what tool to use, what to check]

### Step 2: <step_name>
[Continue for each major step]

## Verification
[How to confirm the procedure succeeded]

## Common Pitfalls
[Things that went wrong during the original session and how to handle them]

## Related Skills
[Leave empty — will be populated during review]"""


UPDATE_PROMPT = """You are updating an existing skill document based on a new agent session that performed a similar procedure.

Your job:
1. PRESERVE everything correct and valuable from the existing skill
2. ADD new steps, pitfalls, or details learned from the new session
3. IMPROVE any steps that the new session handled better or differently
4. REMOVE outdated information contradicted by the new session
5. Keep the same format and structure
6. Keep under 200 lines
7. Do NOT include the raw session transcript

Existing skill document:
{existing_skill}

New session context:
- Task: {task_description}
- Category: {category}
- Tools used: {tool_summary}
- Key files: {files_touched}
- Error recoveries: {error_points}

New session timeline:
{formatted_timeline}

Generate the COMPLETE updated skill document (same format as the original, including YAML frontmatter).
If the new session reveals nothing new, return the existing skill unchanged."""


def update_skill_from_session(session_data: dict, classification: dict, existing_skill_path: Path,
                               config: dict, workspace: Path) -> dict:
    """
    Update an existing skill document using the new session context.
    Returns {"skill_md": str, "slug": str, "title": str, "tags": list, "usage": dict}.
    """
    model = config.get("generationModel", DEFAULTS["generationModel"])
    existing_skill = existing_skill_path.read_text() if existing_skill_path.exists() else ""
    slug = existing_skill_path.parent.name

    prompt = UPDATE_PROMPT.format(
        existing_skill=existing_skill,
        task_description=session_data["first_user_message"][:500],
        category=classification["category"],
        tool_summary=", ".join(session_data["unique_tools"][:15]),
        files_touched=", ".join(session_data["files_modified"][:10]) or "(none detected)",
        error_points=f"{session_data['error_recoveries']} error recovery sequences detected",
        formatted_timeline=format_timeline(session_data),
    )

    text, usage = call_llm(prompt, model, workspace, max_tokens=2500)
    print(f"  Update LLM response ({usage.get('total_tokens', '?')} tokens): {len(text)} chars")

    tags = [classification["category"]]
    for tool in session_data["unique_tools"][:5]:
        tag = tool.lower().replace("_", "-")
        if tag not in tags:
            tags.append(tag)

    return {
        "skill_md": text,
        "slug": slug,
        "title": classification["title"],
        "tags": tags,
        "usage": usage,
    }


def generate_slug(title: str) -> str:
    """Generate a URL-safe slug from a title."""
    slug = title.lower().strip()
    slug = re.sub(r'[^a-z0-9\s-]', '', slug)
    slug = re.sub(r'[\s]+', '-', slug)
    slug = re.sub(r'-+', '-', slug)
    slug = slug.strip('-')
    return slug[:40]


def format_timeline(session_data: dict, max_chars: int = 12000) -> str:
    """Format session messages into a readable timeline for the generation prompt."""
    lines = []
    for i, msg in enumerate(session_data["messages"]):
        role = "USER" if msg["role"] == "user" else "AGENT"
        text = msg.get("text", "")[:800]
        tools = msg.get("tool_calls", [])
        ts = msg.get("timestamp", "")[:19]

        if tools:
            tool_names = ", ".join(t["tool"] for t in tools[:5])
            lines.append(f"[{ts}] {role} (tools: {tool_names}):\n{text}")
        else:
            lines.append(f"[{ts}] {role}:\n{text}")

    full = "\n\n---\n\n".join(lines)
    if len(full) > max_chars:
        full = full[-max_chars:]
    return full


def generate_skill(session_data: dict, classification: dict, config: dict, workspace: Path) -> dict:
    """
    Generate a skill document using the mini LLM.
    Returns {"skill_md": str, "slug": str, "title": str, "tags": list, "usage": dict}.
    """
    model = config.get("generationModel", DEFAULTS["generationModel"])
    slug = generate_slug(classification["title"])

    prompt = GENERATION_PROMPT.format(
        task_description=session_data["first_user_message"][:500],
        category=classification["category"],
        tool_summary=", ".join(session_data["unique_tools"][:15]),
        files_touched=", ".join(session_data["files_modified"][:10]) or "(none detected)",
        error_points=f"{session_data['error_recoveries']} error recovery sequences detected",
        formatted_timeline=format_timeline(session_data),
        slug=slug,
    )

    text, usage = call_llm(prompt, model, workspace, max_tokens=1800)
    print(f"  Generation LLM response ({usage.get('total_tokens', '?')} tokens): {len(text)} chars")

    # Extract tags from category + tools + key terms
    tags = [classification["category"]]
    for tool in session_data["unique_tools"][:5]:
        tag = tool.lower().replace("_", "-")
        if tag not in tags:
            tags.append(tag)

    return {
        "skill_md": text,
        "slug": slug,
        "title": classification["title"],
        "tags": tags,
        "usage": usage,
    }


# ---------------------------------------------------------------------------
# Deduplication — check if a similar skill already exists
# ---------------------------------------------------------------------------


def load_skill_index(workspace: Path) -> dict:
    """Load the skill index file, or return empty index."""
    index_path = workspace / f"skills/{STATE_DIR}/skill-index.json"
    if index_path.exists():
        try:
            return json.loads(index_path.read_text())
        except Exception:
            pass
    # Migrate from old location
    old_index = workspace / "skills/auto-captured/.skill-index.json"
    if old_index.exists():
        try:
            return json.loads(old_index.read_text())
        except Exception:
            pass
    return {"version": 2, "updated": None, "skills": []}


def save_skill_index(workspace: Path, index: dict):
    """Save the skill index file."""
    index["updated"] = datetime.now(timezone.utc).isoformat()
    state_dir = workspace / f"skills/{STATE_DIR}"
    state_dir.mkdir(parents=True, exist_ok=True)
    index_path = state_dir / "skill-index.json"
    index_path.write_text(json.dumps(index, indent=2))


def keyword_overlap(tags_a: list, tags_b: list) -> float:
    """Compute Jaccard overlap between two tag lists."""
    set_a = set(t.lower() for t in tags_a)
    set_b = set(t.lower() for t in tags_b)
    if not set_a or not set_b:
        return 0.0
    intersection = set_a & set_b
    union = set_a | set_b
    return len(intersection) / len(union)


def jaccard_words(text_a: str, text_b: str) -> float:
    """Compute Jaccard similarity on word sets."""
    words_a = set(text_a.lower().split())
    words_b = set(text_b.lower().split())
    if not words_a or not words_b:
        return 0.0
    return len(words_a & words_b) / len(words_a | words_b)


def scan_all_skills(workspace: Path) -> list[dict]:
    """
    Scan ALL skills directories (both hand-crafted and auto-captured) for dedup.
    Returns list of {"slug": str, "title": str, "is_auto": bool, "skill_path": str}.
    """
    skills_dir = workspace / "skills"
    results = []
    skip_dirs = {STATE_DIR, "auto-captured", "__pycache__", "node_modules"}

    for skill_dir in sorted(skills_dir.iterdir()):
        if not skill_dir.is_dir() or skill_dir.name.startswith(".") or skill_dir.name in skip_dirs:
            continue
        skill_md = skill_dir / "SKILL.md"
        if not skill_md.exists():
            continue

        # Determine if auto-captured by checking for _meta.json
        meta_path = skill_dir / "_meta.json"
        is_auto = False
        meta = {}
        if meta_path.exists():
            try:
                meta = json.loads(meta_path.read_text())
                is_auto = "capturedFrom" in meta or "capturedAt" in meta
            except Exception:
                pass

        # Extract title from SKILL.md (first # heading)
        title = skill_dir.name
        try:
            for line in skill_md.read_text(errors="ignore").splitlines()[:20]:
                if line.startswith("# "):
                    title = line[2:].strip()
                    break
        except Exception:
            pass

        # Extract description from frontmatter
        description = meta.get("description", title)

        results.append({
            "slug": skill_dir.name,
            "title": title,
            "description": description,
            "is_auto": is_auto,
            "skill_path": str(skill_md),
            "category": meta.get("category", ""),
            "tags": meta.get("tags", []),
        })

    return results


def check_duplicate(new_slug: str, new_title: str, new_category: str, new_tags: list,
                    workspace: Path, threshold: float = 0.6) -> dict:
    """
    Check if a similar skill already exists across ALL skills/.
    Returns {"action": "create"|"update"|"merge_candidate",
             "existing": dict|None, "is_auto": bool}.
    """
    all_skills = scan_all_skills(workspace)

    for existing in all_skills:
        # Exact slug match → update
        if existing["slug"] == new_slug:
            return {"action": "update", "existing": existing, "is_auto": existing["is_auto"]}

        # Title similarity
        title_sim = jaccard_words(existing["title"], new_title)
        if title_sim > 0.5:
            return {"action": "merge_candidate", "existing": existing, "is_auto": existing["is_auto"]}

        # Category + high tag overlap (only if both have tags)
        if existing.get("category") and existing["category"] == new_category:
            if existing.get("tags"):
                overlap = keyword_overlap(existing["tags"], new_tags)
                if overlap > threshold:
                    return {"action": "merge_candidate", "existing": existing, "is_auto": existing["is_auto"]}

        # Slug word similarity (catches e.g. "deploy-app" matching "deploy-app-staging")
        slug_sim = jaccard_words(existing["slug"].replace("-", " "), new_slug.replace("-", " "))
        if slug_sim > 0.6:
            return {"action": "merge_candidate", "existing": existing, "is_auto": existing["is_auto"]}

    return {"action": "create", "existing": None, "is_auto": False}


# ---------------------------------------------------------------------------
# Write outputs — SKILL.md, _meta.json, INDEX.md
# ---------------------------------------------------------------------------


def write_skill(workspace: Path, slug: str, skill_md: str, meta: dict,
                is_update: bool = False, is_hand_crafted: bool = False):
    """
    Write the skill document and metadata to disk.
    For hand-crafted skills being updated, writes _suggested-update.md instead
    of overwriting SKILL.md directly.
    """
    skill_dir = workspace / f"skills/{slug}"
    skill_dir.mkdir(parents=True, exist_ok=True)

    if is_update and is_hand_crafted:
        # Safety: don't overwrite hand-crafted skills directly
        suggest_path = skill_dir / "_suggested-update.md"
        suggest_path.write_text(skill_md)
        print(f"  Wrote {suggest_path} (suggested update — review before merging)")

        # Write suggestion metadata
        suggest_meta_path = skill_dir / "_suggested-update-meta.json"
        suggest_meta_path.write_text(json.dumps(meta, indent=2))
        print(f"  Wrote {suggest_meta_path}")
    else:
        # Write SKILL.md directly (new skill or updating auto-captured)
        skill_path = skill_dir / "SKILL.md"
        skill_path.write_text(skill_md)
        print(f"  Wrote {skill_path}")

        # Write _meta.json
        meta_path = skill_dir / "_meta.json"
        meta_path.write_text(json.dumps(meta, indent=2))
        print(f"  Wrote {meta_path}")


def notify_daily_log(workspace: Path, slug: str, title: str, category: str,
                     confidence: float, action: str, agent_id: str):
    """Append a one-liner to the agent's daily log so the capture is visible."""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    daily_log = workspace / f"memory/{today}.md"
    label = {"create": "SKILL-CAPTURED", "update": "SKILL-UPDATED",
             "suggest": "SKILL-SUGGESTED"}.get(action, "SKILL")
    entry = (f"\n- [{label}] {title} (`skills/{slug}/SKILL.md`) — "
             f"confidence: {confidence:.2f}, category: {category}, "
             f"source: {agent_id}\n")
    try:
        with open(daily_log, "a") as f:
            f.write(entry)
        print(f"  Notified daily log: {today}.md")
    except Exception as e:
        print(f"  WARNING: Could not write to daily log: {e}")


def update_capture_log(workspace: Path, slug: str, title: str, category: str,
                       description: str, action: str):
    """Append to the auto-capture activity log."""
    log_dir = workspace / f"skills/{STATE_DIR}"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / "capture-log.md"

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    label = {"create": "NEW", "update": "UPDATED", "suggest": "SUGGESTED"}.get(action, action.upper())
    entry = f"- [{label}] **{title}** (`skills/{slug}/`) — {description} ({category}, {today})\n"

    with open(log_path, "a") as f:
        f.write(entry)

    print(f"  Logged to capture-log.md")


def update_skill_index_json(index: dict, slug: str, title: str, description: str,
                            category: str, tags: list, confidence: float):
    """Add or update an entry in the .skill-index.json."""
    # Remove existing entry with same slug
    index["skills"] = [s for s in index["skills"] if s.get("slug") != slug]

    # Add new entry
    index["skills"].append({
        "slug": slug,
        "title": title,
        "description": description,
        "category": category,
        "tags": tags,
        "confidence": confidence,
        "timesUsed": 0,
        "reviewStatus": "auto",
    })


# ---------------------------------------------------------------------------
# Main extraction pipeline
# ---------------------------------------------------------------------------


def run_extraction(workspace: Path, config: dict, dry_run: bool = False):
    """
    Main entry point. Finds all unprocessed sessions, evaluates each through
    both gates, and generates skill documents for those that pass.
    """
    lock = acquire_lock("skill-extractor", timeout=5)
    if not lock:
        print("Another skill extractor instance is running. Exiting.")
        return

    try:
        _run_extraction_inner(workspace, config, dry_run)
    finally:
        release_lock(lock)


def _run_extraction_inner(workspace: Path, config: dict, dry_run: bool = False):
    print(f"Auto Skill Capture — {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
    print(f"Workspace: {workspace}")

    # Find all unprocessed sessions
    sessions = find_unprocessed_sessions(workspace)
    if not sessions:
        print("No unprocessed sessions found. Exiting.")
        return

    print(f"Found {len(sessions)} unprocessed session(s)")

    for session_path, agent_id in sessions:
        print(f"\n{'='*60}")
        _process_single_session(workspace, config, dry_run, session_path, agent_id)


def _process_single_session(workspace: Path, config: dict, dry_run: bool,
                             session_path: Path, agent_id: str):
    """Process a single session through the extraction pipeline."""
    # Load state fresh for each session
    state = load_state(workspace)

    session_id = session_path.stem
    print(f"Evaluating session: {session_id[:12]}... (agent: {agent_id})")

    # Check if already processed
    prev = state["processed"].get(session_id, {})
    if prev.get("status") in ("done", "skip", "dry-run"):
        prev_mtime = prev.get("mtime", 0)
        try:
            current_mtime = session_path.stat().st_mtime
        except FileNotFoundError:
            print("Session file no longer exists. Exiting.")
            return
        if prev_mtime == current_mtime:
            print(f"Session already processed ({prev['status']}). Exiting.")
            return

    # Parse session
    print("Parsing session transcript...")
    session_data = parse_session(session_path)
    print(f"  {session_data['user_turns']} user turns, {session_data['assistant_turns']} assistant turns")
    print(f"  {session_data['tool_call_count']} tool calls ({session_data['unique_tool_count']} unique)")
    print(f"  {session_data['total_chars']} total chars")

    # Gate 1: Local heuristics
    print("Gate 1: Heuristic check...")
    gate1 = gate1_heuristics(session_data, config)
    print(f"  Score: {gate1['score']} — {'PASS' if gate1['pass'] else 'FAIL'} ({gate1['reason']})")

    if not gate1["pass"]:
        state["processed"][session_id] = {
            "mtime": session_path.stat().st_mtime,
            "status": "skip",
            "reason": gate1["reason"],
            "score": gate1["score"],
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        if not dry_run:
            save_state(workspace, state)
        return

    # Gate 2: LLM classification
    print("Gate 2: LLM classification...")
    gate2 = gate2_llm_classification(session_data, config, workspace)
    print(f"  {'CAPTURE' if gate2['pass'] else 'SKIP'}: {gate2.get('reason', '')}")

    if not gate2["pass"] and gate1["reason"] != "priority flag":
        state["processed"][session_id] = {
            "mtime": session_path.stat().st_mtime,
            "status": "skip",
            "reason": f"gate2: {gate2['reason']}",
            "score": gate1["score"],
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        if not dry_run:
            save_state(workspace, state)
        return
    elif not gate2["pass"] and gate1["reason"] == "priority flag":
        # Priority flag bypasses Gate 2 rejection
        print("  Priority flag overrides Gate 2 SKIP — forcing capture")
        gate2["pass"] = True
        gate2["title"] = gate2.get("title") or session_data["first_user_message"][:60]
        gate2["category"] = gate2.get("category", "development")
        gate2["confidence"] = 0.5  # lower confidence for forced captures

    print(f"  Title: {gate2['title']}")
    print(f"  Category: {gate2['category']}")
    print(f"  Confidence: {gate2['confidence']}")

    # Deduplication check — scans ALL skills/, not just auto-captured
    print("Checking for duplicates across all skills/...")
    index = load_skill_index(workspace)
    slug = generate_slug(gate2["title"])
    dup_check = check_duplicate(slug, gate2["title"], gate2["category"],
                                [gate2["category"]], workspace)
    print(f"  Dedup result: {dup_check['action']}")

    # Determine update mode
    is_update = dup_check["action"] in ("update", "merge_candidate")
    is_hand_crafted = is_update and not dup_check.get("is_auto", False)
    existing_slug = None
    if is_update:
        existing = dup_check["existing"]
        existing_slug = existing.get("slug", "")
        craft_label = "hand-crafted" if is_hand_crafted else "auto-captured"
        print(f"  Found existing {craft_label} skill to update: {existing_slug}")

    # Generate or update skill document
    if is_update:
        if is_hand_crafted:
            print(f"Generating suggested update for hand-crafted skill: {existing_slug}...")
        else:
            print(f"Updating auto-captured skill: {existing_slug}...")
    else:
        print("Generating new skill document...")

    if dry_run:
        print("  [DRY RUN] Would generate skill document here.")
        state["processed"][session_id] = {
            "mtime": session_path.stat().st_mtime,
            "status": "dry-run",
            "reason": f"would capture: {gate2['title']}",
            "score": gate1["score"],
            "classification": {
                "title": gate2["title"],
                "category": gate2["category"],
                "confidence": gate2["confidence"],
            },
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        save_state(workspace, state)
        return

    if is_update:
        existing_skill_path = workspace / f"skills/{existing_slug}/SKILL.md"
        gen = update_skill_from_session(session_data, gate2, existing_skill_path, config, workspace)
        gen["slug"] = existing_slug  # preserve the original slug
    else:
        gen = generate_skill(session_data, gate2, config, workspace)

    # Build metadata
    description = gate2.get("reason", gen["title"])
    if is_update and not is_hand_crafted:
        # Load existing meta and bump version for auto-captured updates
        existing_meta_path = workspace / f"skills/{existing_slug}/_meta.json"
        existing_meta = {}
        if existing_meta_path.exists():
            try:
                existing_meta = json.loads(existing_meta_path.read_text())
            except Exception:
                pass
        old_version = existing_meta.get("version", "1.0.0")
        parts = old_version.split(".")
        try:
            parts[-1] = str(int(parts[-1]) + 1)
        except ValueError:
            parts[-1] = "1"
        new_version = ".".join(parts)
        meta = {
            **existing_meta,
            "slug": gen["slug"],
            "version": new_version,
            "updatedAt": datetime.now(timezone.utc).isoformat(),
            "updatedFrom": {
                "sessionId": session_data["session_id"],
                "agentId": agent_id,
                "workspace": str(workspace),
            },
            "category": gate2["category"],
            "complexityScore": gate1["score"],
            "confidence": max(gate2["confidence"], existing_meta.get("confidence", 0)),
            "tags": list(set(existing_meta.get("tags", []) + gen["tags"])),
        }
    else:
        meta = {
            "slug": gen["slug"],
            "version": "1.0.0",
            "capturedAt": datetime.now(timezone.utc).isoformat(),
            "capturedFrom": {
                "sessionId": session_data["session_id"],
                "agentId": agent_id,
                "workspace": str(workspace),
            },
            "category": gate2["category"],
            "complexityScore": gate1["score"],
            "confidence": gate2["confidence"],
            "timesRecalled": 0,
            "timesUsed": 0,
            "lastRecalled": None,
            "lastUsed": None,
            "reviewStatus": "auto",
            "reviewedBy": None,
            "reviewedAt": None,
            "supersededBy": None,
            "tags": gen["tags"],
        }

    # Write to disk
    write_skill(workspace, gen["slug"], gen["skill_md"], meta,
                is_update=is_update, is_hand_crafted=is_hand_crafted)

    # Log the action
    action_type = "suggest" if is_hand_crafted else ("update" if is_update else "create")
    update_capture_log(workspace, gen["slug"], gen["title"], gate2["category"],
                       description, action_type)
    notify_daily_log(workspace, gen["slug"], gen["title"], gate2["category"],
                     gate2["confidence"], action_type, agent_id)

    # Update skill index
    update_skill_index_json(index, gen["slug"], gen["title"], description,
                            gate2["category"], gen["tags"], gate2["confidence"])
    save_skill_index(workspace, index)

    # Update state
    status_label = "suggested update for" if is_hand_crafted else ("updated" if is_update else "captured")
    state["processed"][session_id] = {
        "mtime": session_path.stat().st_mtime,
        "status": "done",
        "reason": f"{status_label}: {gen['slug']}",
        "score": gate1["score"],
        "slug": gen["slug"],
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    save_state(workspace, state)

    output_file = "_suggested-update.md" if is_hand_crafted else "SKILL.md"
    print(f"\nDone! Skill {status_label}: {gen['slug']}")
    print(f"  {output_file}: skills/{gen['slug']}/{output_file}")


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Auto Skill Capture — extraction pipeline")
    parser.add_argument("--workspace", type=str, default="{{WORKSPACE}}",
                        help="Workspace root directory")
    parser.add_argument("--dry-run", action="store_true",
                        help="Run without writing files or making generation LLM calls")
    parser.add_argument("--config", type=str, default=None,
                        help="Path to config JSON (overrides defaults)")
    args = parser.parse_args()

    workspace = Path(args.workspace)
    if not workspace.exists():
        print(f"ERROR: Workspace not found: {workspace}")
        sys.exit(1)

    # Load config
    config = dict(DEFAULTS)
    config_path = args.config or str(Path(__file__).parent.parent / "config" / "defaults.json")
    if Path(config_path).exists():
        try:
            user_config = json.loads(Path(config_path).read_text())
            config.update(user_config)
        except Exception as e:
            print(f"WARNING: Failed to load config from {config_path}: {e}")

    # Verify API keys
    if not get_openai_key(workspace) and not get_anthropic_key(workspace):
        print("ERROR: No API keys found. Need OPENAI_API_KEY or ANTHROPIC_API_KEY.")
        sys.exit(1)

    try:
        run_extraction(workspace, config, dry_run=args.dry_run)
    except Exception as e:
        print(f"ERROR: Extraction failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
