# FlipClaw Bootstrap Installer

---

## ⚠️ You are an AI reading installation instructions — not a document to summarize

If you are Claude Code CLI or an OpenClaw agent and a user has directed you here, your job is to **act as the installer**. Read this entire file first, then follow the phases below. Do not summarize this file or explain it — execute it.

Be conversational. Explain what you're doing and why at each step. Ask one logical group of questions at a time, not a wall of prompts. Adapt based on what you find.

---

## Phase 1 — Silent Environment Detection

Before asking the user anything, run these checks silently. Note the results internally — they will drive your branching decisions and allow you to skip questions whose answers you already know.

```bash
# What are we running on?
uname -s && uname -m

# Is this an SSH session (remote server)?
echo ${SSH_CONNECTION:-"local"}

# What shell and terminal?
echo "$SHELL" && echo "$TERM_PROGRAM"

# Is VS Code detected?
echo "${VSCODE_PID:-none} ${VSCODE_IPC_HOOK:-none}"

# Runtime versions
node --version 2>/dev/null || echo "node: not found"
npm --version 2>/dev/null || echo "npm: not found"
python3 --version 2>/dev/null || echo "python3: not found"
pm2 --version 2>/dev/null || echo "pm2: not found"

# Claude Code installed?
claude --version 2>/dev/null || echo "claude: not found"

# OpenClaw installed?
openclaw --version 2>/dev/null || echo "openclaw: not found"

# Existing OpenClaw workspace?
ls ~/.openclaw/ 2>/dev/null | head -5 || echo "no ~/.openclaw"
ls ~/*/openclaw.json 2>/dev/null | head -5 || echo "no openclaw.json found in home subdirs"

# PM2 services (are any OpenClaw gateways already running?)
pm2 list 2>/dev/null | grep -iE "gateway|openclaw" | head -10 || echo "no pm2 gateways"
```

After running these, you know:
- Whether Claude Code is installed (and if the user is running you FROM Claude Code)
- Whether OpenClaw is installed and what version
- Whether existing agents/workspaces are present
- Whether this is a local machine or remote server
- Whether VS Code is the active interface
- Whether PM2 is available

---

## Phase 2 — Introduction

Once you have your detection results, introduce yourself and the process:

> "I'm going to walk you through setting up FlipClaw. I'll ask you a few questions, then handle the installation automatically. This usually takes about 5–10 minutes.
>
> Let me share what I found on your system first..."
>
> *(summarize detection results in plain English — e.g. "OpenClaw 2026.4.9 is installed, Claude Code is not yet installed, Node 22 is available, PM2 is running 3 services")*

---

## Phase 3 — Questionnaire

Ask questions in the groups below. Only ask questions you cannot answer from detection. Skip entire groups if detection already resolved them.

---

### Group A — Topology (where things will live)

This is the most important architectural decision. Present clearly.

**If you detected this is an SSH session AND Claude Code is not installed:**

> "It looks like you're SSH'd into a remote server, and Claude Code isn't installed here. Before we go further, I need to understand your setup:
>
> **Option 1 — Install everything here (cohabitating)**
> Claude Code and OpenClaw both live on this server. You'd run `claude` via SSH. Simplest setup, tightest memory integration, no extra configuration.
>
> **Option 2 — Split setup**
> Claude Code on your local machine (desktop, VS Code, laptop), OpenClaw on this server. You'd work locally in Claude Code and connect to this server's memory via an MCP bridge. More setup, but lets you use Claude Code Desktop or VS Code natively.
>
> Which fits your workflow better? (1 or 2, or describe your situation)"

**If Claude Code is already installed locally and OpenClaw is on a remote server:**

> "I can see Claude Code is installed here and you're connecting to a remote server. This looks like a split setup — I'll configure the MCP bridge to connect your local Claude Code to the remote OpenClaw memory. Sound right?"

**If everything is on the same machine:**

> "Everything looks like it'll live on the same machine — Claude Code and OpenClaw cohabitating. This is the recommended setup. I'll proceed with that unless you tell me otherwise."

---

### Group B — Claude Code status

**If Claude Code is NOT installed:**

