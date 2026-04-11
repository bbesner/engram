#!/bin/bash
# ============================================================================
# FlipClaw Updater
# Installed to: {{WORKSPACE}}/scripts/flipclaw-update.sh
#
# Safely updates all FlipClaw scripts and extensions to the latest version
# from GitHub while preserving your customizations (memory, config, openclaw.json).
#
# Usage:
#   bash {{WORKSPACE}}/scripts/flipclaw-update.sh              # Update to latest
#   bash {{WORKSPACE}}/scripts/flipclaw-update.sh --dry-run    # Preview changes
#   bash {{WORKSPACE}}/scripts/flipclaw-update.sh --version 3.3.0  # Pin to version
#   bash {{WORKSPACE}}/scripts/flipclaw-update.sh --check      # Version check only
#   bash {{WORKSPACE}}/scripts/flipclaw-update.sh --rollback   # Restore previous version
#   bash {{WORKSPACE}}/scripts/flipclaw-update.sh --list-backups
# ============================================================================

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WORKSPACE="{{WORKSPACE}}"
PARAMS_FILE="$WORKSPACE/.flipclaw-install.json"
VERSION_FILE="$WORKSPACE/.toolkit-version"
BACKUP_ROOT="$WORKSPACE/.flipclaw-backups"
GITHUB_REPO="bbesner/flipclaw"
GITHUB_RAW="https://raw.githubusercontent.com/$GITHUB_REPO/main"
GITHUB_ARCHIVE="https://github.com/$GITHUB_REPO/archive/refs/heads/main.tar.gz"

# Minimum OpenClaw version required for FlipClaw features (memory-core Dreaming,
# memory-wiki, continuation-skip)
MIN_OPENCLAW_VERSION="2026.4.9"

DRY_RUN=false
CHECK_ONLY=false
PIN_VERSION=""
ROLLBACK=false
LIST_BACKUPS=false

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --check)   CHECK_ONLY=true; shift ;;
        --version) PIN_VERSION="$2"; shift 2 ;;
        --rollback) ROLLBACK=true; shift ;;
        --list-backups) LIST_BACKUPS=true; shift ;;
        --help)
            cat << 'HELPEOF'
FlipClaw Updater

Usage:
  flipclaw-update.sh                Update to the latest version from GitHub
  flipclaw-update.sh --check        Check if an update is available (no changes)
  flipclaw-update.sh --dry-run      Preview what would change without applying
  flipclaw-update.sh --version X.Y.Z  Pin to a specific version (for downgrade or reinstall)
  flipclaw-update.sh --list-backups Show all available backups
  flipclaw-update.sh --rollback     Restore the most recent backup

Every run creates a timestamped backup under .flipclaw-backups/
before making any changes.
HELPEOF
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "========================================"
echo -e "${BLUE}FlipClaw Updater${NC}"
echo "$(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================"
echo ""

# ──────────────────────────────────────────────────────────────
# Shared helpers
# ──────────────────────────────────────────────────────────────

# Semver comparison — returns 0 if $1 >= $2
version_gte() {
    local a b
    a=$(echo "$1" | sed 's/^v//')
    b=$(echo "$2" | sed 's/^v//')
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$b" ]
}

get_openclaw_version() {
    local v
    v=$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "$v"
}

