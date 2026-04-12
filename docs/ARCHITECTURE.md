# FlipClaw Architecture Reference

**Version:** 3.2.3 | **Last updated:** 2026-04-11

This document is a comprehensive technical deep-dive into FlipClaw's internals. It covers every layer of the memory system, every pipeline stage, every configuration surface, and the update/backup lifecycle. Read this if you want to understand exactly how FlipClaw works before adopting it.

**Minimum OpenClaw version:** `2026.4.9` — enforced by all installers for `memory-core` Dreaming, `memory-wiki` bridge mode, and `continuation-skip` context injection.

**Recommended OpenClaw version:** `2026.4.10` or later. Two upstream bugs documented in [KNOWN-ISSUES.md](KNOWN-ISSUES.md) (dreaming cron reconciler, wiki bridge listArtifacts) were fixed in `2026.4.10`. FlipClaw's **upstream patch registry** (`scripts/upstream-patches.json` + `scripts/apply-upstream-patches.sh`, added in v3.2.2) installs workarounds automatically when you're on `2026.4.9` and removes them automatically when you upgrade to `2026.4.10+`. You can install on 4.9 and work fine; upgrading to 4.10 is a clean win with no configuration changes required.

---

## Overview

FlipClaw exists because Anthropic removed subscription OAuth from third-party harnesses, which means OpenClaw can no longer run Claude on a Max subscription. FlipClaw flips the architecture: Claude Code CLI (which still works on Max) becomes the primary interface, and OpenClaw wraps around it as the infrastructure layer. This gives Claude Code persistent memory, automatic skill capture, nightly consolidation (Dreaming), semantic search, and a browsable knowledge wiki -- all backed by the same file-based memory system your OpenClaw agent already uses. One shared system between both interfaces.

The core design principle is **shared memory**: both Claude Code sessions and OpenClaw agent sessions read from and write to the same set of Markdown files. Facts from Claude Code are tagged with `[src:claude-code]` for provenance, but otherwise flow through the same extraction, consolidation, and promotion pipeline as native agent facts.

FlipClaw has no database. Everything is Markdown, JSONL, and JSON -- human-readable, git-friendly, and grep-able.

---

## Memory Layers

FlipClaw organizes memory into eight layers, ordered from rawest (ephemeral) to most curated (permanent).

### Layer 1: Session Transcripts

| Property | Value |
|----------|-------|
| **Location** | `agents/main/sessions/*.jsonl` (OpenClaw), `agents/claude-code/sessions/*.jsonl` (Claude Code) |
| **Format** | JSONL -- one JSON object per line. Each file starts with a session header record (`"type": "session"`) followed by message records (`"type": "message"`) |
| **Purpose** | Full conversation archive. Every user and assistant message, including tool calls, is preserved verbatim |
| **Lifecycle** | Created during sessions. Never modified after the session ends. Searchable via semantic search and grep |

Each message record includes: `id`, `parentId` (for threading), `timestamp`, and a `message` object with `role` and `content` blocks (text, tool calls, tool results).

### Layer 2: Session Cache

| Property | Value |
|----------|-------|
| **Location** | `memory/session-cache/{session_id}.md` |
| **Format** | Markdown with two sections: "Recent Context" (last 8 turns) and "Captured Durable Facts" |
| **Purpose** | Lightweight per-session summary. Provides quick context without parsing the full JSONL |
| **Lifecycle** | Written after incremental capture processes a session. Overwritten on each capture pass |

### Layer 3: Daily Logs

| Property | Value |
|----------|-------|
| **Location** | `memory/YYYY-MM-DD.md` |
| **Format** | Markdown with timestamped sections. Each section contains tagged fact bullets: `- [CATEGORY] [src:source] fact text` |
| **Purpose** | Chronological record of all captured facts for a given day. The primary intake destination for the extraction pipeline |
| **Lifecycle** | Created on first capture of the day. Appended to throughout the day. Consolidated by Dreaming's Light phase after 3 days |

Categories: `[DECISION]`, `[PREFERENCE]`, `[PERSON]`, `[PROJECT]`, `[TECHNICAL]`, `[BUSINESS]`, `[RULE]`.

### Layer 4: Structured Memory Files

| Property | Value |
|----------|-------|
| **Location** | `memory/{topic}.md` -- e.g., `infrastructure.md`, `people.md`, `decisions.md`, `business-context.md`, `lessons-learned.md` |
| **Format** | Markdown organized by topic. Facts are grouped under dated headers |
| **Purpose** | Topic-indexed reference. Facts extracted from daily logs are also routed here by category |
| **Lifecycle** | Created by the installer. Appended to by incremental capture. Never truncated automatically |

Routing rules (category to file):
- `DECISION` -> `decisions.md`
- `PREFERENCE`, `RULE` -> `lessons-learned.md`
- `PERSON` -> `people.md`
- `TECHNICAL` -> `infrastructure.md`
- `BUSINESS` -> `business-context.md`
- `PROJECT` -> daily log only (no structured file)

### Layer 5: Curated Core Memory (MEMORY.md)

| Property | Value |
|----------|-------|
| **Location** | `MEMORY.md` (workspace root) |
| **Format** | Markdown with sections: People, Infrastructure, Business Rules, Decisions, Lessons Learned |
| **Purpose** | The most important knowledge, always loaded into the agent's context window. The single document that defines what the agent "knows" at the start of every session |
| **Lifecycle** | Seeded by the installer. Promoted to by Dreaming's Deep phase based on recall frequency. Can also be edited manually |

Promotion criteria (Deep phase): a fact must have been recalled at least 3 times, from at least 2 unique queries, within the last 90 days, with a minimum score of 0.3.

### Layer 6: Dreaming Reports

| Property | Value |
|----------|-------|
| **Location** | `memory/dreaming/` (individual reports), `DREAMS.md` (human-readable diary) |
| **Format** | Markdown reports per phase per run, plus a narrative diary |
| **Purpose** | Audit trail for consolidation. Shows what was deduplicated, promoted, or detected as a pattern |
| **Lifecycle** | Generated nightly by the Dreaming pipeline. Accumulates over time |

### Layer 7: Memory Wiki

| Property | Value |
|----------|-------|
| **Location** | `wiki/` |
| **Format** | Markdown vault with backlinks, dashboards, and navigation pages. Bridge mode -- reads from memory artifacts rather than maintaining its own copy |
| **Purpose** | Organized, browsable knowledge view. Useful for humans reviewing what the agent knows |
| **Lifecycle** | Automatically maintained by the `memory-wiki` plugin. Indexes daily notes, dream reports, and memory root |

### Layer 8: Skills

| Property | Value |
|----------|-------|
| **Location** | `skills/{slug}/SKILL.md` (procedure), `skills/{slug}/_meta.json` (metadata) |
| **Format** | Markdown with YAML frontmatter. Sections: When to Use, Prerequisites, Procedure (numbered steps), Verification, Common Pitfalls, Related Skills |
| **Purpose** | Reusable multi-step procedures. Auto-captured from sessions or hand-crafted by humans |
| **Lifecycle** | Created by auto-skill-capture or manually. Auto-captured skills can be updated; hand-crafted skills are never overwritten (updates go to `_suggested-update.md`) |