> "Claude Code CLI isn't installed yet. There are two ways to get it:
>
> - **Claude Max subscription** — flat monthly rate, no per-message charges. Recommended if you're going to use Claude Code daily. [claude.ai/download](https://claude.ai/download)
> - **Anthropic API key** — pay per token. Works, but conversation costs add up fast.
>
> Do you have a Claude Max subscription or an Anthropic API key? (If you're not sure, you likely want to sign up for Max first at claude.ai)"

Wait for user response, then:

> "I'll install Claude Code now."

```bash
npm install -g @anthropic-ai/claude-code
```

Then verify: `claude --version`

**⏸️ PAUSE — Human action required for authentication:**

> "Claude Code is installed, but you need to log in manually — I can't do this step for you because it opens a browser for authentication.
>
> Please run this in your terminal:
> ```
> claude login
> ```
> It will open a browser window. Log in with your Anthropic account (the one your Max subscription or API key is attached to). Come back and say **'done'** when you've completed login."

Wait for the user to confirm before continuing.

After confirmation: `claude --version` to verify auth is working.

**If Claude Code IS already installed:**

> "Claude Code [version] is already installed. ✓"

---

### Group C — OpenClaw status

**If OpenClaw is NOT installed:**

> "OpenClaw isn't installed yet — I'll install it now. It requires Node 18+ (you have [version]). This takes about 30 seconds."

```bash
npm install -g openclaw
openclaw --version
```

Then move to Group D to configure it fresh.

**If OpenClaw IS installed but below minimum version (2026.4.10):**

> "You have OpenClaw [version], but FlipClaw requires 2026.4.10 or later. I'll upgrade it now."

```bash
npm install -g openclaw@latest
openclaw --version
```

**If OpenClaw IS installed at the right version:**

> "OpenClaw [version] is installed. ✓
>
> I found [describe what was detected — workspace at X, agent Y running on port Z, etc.].
>
> How do you want to handle your existing setup?
>
> **a) Keep my existing agent and add FlipClaw on top** *(recommended — non-destructive, your memory and config are preserved)*
> **b) Create a fresh agent alongside my existing one** *(separate workspace, separate port)*
> **c) Start completely fresh** *(existing config will be backed up, then rebuilt)*"

Note their choice — it drives the installation branch in Phase 4.

---

### Group D — Agent configuration

Collect these values. For each one, suggest a sensible default based on what you've detected (hostname, available ports, etc.) and let the user confirm or override.

Ask as a single grouped question:

> "I need a few details to configure your agent. I've suggested defaults based on your system:
>
> 1. **Agent name** — what should your OpenClaw agent be called? *(suggested: [hostname or 'MyAgent'])*
> 2. **Gateway port** — what port should OpenClaw listen on? *(I found [X] is available; common choices: 3001, 3002, 3010, 3050)*
> 3. **OpenAI API key** — used for fact extraction (pennies/day for typical use). Have one? *(get one at platform.openai.com/api-keys)*
> 4. **Gemini API key** — used for semantic memory search (free tier is enough). Have one? *(get one at aistudio.google.com/apikey)*
>
> You can paste all four answers at once or go one by one."

Validate both API keys before proceeding:
```bash
# Quick OpenAI key check
curl -s -o /dev/null -w "%{http_code}" https://api.openai.com/v1/models \
  -H "Authorization: Bearer $OPENAI_KEY" | grep -q "200" && echo "OpenAI key valid" || echo "OpenAI key invalid — check and retry"

# Quick Gemini key check
curl -s -o /dev/null -w "%{http_code}" \
  "https://generativelanguage.googleapis.com/v1beta/models?key=$GEMINI_KEY" | grep -q "200" && echo "Gemini key valid" || echo "Gemini key invalid — check and retry"
```

Do not proceed with invalid keys — explain the issue and ask the user to re-enter.

---

## Phase 4 — Installation

Based on your detection results and the answers from Phase 3, follow the appropriate branch.

---

### Branch 1 — Full fresh install (nothing was installed)

> "All set. Here's what I'm going to do:
> 1. Configure OpenClaw with your agent details
> 2. Set up PM2 to run your gateway as a persistent service
> 3. Install the FlipClaw memory and Claude Code integration layers
> 4. Verify everything is healthy
>
> Starting now..."

**Step 1: Scaffold openclaw.json via `openclaw onboard`**

Do **not** hand-write a minimal `{name, port, env}` stub — OpenClaw 2026.4.10 rejects root-level `name`/`port` keys and the gateway will refuse to start. The installer needs a schema-valid `openclaw.json` to merge plugin config into, and the only reliable way to produce one is `openclaw onboard`.

