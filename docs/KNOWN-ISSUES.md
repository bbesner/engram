# Known Upstream OpenClaw Issues

This document catalogs bugs in OpenClaw (not FlipClaw) that we've identified during real-world deployments. Each entry includes the symptom, root cause, FlipClaw's workaround (if any), and the status of reporting it upstream.

**If you hit one of these symptoms, it's an OpenClaw bug — not a FlipClaw bug.** FlipClaw ships workarounds for the ones we can work around client-side.

**Version-aware workaround management (v3.2.2+):** FlipClaw now ships a declarative **patch registry** at `scripts/upstream-patches.json` and a runner at `scripts/apply-upstream-patches.sh`. The runner reads the registry, compares each workaround's version range against your installed OpenClaw version, and installs or removes the workaround accordingly. `install-memory.sh` and `flipclaw-update.sh` both call the runner automatically, so upgrading OpenClaw to a version that fixes a bug will automatically remove the corresponding workaround scripts and cron jobs on your next `flipclaw-update.sh` run. Each fixed upstream issue below has a `Fixed in:` line documenting the reconciliation.

---

## Issue 1: Managed dreaming cron removed by reconciler on gateway restart

**Affected versions:** OpenClaw 2026.4.0 – 2026.4.9
**Fixed in:** OpenClaw **2026.4.10** (verified by source inspection + runtime test)
**Registry id:** `dreaming-cron-reconciler`

**Symptom:**
- `dreaming.enabled: true` is set correctly in `openclaw.json` under `plugins.entries.memory-core.config.dreaming`
- On first install or first gateway restart, the managed "Memory Dreaming Promotion" cron is created
- After any subsequent gateway restart, the cron disappears from `openclaw cron list`
- `memory/dreaming/` directory gets no new reports, MEMORY.md is never auto-promoted via Dreaming
- Gateway logs show no errors — the cron is silently removed

**Root cause:**

`memory-core`'s `reconcileShortTermDreamingCronJob` function runs on `gateway:startup`. Looking at the bundled source at `dreaming-DKm55QYQ.js` around line 1180-1240, the reconciler:

1. Calls `resolveMemoryCorePluginConfig(api.config)` to get the current dreaming config
2. Checks `params.config.enabled`
3. If the resolver returns an object where `enabled` is falsy OR the returned config is an empty record, the reconciler takes the "disabled" branch and removes any existing managed cron tagged `[managed-by=memory-core.short-term-promotion]`

The issue appears to be a race condition or ordering bug: `resolveMemoryCorePluginConfig(api.config)` returns an effectively empty record at startup hook time, even when the config file clearly has `dreaming.enabled: true`. The reconciler interprets "empty config" as "dreaming disabled" and wipes the cron.

**FlipClaw workaround (automatic):**

FlipClaw installs two things to work around this:

1. **`scripts/ensure-dreaming-cron.sh`** — A standalone shell script that:
   - Waits for the gateway to be reachable
   - Checks if the managed dreaming cron exists by name/tag
   - If missing, recreates it with the correct `[managed-by=memory-core.short-term-promotion]` description tag, `0 4 * * *` schedule, `next-heartbeat` wake mode, and `__openclaw_memory_core_short_term_promotion_dream__` systemEvent payload — exactly matching what `buildManagedDreamingCronJob` would produce internally

2. **"Restore Dreaming Cron After Restart" OpenClaw cron job** — Registered during install, runs daily at 22:00 ET (5 minutes after a typical 21:55 ET nightly restart) with `wakeMode: next-heartbeat`. It asks the agent to exec `ensure-dreaming-cron.sh`, which heals any missing dreaming cron before the 4 AM ET run.

Both are idempotent. If the upstream bug ever gets fixed and the managed cron persists correctly, the workaround script sees it's already there and exits cleanly.

**Manual recovery if the cron ever disappears between restarts:**
```bash
bash $WORKSPACE/scripts/ensure-dreaming-cron.sh
openclaw cron list | grep -i dreaming   # should show the Memory Dreaming Promotion job
```

**Upstream status:** Not yet reported. Planning to file an issue with reproduction steps once we've confirmed the root cause path more precisely.