---

## Write Pipeline

Facts enter the memory system through four independent write paths. All paths ultimately write to the same set of files.

### Agent Native Pipeline (OpenClaw Sessions)

This is the primary write path for OpenClaw agent sessions.

```
OpenClaw agent turn completes
        |
        v
memory-bridge plugin fires on agent_end event
        |
        v
Calls: python3 incremental-memory-capture.py --include-active
        |
        v
1. Scans agents/main/sessions/ for recently modified JSONL files
2. Extracts the most recent conversational window (last 12 turns)
3. Classifies the window (scoring: user turns, agent turns, content length, topic keywords)
4. If score >= 8: sends the window to the LLM for fact extraction
5. LLM returns tagged facts: [CATEGORY] fact text
6. Echo detection: filters facts that already exist in recent daily logs or MEMORY.md (90%+ word overlap)
7. Writes facts to:
   - memory/YYYY-MM-DD.md (daily log, primary)
   - memory/{topic}.md (structured file, by category routing)
   - memory/session-cache/{session_id}.md (session summary)
```

The capture script uses GPT-5.4 Nano by default for extraction -- fast, cheap, and purpose-built for classification tasks. It falls back to Anthropic if the OpenAI call fails.

Classification scoring:
- User turns: +4 per turn (capped at 6)
- Agent turns: +2 per turn (capped at 6)
- Content length: +1 per 3000 chars (capped at 8)
- Topic keyword bonus: +2 if content mentions memory, maintenance, config, server, api key, agent, deploy, or task
- Automation penalty: score -20 if <= 1 user turn and automation markers detected
- Threshold: score must reach 8 to trigger extraction

### Claude Code -- Per-Turn Capture

This path provides continuous fact extraction during active Claude Code sessions, mirroring the agent native pipeline's per-turn behavior.

```
Claude Code responds (any turn)
        |
        v
Stop hook fires (async, 30s timeout)
        |
        v
claude-code-turn-capture.py executes
        |
        v
1. Reads session_id from hook JSON on stdin (if available)
2. Acquires lock (claude-code-turn-capture, 2s timeout -- skips if another capture is running)
3. Finds active transcript: searches ~/.claude/projects/*/  for the session JSONL
4. Skips if transcript < 2000 bytes
5. Creates a temporary symlink from the active transcript into agents/claude-code/sessions/
6. Runs incremental-memory-capture.py --include-active
7. Cleans up the symlink
```

The `--include-active` flag tells the capture script to process files that were modified very recently (normally it skips files modified in the last 15 seconds to avoid capturing from still-active sessions).

Output is suppressed from the user via `{"suppressOutput": true}` -- the capture runs silently in the background.

### Claude Code -- Session End

This path handles full session capture, resume detection, rate limiting, and skill extraction triggering.

```
Claude Code session ends
        |
        v
SessionEnd hook fires
        |
        v
claude-code-bridge.py receives JSON on stdin:
  { session_id, transcript_path, cwd, hook_event_name }
        |
        v
1. Acquires lock (claude-code-bridge, 10s timeout)
2. Loads persistent state from logs/claude-code-bridge-state.json
3. Debounce check: skip if same session_id processed within last 60 seconds
4. Resume detection: if session was previously captured, check transcript growth
   - Dual threshold: must grow by >10% OR >50KB (whichever comes first)
   - If insufficient growth: skip (prevents duplicate extraction on quick re-opens)
   - If sufficient growth: set is_resumed=true, record resume offset (line number)
5. Rate limit check: max 20 captures per hour
   - If exceeded: queue the session to logs/claude-code-bridge-queue.json (not discarded)
6. Convert the Claude Code JSONL to agent format:
   - Parse user/assistant messages, extract text and tool call metadata
   - Filter system noise (e.g., "Pre-compaction checkpoint")
   - Build [USER]/[AGENT] format messages for classification
   - Generate agent-format JSONL records with session header
7. Skip if < 1 user turn or < 4 total turns
8. Classify the session window (same scoring as incremental capture)
9. If kind=extract: write converted JSONL to agents/claude-code/sessions/{session_id}.jsonl
   - New sessions: atomic write (tmp file + rename)
   - Resumed sessions: append new records to existing file
10. Update state: record session_id, score, message count, transcript size, lines processed
11. Trigger auto-skill-capture: run skill-extractor.py (120s timeout, async)
```

State is persisted across invocations in `logs/claude-code-bridge-state.json`. This enables resume detection -- when a user resumes a Claude Code session, only the new content is processed.

### Dreaming -- Consolidation and Promotion

Dreaming is a built-in memory-core feature that replaces the older manual curation cron jobs. It runs nightly (default: 4 AM) and has three phases:

**Light Phase -- Deduplication and Consolidation**
- Looks back 3 days of daily log facts
- Processes up to 50 facts per run
- Deduplicates facts with similarity threshold of 0.85
- Merges near-duplicate facts into canonical forms
- Cleans up redundant entries in daily logs

**Deep Phase -- Recall-Driven Promotion to MEMORY.md**
- Examines facts based on how often they have been recalled (via semantic search hits)
- Promotion criteria: minimum 3 recalls, from at least 2 unique queries, minimum score of 0.3
- Recency half-life: 14 days (recent facts score higher)
- Maximum age: 90 days (very old facts are not promoted)
- Processes up to 10 promotions per run
- Appends promoted facts to `MEMORY.md` under appropriate sections

**REM Phase -- Pattern Detection**
- Looks back 7 days of facts
- Detects recurring themes, connections, and patterns across facts
- Minimum pattern strength threshold: 0.4
- Generates up to 5 narrative insights per run
- Writes pattern insights to `DREAMS.md` (human-readable dreaming diary)
- Also writes detailed reports to `memory/dreaming/`

All three phases log their work to `memory/dreaming/` for auditability. The schedule, thresholds, and phase toggles are all configurable via `openclaw.json`.

### Secondary Sweep

A cron job (every 4 hours) catches sessions that the SessionEnd hook missed -- crashes, force-kills, network drops, or hook failures.

```
claude-code-sweep.py executes (cron)
        |
        v
1. Acquires lock (claude-code-sweep, 5s timeout)
2. Scans ~/.claude/projects/*/  for JSONL transcript files
3. Filters:
   - Must be modified within the last 24 hours
   - Must NOT be modified in the last 1 hour (still active)
   - Must be >= 1000 bytes
   - Must not already exist in agents/claude-code/sessions/
   - Resume check: if already captured but grew significantly, re-process
4. For each missed session: feeds it through claude-code-bridge.py via subprocess
   (simulates the SessionEnd hook input on stdin)
```

The sweep also checks for the `sessions/{session_id}/transcript.jsonl` directory-based layout used by some Claude Code versions, ensuring compatibility across CLI updates.