check_openclaw_version() {
    local installed
    installed=$(get_openclaw_version)
    if [ -z "$installed" ]; then
        echo -e "${YELLOW}WARNING:${NC} Could not detect OpenClaw version. Is OpenClaw installed?"
        return 1
    fi
    if version_gte "$installed" "$MIN_OPENCLAW_VERSION"; then
        echo -e "  OpenClaw: ${GREEN}$installed${NC} (min required: $MIN_OPENCLAW_VERSION)"
        return 0
    else
        echo -e "  OpenClaw: ${RED}$installed${NC} — minimum required: $MIN_OPENCLAW_VERSION"
        echo ""
        echo -e "${RED}ERROR: OpenClaw version too old.${NC}"
        echo "FlipClaw requires OpenClaw $MIN_OPENCLAW_VERSION or later for memory-core Dreaming,"
        echo "memory-wiki, and continuation-skip support."
        echo ""
        echo "Upgrade OpenClaw:"
        echo "  npm install -g openclaw@latest"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────
# --list-backups mode
# ──────────────────────────────────────────────────────────────

if [ "$LIST_BACKUPS" = true ]; then
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "No backups found."
        exit 0
    fi
    echo "Available backups in $BACKUP_ROOT:"
    echo ""
    ls -1t "$BACKUP_ROOT" 2>/dev/null | while read -r dir; do
        if [ -d "$BACKUP_ROOT/$dir" ]; then
            meta="$BACKUP_ROOT/$dir/backup-meta.json"
            if [ -f "$meta" ]; then
                from=$(python3 -c "import json; print(json.load(open('$meta')).get('version', 'unknown'))" 2>/dev/null)
                at=$(python3 -c "import json; print(json.load(open('$meta')).get('created_at', ''))" 2>/dev/null)
                trigger=$(python3 -c "import json; print(json.load(open('$meta')).get('trigger', ''))" 2>/dev/null)
                printf "  %s  (v%s, %s, %s)\n" "$dir" "$from" "$at" "$trigger"
            else
                printf "  %s\n" "$dir"
            fi
        fi
    done
    echo ""
    echo "Restore a backup with:"
    echo "  bash $WORKSPACE/scripts/flipclaw-update.sh --rollback"
    exit 0
fi

# ──────────────────────────────────────────────────────────────
# Load params (required for most operations)
# ──────────────────────────────────────────────────────────────

if [ ! -f "$PARAMS_FILE" ]; then
    echo -e "${RED}ERROR: .flipclaw-install.json not found at $PARAMS_FILE${NC}"
    echo ""
    echo "This file is written by the installer (v3.2.0+)."
    echo "If you installed an older version, re-run the installer with your original flags:"
    echo "  bash install.sh --agent-name NAME --workspace $WORKSPACE --port PORT"
    exit 1
fi

read_param() {
    python3 -c "import json; p=json.load(open('$PARAMS_FILE')); print(p.get('$1',''))" 2>/dev/null
}
read_model() {
    python3 -c "import json; p=json.load(open('$PARAMS_FILE')); print(p.get('models',{}).get('$1',''))" 2>/dev/null
}

AGENT_NAME=$(read_param agent_name)
PORT=$(read_param port)
CLAUDE_HOME=$(read_param claude_home)
USER_ID=$(read_param user_id)
SESSION_SOURCE=$(read_param session_source)
SHARED=$(read_param shared)
WITH_MCP=$(read_param with_mcp)
CAPTURE_MODEL=$(read_model capture_model)
CAPTURE_PROVIDER=$(read_model capture_provider)
WRITER_MODEL=$(read_model writer_model)
WRITER_PROVIDER=$(read_model writer_provider)
EXTRACTION_MODEL=$(read_model extraction_model)
GENERATION_MODEL=$(read_model generation_model)
SKILL_PROVIDER=$(read_model skill_provider)
EMBEDDING_PROVIDER=$(read_model embedding_provider)
EMBEDDING_MODEL=$(read_model embedding_model)

# Fallback defaults for older param files missing fields
CAPTURE_MODEL="${CAPTURE_MODEL:-gpt-5.4-nano}"
CAPTURE_PROVIDER="${CAPTURE_PROVIDER:-openai}"
WRITER_MODEL="${WRITER_MODEL:-gpt-5.4-mini}"
WRITER_PROVIDER="${WRITER_PROVIDER:-openai}"
EXTRACTION_MODEL="${EXTRACTION_MODEL:-gpt-5.4-mini}"
GENERATION_MODEL="${GENERATION_MODEL:-gpt-5.4-mini}"
SKILL_PROVIDER="${SKILL_PROVIDER:-openai}"
EMBEDDING_PROVIDER="${EMBEDDING_PROVIDER:-gemini}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-gemini-embedding-001}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SESSION_SOURCE="${SESSION_SOURCE:-claude-code}"

# ──────────────────────────────────────────────────────────────
# Snapshot function — used before any modification
# ──────────────────────────────────────────────────────────────

create_snapshot() {
    local trigger="$1"
    local version="$2"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local snap_dir="$BACKUP_ROOT/v${version}-${ts}"

    mkdir -p "$snap_dir/scripts" "$snap_dir/extensions"

    # Scripts
    for f in claude-code-bridge.py claude-code-sweep.py claude-code-turn-capture.py \
              claude-code-update-check.sh flipclaw-update.sh incremental-memory-capture.py \
              memory-writer.py lockutil.py curate-memory-prompt.md index-daily-logs-prompt.md; do
        [ -f "$WORKSPACE/scripts/$f" ] && cp "$WORKSPACE/scripts/$f" "$snap_dir/scripts/$f"
    done

    # Extensions
    if [ -d "$WORKSPACE/extensions/auto-skill-capture" ]; then
        mkdir -p "$snap_dir/extensions/auto-skill-capture/scripts"
        for f in index.ts openclaw.plugin.json package.json; do
            [ -f "$WORKSPACE/extensions/auto-skill-capture/$f" ] && \
                cp "$WORKSPACE/extensions/auto-skill-capture/$f" "$snap_dir/extensions/auto-skill-capture/$f"
        done
        [ -f "$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py" ] && \
            cp "$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py" \
               "$snap_dir/extensions/auto-skill-capture/scripts/skill-extractor.py"
    fi
    if [ -d "$WORKSPACE/extensions/memory-bridge" ]; then
        mkdir -p "$snap_dir/extensions/memory-bridge"
        for f in index.ts openclaw.plugin.json; do
            [ -f "$WORKSPACE/extensions/memory-bridge/$f" ] && \
                cp "$WORKSPACE/extensions/memory-bridge/$f" "$snap_dir/extensions/memory-bridge/$f"
        done
    fi

    # State files
    [ -f "$VERSION_FILE" ] && cp "$VERSION_FILE" "$snap_dir/.toolkit-version"
    [ -f "$PARAMS_FILE" ] && cp "$PARAMS_FILE" "$snap_dir/.flipclaw-install.json"
    # openclaw.json — snapshot for safety even though updater shouldn't touch it
    [ -f "$WORKSPACE/openclaw.json" ] && cp "$WORKSPACE/openclaw.json" "$snap_dir/openclaw.json"

    # Metadata
    python3 - << PYEOF
import json
from datetime import datetime, timezone
meta = {
    'version': '$version',
    'created_at': datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC'),
    'trigger': '$trigger',
    'workspace': '$WORKSPACE',
    'openclaw_version': '$(get_openclaw_version)',
}
with open('$snap_dir/backup-meta.json', 'w') as f:
    json.dump(meta, f, indent=2)
PYEOF

    # Prune old backups — keep last 10
    if [ -d "$BACKUP_ROOT" ]; then
        ls -1t "$BACKUP_ROOT" 2>/dev/null | tail -n +11 | while read -r old; do
            rm -rf "$BACKUP_ROOT/$old" 2>/dev/null
        done
    fi

    echo "$snap_dir"
}

# ──────────────────────────────────────────────────────────────
# --rollback mode
# ──────────────────────────────────────────────────────────────

if [ "$ROLLBACK" = true ]; then
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo -e "${RED}ERROR: No backups directory found at $BACKUP_ROOT${NC}"
        exit 1
    fi

    # Find most recent backup
    LATEST_BACKUP=$(ls -1t "$BACKUP_ROOT" 2>/dev/null | head -1)
    if [ -z "$LATEST_BACKUP" ]; then
        echo -e "${RED}ERROR: No backups found${NC}"
        exit 1
    fi

    SNAP_DIR="$BACKUP_ROOT/$LATEST_BACKUP"
    META="$SNAP_DIR/backup-meta.json"

    if [ -f "$META" ]; then
        FROM_VER=$(python3 -c "import json; print(json.load(open('$META')).get('version', 'unknown'))")
        CREATED=$(python3 -c "import json; print(json.load(open('$META')).get('created_at', ''))")
        echo "Most recent backup:"
        echo "  Path:    $SNAP_DIR"
        echo "  Version: $FROM_VER"
        echo "  Created: $CREATED"
    else
        echo "Most recent backup: $SNAP_DIR"
    fi
    echo ""

    if [ "$DRY_RUN" = false ]; then
        # Before restoring, snapshot the CURRENT state in case rollback goes wrong
        CURRENT_VER=$(cat "$VERSION_FILE" 2>/dev/null | head -1 || echo "unknown")
        echo -e "${BLUE}Snapshotting current state before rollback...${NC}"
        SAFETY_SNAP=$(create_snapshot "pre-rollback" "$CURRENT_VER")
        echo "  Saved: $SAFETY_SNAP"
        echo ""
    fi

    read -p "Restore this backup? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Rollback cancelled."
        exit 0
    fi

    echo ""
    echo -e "${BLUE}Restoring...${NC}"

    # Restore scripts
    if [ -d "$SNAP_DIR/scripts" ]; then
        for f in "$SNAP_DIR/scripts"/*; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            cp "$f" "$WORKSPACE/scripts/$base"
            chmod +x "$WORKSPACE/scripts/$base" 2>/dev/null
            echo "  Restored: scripts/$base"
        done
    fi

    # Restore extensions
    if [ -d "$SNAP_DIR/extensions/auto-skill-capture" ]; then
        for f in "$SNAP_DIR/extensions/auto-skill-capture"/*.ts \
                 "$SNAP_DIR/extensions/auto-skill-capture"/*.json; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            cp "$f" "$WORKSPACE/extensions/auto-skill-capture/$base"
            echo "  Restored: extensions/auto-skill-capture/$base"
        done
        if [ -f "$SNAP_DIR/extensions/auto-skill-capture/scripts/skill-extractor.py" ]; then
            cp "$SNAP_DIR/extensions/auto-skill-capture/scripts/skill-extractor.py" \
               "$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py"
            chmod +x "$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py"
            echo "  Restored: extensions/auto-skill-capture/scripts/skill-extractor.py"
        fi
    fi
    if [ -d "$SNAP_DIR/extensions/memory-bridge" ]; then
        for f in "$SNAP_DIR/extensions/memory-bridge"/*; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            cp "$f" "$WORKSPACE/extensions/memory-bridge/$base"
            echo "  Restored: extensions/memory-bridge/$base"
        done
    fi

    # Restore state files
    [ -f "$SNAP_DIR/.toolkit-version" ] && cp "$SNAP_DIR/.toolkit-version" "$VERSION_FILE" && echo "  Restored: .toolkit-version"
    [ -f "$SNAP_DIR/.flipclaw-install.json" ] && cp "$SNAP_DIR/.flipclaw-install.json" "$PARAMS_FILE" && echo "  Restored: .flipclaw-install.json"

    echo ""
    AGENT_NAME_LOWER=$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]')
    echo -e "${GREEN}Rollback complete.${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Restart the OpenClaw gateway:  pm2 restart ${AGENT_NAME_LOWER}"
    echo "  2. Run health check:              bash $WORKSPACE/scripts/claude-code-update-check.sh"
    exit 0
fi

# ──────────────────────────────────────────────────────────────
# Step 0: Verify OpenClaw version
# ──────────────────────────────────────────────────────────────

echo -e "${BLUE}Step 0: Prerequisites${NC}"
if ! check_openclaw_version; then
    exit 1
fi
echo "  Agent:     $AGENT_NAME"
echo "  Workspace: $WORKSPACE"
echo "  Port:      $PORT"
echo ""

# ──────────────────────────────────────────────────────────────
# Step 1: Check versions
# ──────────────────────────────────────────────────────────────

echo -e "${BLUE}Step 1: Version check${NC}"

INSTALLED_VERSION=$(cat "$VERSION_FILE" 2>/dev/null | head -1 || echo "unknown")

if [ -n "$PIN_VERSION" ]; then
    LATEST_VERSION="$PIN_VERSION"
    echo "  Pinning to version: $LATEST_VERSION"
else
    echo -n "  Checking GitHub for latest version... "
    # Retry up to 3 times for transient failures
    LATEST_VERSION=""
    for attempt in 1 2 3; do
        LATEST_VERSION=$(curl -sf --max-time 10 "$GITHUB_RAW/VERSION" 2>/dev/null | head -1)
        [ -n "$LATEST_VERSION" ] && break
        sleep 2
    done
    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${RED}FAILED${NC}"
        echo "  Could not reach GitHub after 3 attempts. Check your internet connection."
        exit 1
    fi
    echo "$LATEST_VERSION"
fi

echo "  Installed: $INSTALLED_VERSION"
echo "  Latest:    $LATEST_VERSION"
echo ""

# Determine update direction (only matters when not pinning)
UPDATE_DIRECTION="same"
if [ "$INSTALLED_VERSION" != "$LATEST_VERSION" ]; then
    if version_gte "$LATEST_VERSION" "$INSTALLED_VERSION"; then
        UPDATE_DIRECTION="newer"
    else
        UPDATE_DIRECTION="older"
    fi
fi

if [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ] && [ "$CHECK_ONLY" = false ] && [ -z "$PIN_VERSION" ]; then
    echo -e "${GREEN}Already up to date ($INSTALLED_VERSION). Nothing to do.${NC}"
    echo ""
    echo "To force a reinstall of the current version:"
    echo "  bash $WORKSPACE/scripts/flipclaw-update.sh --version $INSTALLED_VERSION"
    exit 0
fi

if [ "$CHECK_ONLY" = true ]; then
    case "$UPDATE_DIRECTION" in
        newer)
            echo -e "${YELLOW}Update available: $INSTALLED_VERSION → $LATEST_VERSION${NC}"
            echo ""
            echo "Run to update:"
            echo "  bash $WORKSPACE/scripts/flipclaw-update.sh"
            touch /tmp/flipclaw-update-available 2>/dev/null
            ;;
        older)
            echo -e "${GREEN}Up to date ($INSTALLED_VERSION)${NC}"
            echo "  (remote is $LATEST_VERSION — you are ahead of main)"
            ;;
        same)
            echo -e "${GREEN}Up to date ($INSTALLED_VERSION)${NC}"
            ;;
    esac
    exit 0
fi

# If remote is older and we're not pinning, refuse to "update" backward
if [ "$UPDATE_DIRECTION" = "older" ] && [ -z "$PIN_VERSION" ]; then
    echo -e "${GREEN}Already up to date ($INSTALLED_VERSION is newer than remote $LATEST_VERSION)${NC}"
    echo ""
    echo "To explicitly downgrade, use:"
    echo "  bash $WORKSPACE/scripts/flipclaw-update.sh --version $LATEST_VERSION"
    exit 0
fi

# Warn if user is explicitly downgrading via --version
if [ -n "$PIN_VERSION" ] && ! version_gte "$LATEST_VERSION" "$INSTALLED_VERSION"; then
    echo -e "${YELLOW}WARNING: You are downgrading from $INSTALLED_VERSION to $LATEST_VERSION${NC}"
    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

if [ "$DRY_RUN" = false ]; then
    echo -e "${BLUE}Updating $INSTALLED_VERSION → $LATEST_VERSION${NC}"
else
    echo -e "${YELLOW}DRY RUN — showing what would change ($INSTALLED_VERSION → $LATEST_VERSION)${NC}"
fi
echo ""

# ──────────────────────────────────────────────────────────────
# Step 2: Download latest toolkit
# ──────────────────────────────────────────────────────────────

echo -e "${BLUE}Step 2: Download toolkit${NC}"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

if [ -n "$PIN_VERSION" ]; then
    ARCHIVE_URL="https://github.com/$GITHUB_REPO/archive/refs/tags/v${PIN_VERSION}.tar.gz"
else
    ARCHIVE_URL="$GITHUB_ARCHIVE"
fi

echo -n "  Downloading from GitHub... "
if ! curl -sL --max-time 60 "$ARCHIVE_URL" | tar xz -C "$TMPDIR" --strip-components=1 2>/dev/null; then
    echo -e "${RED}FAILED${NC}"
    echo "  Could not download toolkit. Check your internet connection or the version tag."
    exit 1
fi
echo "OK"

TOOLKIT_DIR="$TMPDIR"
DOWNLOADED_VERSION=$(cat "$TOOLKIT_DIR/VERSION" 2>/dev/null | head -1 || echo "unknown")
echo "  Downloaded version: $DOWNLOADED_VERSION"
echo ""

# ──────────────────────────────────────────────────────────────
# Step 3: Create full snapshot
# ──────────────────────────────────────────────────────────────

echo -e "${BLUE}Step 3: Snapshot current state${NC}"

if [ "$DRY_RUN" = false ]; then
    BACKUP_DIR=$(create_snapshot "update" "$INSTALLED_VERSION")
    echo "  Backup: $BACKUP_DIR"
    # Count what was backed up
    SCRIPT_COUNT=$(ls -1 "$BACKUP_DIR/scripts" 2>/dev/null | wc -l)
    EXT_COUNT=$(find "$BACKUP_DIR/extensions" -type f 2>/dev/null | wc -l)
    echo "  Includes: $SCRIPT_COUNT scripts, $EXT_COUNT extension files, + state files"
else
    echo "  Would create snapshot at: $BACKUP_ROOT/v${INSTALLED_VERSION}-<timestamp>/"
fi
echo ""

# ──────────────────────────────────────────────────────────────
# Step 4: Re-apply scripts with saved params
# ──────────────────────────────────────────────────────────────

echo -e "${BLUE}Step 4: Apply updated scripts${NC}"

# Hash function for detecting user-modified prompt templates
file_hash() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

apply_script() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [ ! -f "$src" ]; then
        echo "  SKIP (not in this release): $label"
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        if diff -q "$src" "$dst" > /dev/null 2>&1; then
            echo "  UNCHANGED: $label"
        else
            echo "  WOULD UPDATE: $label"
        fi
        return
    fi

    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|{{SESSION_SOURCE}}|$SESSION_SOURCE|g" \
        -e "s|{{RATE_LIMIT}}|20|g" \
        -e "s|{{CLAUDE_HOME}}|$CLAUDE_HOME|g" \
        -e "s|{{AGENT_NAME}}|$AGENT_NAME|g" \
        -e "s|{{PORT}}|$PORT|g" \
        "$src" > "$dst"
    chmod +x "$dst"
    echo "  Updated: $label"
}

apply_model_script() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [ ! -f "$src" ]; then
        echo "  SKIP (not in this release): $label"
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "  WOULD UPDATE: $label"
        return
    fi

    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|{{SESSION_SOURCE}}|$SESSION_SOURCE|g" \
        -e "s|MODEL = \"gpt-5.4-nano\"|MODEL = \"$CAPTURE_MODEL\"|g" \
        -e "s|PROVIDER = \"openai\"|PROVIDER = \"$CAPTURE_PROVIDER\"|g" \
        "$src" > "$dst"
    chmod +x "$dst"
    echo "  Updated: $label"
}

# Claude Code integration scripts
apply_script "$TOOLKIT_DIR/scripts/claude-code-bridge.py"       "$WORKSPACE/scripts/claude-code-bridge.py"       "claude-code-bridge.py"
apply_script "$TOOLKIT_DIR/scripts/claude-code-sweep.py"        "$WORKSPACE/scripts/claude-code-sweep.py"        "claude-code-sweep.py"
apply_script "$TOOLKIT_DIR/scripts/claude-code-turn-capture.py" "$WORKSPACE/scripts/claude-code-turn-capture.py" "claude-code-turn-capture.py"
apply_script "$TOOLKIT_DIR/scripts/claude-code-update-check.sh" "$WORKSPACE/scripts/claude-code-update-check.sh" "claude-code-update-check.sh"
apply_script "$TOOLKIT_DIR/scripts/flipclaw-update.sh"          "$WORKSPACE/scripts/flipclaw-update.sh"          "flipclaw-update.sh (self)"
apply_script "$TOOLKIT_DIR/scripts/lockutil.py"                 "$WORKSPACE/scripts/lockutil.py"                 "lockutil.py"
apply_script "$TOOLKIT_DIR/scripts/apply-upstream-patches.sh"   "$WORKSPACE/scripts/apply-upstream-patches.sh"   "apply-upstream-patches.sh"

# Patch registry (plain JSON — no template substitution, so bypass apply_script)
if [ -f "$TOOLKIT_DIR/scripts/upstream-patches.json" ]; then
    if [ "$DRY_RUN" = true ]; then
        if diff -q "$TOOLKIT_DIR/scripts/upstream-patches.json" "$WORKSPACE/scripts/upstream-patches.json" >/dev/null 2>&1; then
            echo "  UNCHANGED: upstream-patches.json"
        else
            echo "  WOULD UPDATE: upstream-patches.json"
        fi
    else
        cp "$TOOLKIT_DIR/scripts/upstream-patches.json" "$WORKSPACE/scripts/upstream-patches.json"
        echo "  Updated: upstream-patches.json"
    fi
fi

# Memory pipeline scripts
apply_model_script "$TOOLKIT_DIR/scripts/incremental-memory-capture.py" \
    "$WORKSPACE/scripts/incremental-memory-capture.py" "incremental-memory-capture.py"

if [ "$DRY_RUN" = false ]; then
    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|MODEL = \"claude-sonnet-4-6\"|MODEL = \"$WRITER_MODEL\"|g" \
        "$TOOLKIT_DIR/scripts/memory-writer.py" > "$WORKSPACE/scripts/memory-writer.py"
    chmod +x "$WORKSPACE/scripts/memory-writer.py"
    echo "  Updated: memory-writer.py (legacy manual backfill)"
else
    echo "  WOULD UPDATE: memory-writer.py"
fi

# Skill extractor
EXT_SCRIPT="$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py"
if [ -f "$TOOLKIT_DIR/scripts/skill-extractor.py" ]; then
    if [ "$DRY_RUN" = false ]; then
        sed "s|{{WORKSPACE}}|$WORKSPACE|g" \
            "$TOOLKIT_DIR/scripts/skill-extractor.py" > "$EXT_SCRIPT"
        chmod +x "$EXT_SCRIPT"
        echo "  Updated: skill-extractor.py"
    else
        echo "  WOULD UPDATE: skill-extractor.py"
    fi
fi

# Prompt templates — check if user has modified them
# If unmodified from source (or missing), update silently
# If modified, preserve and surface a diff suggestion
for tmpl in curate-memory-prompt.md index-daily-logs-prompt.md; do
    src="$TOOLKIT_DIR/scripts/$tmpl"
    dst="$WORKSPACE/scripts/$tmpl"

    if [ ! -f "$src" ]; then
        continue
    fi

    if [ ! -f "$dst" ]; then
        # Missing — install fresh
        if [ "$DRY_RUN" = false ]; then
            sed "s|{{WORKSPACE}}|$WORKSPACE|g" "$src" > "$dst"
            echo "  Installed (missing): $tmpl"
        else
            echo "  WOULD INSTALL (missing): $tmpl"
        fi
        continue
    fi

    # Render source with substitutions to temp file for fair comparison
    RENDERED=$(mktemp)
    sed "s|{{WORKSPACE}}|$WORKSPACE|g" "$src" > "$RENDERED"

    # Also check against the backed-up previous version to detect user modifications
    PREV_BACKUP="$BACKUP_DIR/scripts/$tmpl"

    if diff -q "$RENDERED" "$dst" > /dev/null 2>&1; then
        # Already up to date
        echo "  UNCHANGED: $tmpl"
    elif [ -f "$PREV_BACKUP" ] && diff -q "$PREV_BACKUP" "$dst" > /dev/null 2>&1; then
        # User hasn't touched the previous version — safe to update
        if [ "$DRY_RUN" = false ]; then
            cp "$RENDERED" "$dst"
            echo "  Updated (unmodified by user): $tmpl"
        else
            echo "  WOULD UPDATE (unmodified by user): $tmpl"
        fi
    else
        # User has modified it — preserve and notify
        if [ "$DRY_RUN" = false ]; then
            NEW_VERSION_PATH="$dst.new"
            cp "$RENDERED" "$NEW_VERSION_PATH"
            echo -e "  ${YELLOW}PRESERVED (user-modified): $tmpl${NC}"
            echo "    New version available at: $NEW_VERSION_PATH"
            echo "    Review with: diff $dst $NEW_VERSION_PATH"
        else
            echo "  WOULD PRESERVE (user-modified): $tmpl"
        fi
    fi
    rm -f "$RENDERED"
done

echo ""

# ──────────────────────────────────────────────────────────────
# Step 5: Update extension files
# ──────────────────────────────────────────────────────────────

echo -e "${BLUE}Step 5: Extensions${NC}"

EXT_SRC="$TOOLKIT_DIR/extensions/auto-skill-capture"
EXT_DST="$WORKSPACE/extensions/auto-skill-capture"

for f in index.ts openclaw.plugin.json package.json; do
    if [ -f "$EXT_SRC/$f" ]; then
        if [ "$DRY_RUN" = false ]; then
            sed "s|{{WORKSPACE}}|$WORKSPACE|g" "$EXT_SRC/$f" > "$EXT_DST/$f"
            echo "  Updated: auto-skill-capture/$f"
        else
            echo "  WOULD UPDATE: auto-skill-capture/$f"
        fi
    fi
done

MEM_SRC="$TOOLKIT_DIR/extensions/memory-bridge"
MEM_DST="$WORKSPACE/extensions/memory-bridge"
if [ -d "$MEM_SRC" ]; then
    for f in index.ts openclaw.plugin.json; do
        if [ -f "$MEM_SRC/$f" ]; then
            if [ "$DRY_RUN" = false ]; then
                sed "s|{{WORKSPACE}}|$WORKSPACE|g" "$MEM_SRC/$f" > "$MEM_DST/$f"
                echo "  Updated: memory-bridge/$f"
            else
                echo "  WOULD UPDATE: memory-bridge/$f"
            fi
        fi
    done
fi

echo ""

# ──────────────────────────────────────────────────────────────
# Step 6: Update version marker + install params + history
# ──────────────────────────────────────────────────────────────

echo -e "${BLUE}Step 6: Finalize${NC}"

if [ "$DRY_RUN" = false ]; then
    echo "$DOWNLOADED_VERSION" > "$VERSION_FILE"
    echo "  Updated .toolkit-version: $INSTALLED_VERSION → $DOWNLOADED_VERSION"

    # Update version + append to update history in install params
    OPENCLAW_NOW=$(get_openclaw_version)
    python3 - << PYEOF
import json
from datetime import datetime, timezone

with open('$PARAMS_FILE') as f:
    p = json.load(f)

p['flipclaw_version'] = '$DOWNLOADED_VERSION'
p['openclaw_version'] = '$OPENCLAW_NOW'

history = p.get('update_history', [])
history.append({
    'from': '$INSTALLED_VERSION',
    'to': '$DOWNLOADED_VERSION',
    'at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'openclaw_version': '$OPENCLAW_NOW',
    'trigger': 'updater',
})
# Keep last 50 history entries
p['update_history'] = history[-50:]

with open('$PARAMS_FILE', 'w') as f:
    json.dump(p, f, indent=2)
PYEOF
    echo "  Updated .flipclaw-install.json (version, openclaw_version, update_history)"

    # Clear any pending update flag
    rm -f /tmp/flipclaw-update-available 2>/dev/null
else
    echo "  Would update .toolkit-version: $INSTALLED_VERSION → $DOWNLOADED_VERSION"
    echo "  Would update .flipclaw-install.json (version + update_history)"
fi

echo ""

# ──────────────────────────────────────────────────────────────
# Step 7: Post-update validation
# ──────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = false ]; then
    echo -e "${BLUE}Step 7: Post-update validation${NC}"

    VALIDATION_FAIL=0

    # Check critical scripts exist and are executable
    for f in claude-code-bridge.py claude-code-sweep.py claude-code-turn-capture.py \
              claude-code-update-check.sh flipclaw-update.sh lockutil.py \
              incremental-memory-capture.py; do
        if [ ! -x "$WORKSPACE/scripts/$f" ]; then
            echo -e "  ${RED}FAIL${NC}: $f missing or not executable"
            VALIDATION_FAIL=$((VALIDATION_FAIL + 1))
        fi
    done

    # Python scripts should parse
    for f in claude-code-bridge.py claude-code-sweep.py claude-code-turn-capture.py \
              lockutil.py incremental-memory-capture.py; do
        if [ -f "$WORKSPACE/scripts/$f" ]; then
            if ! python3 -m py_compile "$WORKSPACE/scripts/$f" 2>/dev/null; then
                echo -e "  ${RED}FAIL${NC}: $f has Python syntax errors"
                VALIDATION_FAIL=$((VALIDATION_FAIL + 1))
            fi
        fi
    done

    # Shell scripts should pass syntax check
    for f in claude-code-update-check.sh flipclaw-update.sh; do
        if [ -f "$WORKSPACE/scripts/$f" ]; then
            if ! bash -n "$WORKSPACE/scripts/$f" 2>/dev/null; then
                echo -e "  ${RED}FAIL${NC}: $f has shell syntax errors"
                VALIDATION_FAIL=$((VALIDATION_FAIL + 1))
            fi
        fi
    done

    # Skill extractor
    EXT_PY="$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py"
    if [ -f "$EXT_PY" ]; then
        if ! python3 -m py_compile "$EXT_PY" 2>/dev/null; then
            echo -e "  ${RED}FAIL${NC}: skill-extractor.py has Python syntax errors"
            VALIDATION_FAIL=$((VALIDATION_FAIL + 1))
        fi
    fi

    if [ "$VALIDATION_FAIL" -eq 0 ]; then
        echo -e "  ${GREEN}All validation checks passed${NC}"
    else
        echo ""
        echo -e "${RED}Validation failed ($VALIDATION_FAIL issue(s) detected)${NC}"
        echo ""
        echo "The update may have left your installation in a broken state."
        read -p "Rollback now? (Y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo ""
            echo "Restoring backup..."
            # Restore from the snapshot we just created
            for f in "$BACKUP_DIR/scripts"/*; do
                [ -f "$f" ] || continue
                base=$(basename "$f")
                cp "$f" "$WORKSPACE/scripts/$base"
                chmod +x "$WORKSPACE/scripts/$base" 2>/dev/null
            done
            [ -f "$BACKUP_DIR/.toolkit-version" ] && cp "$BACKUP_DIR/.toolkit-version" "$VERSION_FILE"
            [ -f "$BACKUP_DIR/.flipclaw-install.json" ] && cp "$BACKUP_DIR/.flipclaw-install.json" "$PARAMS_FILE"
            echo -e "${GREEN}Rollback complete.${NC} You are back on $INSTALLED_VERSION."
            echo ""
            echo "Please report this issue at:"
            echo "  https://github.com/$GITHUB_REPO/issues"
            exit 1
        else
            echo ""
            echo -e "${YELLOW}Leaving broken state in place. Manual recovery:${NC}"
            echo "  bash $WORKSPACE/scripts/flipclaw-update.sh --rollback"
            exit 1
        fi
    fi
    echo ""
fi

# ──────────────────────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────
# Step 8: Reconcile upstream patch registry
# ──────────────────────────────────────────────────────────────
#
# Re-evaluate scripts/upstream-patches.json against the user's current
# OpenClaw version. An OpenClaw upgrade between installs may have landed
# fixes for bugs FlipClaw was working around, in which case this step
# cleanly removes the now-obsolete workaround scripts and cron jobs.

if [ "$DRY_RUN" = false ] && [ -x "$WORKSPACE/scripts/apply-upstream-patches.sh" ]; then
    echo ""
    echo -e "${BLUE}Step 8: Upstream patch reconciliation${NC}"
    PORT_FOR_PATCHES=$(python3 -c "
import json
try:
    with open('$WORKSPACE/openclaw.json') as f:
        d = json.load(f)
    print(d.get('gateway', {}).get('port') or d.get('port') or '3050')
except Exception:
    print('3050')
" 2>/dev/null)
    bash "$WORKSPACE/scripts/apply-upstream-patches.sh" \
        --workspace "$WORKSPACE" \
        --port "$PORT_FOR_PATCHES" || {
        echo -e "${YELLOW}[WARN]${NC} patch reconciliation reported failures — update itself was successful"
    }
fi

echo "========================================"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN complete — no changes made${NC}"
    echo ""
    echo "Run without --dry-run to apply the update."
else
    echo -e "${GREEN}Update complete: $INSTALLED_VERSION → $DOWNLOADED_VERSION${NC}"
    echo ""
    echo "Next steps:"
    AGENT_NAME_LOWER=$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]')
    echo "  1. Restart the OpenClaw gateway:  pm2 restart ${AGENT_NAME_LOWER}"
    echo "  2. Run health check:              bash $WORKSPACE/scripts/claude-code-update-check.sh"
    echo ""
    echo "If anything looks wrong:"
    echo "  bash $WORKSPACE/scripts/flipclaw-update.sh --rollback"
    echo ""
    echo "Backup saved at:"
    echo "  $BACKUP_DIR"
fi
echo "========================================"
