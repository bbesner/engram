# FlipClaw

**Persistent memory, auto-generated skills, and scheduled automation for Claude Code CLI — powered by OpenClaw.**

> Your Claude Max subscription gives you Claude Code CLI. FlipClaw gives it a brain that persists across sessions, learns from every conversation, and runs tasks while you sleep.

<p align="center">
  <a href="https://raw.githubusercontent.com/bbesner/flipclaw/main/docs/hero.svg">
    <img src="docs/hero.svg" alt="FlipClaw — Before and After" width="900">
  </a>
</p>

> *Click the diagram to view full size*

---

## The Problem

If you're running Claude through a third-party harness like OpenClaw, Anthropic's recent OAuth changes mean those conversations now cost API rates or extra usage billing. Your flat-rate Max subscription no longer covers it.

But **Claude Code CLI still works on Max.** It's not just the best coding AI — it's the best agentic AI interface available, period. VS Code, Claude Code Desktop, or the terminal. Included in your subscription, no API metering.

The catch? Claude Code has no memory. Every session starts from zero — no recall of your infrastructure, no awareness of decisions you've already made, and no automations.

## The Solution: Turn the Tables

Instead of putting Claude Code inside OpenClaw as its model, FlipClaw flips it — **Claude Code is now the primary interface, and OpenClaw wraps around it** to provide the persistent infrastructure.

FlipClaw flips the architecture. **Claude Code CLI is now the primary interface.** OpenClaw wraps around it to provide persistent memory, scheduled automation, heartbeats, and 24/7 capabilities — but you're working fully inside Claude Code. VS Code, Claude Code Desktop, CLI terminal — wherever you prefer.

**This is Claude Code first.** OpenClaw isn't the harness running Claude anymore. It's the infrastructure layer that gives Claude Code superpowers it doesn't have natively. Your conversations, your coding, your daily work — all happening in Claude Code on your Max subscription. OpenClaw provides the memory brain, the cron jobs, the skill library, and the remote access layer around it.

What you get:

- **Persistent memory** that survives across sessions — shared between Claude Code and your OpenClaw agent. Same brain, doesn't matter which interface you use.
- **Auto-skill capture** — when you do something complex, the system automatically generates a reusable skill document so next time Claude already knows the procedure
- **Dreaming** — nightly consolidation that deduplicates facts, promotes important knowledge, and detects patterns across your sessions
- **Memory Wiki** — a browsable, backlinked knowledge vault
- **Cron jobs, heartbeats, and scheduled tasks** via OpenClaw, accessible from Claude Code
- **Remote access via Telegram** — multi-session Claude Code from your phone, not limited to Anthropic's single QR-code session (pair with [claude-telegram-relay](https://github.com/bbesner/claude-telegram-relay))
- **Flexible deployment** — Claude Code and OpenClaw on the same machine (local, server, or VPS) for the tightest integration, or split across two machines with the MCP server connection. Same shared memory either way.
- **Self-service updates** — one-command updater with full snapshot backups, dry-run preview, post-update validation, and automatic rollback on failure. Stay current without re-running the installer.

All on your existing Claude Max subscription. No API charges.

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
- **OpenClaw 2026.4.9 or later** (required for memory-core Dreaming, memory-wiki, and continuation-skip). Install with `npm install -g openclaw`. The installer verifies this before making any changes.
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- Python 3.10+, Node.js 18+
- An OpenAI API key (for fact extraction via GPT-5.4 Nano — costs pennies)

### Install

```bash
git clone https://github.com/bbesner/flipclaw.git
cd flipclaw

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
| **claude-code-update-check.sh** | 11-point health check including OpenClaw and FlipClaw version checks |
| **flipclaw-update.sh** | Self-service updater with snapshot backups and rollback support |
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

## Updating

FlipClaw ships a self-service updater. Once you've installed v3.2.0+, staying current is one command:

```bash
# Check if an update is available
bash ~/myagent/scripts/flipclaw-update.sh --check

# Preview what would change
bash ~/myagent/scripts/flipclaw-update.sh --dry-run

# Apply the update
bash ~/myagent/scripts/flipclaw-update.sh

# List available backups
bash ~/myagent/scripts/flipclaw-update.sh --list-backups

# Roll back to the previous version
bash ~/myagent/scripts/flipclaw-update.sh --rollback

# Pin to a specific version (downgrade or reinstall)
bash ~/myagent/scripts/flipclaw-update.sh --version 3.3.0
```

**What the updater does:**
1. Verifies OpenClaw is at the minimum required version
2. Reads your saved install params (`.flipclaw-install.json`) — no flags to remember
3. Downloads the latest toolkit from GitHub (with automatic retry on transient failures)
4. Creates a full snapshot under `.flipclaw-backups/v{old-version}-{timestamp}/` including scripts, extensions, state files, and `openclaw.json`
5. Re-applies each script template with your original values (workspace path, agent name, models, etc.)
6. Updates `.toolkit-version` and `.flipclaw-install.json` (including update history)
7. **Validates the update** — runs Python and shell syntax checks on all installed scripts. If anything broke, prompts to automatically roll back.
8. Clears the update-available flag

**Automatic rollback on failure:** If post-update validation detects broken scripts (syntax errors, missing files), the updater offers to immediately restore the backup it just created. No manual recovery needed.

**Update history** is tracked in `.flipclaw-install.json` — every update logs `{from, to, at, openclaw_version, trigger}`. Useful for debugging if you need to figure out what changed when.

**Backup retention** — The updater keeps your 10 most recent backups and automatically prunes older ones. Each backup includes everything needed to restore: scripts, extensions, state files, and a metadata file recording when/why it was made.

**What the updater never touches:**
- `memory/` files — your knowledge base is never modified
- `MEMORY.md` — preserved
- `openclaw.json` — not touched (but snapshotted into backups for safety)
- `CLAUDE.md` — not touched
- Prompt templates (`curate-memory-prompt.md`, `index-daily-logs-prompt.md`) — if you've modified them, the new version is saved as `.new` alongside the original so you can review and merge manually

**Version notifications** are surfaced automatically. The health check script (`claude-code-update-check.sh`) runs every 6 hours via cron and checks GitHub for a newer VERSION file. When one is found, it prints a warning with the update command and writes `/tmp/flipclaw-update-available` as a flag.

**Upgrading from v3.0.0 / v3.1.0** (before the updater existed): re-run the installer with your original flags and `--skip-openclaw`, then the updater will be installed for future use:

```bash
git clone https://github.com/bbesner/flipclaw.git flipclaw-new
bash flipclaw-new/install.sh \
  --agent-name "YourAgent" \
  --workspace /path/to/your/agent \
  --port YOUR_PORT \
  --skip-openclaw
```

See [CHANGELOG.md](CHANGELOG.md) for what changes between versions.

---

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