---

## Read Pipeline

Three read methods are available, each suited to different query types.

### Semantic Search (Gemini Hybrid)

The primary search method. Uses a hybrid approach combining vector similarity and keyword matching.

```bash
cd /home/user/agent && OPENCLAW_CONFIG_PATH=/home/user/agent/openclaw.json \
  openclaw memory search "your query" --max-results 5
```

Configuration:
- **Provider:** Gemini (gemini-embedding-001)
- **Hybrid weights:** 70% vector similarity + 30% keyword matching
- **Candidate multiplier:** 4x (retrieves 4x max_results candidates, then re-ranks)
- **MMR (Maximal Marginal Relevance):** enabled with lambda 0.7 (diversity vs relevance balance)
- **Temporal decay:** enabled with 30-day half-life (recent facts score higher)
- **Cache:** up to 50,000 entries
- **Sources:** memory files, session transcripts, skills (via `extraPaths`)
- **Sync triggers:** session start, on search, file watch (1500ms debounce)
- **Session sync thresholds:** 25KB delta or 15 new messages trigger re-index

Search covers: all `memory/*.md` files, `MEMORY.md`, daily logs, session transcripts (JSONL), skill documents, and the wiki vault.

### Grep (Exact Keyword)

For exact keyword lookups when you know the precise term:

```bash
grep -rli "keyword" /home/user/agent/memory/
grep -rli "keyword" /home/user/agent/skills/*/SKILL.md
```

Best for: port numbers, file paths, error messages, credential names, specific identifiers.

### Direct File Read

When you know exactly which file contains the information:

- `MEMORY.md` -- curated core knowledge (read first for any task)
- `memory/*.md` -- structured reference by topic
- `memory/YYYY-MM-DD.md` -- today's daily log for freshest context
- `memory/dreaming/` -- consolidation reports
- `DREAMS.md` -- narrative insights
- `wiki/` -- browsable knowledge vault
- `skills/{slug}/SKILL.md` -- specific procedure

---

## Auto-Skill Capture

The auto-skill-capture pipeline evaluates completed sessions and generates reusable skill documents for multi-step procedures worth preserving.

### Pipeline

```
Session completes (agent_end or SessionEnd hook)
        |
        v
skill-extractor.py is triggered
        |
        v
1. SESSION DISCOVERY
   - Scans all agents/*/sessions/ directories
   - Finds JSONL files not yet evaluated (compares mtime against state)
   - Pre-filter: skips files < 2000 bytes or with < 2 user turns (fast check, no full parse)
   - Sorts by recency, processes up to 20 per run

2. SESSION PARSING
   - Full parse of the JSONL transcript
   - Extracts: messages, tool calls, unique tools, files modified, SSH usage,
     API calls, error recovery patterns, multi-step verification, timestamps
   - Bridge-converted sessions (from Claude Code) lack parsed tool calls;
     the pipeline compensates with text volume and turn count heuristics

3. GATE 1: LOCAL HEURISTICS (no LLM call)
   - Priority flag check: /tmp/agent-priority-{session_id} bypasses all gates
   - Skip automation sessions (cron/heartbeat markers)
   - Minimum thresholds:
     - Tool calls: >= 5 (relaxed for Claude Code bridge sessions)
     - User turns: >= 2
     - Transcript: >= 3000 chars, <= 80000 chars
   - Complexity score (higher = more likely reusable):
     - Tool calls: up to 40 points
     - Unique tools: up to 24 points
     - Error recoveries: up to 40 points (8 per recovery)
     - Files modified: up to 20 points
     - User turns: up to 18 points
     - SSH usage: +10
     - API calls: +10
     - Verification steps: +10
     - Claude Code compensation: up to 50 bonus points from turn count + text volume
   - Threshold: score must reach 30

4. GATE 2: LLM CLASSIFICATION (gpt-5.4-mini by default)
   - Sends session summary + compressed transcript tail (last 8000 chars) to LLM
   - LLM responds: CAPTURE or SKIP
   - If CAPTURE: also returns title, category, confidence (0.0-1.0), and reason
   - Categories: infrastructure, deployment, integration, debugging, data, config, automation, development
   - Priority flag overrides a SKIP response (forced capture at confidence 0.5)

5. DEDUPLICATION
   - Scans ALL skills/ directories (both hand-crafted and auto-captured)
   - Checks for:
     - Exact slug match -> update existing
     - Title word similarity > 0.5 -> merge candidate
     - Same category + tag Jaccard overlap > 0.6 -> merge candidate
     - Slug word similarity > 0.6 -> merge candidate
   - Dedup outcome determines action: create, update, or merge_candidate

6. GENERATION / UPDATE
   - New skill: LLM generates a full SKILL.md with frontmatter, procedure, verification, pitfalls
   - Existing auto-captured skill: LLM generates an updated version preserving good content
   - Existing hand-crafted skill: LLM generates a _suggested-update.md (never overwrites)
   - Specific values (IPs, paths, names) are generalized into placeholders

7. WRITE
   - SKILL.md (or _suggested-update.md for hand-crafted)
   - _meta.json with: slug, version, capturedAt/updatedAt, source session, category,
     complexity score, confidence, recall/usage counters, review status, tags
   - Appends to skills/.auto-skill-capture/capture-log.md
   - Appends to daily log: [SKILL-CAPTURED], [SKILL-UPDATED], or [SKILL-SUGGESTED]
   - Updates skills/.auto-skill-capture/skill-index.json
```

### Safety Rules

- **Hand-crafted skills are never overwritten.** If auto-capture detects a match with a hand-crafted skill, it writes `_suggested-update.md` and `_suggested-update-meta.json` alongside the existing `SKILL.md` for human review.
- **Auto-captured skills can be updated** directly. Version is bumped (e.g., 1.0.0 -> 1.0.1) and the source session is recorded.
- **Priority flags** (`/tmp/agent-priority-{session_id}`) bypass both Gate 1 and Gate 2, forcing capture regardless of heuristics or LLM classification. The flag file is consumed (deleted) after use.

---

## Shared Memory Model

Both Claude Code and the OpenClaw agent read from and write to the same filesystem:

```
                     Shared Filesystem
    +-------------------------------------------------+
    |  MEMORY.md          <- Dreaming promotes here   |
    |  memory/*.md        <- Structured knowledge     |
    |  memory/YYYY-MM-DD  <- Daily fact logs          |
    |  memory/dreaming/   <- Consolidation reports    |
    |  skills/*/SKILL.md  <- Procedures               |
    |  wiki/              <- Browsable vault           |
    |  Semantic Index     <- Gemini hybrid search     |
    +-----+---------------------+---------------------+
          |                     |
    Claude Code CLI       OpenClaw Agent
    (Max subscription)    (any model)
          |                     |
    Writes via:           Writes via:
    - SessionEnd hook     - memory-bridge plugin
    - Stop hook           - Dreaming (nightly)
    - Sweep (cron)        - auto-skill-capture
          |                     |
    Reads via:            Reads via:
    - CLAUDE.md           - memory-core recall
    - semantic search     - semantic search
    - grep / file read    - grep / file read
```

