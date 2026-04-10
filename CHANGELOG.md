# Changelog

All notable changes to FlipClaw are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).  
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- Multi-user shared workspace support (Linux + macOS)
- Semantic search via Gemini hybrid search (70% vector + 30% keyword)
- `continuation-skip` context injection for token savings