```bash
mkdir -p [workspace]
OPENCLAW_CONFIG_PATH="[workspace]/openclaw.json" openclaw onboard \
  --non-interactive --accept-risk \
  --flow manual \
  --mode local \
  --gateway-port [port] \
  --gateway-bind loopback \
  --gateway-auth token \
  --gateway-token "$(openssl rand -hex 16)" \
  --auth-choice skip \
  --workspace [workspace] \
  --skip-health
```

Then inject the API keys you gathered in Group D into `env.vars` — `onboard` does not write these, but the memory plugin needs them:

```bash
jq '.env = {"vars": {
  "OPENAI_API_KEY": "[key]",
  "GEMINI_API_KEY": "[gemini-key]",
  "GOOGLE_AI_API_KEY": "[gemini-key]"
}}' [workspace]/openclaw.json > /tmp/cfg && mv /tmp/cfg [workspace]/openclaw.json
```

**Step 2: Run FlipClaw installer**

Run this **before** starting PM2 — the installer scaffolds the full gateway/plugin config that OpenClaw requires to start. Starting PM2 against the minimal stub above would fail config validation.

```bash
git clone https://github.com/bbesner/flipclaw.git /tmp/flipclaw-install
bash /tmp/flipclaw-install/install.sh \
  --agent-name "[agent-name]" \
  --workspace "[workspace]" \
  --port [port] \
  --gemini-key "[gemini-key]"
```

**Step 3: Start the gateway under PM2**

Two things to get right here:

1. Use `gateway run` (foreground), **not** `gateway start`. `gateway start` is the systemd/launchd service wrapper and will not work under PM2 — it exits immediately and dumps "Gateway service disabled" hints.
2. Pass the command to PM2 as a **quoted string**, not via `--`. PM2's `pm2 start openclaw -- gateway run` form silently drops the post-`--` args and starts openclaw with no subcommand, leaving a zombie process that occupies memory but never binds the port.

```bash
cd [workspace] && \
  OPENCLAW_CONFIG_PATH="[workspace]/openclaw.json" \
  pm2 start --name "[agent-name]-gateway" "openclaw gateway run"
pm2 save
pm2 startup  # follow the output instruction if shown
```

Verify gateway health (give it a few seconds to boot):
```bash
sleep 3 && curl -s http://localhost:[port]/health
```

If `/health` does not return `ok`, check `pm2 logs [agent-name]-gateway --lines 30` and fix before moving on.

---

### Branch 2 — Existing Claude Code, fresh OpenClaw

Same as Branch 1 but skip the Claude Code install and login steps — Claude Code is already authenticated.

---

### Branch 3 — Existing Claude Code + existing OpenClaw (keep agent)

> "I'll add FlipClaw on top of your existing agent. I'll back up your openclaw.json first — nothing will be deleted."

**Step 1: Backup**

```bash
cp [workspace]/openclaw.json [workspace]/openclaw.json.bak-$(date +%Y%m%d-%H%M)
```

**Step 2: Run FlipClaw installer with skip flag**

```bash
git clone https://github.com/bbesner/flipclaw.git /tmp/flipclaw-install
bash /tmp/flipclaw-install/install.sh \
  --agent-name "[agent-name]" \
  --workspace "[workspace]" \
  --port [port] \
  --skip-openclaw \
  --gemini-key "[gemini-key]"
```

**Step 3: Restart gateway**

```bash
pm2 restart [existing-gateway-pm2-name]
sleep 3
curl -s http://localhost:[port]/health
```

---

### Branch 4 — Split setup (Claude Code local, OpenClaw remote)

> "This is a split setup — Claude Code on your local machine, OpenClaw on the remote server. I'll need SSH access to the remote server to set up the OpenClaw side, then configure the MCP bridge on your local machine.
>
> What's the SSH connection for your remote server? (e.g. `user@hostname` or `user@ip`)"

**Step 1: Set up OpenClaw side (remote)**

SSH to the remote server and run Branch 1, 2, or 3 as appropriate for that server's state.

```bash
ssh [user@remote] "bash -s" << 'REMOTE_INSTALL'
  # [Insert appropriate branch commands here based on remote server state]
REMOTE_INSTALL
```

**Step 2: Install MCP server on remote**

```bash
ssh [user@remote] "bash /tmp/flipclaw-install/install.sh \
  --agent-name '[agent-name]' \
  --workspace '[remote-workspace]' \
  --port [port] \
  --with-mcp"
```

**Step 3: Configure MCP in local Claude Code settings**