---

## Issue 2: Wiki bridge import returns 0 artifacts

**Affected versions:** OpenClaw 2026.4.0 – 2026.4.9, **regressed in 2026.4.11**
**Fixed in:** OpenClaw **2026.4.10** (verified by runtime test — source inspection was a false negative, see `scripts/upstream-patches.json` verification notes)
**Regressed in:** OpenClaw **2026.4.11** -- `listArtifacts()` returns 0 artifacts again despite the 4.10 fix
**Registry id:** `wiki-bridge-zero-artifacts`

**Symptom:**
- `openclaw wiki status` shows `Bridge: enabled (0 exported artifacts)` and `Pages: 0 sources, 0 entities, 0 concepts, 0 syntheses`
- The warning `"Bridge mode is enabled but the active memory plugin is not exporting any public memory artifacts yet"` appears regardless of how much memory content exists
- Running `openclaw wiki bridge import` prints `Bridge import synced 0 artifacts across 0 workspaces (0 new, 0 updated, 0 unchanged, 0 removed)` even though the memory system has hundreds of indexed files

**Root cause:**

The wiki plugin's bridge mode calls `publicArtifacts.listArtifacts()` on the active memory plugin (memory-core) to discover what's available. In OpenClaw 2026.4.9, this call returns an empty list even when:
- memory-core is enabled and indexing files successfully
- `openclaw memory status` confirms 200+ indexed files and thousands of chunks
- `memory-wiki` config is correctly set up with `bridge.readMemoryArtifacts: true`, `indexDreamReports: true`, `indexDailyNotes: true`, `indexMemoryRoot: true`

The bridge mechanism expects the memory plugin to export artifacts via a public export API, but memory-core isn't populating that export correctly at runtime.

**Regression in 2026.4.11:** The fix shipped in 2026.4.10 did not survive the 2026.4.11 release. `listArtifacts()` returns 0 artifacts again on 4.11, with identical symptoms to the original bug. The root cause of the regression has not been identified -- it may be a revert of the 4.10 config/agent-list resolution change or a new code path that bypasses it.

**FlipClaw workaround (automatic, v3.2.2+):**

FlipClaw now ships an automated daily ingest script as a workaround:

1. **`scripts/wiki-daily-ingest.sh`** -- A standalone shell script that:
   - Accepts `--workspace` flag, `$WORKSPACE` env var, or defaults to current directory
   - Ingests today's and yesterday's daily logs (`memory/YYYY-MM-DD.md`)
   - Ingests today's and yesterday's dreaming reports (light, REM, deep)
   - Ingests core memory (`MEMORY.md`)
   - Logs to `$WORKSPACE/logs/wiki-daily-ingest.log`
   - Is fully idempotent -- re-ingesting updates the wiki page in place

2. **"Wiki Daily Ingest Workaround" OpenClaw cron job** -- Registered during install, runs daily at 5:30 AM ET (after dreaming completes at ~4 AM ET). It runs `wiki-daily-ingest.sh` to keep the wiki populated despite the broken bridge.

**Manual usage:**
```bash
# Run the ingest manually
bash $WORKSPACE/scripts/wiki-daily-ingest.sh --workspace $WORKSPACE

# Or for a one-off specific file
cd $WORKSPACE && OPENCLAW_CONFIG_PATH=$WORKSPACE/openclaw.json openclaw wiki ingest $WORKSPACE/memory/decisions.md --title "Decisions"
```

You can also ingest all `.md` files under `memory/` in one pass:
```bash
find $WORKSPACE/memory -maxdepth 1 -name '*.md' -exec openclaw wiki ingest {} \;
```

**Upstream status:** Not yet reported. The regression in 4.11 makes this higher priority to file -- the fix was clearly fragile.

---

## Issue 3: `auth.profiles.*.primary` field not auto-sanitized by `openclaw doctor --fix`

**Affected versions:** OpenClaw 2026.4.9 (and earlier configs carried forward)

**Symptom:**
- All OpenClaw CLI commands (`openclaw memory status`, `openclaw cron list`, etc.) fail with:
  ```
  Invalid config at /path/to/openclaw.json:
  - auth.profiles.anthropic:default: Unrecognized key: "primary"
  ```