### Source Tagging

Facts from Claude Code sessions are tagged `[src:claude-code]` so the agent (and humans) can identify their provenance. In multi-user setups, the tag includes the user ID: `[src:claude-code-employee1]`.

OpenClaw native agent facts have no source tag (they are the default source).

---

## Configuration Reference

All configuration lives in the agent's `openclaw.json`. Below are the relevant sections with complete examples.

### Dreaming Config

```json
{
  "plugins": {
    "entries": {
      "memory-core": {
        "config": {
          "dreaming": {
            "enabled": true,
            "frequency": "0 4 * * *",
            "timezone": "America/New_York",
            "verboseLogging": true,
            "storage": {
              "mode": "both",
              "separateReports": true
            },
            "phases": {
              "light": {
                "enabled": true,
                "lookbackDays": 3,
                "limit": 50,
                "dedupeSimilarity": 0.85
              },
              "deep": {
                "enabled": true,
                "limit": 10,
                "minScore": 0.3,
                "minRecallCount": 3,
                "minUniqueQueries": 2,
                "recencyHalfLifeDays": 14,
                "maxAgeDays": 90
              },
              "rem": {
                "enabled": true,
                "lookbackDays": 7,
                "limit": 5,
                "minPatternStrength": 0.4
              }
            }
          }
        }
      }
    }
  }
}
```

### Memory Wiki Config

```json
{
  "plugins": {
    "entries": {
      "memory-wiki": {
        "enabled": true,
        "config": {
          "vaultMode": "bridge",
          "vault": {
            "path": "/home/user/agent/wiki",
            "renderMode": "native"
          },
          "bridge": {
            "enabled": true,
            "readMemoryArtifacts": true,
            "indexDreamReports": true,
            "indexDailyNotes": true,
            "indexMemoryRoot": true,
            "followMemoryEvents": true
          },
          "search": {
            "backend": "shared",
            "corpus": "all"
          },
          "context": {
            "includeCompiledDigestPrompt": false
          },
          "render": {
            "preserveHumanBlocks": true,
            "createBacklinks": true,
            "createDashboards": true
          }
        }
      }
    }
  }
}
```

### Semantic Search Config

```json
{
  "agents": {
    "defaults": {
      "memorySearch": {
        "enabled": true,
        "sources": ["memory", "sessions"],
        "experimental": { "sessionMemory": true },
        "provider": "gemini",
        "model": "gemini-embedding-001",
        "sync": {
          "onSessionStart": true,
          "onSearch": true,
          "watch": true,
          "watchDebounceMs": 1500,
          "sessions": {
            "deltaBytes": 25000,
            "deltaMessages": 15,
            "postCompactionForce": true
          }
        },
        "query": {
          "maxResults": 8,
          "hybrid": {
            "enabled": true,
            "vectorWeight": 0.7,
            "textWeight": 0.3,
            "candidateMultiplier": 4,
            "mmr": { "enabled": true, "lambda": 0.7 },
            "temporalDecay": { "enabled": true, "halfLifeDays": 30 }
          }
        },
        "cache": { "enabled": true, "maxEntries": 50000 },
        "extraPaths": ["skills"]
      }
    }
  }
}
```

### Auto-Skill-Capture Config

```json
{
  "plugins": {
    "entries": {
      "auto-skill-capture": {
        "enabled": true,
        "config": {
          "captureEnabled": true,
          "recallEnabled": false,
          "outputDir": "skills",
          "extractionModel": "gpt-5.4-mini",
          "generationModel": "gpt-5.4-mini",
          "provider": "openai",
          "complexity": {
            "minToolCalls": 5,
            "minUserTurns": 2,
            "minTranscriptChars": 3000,
            "scoreThreshold": 30
          },
          "quality": {
            "maxSkills": 200,
            "pruneAfterDays": 90,
            "pruneIfUnused": true,
            "deduplicationThreshold": 0.6
          },
          "skipSessionPatterns": ["^cron:", "^heartbeat", "^hook:"]
        }
      }
    }
  }
}
```

### continuation-skip

Configured at the agent defaults level. When enabled, continuation sessions (where the agent resumes a previous conversation) skip re-injecting the full memory context, saving tokens:

```json
{
  "agents": {
    "defaults": {
      "contextInjection": "continuation-skip"
    }
  }
}
```

---

## Reliability and Monitoring

### File Locking

All write-path scripts use `lockutil.py`, a file-based locking utility built on `fcntl.flock`:

- Lock files are stored in `/tmp/agent-locks/`
- Locks are non-blocking with configurable timeout (0 = fail immediately)
- Stale lock detection: locks older than 5 minutes are forcibly removed
- Each pipeline stage has its own named lock:
  - `claude-code-bridge` (10s timeout)
  - `claude-code-turn-capture` (2s timeout -- skips silently if busy)
  - `claude-code-sweep` (5s timeout)
  - `skill-extractor` (5s timeout)

This prevents concurrent writes to memory files and avoids duplicate processing.

### Rate Limiting

The bridge enforces a rate limit of 20 captures per hour. When exceeded:
- Sessions are not discarded -- they are queued to `logs/claude-code-bridge-queue.json`
- Each queued entry records: `session_id`, `transcript_path`, `queued_at`
- The sweep job processes queued sessions on its next run

### Debounce

The bridge debounces by session ID: if the same session was processed within the last 60 seconds, the invocation is skipped. This prevents duplicate processing when hooks fire multiple times.

### Resume Detection

When a session is resumed (user comes back to an existing Claude Code session), the bridge detects this by comparing the current transcript size against the previously recorded size:

- **Dual threshold:** transcript must grow by > 10% OR > 50KB (absolute minimum)
- The 50KB absolute threshold catches meaningful follow-ups on very large sessions that would not clear a percentage threshold
- If growth is insufficient: skip (the session was probably just reopened briefly)
- If growth is sufficient: process only the new content (skip already-processed lines)

### Crash Sweep

The sweep cron job (`claude-code-sweep.py`) runs every 4 hours and catches sessions where:
- The SessionEnd hook never fired (crash, force-kill, network drop)
- The hook fired but the bridge script failed
- The session was resumed after the initial capture

It scans Claude Code's transcript directories, filters by recency and size, and feeds missed sessions through the bridge.

### 12-Point Health Check

`claude-code-update-check.sh` verifies the complete integration:

1. Claude Code CLI version
2. SessionEnd hook is configured in `settings.json`
3. Bridge script exists and parses (no syntax errors)
4. Bridge log exists and shows recent activity
5. `CLAUDE.md` contains the memory override directive
6. Local memory directory is not being used (only the redirect `MEMORY.md` exists)
7. Skill extractor exists and parses
8. auto-skill-capture plugin is enabled in `openclaw.json`
9. `settings.json` matches the backup copy
10. Stop hook for per-turn capture
11. Sweep script exists
12. Toolkit version marker

