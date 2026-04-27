# Changelog

All notable changes to FlipClaw are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).  
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

---

## [3.2.8] — 2026-04-27

### Fixed

- **`scripts/flipclaw-update.sh`** — Wrapped the imperative body in `main() { … } main "$@"` to eliminate a self-modify race. The updater overwrites itself in Step 4 (`apply_script "$TOOLKIT_DIR/scripts/flipclaw-update.sh" "$WORKSPACE/scripts/flipclaw-update.sh"`); without the wrapper, bash's stream-reader picks up the new file content at the old read offset and hits a `syntax error near unexpected token` on subsequent lines, aborting the update mid-flight before extension files, prompt templates, and the patch reconciliation step run. With `main()`, bash parses the entire script up front, so subsequent file reads can't desync. Caught on Ultra during an `e1` update from 3.2.5 → 3.2.7 — the run aborted at line 623 the first attempt and line 597 the second, leaving the install in a partial state. The same race exists for any updater path beyond a tiny script footprint, so this is a structural fix, not version-specific.

### Known issue — upgrading from 3.2.5 / 3.2.6 to 3.2.8

Existing installs on 3.2.5 or 3.2.6 cannot upgrade cleanly via `flipclaw-update.sh`. Their installed `apply_script` substitutes the old concrete refs (`/home/e1/agent` → `$WORKSPACE`, etc.), but the toolkit source moved to `{{WORKSPACE}}` / `{{PORT}}` / `{{AGENT_NAME}}` placeholders in 3.2.7. The on-disk `apply_script` patterns no longer match, so 3.2.7+ source files are written to disk with literal `{{WORKSPACE}}` strings and won't run. The self-modify race in 3.2.7 hid this from view because the updater aborted before printing affected files.

Recommended path:

1. Pre-warm any in-flight Claude Code sessions through the bridge so nothing is lost (`echo '{"session_id":"…","transcript_path":"…"}' | python3 $WORKSPACE/scripts/claude-code-bridge.py`).
2. Re-run `install-memory.sh` against the existing workspace to refresh `apply_script` and the script set in one shot. The installer is idempotent for memory dirs, AGENTS.md, MEMORY.md, openclaw.json, and `.flipclaw-install.json` — it preserves user content and rewrites the script set with proper substitutions.
3. Verify with `bash $WORKSPACE/scripts/claude-code-update-check.sh`.

Once on 3.2.8, all subsequent updates run clean — apply_script substitutes the new placeholder format and the `main()` wrapper holds across self-replace.

---

## [3.2.7] — 2026-04-26

### Fixed

- **`install-claude-code.sh`** — MCP server registration moved from `~/.claude/settings.json` (which current Claude Code releases no longer read for MCP discovery) to `~/.claude.json` via the official `claude mcp add --scope user` CLI. Previously, the script wrote the agent's `${name}-memory` entry into the legacy `mcpServers` block in `settings.json`; Claude Code has since migrated MCP server discovery to `~/.claude.json` (the file `claude mcp add` manages), so the legacy entry was inert and the FlipClaw MCP server was silently absent from sessions. Same root cause and fix as Memstem PR #30. The script now (1) cleans up any stale `mcpServers.${name}-memory` entry from the legacy settings.json on each run, and (2) registers via `claude mcp add` with the agent's `OPENCLAW_WORKSPACE` / `OPENCLAW_CONFIG_PATH` env vars passed via `-e`. Falls back to printing the manual command if the `claude` CLI is not on PATH at install time.
- **`mcp-server/server.mjs`** — Updated module header comment to describe registration via `claude mcp add` rather than direct settings.json editing.
- **`docs/ARCHITECTURE.md`** — Updated MCP Server section to document the new registration path and the legacy-cleanup behavior.

---

## [3.2.6] — 2026-04-23

### Fixed

- **`install-memory.sh`** — Changed the default `dreaming.storage.mode` written into new installs from the legacy `"both"` (with `separateReports: true`) to `"separate"`. OpenClaw 2026.4.15 documented only `inline` and `separate` as valid modes and changed the default from `inline` to `separate`, with dream phase blocks (`## Light Sleep`, `## REM Sleep`) now landing in `memory/dreaming/{phase}/YYYY-MM-DD.md` instead of the daily `memory/YYYY-MM-DD.md` file. The `"both"` value was an Ari-legacy pattern whose behavior is no longer part of the supported surface. Existing installs that wrote `"both"` should be migrated to `"separate"` before upgrading past 2026.4.14 — the wiki bridge (`wiki-daily-ingest.sh`) already reads from `memory/dreaming/{phase}/` so consumption is unchanged. **Requires OpenClaw ≥ 2026.4.15.**
- **`scripts/claude-code-update-check.sh`** — Tightened SessionEnd hook validation to FAIL (not PASS) when the deprecated flat schema is detected. Recent Claude Code versions reject the flat form on session start with `hooks: Expected array, but received undefined`, but the previous check accepted both shapes and reported PASS. The check now explicitly identifies the schema shape (`NESTED`, `FLAT`, `NOT_CONFIGURED`, `MALFORMED`) and tells operators how to migrate. Caught on Ultra when e1's first Claude Code launch failed post-CLI-update — `install-claude-code.sh` already emits the nested form, so only pre-existing installs are affected.