- `openclaw doctor` reports the legacy key but `openclaw doctor --fix` does NOT remove it
- Users are blocked from running even diagnostic commands until the key is manually removed

**Root cause:**

OpenClaw's config schema validator was tightened in 2026.4.9 to reject `auth.profiles.<name>.primary`. The `doctor --fix` code path knows about many legacy fields but doesn't currently strip this one.

**FlipClaw workaround (automatic in v3.2.1+):**

The installer detects the legacy field during pre-flight and removes it from both the workspace and state-dir configs before making any other changes. Pre-flight shows:
```
[WARN] Legacy auth.profiles.*.primary key detected — will be auto-sanitized by installer
```

**Manual fix if you're not running the installer:**
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

**Upstream status:** Not yet reported. Low priority — affects only workspaces carried forward from older OpenClaw versions.

---

## Issue 4: `openclaw-mem0` extension auto-discovered from extensions directory even when disabled in config

**Affected versions:** OpenClaw 2026.4.x

**Symptom:**
- `openclaw.json` has `plugins.entries.openclaw-mem0.enabled: false` (or the entry is removed entirely)
- Gateway logs still print `duplicate plugin id detected; global plugin will be overridden by config plugin (/path/to/extensions/openclaw-mem0/index.ts)` on every startup
- `openclaw-mem0: registered` appears in logs
- `memory-core` logs as `plugin disabled (memory slot set to "openclaw-mem0")` unless you also explicitly set `plugins.slots.memory = "memory-core"`
- Running any CLI command prints the same warning repeatedly

**Root cause:**

OpenClaw's plugin loader auto-discovers plugins by scanning directories configured in `plugins.load.paths` (default includes `~/.openclaw/extensions/` and `$WORKSPACE/extensions/`). If it finds a directory with an `openclaw.plugin.json` or `index.ts`, it loads the plugin. Setting `enabled: false` in the config prevents the plugin from ACTIVATING, but does not prevent the discovery pass from registering it, which triggers the duplicate-id warning and causes it to compete for plugin slots.

**FlipClaw workaround (automatic in v3.2.1+):**

The installer detects the physical `openclaw-mem0` directory at both common locations (`$WORKSPACE/extensions/openclaw-mem0` and `~/.openclaw/extensions/openclaw-mem0`) and moves it aside to `.disabled-openclaw-mem0-YYYYMMDD-HHMMSS` before making any config changes. It also fully removes the `openclaw-mem0` entry from both `plugins.entries` and `plugins.allow` rather than just setting `enabled: false`.

**Manual fix:**
```bash
# Move the extension directory out of discovery paths
mv $WORKSPACE/extensions/openclaw-mem0 $WORKSPACE/extensions/.disabled-openclaw-mem0
mv ~/.openclaw/extensions/openclaw-mem0 ~/.openclaw/extensions/.disabled-openclaw-mem0

# Remove from config entries (not just enabled: false)
python3 -c "
import json
for path in ['$WORKSPACE/openclaw.json', '$HOME/.openclaw/openclaw.json']:
    try:
        with open(path) as f: d = json.load(f)
    except FileNotFoundError:
        continue
    entries = d.get('plugins', {}).get('entries', {})
    if 'openclaw-mem0' in entries: del entries['openclaw-mem0']
    allow = d.get('plugins', {}).get('allow', [])
    if 'openclaw-mem0' in allow: allow.remove('openclaw-mem0')
    with open(path, 'w') as f: json.dump(d, f, indent=2)
"

pm2 restart <gateway-name>
```

**Upstream status:** Arguably working-as-designed (auto-discovery IS a feature), but the interaction with `enabled: false` is surprising. Worth filing as a usability issue.

---

## Issue 5: OpenClaw may load either `$WORKSPACE/openclaw.json` OR `~/.openclaw/openclaw.json` depending on how the gateway was started

**Affected versions:** All versions (this is a config resolution behavior, not a bug per se)