Exit codes: 0 = all pass (or warnings only), 1 = at least one failure.

Recommended schedule: run every 6 hours via OpenClaw cron, with failure notifications.

### Backup Strategy

- `settings.json` is backed up to `../backups/claude-code-settings.json` during installation
- The memory installer backs up the entire `memory/`, `skills/`, `MEMORY.md`, and `openclaw.json` to a timestamped directory before making changes
- All write operations use atomic write (tmp file + rename) where possible

---

## Two Configs That Matter

*Added in v3.2.1 — prior to this, the installer only touched the workspace config and silently ignored the state-dir config, which broke installs on agents where the gateway was reading the state-dir config at runtime.*

OpenClaw looks for its main `openclaw.json` file in three places, in order:

1. **`$OPENCLAW_CONFIG_PATH`** — the environment variable, if set
2. **`./openclaw.json`** — in the current working directory when `openclaw gateway run` was invoked
3. **`~/.openclaw/openclaw.json`** — the state-directory default (this is where `openclaw init` writes config for new installations without an explicit workspace)

On a typical FlipClaw agent, the workspace directory contains its own `openclaw.json` and a PM2 start script that looks like this:

```bash
#!/bin/bash
cd /home/user/myagent
exec openclaw gateway run
```

Because `cd` runs first, OpenClaw's resolution hits step 2 and picks `myagent/openclaw.json`. But if the start script doesn't `cd`, or the PM2 ecosystem file doesn't set `cwd`, OR the `OPENCLAW_CONFIG_PATH` is never exported, the gateway falls back to step 3 and reads the state-dir config instead.

**Why this matters for FlipClaw:**

On long-lived agents, both files often coexist. The workspace config is what humans edit; the state-dir config is what older tooling wrote and forgot about. A user might see their edits in `myagent/openclaw.json` and assume that's what the gateway is using, but the gateway is actually reading `~/.openclaw/openclaw.json` and ignoring the workspace file entirely.

**How v3.2.1+ handles this:**

The installer detects whether both files exist and writes plugin, slot, allow-list, `continuation-skip`, and `memorySearch` config to BOTH of them. This way, whichever file the gateway ends up reading, it sees the correct FlipClaw configuration.

The pre-flight check announces when it detects a state-dir config:

```
  [OK] State-dir config detected — installer will sync plugin changes to both
```

**What FlipClaw does NOT sync to the state-dir:**

Memory files, skills, and gateway auth. The state-dir contains its own auth profiles and its own history; we leave those alone. Only the plugin and memorySearch config blocks are mirrored.

**Best practice for new agents:** Always set `OPENCLAW_CONFIG_PATH` explicitly in the PM2 ecosystem file:

```javascript
module.exports = {
  apps: [{
    name: 'myagent-gateway',
    script: 'openclaw',
    args: 'gateway run',
    cwd: '/home/user/myagent',
    env: {
      OPENCLAW_CONFIG_PATH: '/home/user/myagent/openclaw.json',
      OPENCLAW_GATEWAY_PORT: '3050'
    }
  }]
};
```

This eliminates any ambiguity about which config the gateway is reading, even if the working directory logic changes in a future OpenClaw version.

---

## Upstream OpenClaw Issues

FlipClaw depends on OpenClaw and inherits its bugs. A few of those bugs are significant enough that FlipClaw ships workarounds for them. See **[docs/KNOWN-ISSUES.md](KNOWN-ISSUES.md)** for the full catalog with symptoms, root causes, and workaround details.

### Upstream patch registry (v3.2.2+)

Starting in v3.2.2, FlipClaw manages upstream workarounds via a declarative registry:

- **`scripts/upstream-patches.json`** — declarative entries with `broken_from` / `fixed_in` version ranges, workaround artifacts (scripts, cron jobs), and optional runtime probes
- **`scripts/apply-upstream-patches.sh`** — version-aware runner that reads the registry, compares against your installed OpenClaw version, and installs or removes workaround artifacts accordingly

Both `install-memory.sh` and `flipclaw-update.sh` call the runner automatically. The practical effect: upgrading OpenClaw between FlipClaw updates triggers automatic workaround reconciliation. Users on an old OpenClaw get the workarounds installed; users on a new OpenClaw get them cleanly removed, with no manual steps.

### Dreaming cron reconciler bug (Issue #1)

**Affected versions:** OpenClaw 2026.4.0 – 2026.4.9. **Fixed upstream in 2026.4.10.**

On every gateway startup in affected versions, `memory-core.reconcileShortTermDreamingCronJob` calls `resolveMemoryCorePluginConfig(api.config)` to read the current dreaming config. At startup hook time `api.config` is not yet populated, so the resolver returns an empty record, which the reconciler interprets as `dreaming.enabled: false` and removes any existing managed cron. The result: the managed dreaming cron works the first time it's created, then disappears on every subsequent restart.

**Upstream fix (2026.4.10):** a new `startupCfg` path is introduced that reads the config from the startup event payload (which carries the file-loaded config) *before* falling back to `api.config`:

```js
const startupCfg = params.reason === "startup" && params.startupEvent !== void 0
    ? resolveStartupConfigFromEvent(params.startupEvent, api.config)
    : api.config;
const config = resolveShortTermPromotionDreamingConfig({
    pluginConfig: resolveMemoryCorePluginConfig(startupCfg)
        ?? resolveMemoryCorePluginConfig(api.config)
        ?? api.pluginConfig,
    cfg: startupCfg
});
```

Verified by diffing 2026.4.9 vs 2026.4.10 source and by runtime test on a clean 2026.4.10 container.

**FlipClaw workaround (registry id: `dreaming-cron-reconciler`):**

On OpenClaw ≤ 2026.4.9 the patch registry installs:
- `scripts/ensure-dreaming-cron.sh` — a standalone heal script templated with the workspace path and gateway port
- **"Restore Dreaming Cron After Restart"** OpenClaw cron job running daily at 22:00 ET with `wakeMode: next-heartbeat`
- The cron asks the agent to exec the heal script, which detects the missing managed cron and recreates it with the correct `[managed-by=memory-core.short-term-promotion]` tag

On OpenClaw ≥ 2026.4.10 the registry removes both artifacts (the heal script and the cron job) automatically on the next `flipclaw-update.sh` or installer run. No user action required.

### Wiki bridge import returns 0 artifacts (Issue #2)

**Affected versions:** OpenClaw 2026.4.0 – 2026.4.9. **Fixed upstream in 2026.4.10.**

In affected versions, `memory-wiki`'s bridge mode calls `publicArtifacts.listArtifacts()` on the active memory plugin. This call returns an empty list even when memory-core has hundreds of indexed files — `openclaw wiki bridge import` reports `Bridge import synced 0 artifacts across 0 workspaces` regardless of how much memory exists.

