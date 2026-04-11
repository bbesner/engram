# FlipClaw Troubleshooting Guide

This is a focused symptom-first reference for issues we've seen during real-world installs. Every entry is based on a real problem we diagnosed and fixed.

For upstream OpenClaw bugs that FlipClaw works around automatically, see [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

---

## Install-time issues

### `ERROR: OpenClaw X.Y.Z is too old`

**Cause:** You're running an OpenClaw version older than the minimum FlipClaw requires (currently `2026.4.9`).

**Fix:**
```bash
sudo npm install -g openclaw@latest
openclaw --version   # verify
```

Then restart any running agent gateways:
```bash
pm2 restart ultra-gateway   # or whatever your gateway is named
```

> The OpenClaw binary is global, so upgrading affects every agent on the server. Plan a brief restart window if other agents are in production use.

---

### `ERROR: OpenClaw is not installed or not in PATH`

**Cause:** OpenClaw CLI is not on your PATH.

**Fix:**
```bash
sudo npm install -g openclaw
which openclaw   # should print a path
```

---

### Pre-flight warning: "Gemini API key not found"

**Cause:** Your `openclaw.json` env.vars block doesn't include a Gemini API key. Memory search will fall back to keyword-only mode.

**Fix 1 — Pass the key during install:**
```bash
bash install.sh \
  --agent-name "MyAgent" \
  --workspace /path/to/agent \
  --port 3050 \
  --gemini-key "AIza..."
```

**Fix 2 — Add the key manually to `openclaw.json`:**
```json
{
  "env": {
    "vars": {
      "GEMINI_API_KEY": "AIza...",
      "GOOGLE_AI_API_KEY": "AIza..."
    }
  }
}
```

Get a free key at [aistudio.google.com/apikey](https://aistudio.google.com/apikey).

---

### LLM provider key not set (fact extraction / auto-skill capture silently skipped)

**Cause:** FlipClaw's per-turn fact extraction (`incremental-memory-capture.py`) and the auto-skill-capture extension both call an LLM on every eligible session. By default they use OpenAI (`gpt-5.4-nano` for extraction, `gpt-5.4-mini` for skill capture), which requires `OPENAI_API_KEY` in your `openclaw.json` `env.vars`. If the key is missing, these pipelines silently skip — the gateway keeps running, but daily logs and `skills/auto-captured/` stop growing.

**Symptom check:**
```bash
# Are facts being extracted? Look for today's daily log
ls -l $WORKSPACE/memory/$(date -u +%Y-%m-%d).md 2>&1

# Are skills being auto-captured?
ls $WORKSPACE/skills/auto-captured/ 2>&1 | head

# Is the key set?
python3 -c "import json; print(json.load(open('$WORKSPACE/openclaw.json'))['env']['vars'].get('OPENAI_API_KEY','MISSING')[:10])"
```

**Fix 1 — Add the OpenAI key to `openclaw.json`:**
```json
{
  "env": {
    "vars": {
      "OPENAI_API_KEY": "sk-proj-..."
    }
  }
}
```

Get a key at [platform.openai.com/api-keys](https://platform.openai.com/api-keys). Typical cost is pennies to single-digit dollars per month for personal/small-team workloads.

**Fix 2 — Switch to a different provider you already have configured.** FlipClaw is provider-agnostic for these calls. If you already have an Anthropic key or OAuth profile in OpenClaw, re-run the installer (or `flipclaw-update.sh`) with provider flags to point at it:

```bash
bash install.sh \
  --agent-name "MyAgent" --workspace $WORKSPACE --port 3050 \
  --gemini-key "AIza..." \
  --capture-provider anthropic --capture-model claude-haiku-4-5-20251001 \
  --extraction-model claude-haiku-4-5-20251001 \
  --generation-model claude-sonnet-4-6 \
  --skip-openclaw
```

The only key that cannot be swapped is the Gemini embedding key — memory-core's semantic search requires Gemini embeddings specifically.

---

### Pre-flight warning: "Legacy auth.profiles.*.primary key detected"

**Cause:** Your `openclaw.json` has an `auth.profiles.ANY.primary` field left over from an older OpenClaw version. OpenClaw 2026.4.9+ rejects this key as "Unrecognized".

**Fix:** The v3.2.1+ installer sanitizes this automatically. If you see it in a warning, let the installer proceed — it will remove the key from both the workspace and state-dir configs.

Manual fix if needed:
```bash
python3 -c "
import json
path = '/path/to/workspace/openclaw.json'
with open(path) as f: d = json.load(f)
for name, p in d.get('auth', {}).get('profiles', {}).items():
    if isinstance(p, dict) and 'primary' in p:
        del p['primary']
with open(path, 'w') as f: json.dump(d, f, indent=2)
"
```

---

### Pre-flight warning: "openclaw-mem0 extension at ..."

**Cause:** An older `openclaw-mem0` extension directory is present. It gets auto-discovered by the gateway and competes with `memory-core` for the memory slot, causing "duplicate plugin id" warnings.

**Fix:** The v3.2.1+ installer moves these directories aside automatically to `.disabled-openclaw-mem0-YYYYMMDD-HHMMSS`. No action needed.

If you see old mem0 data you want to preserve, check both locations before the install:
```bash
ls $WORKSPACE/extensions/openclaw-mem0
ls ~/.openclaw/extensions/openclaw-mem0
```

---

## Post-install runtime issues

### `openclaw memory status` shows `Provider: none (requested: auto)`

**Cause:** Memory search can't find a usable embedding provider. Usually means the Gemini API key isn't set.

**Fix:**
1. Check env.vars in `openclaw.json`:
   ```bash
   python3 -c "import json; print(json.load(open('$WORKSPACE/openclaw.json'))['env']['vars'])"
   ```
2. If `GEMINI_API_KEY` is missing, add it (see "Gemini API key not found" above).
3. If `memorySearch.provider` is missing, re-run the installer or set manually:
   ```json
   "memorySearch": {
     "provider": "gemini",
     "model": "gemini-embedding-001"
   }
   ```
4. Restart the gateway: `pm2 restart <gateway-name>`

---

### `memory-core: plugin disabled (memory slot set to "...")`

**Cause:** `plugins.slots.memory` is set to something other than `memory-core` (often `openclaw-mem0` from a legacy install), so memory-core never becomes the active memory provider.

**Fix:** The v3.2.1+ installer sets this correctly. Manual fix:
```bash
python3 -c "
import json
path = '/path/to/workspace/openclaw.json'
with open(path) as f: d = json.load(f)
d.setdefault('plugins', {}).setdefault('slots', {})['memory'] = 'memory-core'
with open(path, 'w') as f: json.dump(d, f, indent=2)
"
pm2 restart <gateway-name>
```

---

### `plugins.entries.memory-core: plugin not found` or "disabled"

**Cause:** The `memory-core` plugin entry doesn't have `enabled: true`, OR it's missing from `plugins.allow`.

**Fix:** The v3.2.1+ installer handles both. Manual fix:
```bash
python3 -c "
import json
path = '/path/to/workspace/openclaw.json'
with open(path) as f: d = json.load(f)
entries = d.setdefault('plugins', {}).setdefault('entries', {})
mc = entries.setdefault('memory-core', {})
mc['enabled'] = True
allow = d['plugins'].get('allow', [])
if allow and 'memory-core' not in allow:
    allow.append('memory-core')
    d['plugins']['allow'] = allow
with open(path, 'w') as f: json.dump(d, f, indent=2)
"
pm2 restart <gateway-name>
```

---

### Gateway starts but shows only 5 plugins loaded, missing memory-bridge or auto-skill-capture

**Cause:** You may have two `openclaw.json` configs — one in your workspace and one in `~/.openclaw/` — and the gateway is reading the wrong one. This happens when PM2 starts the gateway without `OPENCLAW_CONFIG_PATH` set.

**Quick check:**
```bash
python3 -c "
import json
for path in ['$WORKSPACE/openclaw.json', '$HOME/.openclaw/openclaw.json']:
    try:
        with open(path) as f: d = json.load(f)
        entries = d.get('plugins', {}).get('entries', {})
        enabled = sorted(n for n, c in entries.items() if c.get('enabled'))
        print(f'{path}: {enabled}')
    except Exception as e:
        print(f'{path}: (not found)')
"
```

**Fix:** v3.2.1+ installer syncs plugin config to both files automatically. Manual recovery:
```bash
# Re-run the v3.2.1+ installer — it will sync both configs
bash /path/to/flipclaw/install.sh --agent-name Foo --workspace /path --port 3050 --skip-openclaw
# Or manually copy the entries block from workspace to state-dir
```

---

### `Invalid config: Unrecognized key "primary"` on gateway startup or CLI commands

**Cause:** Legacy `auth.profiles.<name>.primary` field in `openclaw.json`.

**Fix:** See "Legacy auth.profiles.*.primary key detected" above.

---

### Nightly dreaming runs never seem to execute

**Symptoms:**
- `openclaw cron list` shows no "Memory Dreaming Promotion" cron
- `memory/dreaming/` directory has no new reports after 4 AM ET
- MEMORY.md never gets updated via Dreaming

**Cause:** OpenClaw 2026.4.x has a bug where `memory-core.reconcileShortTermDreamingCronJob` removes the managed dreaming cron on every gateway startup. See [KNOWN-ISSUES.md](KNOWN-ISSUES.md) for full technical details.

**Fix:** v3.2.1+ ships an `ensure-dreaming-cron.sh` workaround script and registers a daily OpenClaw cron job that re-creates the dreaming cron after each nightly restart. No action needed on fresh installs.

Manual fix (one-shot):
```bash
bash $WORKSPACE/scripts/ensure-dreaming-cron.sh
openclaw cron list | grep -i dreaming   # should now show the Memory Dreaming Promotion job
```

---

### Memory Wiki shows "Bridge: enabled (0 exported artifacts)"

**Cause:** Upstream OpenClaw 2026.4.9 bug — `publicArtifacts.listArtifacts()` returns empty even though the bridge is correctly configured. Affects `openclaw wiki bridge import`. See [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

**Workaround:** Use manual ingest for individual files:
```bash
openclaw wiki ingest $WORKSPACE/memory/decisions.md
openclaw wiki ingest $WORKSPACE/memory/infrastructure.md
# ... etc
```

**Status:** Waiting on upstream OpenClaw fix. This is NOT a FlipClaw bug.

---

### Health check reports "SessionEnd hook — Hook exists but points to: NO COMMAND"

**Cause:** In v3.2.0 and earlier, the health check's hook parser only looked at the flat hook form (`[ {command: ...} ]`) and missed the nested matcher form (`[ {hooks: [{command: ...}]} ]`) that newer Claude Code installers produce.

**Fix:** v3.2.1+ updates the parser to handle both forms. If you still see this warning:
```bash
# Verify the hook is actually configured
python3 -c "
import json
d = json.load(open('$HOME/.claude/settings.json'))
print(json.dumps(d.get('hooks', {}).get('SessionEnd', []), indent=2))
"
```
If the command looks correct but the warning persists, you may be running an older v3.2.0 health check script. Run the updater:
```bash
bash $WORKSPACE/scripts/flipclaw-update.sh
```

---

### `fetch failed | other side closed` during memory indexing

**Cause:** Transient network failure to the Gemini API endpoint.

**Fix:** Retry the index. The underlying `openclaw memory index` command also retries internally with a short backoff:
```bash
cd $WORKSPACE && openclaw memory index --force
```

If it fails repeatedly, verify the API key works:
```bash
curl -sf "https://generativelanguage.googleapis.com/v1beta/models?key=$GEMINI_API_KEY" | head -20
```

---

## Update-time issues

### `flipclaw-update.sh --check` says "update available" but versions match

**Cause:** In v3.2.0, the updater used string equality instead of semver comparison. If your installed version was ahead of the remote (e.g., from a feature branch test), it incorrectly reported "update available" in the wrong direction.

**Fix:** v3.2.1+ uses proper semver via `sort -V`. If you're still on an older updater script, re-run the installer with `--skip-openclaw` to pick up the fix.

---

### "Validation failed" after running the updater

**Cause:** The updater detected syntax errors or missing files in the scripts it just installed.

**Fix:** The updater offers an automatic rollback prompt. Press `Y` to restore the pre-update snapshot. If you already dismissed the prompt:
```bash
bash $WORKSPACE/scripts/flipclaw-update.sh --rollback
```

This restores the most recent backup. Then file an issue at [github.com/bbesner/flipclaw/issues](https://github.com/bbesner/flipclaw/issues) with the validation error you saw.

---

## General diagnostic commands

Quick sanity check of a FlipClaw install:

```bash
# 1. Health check
bash $WORKSPACE/scripts/claude-code-update-check.sh

# 2. Memory provider and index status
cd $WORKSPACE && openclaw memory status

# 3. Plugins loaded (from gateway logs)
pm2 logs <gateway-name> --lines 50 --nostream | grep -iE 'plugin|memory|dream|wiki|started|ready'

# 4. Cron jobs
openclaw cron list

# 5. FlipClaw version + what got installed
cat $WORKSPACE/.toolkit-version
cat $WORKSPACE/.flipclaw-install.json

# 6. Installer backups (useful for rollback)
bash $WORKSPACE/scripts/flipclaw-update.sh --list-backups
```

---

## Still stuck?

- Search the [issues tab](https://github.com/bbesner/flipclaw/issues) for similar symptoms
- Open a new issue with:
  - `openclaw --version`
  - Contents of `$WORKSPACE/.flipclaw-install.json` (redact API keys)
  - Output of `bash $WORKSPACE/scripts/claude-code-update-check.sh`
  - Relevant gateway logs from `pm2 logs <gateway-name>`