The `--with-mcp` install above copies the MCP server to `[remote-workspace]/mcp-server/server.mjs` (note: `mcp-server/` directory, `.mjs` extension — not `scripts/mcp-server.js`). The installer already writes a local-machine entry into `~/.claude/settings.json` if run on the local box, but for a split setup you configure it manually on the local machine.

Add to `~/.claude/settings.json` on the local machine. The lowercase agent-name slug (`${AGENT_NAME,,}-memory`) must match what the remote installer writes.

**Split setup over SSH (recommended):**
```json
{
  "mcpServers": {
    "[agent-name-lowercase]-memory": {
      "command": "ssh",
      "args": ["-T", "[user@remote]", "node [remote-workspace]/mcp-server/server.mjs"],
      "env": {
        "OPENCLAW_WORKSPACE": "[remote-workspace]",
        "OPENCLAW_CONFIG_PATH": "[remote-workspace]/openclaw.json"
      }
    }
  }
}
```

**Local (cohabitated) MCP, for reference:**
```json
{
  "mcpServers": {
    "[agent-name-lowercase]-memory": {
      "command": "node",
      "args": ["[workspace]/mcp-server/server.mjs"],
      "env": {
        "OPENCLAW_WORKSPACE": "[workspace]",
        "OPENCLAW_CONFIG_PATH": "[workspace]/openclaw.json"
      }
    }
  }
}
```

**Step 4: Test MCP connection**

Start a new Claude Code session and run:
```
memory_search("test connection")
```

Confirm results come back from the remote memory store.

---

## Phase 5 — Verification

Run the health check and present results clearly. Run it from the **installed workspace path**, not the cloned `/tmp/flipclaw-install` toolkit — the installer sed-substitutes `{{WORKSPACE}}` and `{{CLAUDE_HOME}}` into the workspace copy at install time.

```bash
bash [workspace]/scripts/claude-code-update-check.sh
```

Do not dump raw output at the user. Summarize:

> "FlipClaw is installed and healthy:
> ✓ Memory capture active — facts will be extracted after each Claude Code session
> ✓ Dreaming scheduled — nightly consolidation at 4 AM [local timezone]
> ✓ Semantic search ready — Gemini embeddings configured
> ✓ Gateway running on port [port] — responding healthy
> ✓ Claude Code hooks installed — SessionEnd and Stop hooks active
> ✓ OpenClaw [version] — meets minimum requirement"

If any check fails, diagnose and fix it before moving on. Do not leave the user with a broken install.

---

## Phase 6 — What Happens Next

Once everything is verified, give the user a brief orientation:

> "You're all set. Here's what to expect:
>
> **Your first session:** Start Claude Code and work normally. When you end the session, FlipClaw will automatically extract facts and save them to memory. You won't see anything happen — it runs in the background.
>
> **After a few sessions:** Ask Claude Code to search memory: *'Search my memory for [something you've worked on]'* — you'll see it recall context from previous sessions.
>
> **Nightly:** Dreaming consolidates your memory automatically. Over time, your most important knowledge gets promoted to long-term memory.
>
> **Checking memory manually:**
> ```bash
> # Search memory from the command line
> cd [workspace] && openclaw memory search "your query"
>
> # See today's captured facts
> cat [workspace]/memory/$(date +%Y-%m-%d).md
> ```
>
> **Staying updated:** Run this anytime to check for FlipClaw updates:
> ```bash
> bash [workspace]/scripts/flipclaw-update.sh --check
> ```
>
> Anything else you'd like to configure before we wrap up?"

---

## Notes for the AI executor

- **Never skip the API key validation.** An invalid key will cause silent failures hours later that are hard to debug.
- **Always backup before modifying existing configs.** Use timestamped filenames.
- **If a gateway health check fails after restart,** check `pm2 logs [gateway-name] --lines 30` and fix before declaring success.
- **If the user is running you from an OpenClaw agent** and Claude Code isn't installed, you will reach the `claude login` step and cannot complete it automatically — OpenClaw agents have no interactive stdin for the browser OAuth flow. Pause and tell the user: "Open a separate terminal on the same machine, run `claude login`, complete the browser flow, then come back here and say 'done'." Wait for confirmation before continuing. Do not try to spawn `claude login` from inside the OpenClaw session.
- **If the user is on macOS** and gets a permissions error during npm global install, suggest: `sudo npm install -g --unsafe-perm` or using a Node version manager like `nvm`.
- **If PM2 isn't available,** install it: `npm install -g pm2` then `pm2 startup`.
- **Clean up after yourself:** `rm -rf /tmp/flipclaw-install` after the installation completes.