**Upstream fix (2026.4.10):** verified by runtime test. A clean install of OpenClaw 2026.4.10 with 5 memory artifacts on disk (MEMORY.md + 3 topic files + 1 dreaming report) reports `Bridge: enabled (5 exported artifacts)` and `Bridge import synced 5 artifacts across 1 workspaces` on first start. The fix lives outside the direct `listArtifacts` call chain (all the functions along that chain are byte-identical between 4.9 and 4.10) — the actual fix is probably in config / agent-list resolution that happens earlier in the startup sequence, but the observable behavior is fully resolved.

**FlipClaw handling (registry id: `wiki-bridge-zero-artifacts`):**

No automatic workaround ships. On 4.9 users must use `openclaw wiki ingest <file>` to pull specific files into the wiki manually; on 4.10+ the bridge works automatically on first start. The registry's runtime probe (`openclaw wiki status | grep -qE 'Bridge: enabled \([1-9][0-9]* exported'`) can verify the fix is active after upgrade.

### Legacy `auth.profiles.*.primary` (Issue #3)

OpenClaw 2026.4.9 rejects the legacy `auth.profiles.<name>.primary` field as "Unrecognized". `openclaw doctor --fix` doesn't strip it. Any workspace config carried forward from an older OpenClaw version hits this on every CLI invocation until the key is removed.

**FlipClaw workaround:** The installer auto-sanitizes this key during the config-update step.

### `openclaw-mem0` auto-discovery (Issue #4)

Setting `plugins.entries.openclaw-mem0.enabled: false` prevents the plugin from activating but does NOT prevent OpenClaw's auto-discovery from loading it from the physical extension directory, causing "duplicate plugin id detected" warnings and slot contention with memory-core.

**FlipClaw workaround:** The installer moves conflicting `openclaw-mem0` directories aside (to `.disabled-openclaw-mem0-<timestamp>`) BEFORE making config changes, and fully removes the plugin entry instead of just setting `enabled: false`.

---

## Update and Backup Lifecycle

FlipClaw 3.2.0+ ships with a self-service updater (`flipclaw-update.sh`) that handles version upgrades, downgrades, and rollback. The same backup mechanism is used by the installers and the updater to ensure every state transition is recoverable.

### Install Params File

Location: `$WORKSPACE/.flipclaw-install.json`

Written by the installer at install time, this file is the single source of truth for future updates. It stores everything the updater needs to re-render templates with the user's original choices:

```json
{
  "flipclaw_version": "3.2.3",
  "openclaw_version": "2026.4.10",
  "installed_at": "2026-04-11",
  "workspace": "/home/user/agent",
  "agent_name": "MyAgent",
  "port": "3050",
  "claude_home": "/home/user/.claude",
  "user_id": "",
  "session_source": "claude-code",
  "shared": false,
  "with_mcp": false,
  "models": {
    "capture_model": "gpt-5.4-nano",
    "capture_provider": "openai",
    "writer_model": "gpt-5.4-mini",
    "writer_provider": "openai",
    "extraction_model": "gpt-5.4-mini",
    "generation_model": "gpt-5.4-mini",
    "skill_provider": "openai",
    "embedding_provider": "gemini",
    "embedding_model": "gemini-embedding-001"
  },
  "update_history": [
    {
      "from": "fresh-install",
      "to": "3.0.0",
      "at": "2026-04-09T14:22:10Z",
      "openclaw_version": "2026.4.9",
      "trigger": "install-memory"
    },
    {
      "from": "3.0.0",
      "to": "3.2.0",
      "at": "2026-04-10T09:15:44Z",
      "openclaw_version": "2026.4.9",
      "trigger": "updater"
    }
  ]
}
```

The `update_history` array is capped at the last 50 entries and logs every version transition — useful for debugging when users report issues months after install.

### Unified Backup Directory

Location: `$WORKSPACE/.flipclaw-backups/`

Every installer run (on upgrade only) and every updater run creates a timestamped snapshot directory under this root:

```
.flipclaw-backups/
├── v3.0.0-20260410-091500/
│   ├── backup-meta.json
│   ├── openclaw.json
│   ├── .toolkit-version
│   ├── .flipclaw-install.json
│   ├── scripts/
│   │   ├── claude-code-bridge.py
│   │   ├── claude-code-sweep.py
│   │   ├── claude-code-turn-capture.py
│   │   ├── claude-code-update-check.sh
│   │   ├── flipclaw-update.sh
│   │   ├── incremental-memory-capture.py
│   │   ├── memory-writer.py
│   │   ├── lockutil.py
│   │   ├── curate-memory-prompt.md
│   │   └── index-daily-logs-prompt.md
│   └── extensions/
│       ├── auto-skill-capture/
│       │   ├── index.ts
│       │   ├── openclaw.plugin.json
│       │   ├── package.json
│       │   └── scripts/skill-extractor.py
│       └── memory-bridge/
│           ├── index.ts
│           └── openclaw.plugin.json
├── v3.1.0-20260410-113000/
└── v3.2.0-20260410-091544/
```

Each snapshot includes:

| Contents | Why |
|----------|-----|
| All scripts | Restoration targets — these are what the updater rewrites |
| Both extensions with manifests | Same reason — updater rewrites these |
| `.toolkit-version`, `.flipclaw-install.json` | State files |
| `openclaw.json` | Safety net — updater doesn't modify it, but snapshotted anyway |
| `backup-meta.json` | Metadata: `{version, created_at, trigger, workspace, openclaw_version}` |

**What is NOT snapshotted:**
- `memory/` files — never touched by updates, far too large
- `MEMORY.md` — never touched
- `skills/` — user content, never touched
- `wiki/` and `memory/dreaming/` — generated content

A separate "data backup" (under `$(dirname $WORKSPACE)/backups/memory-pre-install-{timestamp}/`) is created by the installer on upgrade as an extra safety net for `memory/`, `skills/`, and `MEMORY.md`. This is separate from the rollback snapshots because the files are large and the updater never touches them — this is purely a belt-and-suspenders safeguard.

### Backup Retention

The 10 most recent snapshots are kept. Older snapshots are automatically pruned on every new snapshot creation. This is enforced by both the installer (during upgrade) and the updater.

### Fresh Install vs Upgrade Install

The installer detects whether this is a fresh install (`.toolkit-version` does not exist) or an upgrade (it exists):

- **Fresh install:** No rollback snapshot is created (nothing to snapshot). Only the data backup runs if any pre-existing `memory/`, `skills/`, or `MEMORY.md` files exist.
- **Upgrade install:** Full rollback snapshot is created before any file is modified. All scripts and extensions are captured.

This avoids creating spurious empty `vunknown-{timestamp}` directories on fresh installs.

### Update Flow

The updater (`flipclaw-update.sh`) follows this sequence:

```
1. Verify OpenClaw >= 2026.4.9           (fail fast; 2026.4.10+ recommended)
2. Read .flipclaw-install.json           (user params)
3. Check versions (local vs GitHub)      (semver comparison)
4. Download toolkit archive              (3 retries on transient failure)
5. Create snapshot                       (.flipclaw-backups/v{prev}-{ts}/)
6. Apply updated scripts                 (sed-render with user params)
7. Apply updated extensions              (same)
8. Handle prompt templates                (smart diff — see below)
9. Update .toolkit-version               (to downloaded version)
10. Update .flipclaw-install.json         (version + history entry)
11. Validate                              (Python/shell syntax checks)
12. If validation fails: offer rollback   (interactive y/N)
13. Reconcile upstream patch registry    (install/remove workarounds by version)
```

### Smart Prompt Template Handling

`curate-memory-prompt.md` and `index-daily-logs-prompt.md` are templates users may customize. The updater treats them carefully:

- **Template missing on disk:** Install fresh (normal path)
- **Template matches current source:** Mark as unchanged, no action
- **Template matches previous backup (unmodified by user):** Safe to update silently
- **Template differs from previous backup (user-modified):** Preserve the user's version, save the new version as `{name}.new` alongside, print a diff suggestion

This avoids the two bad outcomes: silently stomping user customizations, or never shipping improved templates.

### Post-Update Validation

After applying changes, the updater runs:

- `python3 -m py_compile` on every installed Python script
- `bash -n` on every installed shell script

If any check fails, the updater prints the failure and prompts:

```
Validation failed (1 issue(s) detected)

The update may have left your installation in a broken state.
Rollback now? (Y/n)
```

Pressing `Y` (or just Enter) immediately restores the pre-update snapshot. The user stays on the previous working version with no manual recovery needed.

### Rollback Flow

The `--rollback` flag restores the most recent snapshot:

```
1. List .flipclaw-backups/ by mtime, select most recent
2. Show version, created_at, trigger from backup-meta.json
3. Snapshot current state as "pre-rollback" (safety net for failed rollback)
4. Interactive confirmation (y/N)
5. Restore all scripts with executable bit
6. Restore extensions
7. Restore state files (.toolkit-version, .flipclaw-install.json)
```

The "pre-rollback" snapshot means even a broken rollback is recoverable. If restoring the backup leaves the system in a worse state, the user can run `--rollback` again to get back to where they were before the initial rollback attempt.

### Version Detection Semantics

Both the updater and the health check use proper semver comparison (via `sort -V`), not string equality. This correctly handles these cases:

- **Remote newer than installed:** "Update available"
- **Remote matches installed:** "Up to date"
- **Remote older than installed:** "Up to date (ahead of main)" — the updater refuses to "update" backward without explicit `--version` pin
- **Explicit `--version` downgrade:** Interactive confirmation required

### OpenClaw Version Enforcement

Both installers (`install-memory.sh`, `install-claude-code.sh`) and the updater verify OpenClaw >= `2026.4.9` before making any changes. If OpenClaw is missing or too old, the script exits immediately with a clear message and upgrade command:

```
ERROR: OpenClaw 2026.4.8 is too old.

FlipClaw requires OpenClaw 2026.4.9 or later for:
  - memory-core Dreaming (light/deep/REM phases)
  - memory-wiki plugin (bridge mode)
  - continuation-skip context injection

Upgrade OpenClaw:
  npm install -g openclaw@latest
```

**Recommended version is 2026.4.10 or later** — it ships upstream fixes for the dreaming cron reconciler and wiki bridge bugs. FlipClaw's patch registry handles both the 2026.4.9 workaround install and the 2026.4.10 workaround cleanup automatically, so either version works, but 2026.4.10+ is the clean state.

The installed OpenClaw version is recorded in `.flipclaw-install.json` as `openclaw_version` and updated on every installer and updater run. The health check verifies this on every run.

---

## Multi-User Support

Multiple people can share one agent's memory system. Each user runs their own Claude Code CLI but contributes to and reads from the same knowledge base.

### Setup

```bash
bash install.sh \
  --agent-name "MyAgent" \
  --workspace /home/user/agent \
  --port 3050 \
  --user employee1 \
  --shared
```

### How It Works

- The `--user` flag sets the session source to `claude-code-{user_id}` (e.g., `claude-code-employee1`)
- Session transcripts are stored in `agents/claude-code-employee1/sessions/`
- Extracted facts are tagged `[src:claude-code-employee1]`
- The `--shared` flag sets up a Unix group (`{agent-name}-shared`) with group write permissions on the workspace
- On Linux: uses `groupadd`/`usermod` and sets the setgid bit on key directories
- On macOS: uses `dseditgroup` for group management

Each user gets their own:
- Session directory (`agents/claude-code-{user}/sessions/`)
- Source tag on captured facts
- Bridge state tracking

All users share:
- `MEMORY.md` and all memory files
- Skills directory
- Semantic search index
- Dreaming consolidation
- Memory Wiki

---

## MCP Server

The optional MCP (Model Context Protocol) server exposes the memory system as tools for remote Claude Code instances. Install with `--with-mcp`.

### Architecture

- Runs as a stdio MCP server (Node.js, `@modelcontextprotocol/sdk`)
- Configured in Claude Code's `settings.json` under `mcpServers`
- Security-scoped: only `memory/`, `skills/`, and `MEMORY.md` are accessible
- Search results are cached in-memory with a 5-minute TTL (max 50 entries)

### Read Tools

| Tool | Description |
|------|-------------|
| `memory_search` | Semantic search via `openclaw memory search`. Hybrid 70/30 vector/keyword. Cached for 5 minutes |
| `memory_read` | Read a specific file. Path must be within `memory/`, `skills/`, or `MEMORY.md` |
| `skill_list` | List all skills with titles, slugs, and types (hand-crafted vs auto-captured) |
| `skill_read` | Read a skill's `SKILL.md` by slug |
| `memory_grep` | Exact keyword search across memory and/or skills. Returns matching file paths |

### Write Tools

| Tool | Description |
|------|-------------|
| `memory_candidate` | Submit tagged fact bullets to the daily log. Supports all standard categories |
| `session_submit` | Submit a complete session transcript (< 200KB). Feeds it through the bridge |
| `session_chunk_start` | Start a chunked upload for large sessions. Specify total chunk count |
| `session_chunk` | Send one chunk (0-indexed). Chunks are written to disk as they arrive |
| `session_chunk_finish` | Reassemble all chunks and submit to the bridge. Validates completeness |
| `session_flag` | Create a priority flag for a session (bypasses auto-skill-capture gates) |

### System Tools

| Tool | Description |
|------|-------------|
| `health` | Comprehensive health check: workspace, bridge, MEMORY.md, skills, gateway, bridge log, toolkit version, OpenClaw/Claude Code versions |

### Chunked Upload

For large session transcripts that exceed MCP message size limits:

1. Call `session_chunk_start` with `session_id` and `total_chunks`
2. Send each chunk via `session_chunk` with `chunk_index` (0-based) and `content`
3. Call `session_chunk_finish` to reassemble and submit
4. Missing chunks are detected and reported before reassembly

Chunks are stored on disk at `logs/.mcp-chunks/` and cleaned up after reassembly.

---

## File Reference

### Root

| File | Description |
|------|-------------|
| `install.sh` | Combined installer -- runs install-memory.sh then install-claude-code.sh |
| `install-memory.sh` | Memory pipeline installer: capture scripts, extensions, Dreaming, Wiki, search config. Enforces OpenClaw >= 2026.4.9 (2026.4.10+ recommended). Creates rollback snapshots on upgrade. Calls `apply-upstream-patches.sh` during install. |
| `install-claude-code.sh` | Claude Code integration installer: hooks, bridge, sweep, health check, updater, CLAUDE.md. Enforces OpenClaw >= 2026.4.9 (2026.4.10+ recommended). |
| `VERSION` | Toolkit version (semver + date) |
| `CHANGELOG.md` | Keep-a-changelog format release notes |
| `README.md` | User-facing documentation and quick start guide |
| `CONTRIBUTING.md` | Contribution guidelines |
| `LICENSE` | MIT license |
| `.gitignore` | Ignores node_modules, env files, credentials, pycache |

### scripts/

| File | Description |
|------|-------------|
| `claude-code-bridge.py` | SessionEnd hook handler -- converts Claude Code transcripts, manages resume detection, rate limiting, triggers skill extraction |
| `claude-code-turn-capture.py` | Stop hook handler -- per-turn fact extraction during active Claude Code sessions |
| `claude-code-sweep.py` | Cron job -- catches sessions missed by the SessionEnd hook (crashes, force-kills) |
| `claude-code-update-check.sh` | 12-point health check script including FlipClaw version and OpenClaw minimum version |
| `flipclaw-update.sh` | Self-service updater with snapshot backups, post-update validation, rollback, version pinning, and automatic patch registry reconciliation |
| `claude-code-bridge-remote.sh` | Helper script for remote bridge invocation |
| `incremental-memory-capture.py` | Core fact extraction engine -- reads session windows, classifies, calls LLM, routes facts to memory files |
| `memory-writer.py` | Legacy manual backfill tool -- writes structured memory from daily logs (not part of active pipeline) |
| `skill-extractor.py` | Auto-skill-capture pipeline -- Gate 1 heuristics, Gate 2 LLM classification, dedup, generation, write |
| `lockutil.py` | File-based locking utility using fcntl.flock -- prevents concurrent write corruption |
| `upstream-patches.json` | Declarative registry of upstream OpenClaw bug workarounds (v3.2.2+) -- single source of truth for version-conditional patch management |
| `apply-upstream-patches.sh` | Version-aware patch runner (v3.2.2+) -- reads `upstream-patches.json`, compares against installed OpenClaw version, installs or removes workaround artifacts accordingly. Called automatically by `install-memory.sh` and `flipclaw-update.sh` |
| `ensure-dreaming-cron.sh` | Dreaming cron heal script (installed conditionally by the patch registry only on OpenClaw ≤ 2026.4.9; removed automatically when upgrading to 2026.4.10+) |
| `curate-memory-prompt.md` | LLM prompt template for manual memory curation (legacy reference) |
| `index-daily-logs-prompt.md` | LLM prompt template for daily log indexing (legacy reference) |

### State files (written to `$WORKSPACE/` at install/update time)

| File | Description |
|------|-------------|
| `.toolkit-version` | Installed FlipClaw version marker (one line, e.g. `3.2.0`) |
| `.flipclaw-install.json` | Install params (agent, port, workspace, models, OpenClaw version) and update history |
| `.flipclaw-backups/` | Rollback snapshot directory — 10 most recent kept, auto-pruned |

### extensions/

| File | Description |
|------|-------------|
| `memory-bridge/index.ts` | OpenClaw plugin -- fires incremental-memory-capture.py on every `agent_end` event |
| `memory-bridge/openclaw.plugin.json` | Plugin manifest for memory-bridge |
| `auto-skill-capture/index.ts` | OpenClaw plugin -- fires skill-extractor.py on every `session_end` event |
| `auto-skill-capture/openclaw.plugin.json` | Plugin manifest and config schema for auto-skill-capture |
| `auto-skill-capture/package.json` | Node.js package metadata for the extension |
| `auto-skill-capture/scripts/` | Installed copy of skill-extractor.py (parameterized for the workspace) |
| `auto-skill-capture/config/` | Optional defaults.json for skill capture configuration overrides |

### mcp-server/

| File | Description |
|------|-------------|
| `server.mjs` | MCP server implementation -- exposes memory read/write/search tools over stdio |
| `package.json` | Node.js package with `@modelcontextprotocol/sdk` dependency |

### templates/

| File | Description |
|------|-------------|
| `CLAUDE.md.template` | Full CLAUDE.md template for new installations (parameterized with agent name, workspace, port) |
| `CLAUDE-append.md.template` | Append-only template for adding memory integration to an existing CLAUDE.md |

### Installed workspace structure (post-install)

```
/home/user/agent/
  MEMORY.md                          # Curated core knowledge (Layer 5)
  DREAMS.md                          # Human-readable dreaming diary (Layer 6)
  .toolkit-version                   # Installed toolkit version
  memory/
    YYYY-MM-DD.md                    # Daily fact logs (Layer 3)
    infrastructure.md                # Structured memory (Layer 4)
    people.md                        #   "
    decisions.md                     #   "
    business-context.md              #   "
    lessons-learned.md               #   "
    session-cache/                   # Per-session summaries (Layer 2)
      {session_id}.md
    dreaming/                        # Dreaming phase reports (Layer 6)
    incremental-capture-state.json   # Capture pipeline state
  wiki/                              # Memory Wiki vault (Layer 7)
  skills/
    {slug}/
      SKILL.md                       # Skill procedure (Layer 8)
      _meta.json                     # Skill metadata
      _suggested-update.md           # (only for hand-crafted skills with auto-updates)
    .auto-skill-capture/
      state.json                     # Skill extractor state
      skill-index.json               # Skill index for dedup
      capture-log.md                 # Activity log
  agents/
    main/sessions/*.jsonl            # OpenClaw agent session transcripts (Layer 1)
    claude-code/sessions/*.jsonl     # Claude Code session transcripts (Layer 1)
  extensions/
    memory-bridge/                   # Per-turn capture plugin
    auto-skill-capture/              # Skill extraction plugin
      scripts/skill-extractor.py
      config/defaults.json
  scripts/
    claude-code-bridge.py            # SessionEnd hook handler
    claude-code-turn-capture.py      # Stop hook handler
    claude-code-sweep.py             # Crash sweep
    claude-code-update-check.sh      # Health check
    incremental-memory-capture.py    # Core extraction engine
    memory-writer.py                 # Legacy backfill (inactive)
    lockutil.py                      # File locking utility
  logs/
    claude-code-bridge.jsonl         # Bridge event log
    claude-code-bridge-state.json    # Bridge persistent state
    claude-code-bridge-queue.json    # Rate-limited session queue
  mcp-server/                        # (optional, if --with-mcp)
    server.mjs
    package.json
    node_modules/
  openclaw.json                      # Agent gateway configuration
```