**Symptom:**
- You edit `$WORKSPACE/openclaw.json` and restart the gateway, but your changes don't take effect
- Gateway logs show the old config values
- Config changes only work if you ALSO update `~/.openclaw/openclaw.json`

**Root cause:**

OpenClaw resolves the config file to use in this order:
1. `OPENCLAW_CONFIG_PATH` environment variable (if set)
2. `./openclaw.json` in the current working directory
3. `~/.openclaw/openclaw.json` (state-dir default)

If your PM2 start script does `cd $WORKSPACE && openclaw gateway run` WITHOUT exporting `OPENCLAW_CONFIG_PATH`, then step 2 finds `$WORKSPACE/openclaw.json` and uses it. But if the start script doesn't `cd` first, OR if it's running from a different directory, OpenClaw falls back to step 3 and reads the state-dir config instead.

**FlipClaw mitigation (v3.2.1+):**

The installer writes plugin and memorySearch config to BOTH files when both exist. This means whichever one the gateway reads, it sees the correct FlipClaw config. The pre-flight check flags this scenario:
```
[OK] State-dir config detected — installer will sync plugin changes to both
```

**Best practice:** Ensure your PM2 ecosystem file or start script exports `OPENCLAW_CONFIG_PATH` explicitly:
```javascript
// ecosystem.config.js
module.exports = {
  apps: [{
    name: 'my-gateway',
    script: 'openclaw',
    args: 'gateway run',
    cwd: '/path/to/workspace',
    env: {
      OPENCLAW_CONFIG_PATH: '/path/to/workspace/openclaw.json',
      OPENCLAW_GATEWAY_PORT: '3050'
    }
  }]
};
```

**Upstream status:** Not a bug — intentional behavior. Documented here for installer users who don't realize this.

---

## Summary of workarounds (v3.2.2+)

Starting in v3.2.2, FlipClaw manages version-conditional workarounds via a declarative patch registry at `scripts/upstream-patches.json`. The runner at `scripts/apply-upstream-patches.sh` is invoked on every install and update, so upgrading OpenClaw to a version that ships an upstream fix automatically removes the corresponding workaround.

| Issue | Fixed in OpenClaw | FlipClaw Action (≤ 2026.4.9) | FlipClaw Action (≥ 2026.4.10) | User Action |
|-------|---|---|---|-------------|
| 1. Dreaming cron reconciler bug | **2026.4.10** | Installs `ensure-dreaming-cron.sh` + daily heal cron via patch registry | Removes heal script + cron automatically on next update | None — automatic reconciliation |
| 2. Wiki bridge import returns 0 | **2026.4.10** (regressed in **2026.4.11**) | Installs `wiki-daily-ingest.sh` + daily ingest cron via patch registry | Removes ingest script + cron if upstream fix confirmed | None -- automatic daily ingest |
| 3. Legacy `auth.profiles.*.primary` | Not fixed upstream | Auto-sanitizes during install | Auto-sanitizes during install | None |
| 4. openclaw-mem0 auto-discovery | Not fixed upstream | Moves directory aside + removes from config | Moves directory aside + removes from config | None |
| 5. Two-config resolution | Not a bug — working-as-designed | Syncs plugin config to both files | Syncs plugin config to both files | Set `OPENCLAW_CONFIG_PATH` in start scripts (recommended) |

---

## Reporting these upstream

Issue #1 was **fixed in OpenClaw 2026.4.10** and verified by source inspection and runtime test. Issue #2 was also fixed in 2026.4.10 but **regressed in 2026.4.11** -- FlipClaw now ships an automated workaround (`wiki-daily-ingest.sh`). If you maintain OpenClaw, these issues would benefit from being addressed:

1. **Issue #3** is a minor inconvenience that should be handled by `openclaw doctor --fix`
2. **Issue #4** is a usability issue — plugin auto-discovery should respect `plugins.entries.<name>.enabled: false`
3. **Issue #5** is working-as-designed but documentation could be clearer

FlipClaw's patch registry (v3.2.2+) makes future upstream fixes cheap to adopt: update `scripts/upstream-patches.json` with the new `fixed_in` version, and every user running `flipclaw-update.sh` on an upgraded OpenClaw will automatically have their workarounds removed.
