# Engram

**Persistent memory, auto-generated skills, and scheduled automation for Claude Code CLI — powered by OpenClaw.**

> Your Claude Max subscription gives you Claude Code CLI. Engram gives it a brain that persists across sessions, learns from every conversation, and runs tasks while you sleep.

<p align="center">
  <a href="https://raw.githubusercontent.com/bbesner/engram/main/docs/hero.svg">
    <img src="docs/hero.svg" alt="Engram — Before and After" width="900">
  </a>
</p>

> *Click the diagram to view full size*

---

## The Problem

Claude Code CLI is the most capable AI coding tool available. But every session starts from zero — no memory of yesterday's work, no recall of your infrastructure, no awareness of decisions you've already made.

Meanwhile, Anthropic's recent OAuth changes mean running Claude through third-party harnesses (like OpenClaw) now incurs API rates or extra usage billing. Claude Code CLI still works on your flat-rate Max subscription — but it lacks the persistent infrastructure that makes an AI assistant truly useful.

## The Solution

This toolkit bridges Claude Code CLI with OpenClaw's memory and automation infrastructure. The result:

- **Persistent memory** shared between Claude Code and your OpenClaw agent — same knowledge base, regardless of which interface you use
- **Auto-generated skills** — multi-step procedures are captured automatically and reused across sessions
- **Built-in Dreaming** — your AI consolidates and promotes important facts while you're away
- **Memory Wiki** — organized, browsable knowledge vault with backlinks
- **Cron jobs, heartbeats, and scheduled tasks** via OpenClaw, accessible from Claude Code
- **Remote access via Telegram** with multi-session support (pair with [claude-telegram-relay](https://github.com/bbesner/claude-telegram-relay))
- **Works from anywhere** — server, laptop, phone — all hitting the same memory

All on your existing Claude Max subscription.

## How It Works

```
Claude Code CLI                    OpenClaw Agent
(Max subscription)                 (any model)
      |                                |
      v                                v
 SessionEnd Hook                 agent_end event
      |                                |
      v                                v
 claude-code-bridge.py           memory-bridge plugin
      |                                |
      +----> Shared Memory <-----------+
             |
             v
      memory/daily-logs
      memory/structured-files
      skills/auto-captured
             |
             v
      Dreaming (nightly)
      ┌─────────────────┐
      │ Dedup & merge    │
      │ Promote → MEMORY │
      │ Patterns → DREAMS│
      └─────────────────┘
             |
             v
      Memory Wiki (browsable)
      Semantic Search (Gemini)
```

**Three-layer capture ensures nothing is lost:**
1. **Every turn** — Facts extracted continuously during your session
2. **Session end** — Full transcript saved, skills evaluated
3. **Crash sweep** — Catches sessions that ended abnormally

## Quick Start

### Prerequisites
- [OpenClaw](https://github.com/openclaw) installed and running
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- Python 3.10+, Node.js 18+
- An OpenAI API key (for fact extraction via GPT-5.4 Nano — costs pennies)

### Install

```bash
git clone https://github.com/bbesner/engram.git
cd engram

# Full install (memory system + Claude Code hooks)
bash install.sh \
  --agent-name "MyAgent" \
  --workspace /home/user/agent \
  --port 3050

# Restart your OpenClaw gateway
pm2 restart my-agent-gateway
```

### Verify

```bash
bash /home/user/agent/scripts/claude-code-update-check.sh
```

Then start a Claude Code session, do some work, end it, and check:
```bash
# See captured session
ls /home/user/agent/agents/claude-code/sessions/

# See extracted facts in today's log
cat /home/user/agent/memory/$(date +%Y-%m-%d).md

# Search memory
cd /home/user/agent && openclaw memory search "what I worked on today"
```

## What Gets Installed

### Memory System (`install-memory.sh`)

| Component | Purpose |
|-----------|---------|
| **incremental-memory-capture.py** | Per-turn fact extraction → daily logs (GPT-5.4 Nano) |
| **memory-bridge extension** | OpenClaw plugin that triggers capture on every agent turn |
| **auto-skill-capture extension** | Auto-generates reusable skill documents from sessions |
| **memory-core Dreaming** | Built-in consolidation, dedup, and MEMORY.md promotion |
| **Memory Wiki** | Bridge-mode organized knowledge vault |
| **Semantic search** | Gemini hybrid search (70% vector + 30% keyword) |
| **continuation-skip** | Token savings on continuation sessions |

### Claude Code Integration (`install-claude-code.sh`)

| Component | Purpose |
|-----------|---------|
| **claude-code-bridge.py** | Session-end capture — saves transcript, triggers skill extraction |
| **claude-code-turn-capture.py** | Per-turn capture via Stop hook — extracts facts after every response |
| **claude-code-sweep.py** | Catches sessions hooks missed (crashes, force-kills) |
| **claude-code-update-check.sh** | 12-point health check with alerting |
| **lockutil.py** | Prevents concurrent write corruption |
| **CLAUDE.md** | Instructions that make Claude Code use the shared memory |
| **MCP server** (optional) | Remote memory access: search, read, write tools |

## Three Installers

| Installer | What it does | When to use |
|-----------|-------------|-------------|
| `install-memory.sh` | Memory pipeline + Dreaming + Wiki + search | Fresh agent setup |
| `install-claude-code.sh` | Claude Code hooks + bridge + sweep + health | Agent already has memory |
| `install.sh` | Both in sequence | Full setup from scratch |

## Architecture Deep Dive

### Memory Layers

1. **MEMORY.md** — Curated core knowledge, always loaded into context
2. **memory/*.md** — Structured reference files by topic (infrastructure, people, decisions, etc.)
3. **memory/YYYY-MM-DD.md** — Daily logs with captured facts
4. **memory/dreaming/** — Consolidation reports from Dreaming phases
5. **DREAMS.md** — Human-readable dreaming diary and pattern insights
6. **wiki/** — Organized knowledge vault (Memory Wiki, bridge mode)
7. **skills/*/SKILL.md** — Auto-captured and hand-crafted procedures
8. **sessions/*.jsonl** — Full searchable session archive

### Dreaming (Consolidation)

Memory-core Dreaming runs nightly and replaces manual curation:

- **Light phase** — Deduplicates and consolidates recent daily facts
- **Deep phase** — Promotes well-recalled facts to MEMORY.md based on recall frequency
- **REM phase** — Detects patterns across recent facts, generates narrative insights

### Auto-Skill Capture

The system watches completed sessions and automatically generates reusable skill documents:

1. **Gate 1 (heuristics)** — Filters trivial sessions (minimum tool calls, user turns, complexity)
2. **Gate 2 (LLM classification)** — Evaluates whether the session contains a reusable procedure
3. **Deduplication** — Checks against ALL existing skills to avoid duplicates
4. **Generation** — Creates SKILL.md with steps, prerequisites, verification, pitfalls
5. **Safety** — Hand-crafted skills are never overwritten; updates go to `_suggested-update.md`

### Shared Memory Model

```
┌─────────────────────────────────────────────┐
│              Shared Memory                   │
│                                             │
│  MEMORY.md ← Dreaming promotes here         │
│  memory/*.md ← Structured knowledge         │
│  skills/*/SKILL.md ← Procedures             │
│  Semantic Index ← Gemini hybrid search      │
│                                             │
├─────────────┬───────────────────────────────┤
│ Claude Code │     OpenClaw Agent            │
│ CLI writes  │     writes & reads            │
│ & reads     │     cron jobs run here        │
│             │     heartbeats run here       │
│             │     Dreaming runs here        │
└─────────────┴───────────────────────────────┘
```

Both interfaces contribute to and retrieve from the same memory. Facts from Claude Code sessions are tagged `[src:claude-code]` for provenance.

## Multi-User Support

Multiple people can share one agent's memory:

```bash
bash install.sh \
  --agent-name "TeamAgent" \
  --workspace /home/user/agent \
  --port 3050 \
  --user employee1 \
  --shared

# Each user's sessions are tagged separately:
# [src:claude-code-employee1], [src:claude-code-employee2], etc.
```

## Remote Access (MCP Server)

For Claude Code on a different machine:

```bash
bash install.sh --agent-name "MyAgent" --workspace /path --port 3050 --with-mcp
```

Available MCP tools: `memory_search`, `memory_read`, `skill_list`, `skill_read`, `memory_grep`, `memory_candidate`, `session_submit`, `session_flag`

## Companion: Telegram Relay

Pair with [claude-telegram-relay](https://github.com/bbesner/claude-telegram-relay) for remote multi-session Claude Code access from your phone. Send messages from Telegram, get Claude Code responses — with full memory integration.

## Configuration

### Model Defaults (configurable via installer flags)

| Role | Default Model | Provider |
|------|--------------|----------|
| Fact extraction | gpt-5.4-nano | OpenAI |
| Skill classification | gpt-5.4-mini | OpenAI |
| Skill generation | gpt-5.4-mini | OpenAI |
| Embeddings | gemini-embedding-001 | Google |

### Dreaming Schedule

Default: daily at 4 AM (configurable in `openclaw.json`):
```json
{
  "dreaming": {
    "enabled": true,
    "frequency": "0 4 * * *",
    "timezone": "America/New_York"
  }
}
```

## Supported Platforms

| Platform | Status |
|----------|--------|
| Linux (Ubuntu/Debian) | Fully supported |
| macOS | Fully supported |
| Windows WSL | Supported |

## Roadmap

- [ ] Codex CLI integration (architecture supports it — contributions welcome)
- [ ] Aider integration
- [ ] Web-based memory browser
- [ ] Improved skill deduplication
- [ ] Memory export/import between agents

## License

[MIT](LICENSE) — use it however you want.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

*Built by [Brad Besner](https://github.com/bbesner) at [Ultraweb Labs](https://ultraweblabs.com). If this toolkit saves you time, give it a star and tell a friend.*