---

## [3.2.5] — 2026-04-13

### Added

- **`install-memory.sh`** — New `--group GROUP` flag for multi-user installs. When specified, the installer applies `chgrp -R`, setgid (`chmod 2775`) on directories, and group-write on files after directory creation. This allows gateway processes running as a different user (e.g., `ubuntu` running gateways for `e1/e2/e3` employee accounts) to write to workspace directories without EACCES errors.
- **`install-memory.sh`** — Added `cron/`, `state/`, and `memory/.dreams/` to the directory creation list. OpenClaw's `memory-core` and `acpx` plugins expect these at runtime; creating them during install prevents EACCES failures in multi-user setups where the gateway user lacks permission to mkdir in the workspace root.
- **`scripts/wiki-daily-ingest.sh`** — New workaround script for OpenClaw wiki bridge Known Issue #2 (regressed in 2026.4.11). Ingests daily logs, dreaming reports, and MEMORY.md into the wiki vault via `openclaw wiki ingest`. Intended to run daily after dreaming completes (e.g., 5:30 AM ET cron). Idempotent; logs to `$WORKSPACE/logs/wiki-daily-ingest.log`.

### Removed

- **`install-claude-code.sh`** — Removed `--shared` flag and shared workspace mode (Step 6). The multi-tenant architecture (multiple Claude Code users sharing one agent's memory pool) is not a supported pattern. Each user should have their own agent instance. The `--user` flag is retained for colocated single-tenant installs (e.g., ubuntu installing hooks for e1/e2/e3 employee accounts that each have their own agent).
- **`README.md`** — Replaced "Multi-User Support (Experimental)" section with "Colocated Agents" documenting the actual supported pattern: multiple independent single-tenant stacks sharing hardware.
- **`docs/ARCHITECTURE.md`** — Replaced "Multi-User Support" section with "Colocated Agents." Removed reference to per-user source tagging (`[src:claude-code-employee1]`) which was never implemented at the runtime level.

### Fixed

- **`docs/KNOWN-ISSUES.md`** — Issue #2 (wiki bridge `listArtifacts` returns 0) updated to note regression in OpenClaw 2026.4.11. Previously marked as fixed in 4.10; the fix did not hold across versions. Automated workaround via `wiki-daily-ingest.sh` now documented.
- **`scripts/upstream-patches.json`** — Wiki bridge patch entry updated with `regressed_in: "2026.4.11"`, regression verification note, and `wiki-daily-ingest.sh` artifact.

---

## [3.2.4] — 2026-04-13

### Fixed

- **`install-claude-code.sh`** — When `--user` is provided without `--claude-home`, the installer now resolves the target user's home directory via `getent passwd` instead of defaulting to `$HOME/.claude` (which is the *installing* user's home, not the target user's). This caused `claude-code-sweep.py`, `claude-code-turn-capture.py`, and `claude-code-update-check.sh` to have the wrong `CLAUDE_HOME` baked in, breaking crash-recovery session scanning and health checks for multi-user installs where the installer runs as a different user (e.g., root or ubuntu installing for employee accounts).

---

## [3.2.3] — 2026-04-11

Documentation and branding pass. All prose was swept for stale version references and outdated upstream-bug framing after the v3.2.2 patch registry landed; extensions and the MCP server now self-identify as FlipClaw components so users can tell what FlipClaw adds versus what's stock OpenClaw.

### Documentation

- **`docs/ARCHITECTURE.md`** — version header bumped 3.2.1 → 3.2.3. Minimum OpenClaw clarified: enforcement stays at `2026.4.9` but `2026.4.10` is now the **recommended** version (both known upstream bugs are fixed there and the patch registry handles reconciliation automatically).
- **`docs/ARCHITECTURE.md` "Upstream OpenClaw Issues" section** — full rewrite. Issue #1 (dreaming cron reconciler) and Issue #2 (wiki bridge listArtifacts) marked **fixed in 2026.4.10** with the upstream code diff for Issue #1 and the runtime-test verification for Issue #2. Both now document the patch registry's install/remove behavior on each version.
- **`docs/ARCHITECTURE.md` scripts/ file reference table** — added `upstream-patches.json` and `apply-upstream-patches.sh` entries; `ensure-dreaming-cron.sh` reclassified as conditional (installed only on OpenClaw ≤ 2026.4.9). Updater flow diagram gained a Step 13 for patch registry reconciliation.
- **`docs/ARCHITECTURE.md`** — Gate 2 description fixed: `nano model` → `gpt-5.4-mini by default` (matches the v3.2.2 plugin schema fix and what `install-memory.sh` actually writes). Health check count fixed from `11-point` to `12-point`. Installer descriptions in the file reference table now note `2026.4.10+ recommended`.
- **`docs/TROUBLESHOOTING.md`** — Minimum OpenClaw wording updated to mention the `2026.4.10` recommendation. Customer-specific gateway name (`ultra-gateway`) genericized to `<gateway-name>`.
- **`docs/TROUBLESHOOTING.md` "Nightly dreaming runs never seem to execute" section** — now leads with the 2026.4.10 upgrade as the preferred fix. Workaround path for stuck-on-4.9 users documented with both the full registry re-run and the one-shot heal script.
- **`docs/TROUBLESHOOTING.md` "Memory Wiki shows 0 exported artifacts" section** — removed "waiting on upstream OpenClaw fix" status. Now leads with the 2026.4.10 upgrade; manual ingest retained as the 4.9 fallback with a `find`-based loop example.
- **`docs/KNOWN-ISSUES.md` summary table** — renamed from "Summary of v3.2.1 workarounds" to "Summary of workarounds (v3.2.2+)". New columns for `Fixed in OpenClaw`, `FlipClaw Action (≤ 4.9)`, and `FlipClaw Action (≥ 4.10)`. Issues #1 and #2 now explicitly show the automatic workaround removal path.
- **`docs/KNOWN-ISSUES.md` "Reporting these upstream" section** — acknowledges the upstream fixes for Issues #1 and #2 and notes that the patch registry makes future upstream fixes cheap to adopt.
- **`CONTRIBUTING.md`** — Expanded from 33 lines to 112. New "Testing changes" section documents the LXD-container smoke-test workflow used to verify v3.2.2 end-to-end (clean Ubuntu 24.04 + OpenClaw 2026.4.10, `openclaw onboard` → `jq` env injection → `install.sh --gemini-key` → `pm2 start --name X "openclaw gateway run"` → `/health` probe → 12-point health check). New "Adding new upstream patches" section documents how to add a registry entry for a new upstream bug workaround (pointing at `scripts/upstream-patches.json` as the single source of truth). Adds JSON registry formatting note to the Code Style section.

### Changed

- **`mcp-server/package.json`** — `"name": "openclaw-memory-mcp"` → `"flipclaw-memory-mcp"`. Description rewritten to explicitly identify it as a FlipClaw component that wraps an OpenClaw agent's shared memory.
- **`mcp-server/server.mjs`** — file header comment updated from "OpenClaw Memory MCP Server" to "FlipClaw MCP Server (flipclaw-memory-mcp)" with provenance note.
- **`extensions/auto-skill-capture/openclaw.plugin.json`** — plugin display name now `Auto Skill Capture (FlipClaw)`. Description rewritten to identify it as FlipClaw value-add.
- **`extensions/auto-skill-capture/package.json`** — same.
- **`extensions/memory-bridge/openclaw.plugin.json`** — plugin display name now `Memory Bridge (FlipClaw)`. Description rewritten to identify it as FlipClaw value-add that fires per-turn memory capture.
- **`scripts/ensure-dreaming-cron.sh`** — header comment updated: removed reference to "Ari's exec tool" (which leaked a project-specific agent name into the public toolkit) in favor of the generic "OpenClaw agent systemEvent" framing.
- **`docs/hero.svg`** — Bottom-banner label "WHAT OPENCLAW ADDS TO CLAUDE CODE" → "WHAT FLIPCLAW ADDS TO CLAUDE CODE". Four of the six badges below it (Persistent Memory, Nightly Dreaming, Memory Wiki, Cron Jobs & Heartbeats) are stock OpenClaw features, but without FlipClaw Claude Code can reach none of them — FlipClaw is what delivers the entire bundle to the Claude Code CLI, so the accurate framing is "what FlipClaw adds".
- **`LICENSE`** — Added a `FlipClaw` header line above the standard MIT text and appended `(FlipClaw project)` to the copyright line. Body text unchanged. The file was carried forward from the Engram era without naming the software it covers; this fixes the project identification without altering license terms.
- **`templates/CLAUDE.md.template`** — Header line 3 now credits FlipClaw explicitly: "Installed by: [FlipClaw](https://github.com/bbesner/flipclaw) on {{DATE}}" with the update command inline. Previously said only "Installed: {{DATE}}" with no project identifier.
- **`templates/CLAUDE-append.md.template`** — Added two HTML-comment provenance lines at the top of the append block identifying FlipClaw as the installer and pointing at `flipclaw-update.sh`. Invisible in rendered markdown but visible in raw view, so agents using this append block can trace its origin.

### Removed

- **`BUGS-FOR-3.2.1.md`** — this file was never in the public repo (`.gitignore` has `BUGS-FOR-*.md`) but existed in local working copies from the 3.2.1 release cycle. Noted here for clarity; no history rewrite needed.

---

## [3.2.2] — 2026-04-11

**Headline feature: install FlipClaw in one command.** This release ships `BOOTSTRAP.md` — an executor-agnostic AI installer that handles the entire setup for you. Point Claude Code CLI (or any existing OpenClaw agent) at the bootstrap URL and it detects your environment, asks a few questions, and handles fresh installs, existing-Claude-Code installs, existing-OpenClaw installs, and split-machine (MCP bridge) setups automatically:

```
claude "Install FlipClaw. Read and follow the instructions at: https://raw.githubusercontent.com/bbesner/flipclaw/main/BOOTSTRAP.md"
```

Under the hood, this release also introduces the **upstream patch registry** (`scripts/upstream-patches.json` + `scripts/apply-upstream-patches.sh`) — a declarative, version-aware framework for managing workarounds against known OpenClaw bugs. Both dreaming cron reconciler and wiki bridge zero-artifacts bugs documented in KNOWN-ISSUES.md were verified fixed in OpenClaw **2026.4.10**, and the registry now cleans up those workarounds automatically when users upgrade. Plus install-flow fixes for OpenClaw 2026.4.10's stricter config schema, and a documentation overhaul differentiating FlipClaw custom features from OpenClaw stock features.

### Added

- **`BOOTSTRAP.md`** — 🆕 **Headline feature.** Executor-agnostic AI installer that detects the user's environment and handles installation via Claude Code CLI or any OpenClaw agent. Covers four install paths: fresh (nothing installed), existing-Claude-Code (just needs FlipClaw + OpenClaw), existing-OpenClaw (just needs Claude Code + FlipClaw), and split-machine (Claude Code local + OpenClaw remote via MCP bridge). Handles environment detection, branching, API key validation, config scaffolding via `openclaw onboard`, `jq`-based env var injection, PM2 gateway start with the correct string-command form, and post-install health verification. One-command install replaces the multi-step manual flow.
- **`scripts/upstream-patches.json`** — Declarative registry of FlipClaw workarounds for upstream OpenClaw bugs. Each entry records `broken_from`/`fixed_in` version ranges, workaround artifacts (scripts, cron jobs), and an optional runtime probe for regression safety. Single source of truth for version-conditional patch management.
- **`scripts/apply-upstream-patches.sh`** — Version-aware runner that reads the registry, compares against the installed OpenClaw version, and installs or removes workaround artifacts accordingly. Called automatically by `install-memory.sh` and `flipclaw-update.sh` so OpenClaw upgrades trigger workaround cleanup with no user action.
- **`README.md` "What FlipClaw Adds to OpenClaw" section** — Explicitly differentiates FlipClaw custom features (per-turn memory capture, auto-skill capture, Claude Code bridge, crash sweep, updater, Telegram relay integration, MCP server for remote memory, patch registry) from OpenClaw stock features FlipClaw configures (memory-core Dreaming, Memory Wiki, semantic search, cron system, gateway).
- **`README.md` "API Keys & Costs" section** — Correctly frames Gemini as the only hard requirement (memory-core embeddings) and every other LLM provider as user choice. Includes provider-swap example using Anthropic OAuth instead of OpenAI.
- **`README.md` "Install in one command" top-level callout** — AI-bootstrap install command visible above the fold.
- **`Origin` column on "What Gets Installed" tables** — Each component tagged as FlipClaw-custom or OpenClaw-stock.
- **`docs/TROUBLESHOOTING.md` OpenAI-key section** — Mirrors the existing Gemini section with provider-swap guidance.

### Fixed

- **`install.sh` arg splitter** — Memory-only flags (`--gemini-key`, `--capture-model`, etc.) no longer leak into `install-claude-code.sh`, which previously hard-exited on unknown flags. Phase 2 (Claude Code integration) now runs cleanly after Phase 1 (memory system) when using combined flags.
- **`scripts/incremental-memory-capture.py`** — Daily log bucketing now reads the session's last message timestamp instead of using the processing time, so facts from sessions processed hours or days after they ended (crash sweep, delayed processing) are attributed to the correct calendar day. Bucketing remains UTC for timezone-neutral behavior in the public toolkit.
- **`extensions/auto-skill-capture/openclaw.plugin.json`** — `extractionModel` plugin schema default corrected from `gpt-5.4-nano` to `gpt-5.4-mini` to match what `install-memory.sh` actually writes during install (documentation consistency fix; no runtime behavior change).

### Changed

- **`install-memory.sh`** — Replaced the inline dreaming-cron-workaround install block (~50 lines) with a single call to `apply-upstream-patches.sh`. Patch registry now owns all version-conditional workaround logic.
- **`scripts/flipclaw-update.sh`** — Added post-update Step 8 that re-runs the patch registry against the user's current OpenClaw version. Upgrading OpenClaw between FlipClaw updates now automatically removes obsolete workarounds.
- **`docs/KNOWN-ISSUES.md`** — Both Issue 1 (dreaming cron) and Issue 2 (wiki bridge) marked as **Fixed in 2026.4.10**, with registry IDs linking back to `upstream-patches.json` for the reconciliation policy.
- **`README.md` symptom table** — Dreaming and wiki-bridge rows updated to note the upstream fix and direct users to upgrade rather than stay on the workaround.

### Verification

- **Dreaming cron reconciler fix** — Verified by source inspection comparing `dreaming-*.js` between 2026.4.9 and 2026.4.10 (new `startupCfg` path reads config from the startup event payload instead of the empty `api.config` at hook time).
- **Wiki bridge fix** — Verified by runtime test in a clean Ubuntu 24.04 + OpenClaw 2026.4.10 LXD container with 5 memory artifacts on disk. `openclaw wiki status` reported `Bridge: enabled (5 exported artifacts)` and `openclaw wiki bridge import` reported `Bridge import synced 5 artifacts across 1 workspaces`. (Source inspection alone was a false negative — the fix lives outside the `listArtifacts` call chain; runtime verification caught it.)
- **`install.sh` arg filter + full install flow** — Verified end-to-end in the same container: `openclaw onboard` → `jq` env injection → `install.sh --gemini-key KEY` → `pm2 start --name fctest-gateway "openclaw gateway run"` → `/health` returned `{"ok":true,"status":"live"}` → `claude-code-update-check.sh` reported 12 passed / 1 warning / 0 failed.

---

## [3.2.1] — 2026-04-10

Production-hardened patch release based on learnings from the first real-world install on a second agent, plus a second round of issues discovered during live gateway startup testing. The v3.2.0 installer worked on fresh synthetic test workspaces but hit 10 distinct issues when run against a long-lived OpenClaw agent with a pre-existing config, extensions, and a state-dir config alongside the workspace config. An 11th issue (multi-user mode not wired up) was found during test planning and deferred to v3.3.0 as experimental. A 12th issue (plugins.load.paths only set in state-dir, not workspace) was found during Phase 3 live gateway testing and fixed immediately. v3.2.1 bundles fixes for bugs 1–10 and 12, documents bug 11 as experimental, and adds significantly expanded documentation so users don't have to rediscover these issues.

### Added

- **`docs/TROUBLESHOOTING.md`** — Comprehensive symptom-first troubleshooting guide covering every issue we've seen in real installs. Organized into install-time, post-install runtime, and update-time sections. Each entry has symptom, cause, fix, and manual recovery commands.

- **`docs/KNOWN-ISSUES.md`** — Catalog of upstream OpenClaw bugs that affect FlipClaw, with workarounds the toolkit ships automatically plus clear "this is NOT a FlipClaw bug" framing. Five documented issues covering the dreaming cron reconciler bug, wiki bridge import returning 0 artifacts, legacy auth field, openclaw-mem0 auto-discovery, and two-config resolution.

- **Pre-flight checks in installers** — Before making any changes, `install-memory.sh` now runs 7 non-destructive checks and reports OK/WARN/FAIL for each:
  1. Workspace directory exists and is writable
  2. `openclaw.json` present (unless `--skip-openclaw`)
  3. State-dir config detection (`~/.openclaw/openclaw.json`) for two-config sync
  4. Conflicting `openclaw-mem0` extension directories
  5. Legacy `auth.profiles.*.primary` key
  6. Gateway reachability on the configured port
  7. Gemini API key presence
  Blockers cause early exit with clear messages; warnings proceed with the install.

- **`--gemini-key` installer flag** — New CLI option to pass a Gemini API key directly during install. Auto-writes the key to both `GEMINI_API_KEY` and `GOOGLE_AI_API_KEY` env.vars (memory-core uses one, the CLI uses the other; setting both avoids "provider: none" errors).

- **`scripts/ensure-dreaming-cron.sh`** — Workaround script for an OpenClaw 2026.4.x bug where `memory-core.reconcileShortTermDreamingCronJob` removes the managed "Memory Dreaming Promotion" cron on every gateway startup. See KNOWN-ISSUES.md Issue #1 for the full technical breakdown.

- **"Restore Dreaming Cron After Restart" OpenClaw cron job** — Registered by `install-memory.sh` Step 8. Runs daily at 22:00 ET with `wakeMode: next-heartbeat` and asks the agent to exec `ensure-dreaming-cron.sh`, which recreates the managed dreaming cron if missing. Idempotent (re-runs detect an existing job and skip).

- **README Prerequisites expansion** — Now clearly documents both required API keys (OpenAI and Gemini) with purposes, cost expectations, and where to get them. Adds a "First-install checklist" to catch the most common install-time surprises before they happen.

- **README Troubleshooting & Known Issues section** — New section with a quick symptom → cause → fix table and links to the new TROUBLESHOOTING.md and KNOWN-ISSUES.md docs.

### Fixed — All 10 bugs found during the Ultra install

#### Bug #1: `memory-core.enabled` flag not set on fresh install (Blocker)

The installer added the dreaming config under `memory-core.config.dreaming` but never set `memory-core.enabled: true`. On workspaces where memory-core wasn't already present, memory-core got created with a valid config but was silently disabled, so Dreaming never ran. Fixed by unconditionally setting `mc['enabled'] = True` when adding the dreaming config.

#### Bug #2: Installer only updated workspace config, not state-dir config (Blocker)

OpenClaw agents can have two `openclaw.json` files that matter: one in the workspace (`$WORKSPACE/openclaw.json`) and one in the state-dir (`~/.openclaw/openclaw.json`). Which one the gateway reads depends on how the gateway was started — if the PM2 start script doesn't `cd` to the workspace or set `OPENCLAW_CONFIG_PATH`, the gateway falls back to the state-dir config. The v3.2.0 installer only modified the workspace config, so on such agents, all plugin changes were invisible to the running gateway.

Fixed by restructuring the config-modification Python block to iterate over a `targets` list that includes both files (when the state-dir config exists), so plugin entries, slots, allow list, continuation-skip, and memorySearch all get applied to both.

#### Bug #3: `plugins.slots.memory` not set to `memory-core` (Blocker)

Even with `memory-core.enabled: true`, the plugin won't load as the active memory provider unless `plugins.slots.memory = "memory-core"` is set. Without this, the gateway logs `memory-core: plugin disabled (memory slot set to "openclaw-mem0")` and falls back to whatever plugin previously held the slot. Fixed by setting `plugins.slots.memory = "memory-core"` during install.

#### Bug #4: FlipClaw plugins missing from `plugins.allow` list (Blocker)

On workspaces with a pre-existing `plugins.allow` list (allowlist mode for plugin loading), `memory-core`, `memory-bridge`, and `auto-skill-capture` were silently dropped because only `memory-wiki` was being added to the allow list by the installer. Gateway logs showed `plugins.entries.memory-bridge: plugin not found: memory-bridge (stale config entry ignored)`.

Fixed by extending the allow-list-append logic to cover all four FlipClaw plugins (`memory-core`, `memory-wiki`, `memory-bridge`, `auto-skill-capture`). Only enforces if an allow list is already configured — empty allow list in OpenClaw means "allow all" so we leave it alone.

#### Bug #5: Legacy `auth.profiles.*.primary` not auto-sanitized (Blocker)

OpenClaw 2026.4.9 rejects the legacy `auth.profiles.<name>.primary` field as "Unrecognized key", causing every CLI command to fail with a config validation error. `openclaw doctor --fix` doesn't strip this field. The installer previously left the key in place, so users hit the error on their first post-install CLI command. Fixed by auto-sanitizing the key from both configs during install.

#### Bug #6: Gemini API key requirement not documented (High)

The README listed OpenAI as the only required API key, which left users confused when `openclaw memory status` showed `Provider: none` after install. Memory search falls back to keyword-only without Gemini, and users didn't know why their search quality was poor.

Fixed by adding an explicit "API keys" section to the README Prerequisites that documents both OpenAI and Gemini keys with purposes, cost, and source URLs. Plus the installer now warns at pre-flight time if the Gemini key is missing.

#### Bug #7: No `--gemini-key` flag or auto-detect (Medium)

Related to Bug #6. Users had to manually edit `openclaw.json` to add the Gemini key after running the installer. Fixed by adding the `--gemini-key KEY` flag that writes the key directly into both workspace and state-dir configs (both `GEMINI_API_KEY` and `GOOGLE_AI_API_KEY` vars, since different parts of OpenClaw look at different names).

#### Bug #8: `ensure-dreaming-cron.sh` not tracked in the repo (High)

The workaround script for the dreaming cron reconciler bug existed locally during development but was never committed to the repo. Fresh clones from GitHub didn't include the script, and the installer's "install ensure-dreaming-cron.sh" step silently failed on fresh installs. Fixed by committing the script to `scripts/ensure-dreaming-cron.sh` in the repo.

#### Bug #9: `openclaw-mem0` not cleanly disabled (Medium)

Setting `plugins.entries.openclaw-mem0.enabled: false` prevented the plugin from activating but did NOT prevent OpenClaw's auto-discovery from scanning the physical extension directory at `$WORKSPACE/extensions/openclaw-mem0/` or `~/.openclaw/extensions/openclaw-mem0/`. The gateway printed "duplicate plugin id detected" warnings on every startup and the plugin still competed for the memory slot.

Fixed by moving any conflicting `openclaw-mem0` directories aside to `.disabled-openclaw-mem0-<timestamp>` BEFORE applying config changes, and fully removing `openclaw-mem0` from `plugins.entries` and `plugins.allow` instead of just flipping its `enabled` flag.

#### Bug #10: Health check SessionEnd hook parser false positive (Low)

`claude-code-update-check.sh` reported `SessionEnd hook — Hook exists but points to: NO COMMAND` when the settings.json used the newer nested matcher form:
```json
"SessionEnd": [{"hooks": [{"type": "command", "command": "..."}]}]
```
The parser only looked at `se[0].command` and missed the nested `se[0].hooks[0].command`. The hook actually worked fine — only the health check was confused.

Fixed by updating the parser to handle both flat and nested forms.

#### Bug #12: `plugins.load.paths` only set in state-dir config (Blocker)

**Discovered during Phase 3 testing** of the v3.2.1 installer on a throwaway agent. When the installer ran against a workspace with no state-dir config, `plugins.load.paths` never got set in the workspace config because line 822 gated that logic on `is_state_dir`. On gateway startup, the gateway couldn't find the memory-bridge or auto-skill-capture extensions at `$WORKSPACE/extensions/`, and the logs showed:
```
plugins.entries.memory-bridge: plugin not found: memory-bridge (stale config entry ignored)
plugins.entries.auto-skill-capture: plugin not found: auto-skill-capture (stale config entry ignored)
```

Fixed by removing the `is_state_dir` condition — both workspace and state-dir configs now get `plugins.load.paths` set to `$WORKSPACE/extensions`. Verified by re-running the Phase 3 test: the gateway now loads all 10 plugins including memory-bridge and auto-skill-capture, with explicit "started" log lines for both.

### Changed

- `install-memory.sh` now runs pre-flight checks before Step 1 and exits early on blockers
- `install-memory.sh` iterates plugin/config updates over both workspace and state-dir configs
- `install-memory.sh` moves aside conflicting `openclaw-mem0` extension directories before config changes
- `install-memory.sh` fully removes `openclaw-mem0` from `plugins.entries` and `plugins.allow` instead of setting `enabled: false`
- `install-memory.sh` strips legacy `auth.profiles.*.primary` fields from both configs
- `install-memory.sh` unconditionally sets `memory-core.enabled: true` when adding dreaming config
- `install-memory.sh` sets `plugins.slots.memory = "memory-core"` during install
- `install-memory.sh` adds `memory-core`, `memory-bridge`, `auto-skill-capture`, `memory-wiki` to `plugins.allow` if an allow list exists
- `install-memory.sh` accepts `--gemini-key` flag and writes it to env.vars
- `install-memory.sh` warns at pre-flight time if no Gemini API key is configured
- `install-memory.sh` installs `ensure-dreaming-cron.sh` to the workspace and registers the heal cron
- `install-memory.sh` sets `plugins.load.paths` in both workspace and state-dir configs (previously only state-dir)
- `scripts/claude-code-update-check.sh` SessionEnd hook parser handles both flat and nested hook formats
- `README.md` Prerequisites section now documents both OpenAI and Gemini API keys with cost and source info
- `README.md` new Troubleshooting & Known Issues section with quick-fix table

### Upstream issues documented

See [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md) for the full technical details on:

1. OpenClaw 2026.4.x dreaming cron reconciler bug (FlipClaw ships `ensure-dreaming-cron.sh` workaround)
2. Wiki bridge import returns 0 artifacts (manual `wiki ingest` workaround)
3. Legacy `auth.profiles.*.primary` not handled by `openclaw doctor --fix` (installer auto-sanitizes)
4. `openclaw-mem0` auto-discovery ignoring `enabled: false` (installer moves directory aside)
5. Two-config resolution behavior (installer syncs plugin config to both)

### Upgrade path from 3.2.0

Run the updater:
```bash
bash $WORKSPACE/scripts/flipclaw-update.sh
```

The updater will:
- Create a snapshot of your current scripts/extensions/state-files
- Download v3.2.1 from GitHub
- Apply the new scripts with your original install params
- Validate post-update (Python + shell syntax checks)
- Offer automatic rollback on validation failure

If your agent was affected by one or more of the 10 bugs, you'll also need to re-run the installer once after the updater (with `--skip-openclaw` if you want to preserve any manual config changes):
```bash
bash /path/to/flipclaw-clone/install.sh \
  --agent-name "YourAgent" \
  --workspace $WORKSPACE \
  --port YOUR_PORT
```
The v3.2.1 installer is idempotent — running it on an already-installed workspace only updates what needs updating.

---

## [3.2.0] — 2026-04-10

### Added

- **`flipclaw-update.sh`** — Self-service updater script, installed to `$WORKSPACE/scripts/`.  
  Reads saved install params, downloads the latest toolkit from GitHub, creates a full snapshot backup, and re-applies templates with your original values. No flags to remember.
  ```bash
  bash ~/myagent/scripts/flipclaw-update.sh                # Update to latest
  bash ~/myagent/scripts/flipclaw-update.sh --dry-run      # Preview changes first
  bash ~/myagent/scripts/flipclaw-update.sh --check        # Version check only
  bash ~/myagent/scripts/flipclaw-update.sh --rollback     # Restore previous version
  bash ~/myagent/scripts/flipclaw-update.sh --list-backups # Show all backups
  bash ~/myagent/scripts/flipclaw-update.sh --version 3.3.0 # Pin to specific version
  ```

- **`.flipclaw-install.json`** — Install params file written to `$WORKSPACE/` at install time.  
  Stores workspace path, agent name, port, Claude home, session source, all model choices, OpenClaw version, and update history. Required by `flipclaw-update.sh` to safely re-apply templates on update.

- **Unified backup system** (`.flipclaw-backups/`) — Every installer and updater run now creates a timestamped snapshot under `$WORKSPACE/.flipclaw-backups/v{version}-{timestamp}/` before making any changes. Snapshots include:
  - All installed scripts
  - Both extensions (memory-bridge, auto-skill-capture) including plugin manifests
  - State files (`.toolkit-version`, `.flipclaw-install.json`)
  - `openclaw.json` (for safety, even though the updater never modifies it)
  - `backup-meta.json` with version, timestamp, trigger, and OpenClaw version
  Retention: the 10 most recent backups are kept, older ones are auto-pruned.

- **`--rollback` flag** — One-command restore of the most recent backup. Before restoring, the updater snapshots the current (broken) state too, so a failed rollback is also recoverable.

- **`--list-backups` flag** — Shows all available backups with their version, timestamp, and trigger (`install-memory`, `install-claude-code`, `update`, `pre-rollback`).

- **Post-update validation** — After applying an update, the updater runs Python `py_compile` on all Python scripts and `bash -n` on all shell scripts. If any script fails validation, the user is prompted to automatically roll back. This catches broken updates before they affect the running system.

- **Automatic rollback offer on validation failure** — If the update leaves the installation in a broken state, pressing `Y` restores the pre-update snapshot immediately.

- **OpenClaw version check** — All three installers (`install-memory.sh`, `install-claude-code.sh`) and `flipclaw-update.sh` now verify that OpenClaw 2026.4.9 or later is installed before making any changes. Fresh installs fail early with a clear message if OpenClaw is missing or too old.

- **OpenClaw version tracking** — The installed OpenClaw version is recorded in `.flipclaw-install.json` at install time and updated during each run. Useful for debugging when users report issues months after install.

- **Update history** — `.flipclaw-install.json` now includes an `update_history` array tracking every version transition as `{from, to, at, openclaw_version, trigger}`. Limited to the last 50 entries.

- **Smart prompt template handling** — The updater now compares `curate-memory-prompt.md` and `index-daily-logs-prompt.md` against the previous backup to detect whether the user has modified them. Unmodified templates are updated automatically; user-modified templates are preserved and the new version is saved as `.new` alongside the original with a diff suggestion.

- **Retry on GitHub fetch** — Version and archive downloads now retry up to 3 times with backoff to handle transient network issues.

- **Version check in `claude-code-update-check.sh`** (check #10) — Automatically compares your installed FlipClaw version against the latest on GitHub during every health check. Prints a warning and the update command if a newer version is available. Also writes `/tmp/flipclaw-update-available` as a flag file for downstream surfacing.

- **OpenClaw version check in `claude-code-update-check.sh`** (check #11) — Verifies the installed OpenClaw version meets the minimum requirement. Fails loudly if OpenClaw is missing or below 2026.4.9.

### Changed

- `install-claude-code.sh` — Now installs `flipclaw-update.sh` during Step 2 (script installation).
- `install-claude-code.sh` — Now writes/merges `.flipclaw-install.json` during Step 7 with `openclaw_version` and `update_history`.
- `install-claude-code.sh` — Adds OpenClaw minimum version check before any modifications.
- `install-memory.sh` — Adds OpenClaw minimum version check before any modifications.
- `install-memory.sh` — Now creates a snapshot under `.flipclaw-backups/` in addition to the separate data backup (for `memory/`, `MEMORY.md`, `skills/`) in the parent directory.
- `install-memory.sh` — Now writes `.flipclaw-install.json` (with model params, OpenClaw version, and initial update history entry) during Step 7.
- `README.md` — Updated Prerequisites section to specify minimum OpenClaw version.
- `README.md` — Expanded Updating section to document `--rollback`, `--list-backups`, post-update validation, update history, and prompt template handling.
- Updater uses bash 3.2-compatible lowercase conversion (`tr` instead of `${var,,}`) for macOS compatibility.

### Fixed

- **`claude-code-update-check.sh` pre-existing bug:** `$WORKSPACE` and `$CLAUDE_HOME` were referenced throughout the script but never initialized. The script silently relied on the caller's environment having them set, which was unreliable. Now baked in at install time via template placeholders that the installer's sed substitution fills in.
- **Version comparison used string equality instead of semver** (check #10 and updater `--check`). This incorrectly reported "update available: 3.2.0 → 3.0.0" when the installed version was actually newer than main. Now uses `sort -V` for proper semver ordering and correctly distinguishes "update available," "up to date," and "ahead of main."
- **Fresh installs created a spurious `vunknown-{timestamp}` backup directory** because `.toolkit-version` didn't exist yet. The installer now detects fresh installs via an `IS_FRESH_INSTALL` flag and skips the rollback snapshot (nothing to snapshot) while still creating the data backup if any pre-existing memory files are present.
- **Missing refusal for accidental backward "update":** If the user ran the updater without `--version` and the remote happened to be older than installed, the updater would try to "update" backward. Now correctly reports "up to date" and suggests using `--version` for explicit downgrade.
- **Missing confirmation on explicit downgrade:** The updater had a warning but would still proceed when `--version` pinned to an older version. Now requires interactive `y/N` confirmation before proceeding with a downgrade.
- **Updater would fail on macOS default bash (3.2)** due to bash 4.x parameter expansion syntax (`${var,,}`) in the final "next steps" hint. Now uses `tr '[:upper:]' '[:lower:]'` which works on all bash versions.

### Prerequisites

**OpenClaw 2026.4.9 or later is required.** FlipClaw depends on built-in features only available in that version:
- `memory-core` Dreaming (light/deep/REM phases)
- `memory-wiki` plugin (bridge mode)
- `agents.defaults.contextInjection: continuation-skip`

Older OpenClaw versions will be rejected by all installers with a clear error message and upgrade instructions.

### Update path for existing installs (v3.0.0 / v3.1.0 → v3.2.0)

Re-run the installer with your original flags — it will verify OpenClaw version, snapshot the current state, update scripts, and preserve memory and config:

```bash
git clone https://github.com/bbesner/flipclaw.git flipclaw-new
cd flipclaw-new
bash install.sh \
  --agent-name "YourAgent" \
  --workspace /path/to/your/agent \
  --port YOUR_PORT \
  --skip-openclaw
```

After this, future updates can use `flipclaw-update.sh` directly with full rollback support.

---

## [3.1.0] — 2026-04-09

*Internal version — live system versioned ahead of toolkit. No functional changes from 3.0.0.*

---

## [3.0.0] — 2026-04-09

### Initial release

- Full memory pipeline: incremental capture, memory bridge, auto-skill-capture, Dreaming, Memory Wiki
- Claude Code integration: SessionEnd hook, bridge, sweep, turn capture, health check
- Combined installer (`install.sh`) with separate `install-memory.sh` and `install-claude-code.sh`
- MCP server for remote Claude Code access
- Colocated agent support (`--user` flag for installing across Linux accounts)
- Semantic search via Gemini hybrid search (70% vector + 30% keyword)
- `continuation-skip` context injection for token savings
