#!/bin/bash
# ============================================================================
# Memory System Installer
# Version: 3.2.0 (2026-04-10)
#
# Installs the complete file-based memory pipeline for an OpenClaw agent:
#   - Incremental memory capture (per-turn fact extraction)
#   - Memory bridge extension (triggers capture on agent_end)
#   - Auto-skill-capture extension (generates skills from sessions)
#   - Semantic search configuration (Gemini hybrid search)
#   - memory-core Dreaming (consolidation, dedup, MEMORY.md promotion)
#   - Memory Wiki (bridge mode, organized knowledge view)
#   - Prompt templates for LLM-driven curation (manual use only)
#
# NOTE: As of v3.0.0, memory-writer.py, curation cron, and reindex cron are
# no longer installed as active cron jobs. Dreaming handles consolidation and
# MEMORY.md promotion. memory-writer.py is kept for manual backfill only.
#
# Handles migration from existing memory systems (Mem0, LanceDB).
# Never deletes or overwrites existing memory files.
#
# Usage:
#   bash install-memory.sh --agent-name "MyAgent" --workspace /home/user/agent --port 3050
#   bash install-memory.sh --agent-name "Bot" --workspace /path --port 3050 --capture-model gpt-5.4-nano
#   bash install-memory.sh --dry-run --agent-name "Test" --workspace /tmp/test --port 9999
#
# ============================================================================

set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# OS detection
OS="$(uname -s)"
case "$OS" in
    Darwin) IS_MACOS=true ;;
    *)      IS_MACOS=false ;;
esac

# Portable readlink
resolve_path() {
    local target="$1"
    cd "$(dirname "$target")" 2>/dev/null || return 1
    target="$(basename "$target")"
    while [ -L "$target" ]; do
        target="$(readlink "$target")"
        cd "$(dirname "$target")" 2>/dev/null || return 1
        target="$(basename "$target")"
    done
    echo "$(pwd -P)/$target"
}

TOOLKIT_DIR="$(cd "$(dirname "$(resolve_path "$0")")" && pwd)"
TOOLKIT_VERSION="$(head -1 "$TOOLKIT_DIR/VERSION")"

# Defaults
AGENT_NAME=""
WORKSPACE=""
PORT=""
DRY_RUN=false
SKIP_OPENCLAW_CONFIG=false
GROUP=""

# Model defaults (configurable)
CAPTURE_MODEL="gpt-5.4-nano"
CAPTURE_PROVIDER="openai"
WRITER_MODEL="gpt-5.4-mini"
WRITER_PROVIDER="openai"
EXTRACTION_MODEL="gpt-5.4-mini"
GENERATION_MODEL="gpt-5.4-mini"
SKILL_PROVIDER="openai"
EMBEDDING_PROVIDER="gemini"
EMBEDDING_MODEL="gemini-embedding-001"

# API keys (v3.2.1 addition)
GEMINI_KEY=""

usage() {
    echo "Usage: bash install-memory.sh [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  --agent-name NAME        Name of the OpenClaw agent"
    echo "  --workspace PATH         Absolute path to the agent workspace"
    echo "  --port PORT              OpenClaw gateway port number"
    echo ""
    echo "Model configuration (optional — sensible defaults provided):"
    echo "  --capture-model MODEL    Incremental capture model (default: gpt-5.4-nano)"
    echo "  --capture-provider PROV  Provider for capture: openai|anthropic (default: openai)"
    echo "  --writer-model MODEL     Memory writer model (default: gpt-5.4-mini)"
    echo "  --writer-provider PROV   Provider for writer: openai|anthropic (default: openai)"
    echo "  --extraction-model MODEL Skill extraction model (default: gpt-5.4-mini)"
    echo "  --generation-model MODEL Skill generation model (default: gpt-5.4-mini)"
    echo "  --embedding-provider P   Embedding provider: gemini|openai (default: gemini)"
    echo "  --embedding-model MODEL  Embedding model (default: gemini-embedding-001)"
    echo ""
    echo "API keys (optional — can also be set directly in openclaw.json env.vars):"
    echo "  --gemini-key KEY         Gemini API key (required for hybrid semantic search)"
    echo "                           Get a free key at https://aistudio.google.com/apikey"
    echo ""
    echo "Multi-user options:"
    echo "  --group GROUP            Set group ownership and setgid on workspace directories"
    echo "                           Use when the gateway runs as a different user than the"
    echo "                           workspace owner (e.g., ubuntu installing for e1/e2/e3)"
    echo ""
    echo "Other options:"
    echo "  --skip-openclaw          Skip OpenClaw config changes"
    echo "  --dry-run                Show what would be done without making changes"
    echo "  --help                   Show this help"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent-name) AGENT_NAME="$2"; shift 2 ;;
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --capture-model) CAPTURE_MODEL="$2"; shift 2 ;;
        --capture-provider) CAPTURE_PROVIDER="$2"; shift 2 ;;
        --writer-model) WRITER_MODEL="$2"; shift 2 ;;
        --writer-provider) WRITER_PROVIDER="$2"; shift 2 ;;
        --extraction-model) EXTRACTION_MODEL="$2"; shift 2 ;;
        --generation-model) GENERATION_MODEL="$2"; shift 2 ;;
        --embedding-provider) EMBEDDING_PROVIDER="$2"; shift 2 ;;
        --embedding-model) EMBEDDING_MODEL="$2"; shift 2 ;;
        --gemini-key) GEMINI_KEY="$2"; shift 2 ;;
        --group) GROUP="$2"; shift 2 ;;
        --skip-openclaw) SKIP_OPENCLAW_CONFIG=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$AGENT_NAME" ] || [ -z "$WORKSPACE" ] || [ -z "$PORT" ]; then
    echo -e "${RED}Missing required arguments: --agent-name, --workspace, --port${NC}"
    echo ""
    usage
fi

# ──────────────────────────────────────────────────────────────
# Prerequisite: OpenClaw minimum version
# ──────────────────────────────────────────────────────────────

MIN_OPENCLAW_VERSION="2026.4.9"

version_gte() {
    local a b
    a=$(echo "$1" | sed 's/^v//')
    b=$(echo "$2" | sed 's/^v//')
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$b" ]
}

OPENCLAW_VERSION=$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

if [ -z "$OPENCLAW_VERSION" ]; then
    echo -e "${RED}ERROR: OpenClaw is not installed or not in PATH.${NC}"
    echo ""
    echo "Install OpenClaw first:"
    echo "  npm install -g openclaw"
    echo ""
    echo "Minimum required version: $MIN_OPENCLAW_VERSION"
    exit 1
fi

if ! version_gte "$OPENCLAW_VERSION" "$MIN_OPENCLAW_VERSION"; then
    echo -e "${RED}ERROR: OpenClaw $OPENCLAW_VERSION is too old.${NC}"
    echo ""
    echo "FlipClaw requires OpenClaw $MIN_OPENCLAW_VERSION or later for:"
    echo "  - memory-core Dreaming (light/deep/REM phases)"
    echo "  - memory-wiki plugin (bridge mode)"
    echo "  - continuation-skip context injection"
    echo ""
    echo "Upgrade OpenClaw:"
    echo "  npm install -g openclaw@latest"
    exit 1
fi

echo "============================================"
echo -e "${BLUE}Memory System Installer${NC}"
echo "Toolkit version: $TOOLKIT_VERSION"
echo "OpenClaw:        $OPENCLAW_VERSION (min: $MIN_OPENCLAW_VERSION)"
echo "Built by:        Brad Besner — github.com/bbesner/flipclaw"
echo "============================================"
echo ""
echo "  Agent name:       $AGENT_NAME"
echo "  Workspace:        $WORKSPACE"
echo "  Gateway port:     $PORT"
echo ""
echo "  Models:"
echo "    Capture:        $CAPTURE_MODEL ($CAPTURE_PROVIDER)"
echo "    Writer:         $WRITER_MODEL ($WRITER_PROVIDER)"
echo "    Skill extract:  $EXTRACTION_MODEL ($SKILL_PROVIDER)"
echo "    Skill generate: $GENERATION_MODEL ($SKILL_PROVIDER)"
echo "    Embeddings:     $EMBEDDING_MODEL ($EMBEDDING_PROVIDER)"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN — no changes will be made${NC}"
    echo ""
fi

# ──────────────────────────────────────────────────────────────
# v3.2.1 addition: Pre-flight checks
# ──────────────────────────────────────────────────────────────
# Validate the install environment BEFORE making any changes. Each check
# is non-fatal unless it is a blocker. Blockers cause an early exit with
# a clear error message. Warnings are printed but install proceeds.

echo -e "${BLUE}Pre-flight checks${NC}"

PREFLIGHT_FAIL=0
PREFLIGHT_WARN=0

preflight_ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
preflight_warn() { echo -e "  ${YELLOW}[WARN]${NC} $1${2:+ — $2}"; PREFLIGHT_WARN=$((PREFLIGHT_WARN+1)); }
preflight_fail() { echo -e "  ${RED}[FAIL]${NC} $1${2:+ — $2}"; PREFLIGHT_FAIL=$((PREFLIGHT_FAIL+1)); }

# 1. Workspace directory exists and is writable
if [ ! -d "$WORKSPACE" ]; then
    preflight_fail "Workspace directory" "not found: $WORKSPACE (create it before running the installer)"
elif [ ! -w "$WORKSPACE" ]; then
    preflight_fail "Workspace writability" "$WORKSPACE exists but is not writable by $(whoami)"
else
    preflight_ok "Workspace writable: $WORKSPACE"
fi

# 2. openclaw.json present (unless --skip-openclaw)
if [ "$SKIP_OPENCLAW_CONFIG" = false ]; then
    if [ ! -f "$WORKSPACE/openclaw.json" ]; then
        preflight_warn "openclaw.json" "not found at $WORKSPACE/openclaw.json — plugin config step will be skipped"
    else
        preflight_ok "openclaw.json found at $WORKSPACE/openclaw.json"
    fi
fi

# 3. State-dir config detection (Bug #2 visibility)
if [ -f "$HOME/.openclaw/openclaw.json" ]; then
    preflight_ok "State-dir config detected — installer will sync plugin changes to both"
fi

# 4. Conflicting openclaw-mem0 extensions (Bug #9 visibility)
MEM0_FOUND=0
for ext_dir in "$WORKSPACE/extensions/openclaw-mem0" "$HOME/.openclaw/extensions/openclaw-mem0"; do
    if [ -d "$ext_dir" ]; then
        preflight_warn "openclaw-mem0 extension at $ext_dir" "will be moved aside during install"
        MEM0_FOUND=1
    fi
done
if [ "$MEM0_FOUND" -eq 0 ]; then
    preflight_ok "No conflicting openclaw-mem0 extension"
fi

# 5. Legacy auth.profiles.*.primary key (Bug #5 visibility)
if [ -f "$WORKSPACE/openclaw.json" ] && command -v python3 >/dev/null 2>&1; then
    HAS_LEGACY_AUTH=$(python3 -c "
import json
try:
    d = json.load(open('$WORKSPACE/openclaw.json'))
    profiles = d.get('auth', {}).get('profiles', {})
    found = any(isinstance(p, dict) and 'primary' in p for p in profiles.values())
    print('yes' if found else 'no')
except Exception:
    print('no')
" 2>/dev/null)
    if [ "$HAS_LEGACY_AUTH" = "yes" ]; then
        preflight_warn "Legacy auth.profiles.*.primary key detected" "will be auto-sanitized by installer"
    else
        preflight_ok "No legacy auth.profiles.*.primary keys"
    fi
fi

# 6. Gateway health (informational only)
if [ "$SKIP_OPENCLAW_CONFIG" = false ] && [ -n "$PORT" ]; then
    if curl -sf -m 3 "http://localhost:$PORT/health" >/dev/null 2>&1; then
        preflight_ok "Gateway reachable on port $PORT"
    else
        preflight_warn "Gateway not reachable on port $PORT" "cron jobs will be skipped; set them up manually after the gateway is running"
    fi
fi

# 7. Gemini API key presence (Bug #6 visibility)
if [ "$SKIP_OPENCLAW_CONFIG" = false ] && [ -f "$WORKSPACE/openclaw.json" ]; then
    if [ -n "$GEMINI_KEY" ]; then
        preflight_ok "Gemini API key provided via --gemini-key flag"
    else
        HAS_GEMINI_PRE=$(python3 -c "
import json
try:
    d = json.load(open('$WORKSPACE/openclaw.json'))
    env_vars = d.get('env', {}).get('vars', {})
    print('yes' if ('GEMINI_API_KEY' in env_vars or 'GOOGLE_AI_API_KEY' in env_vars) else 'no')
except Exception:
    print('no')
" 2>/dev/null)
        if [ "$HAS_GEMINI_PRE" = "yes" ]; then
            preflight_ok "Gemini API key already in openclaw.json env.vars"
        else
            preflight_warn "Gemini API key not found" "memory search will fall back to keyword-only until configured (see install summary)"
        fi
    fi
fi

echo ""
if [ "$PREFLIGHT_FAIL" -gt 0 ]; then
    echo -e "${RED}Pre-flight check failed ($PREFLIGHT_FAIL blocker(s)). Fix the errors above and re-run.${NC}"
    exit 1
elif [ "$PREFLIGHT_WARN" -gt 0 ]; then
    echo -e "  ${YELLOW}Pre-flight: $PREFLIGHT_WARN warning(s) — proceeding with install${NC}"
else
    echo -e "  ${GREEN}Pre-flight: all checks passed${NC}"
fi
echo ""

# ──────────────────────────────────────────────────────────────
# Step 1: Detect and handle existing memory systems
# ──────────────────────────────────────────────────────────────

echo -e "${BLUE}Step 1: Detect existing memory system${NC}"

EXISTING_SYSTEM="none"
OC_CONFIG="$WORKSPACE/openclaw.json"

if [ -f "$OC_CONFIG" ]; then
    EXISTING_SYSTEM=$(python3 -c "
import json
d = json.load(open('$OC_CONFIG'))
entries = d.get('plugins', {}).get('entries', {})
if entries.get('openclaw-mem0', {}).get('enabled', False):
    print('mem0')
elif entries.get('memory-bridge', {}).get('enabled', False) or entries.get('ari-memory-bridge', {}).get('enabled', False):
    print('memory-pipeline')
else:
    # Check for LanceDB or other vector stores
    import os
    if os.path.exists('$WORKSPACE/.lancedb') or os.path.exists('$WORKSPACE/lancedb'):
        print('lancedb')
    else:
        print('none')
" 2>/dev/null || echo "none")
fi

case "$EXISTING_SYSTEM" in
    mem0)
        echo -e "  ${YELLOW}Detected: Mem0 plugin (openclaw-mem0)${NC}"
        echo "  Will disable Mem0 and install file-based pipeline"
        echo "  Existing memory files will NOT be deleted"
        ;;
    lancedb)
        echo -e "  ${YELLOW}Detected: LanceDB vector store${NC}"
        echo "  Will install file-based pipeline alongside"
        echo "  LanceDB files will NOT be deleted"
        ;;
    memory-pipeline)
        echo -e "  ${GREEN}Detected: Memory pipeline already installed${NC}"
        echo "  Will update scripts and config (preserving existing memories)"
        ;;
    none)
        echo "  No existing memory system detected — fresh install"
        ;;
esac

# ──────────────────────────────────────────────────────────────
# Step 2: Snapshot existing state
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 2: Snapshot existing state${NC}"

# Unified backup location used by installer and flipclaw-update.sh
BACKUP_ROOT="$WORKSPACE/.flipclaw-backups"
PREV_VERSION=$(cat "$WORKSPACE/.toolkit-version" 2>/dev/null | head -1)
if [ -z "$PREV_VERSION" ]; then
    # Fresh install — no previous version to snapshot
    BACKUP_DIR="$BACKUP_ROOT/pre-install-$(date +%Y%m%d-%H%M%S)"
    IS_FRESH_INSTALL=true
else
    BACKUP_DIR="$BACKUP_ROOT/v${PREV_VERSION}-$(date +%Y%m%d-%H%M%S)"
    IS_FRESH_INSTALL=false
fi

# Also keep a pre-install safety copy of memory/skills in the parent directory
# (separate from rollback snapshots because these are large)
DATA_BACKUP_DIR="$(dirname "$WORKSPACE")/backups/memory-pre-install-$(date +%Y%m%d-%H%M%S)"

if [ "$DRY_RUN" = true ]; then
    if [ "$IS_FRESH_INSTALL" = true ]; then
        echo "  Fresh install — no previous state to snapshot"
    else
        echo "  Would create rollback snapshot at: $BACKUP_ROOT/v${PREV_VERSION}-<timestamp>/"
    fi
    echo "  Would create data backup at: $DATA_BACKUP_DIR"
elif [ "$IS_FRESH_INSTALL" = true ]; then
    echo "  Fresh install — no previous state to snapshot"

    # Still back up any pre-existing data files (memory/skills) for safety
    if [ -d "$WORKSPACE/memory" ] || [ -f "$WORKSPACE/MEMORY.md" ] || [ -d "$WORKSPACE/skills" ]; then
        mkdir -p "$DATA_BACKUP_DIR"
        if [ -d "$WORKSPACE/memory" ]; then
            cp -r "$WORKSPACE/memory" "$DATA_BACKUP_DIR/memory" 2>/dev/null
            echo "  Data backup: memory/ → $DATA_BACKUP_DIR/memory/"
        fi
        if [ -f "$WORKSPACE/MEMORY.md" ]; then
            cp "$WORKSPACE/MEMORY.md" "$DATA_BACKUP_DIR/MEMORY.md"
            echo "  Data backup: MEMORY.md"
        fi
        if [ -f "$OC_CONFIG" ]; then
            cp "$OC_CONFIG" "$DATA_BACKUP_DIR/openclaw.json"
        fi
        if [ -d "$WORKSPACE/skills" ]; then
            cp -r "$WORKSPACE/skills" "$DATA_BACKUP_DIR/skills" 2>/dev/null
            echo "  Data backup: skills/"
        fi
    fi
else
    # Upgrade install — snapshot existing state for rollback
    mkdir -p "$BACKUP_DIR/scripts" "$BACKUP_DIR/extensions"

    # Snapshot scripts (for rollback)
    if [ -d "$WORKSPACE/scripts" ]; then
        for f in claude-code-bridge.py claude-code-sweep.py claude-code-turn-capture.py \
                  claude-code-update-check.sh flipclaw-update.sh incremental-memory-capture.py \
                  memory-writer.py lockutil.py curate-memory-prompt.md index-daily-logs-prompt.md; do
            [ -f "$WORKSPACE/scripts/$f" ] && cp "$WORKSPACE/scripts/$f" "$BACKUP_DIR/scripts/$f"
        done
    fi

    # Snapshot extensions (for rollback)
    if [ -d "$WORKSPACE/extensions/auto-skill-capture" ]; then
        mkdir -p "$BACKUP_DIR/extensions/auto-skill-capture/scripts"
        for f in index.ts openclaw.plugin.json package.json; do
            [ -f "$WORKSPACE/extensions/auto-skill-capture/$f" ] && \
                cp "$WORKSPACE/extensions/auto-skill-capture/$f" "$BACKUP_DIR/extensions/auto-skill-capture/$f"
        done
        [ -f "$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py" ] && \
            cp "$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py" \
               "$BACKUP_DIR/extensions/auto-skill-capture/scripts/skill-extractor.py"
    fi
    if [ -d "$WORKSPACE/extensions/memory-bridge" ]; then
        mkdir -p "$BACKUP_DIR/extensions/memory-bridge"
        for f in index.ts openclaw.plugin.json; do
            [ -f "$WORKSPACE/extensions/memory-bridge/$f" ] && \
                cp "$WORKSPACE/extensions/memory-bridge/$f" "$BACKUP_DIR/extensions/memory-bridge/$f"
        done
    fi

    # Snapshot state files
    [ -f "$WORKSPACE/.toolkit-version" ] && cp "$WORKSPACE/.toolkit-version" "$BACKUP_DIR/.toolkit-version"
    [ -f "$WORKSPACE/.flipclaw-install.json" ] && cp "$WORKSPACE/.flipclaw-install.json" "$BACKUP_DIR/.flipclaw-install.json"
    [ -f "$OC_CONFIG" ] && cp "$OC_CONFIG" "$BACKUP_DIR/openclaw.json"

    # Backup metadata
    python3 - << PYEOF
import json
from datetime import datetime, timezone
meta = {
    'version': '$PREV_VERSION',
    'created_at': datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC'),
    'trigger': 'install-memory',
    'workspace': '$WORKSPACE',
    'openclaw_version': '$OPENCLAW_VERSION',
}
with open('$BACKUP_DIR/backup-meta.json', 'w') as f:
    json.dump(meta, f, indent=2)
PYEOF

    # Prune old backups — keep last 10
    if [ -d "$BACKUP_ROOT" ]; then
        ls -1t "$BACKUP_ROOT" 2>/dev/null | tail -n +11 | while read -r old; do
            rm -rf "$BACKUP_ROOT/$old" 2>/dev/null
        done
    fi

    echo "  Rollback snapshot: $BACKUP_DIR"

    # Separate data backup for safety (memory/, skills/, MEMORY.md)
    mkdir -p "$DATA_BACKUP_DIR"
    if [ -d "$WORKSPACE/memory" ]; then
        cp -r "$WORKSPACE/memory" "$DATA_BACKUP_DIR/memory" 2>/dev/null
        echo "  Data backup: memory/ → $DATA_BACKUP_DIR/memory/"
    fi
    if [ -f "$WORKSPACE/MEMORY.md" ]; then
        cp "$WORKSPACE/MEMORY.md" "$DATA_BACKUP_DIR/MEMORY.md"
        echo "  Data backup: MEMORY.md"
    fi
    if [ -f "$OC_CONFIG" ]; then
        cp "$OC_CONFIG" "$DATA_BACKUP_DIR/openclaw.json"
    fi
    if [ -d "$WORKSPACE/skills" ]; then
        cp -r "$WORKSPACE/skills" "$DATA_BACKUP_DIR/skills" 2>/dev/null
        echo "  Data backup: skills/"
    fi
fi

# ──────────────────────────────────────────────────────────────
# Step 3: Create directory structure
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 3: Directory structure${NC}"

DIRS=(
    "$WORKSPACE/memory"
    "$WORKSPACE/memory/session-cache"
    "$WORKSPACE/memory/dreaming"
    "$WORKSPACE/memory/.dreams"
    "$WORKSPACE/wiki"
    "$WORKSPACE/skills"
    "$WORKSPACE/skills/.auto-skill-capture"
    "$WORKSPACE/agents/main/sessions"
    "$WORKSPACE/scripts"
    "$WORKSPACE/scripts/.archived"
    "$WORKSPACE/extensions/memory-bridge"
    "$WORKSPACE/extensions/auto-skill-capture/scripts"
    "$WORKSPACE/extensions/auto-skill-capture/config"
    "$WORKSPACE/cron"
    "$WORKSPACE/state"
    "$WORKSPACE/logs"
)

for dir in "${DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        if [ "$DRY_RUN" = false ]; then
            mkdir -p "$dir"
            echo "  Created: $dir"
        else
            echo "  Would create: $dir"
        fi
    fi
done

# Apply group ownership and setgid if --group was specified
if [ -n "$GROUP" ]; then
    if [ "$DRY_RUN" = false ]; then
        chgrp -R "$GROUP" "$WORKSPACE"
        find "$WORKSPACE" -type d -exec chmod 2775 {} +
        find "$WORKSPACE" -type f -exec chmod g+w {} +
        echo "  Applied group ownership: $GROUP (setgid on directories, g+w on files)"
    else
        echo "  Would apply group ownership: $GROUP (setgid on directories, g+w on files)"
    fi
fi

# ──────────────────────────────────────────────────────────────
# Step 4: Install memory processing scripts
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 4: Install memory scripts${NC}"

if [ "$DRY_RUN" = false ]; then
    # lockutil.py
    cp "$TOOLKIT_DIR/scripts/lockutil.py" "$WORKSPACE/scripts/lockutil.py"
    chmod +x "$WORKSPACE/scripts/lockutil.py"
    echo "  Installed: lockutil.py"

    # incremental-memory-capture.py
    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|{{SESSION_SOURCE}}|claude-code|g" \
        -e "s|MODEL = \"gpt-5.4-nano\"|MODEL = \"$CAPTURE_MODEL\"|g" \
        -e "s|PROVIDER = \"openai\"|PROVIDER = \"$CAPTURE_PROVIDER\"|g" \
        "$TOOLKIT_DIR/scripts/incremental-memory-capture.py" > "$WORKSPACE/scripts/incremental-memory-capture.py"
    chmod +x "$WORKSPACE/scripts/incremental-memory-capture.py"
    echo "  Installed: incremental-memory-capture.py (model: $CAPTURE_MODEL)"

    # memory-writer.py (legacy manual backfill tool only)
    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|MODEL = \"claude-sonnet-4-6\"|MODEL = \"$WRITER_MODEL\"|g" \
        "$TOOLKIT_DIR/scripts/memory-writer.py" > "$WORKSPACE/scripts/memory-writer.py"
    chmod +x "$WORKSPACE/scripts/memory-writer.py"
    echo "  Installed: memory-writer.py (legacy manual backfill only, not active architecture)"

    # Prompt templates
    sed "s|{{WORKSPACE}}|$WORKSPACE|g" "$TOOLKIT_DIR/scripts/curate-memory-prompt.md" > "$WORKSPACE/scripts/curate-memory-prompt.md"
    echo "  Installed: curate-memory-prompt.md"

    sed "s|{{WORKSPACE}}|$WORKSPACE|g" "$TOOLKIT_DIR/scripts/index-daily-logs-prompt.md" > "$WORKSPACE/scripts/index-daily-logs-prompt.md"
    echo "  Installed: index-daily-logs-prompt.md"

    # Upstream patch registry + runner. apply-upstream-patches.sh consults
    # upstream-patches.json at the end of install to decide which workaround
    # scripts and cron jobs to install for the user's OpenClaw version. This
    # replaces inline workaround installation and means upgrading OpenClaw
    # later (via flipclaw-update.sh) will automatically remove workarounds
    # that are no longer needed.
    cp "$TOOLKIT_DIR/scripts/upstream-patches.json" "$WORKSPACE/scripts/upstream-patches.json"
    echo "  Installed: upstream-patches.json (patch registry)"
    cp "$TOOLKIT_DIR/scripts/apply-upstream-patches.sh" "$WORKSPACE/scripts/apply-upstream-patches.sh"
    chmod +x "$WORKSPACE/scripts/apply-upstream-patches.sh"
    echo "  Installed: apply-upstream-patches.sh (version-aware workaround runner)"
else
    echo "  Would install: incremental-memory-capture.py (model: $CAPTURE_MODEL)"
    echo "  Would install: memory-writer.py (legacy manual backfill only, model: $WRITER_MODEL)"
    echo "  Would install: curate-memory-prompt.md (legacy manual reference)"
    echo "  Would install: index-daily-logs-prompt.md"
    echo "  Would install: lockutil.py"
    echo "  Would install: upstream-patches.json + apply-upstream-patches.sh"
fi

# ──────────────────────────────────────────────────────────────
# Step 5: Install extensions
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 5: Install extensions${NC}"

if [ "$DRY_RUN" = false ]; then
    # Memory bridge extension
    sed "s|{{WORKSPACE}}|$WORKSPACE|g" \
        "$TOOLKIT_DIR/extensions/memory-bridge/index.ts" > "$WORKSPACE/extensions/memory-bridge/index.ts"
    cp "$TOOLKIT_DIR/extensions/memory-bridge/openclaw.plugin.json" "$WORKSPACE/extensions/memory-bridge/openclaw.plugin.json"
    echo "  Installed: memory-bridge extension (per-turn capture)"

    # Auto-skill-capture extension
    for f in index.ts openclaw.plugin.json package.json; do
        if [ -f "$TOOLKIT_DIR/extensions/auto-skill-capture/$f" ]; then
            sed "s|{{WORKSPACE}}|$WORKSPACE|g" "$TOOLKIT_DIR/extensions/auto-skill-capture/$f" > "$WORKSPACE/extensions/auto-skill-capture/$f"
        fi
    done
    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        "$TOOLKIT_DIR/scripts/skill-extractor.py" > "$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py"
    chmod +x "$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py"
    echo "  Installed: auto-skill-capture extension (model: $EXTRACTION_MODEL)"
else
    echo "  Would install: memory-bridge extension"
    echo "  Would install: auto-skill-capture extension"
fi

# ──────────────────────────────────────────────────────────────
# Step 6: Configure OpenClaw
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 6: Configure OpenClaw${NC}"

if [ "$SKIP_OPENCLAW_CONFIG" = true ]; then
    echo "  Skipped (--skip-openclaw)"
elif [ ! -f "$OC_CONFIG" ]; then
    echo -e "  ${YELLOW}No openclaw.json found — skipping config${NC}"
    echo "  Add plugin and memorySearch config manually after creating openclaw.json"
else
    # ─────────────────────────────────────────────────────────────────
    # v3.2.1 Bug #9 fix: move any conflicting openclaw-mem0 extension
    # directories out of the way BEFORE config changes, so the gateway
    # cannot auto-discover them and compete for the memory slot.
    # ─────────────────────────────────────────────────────────────────
    if [ "$DRY_RUN" = false ]; then
        for ext_dir in \
            "$WORKSPACE/extensions/openclaw-mem0" \
            "$HOME/.openclaw/extensions/openclaw-mem0"; do
            if [ -d "$ext_dir" ]; then
                dest="$(dirname "$ext_dir")/.disabled-openclaw-mem0-$(date +%Y%m%d-%H%M%S)"
                mv "$ext_dir" "$dest"
                echo "  Moved aside: $ext_dir → $(basename "$dest")"
            fi
        done
    fi

    # ─────────────────────────────────────────────────────────────────
    # v3.2.1 Bug #2 fix: apply config changes to BOTH the workspace
    # config and the state-dir config (if it exists). Some agents use
    # ~/.openclaw/openclaw.json at runtime (PM2 start scripts that don't
    # set OPENCLAW_CONFIG_PATH). The installer previously only touched
    # the workspace config, leaving the state-dir stale.
    # ─────────────────────────────────────────────────────────────────
    STATE_DIR_CONFIG="$HOME/.openclaw/openclaw.json"
    if [ "$DRY_RUN" = false ]; then
        python3 << PYEOF
import json
import os

# Config targets: workspace always, state-dir if present
targets = ['$OC_CONFIG']
state_dir_cfg = '$STATE_DIR_CONFIG'
if os.path.exists(state_dir_cfg) and state_dir_cfg != '$OC_CONFIG':
    targets.append(state_dir_cfg)
    print(f'  Note: state-dir config detected at {state_dir_cfg} — will sync plugin changes to both.')

def dreaming_config():
    return {
        'enabled': True,
        'frequency': '0 4 * * *',
        'timezone': 'America/New_York',
        'verboseLogging': True,
        'storage': {'mode': 'separate'},
        'phases': {
            'light': {
                'enabled': True,
                'lookbackDays': 3,
                'limit': 50,
                'dedupeSimilarity': 0.85
            },
            'deep': {
                'enabled': True,
                'limit': 10,
                'minScore': 0.3,
                'minRecallCount': 3,
                'minUniqueQueries': 2,
                'recencyHalfLifeDays': 14,
                'maxAgeDays': 90
            },
            'rem': {
                'enabled': True,
                'lookbackDays': 7,
                'limit': 5,
                'minPatternStrength': 0.4
            }
        }
    }

def memory_wiki_config():
    return {
        'enabled': True,
        'config': {
            'vaultMode': 'bridge',
            'vault': {'path': '$WORKSPACE/wiki', 'renderMode': 'native'},
            'bridge': {
                'enabled': True,
                'readMemoryArtifacts': True,
                'indexDreamReports': True,
                'indexDailyNotes': True,
                'indexMemoryRoot': True,
                'followMemoryEvents': True
            },
            'search': {'backend': 'shared', 'corpus': 'all'},
            'context': {'includeCompiledDigestPrompt': False},
            'render': {'preserveHumanBlocks': True, 'createBacklinks': True, 'createDashboards': True}
        }
    }

for target_path in targets:
    is_state_dir = (target_path == state_dir_cfg)
    label = 'state-dir' if is_state_dir else 'workspace'
    print(f'  [{label}] {target_path}')

    with open(target_path) as f:
        d = json.load(f)

    # ─────────────────────────────────────────────────────────
    # v3.2.1 Bug #5 fix: strip legacy auth.profiles.*.primary key
    # that fails validation on OpenClaw 2026.4.9+.
    # ─────────────────────────────────────────────────────────
    auth = d.get('auth', {})
    profiles = auth.get('profiles', {})
    for profile_name, profile in profiles.items():
        if isinstance(profile, dict) and 'primary' in profile:
            del profile['primary']
            print(f'    Sanitized: removed legacy auth.profiles.{profile_name}.primary')

    plugins = d.setdefault('plugins', {})
    entries = plugins.setdefault('entries', {})

    # ─────────────────────────────────────────────────────────
    # v3.2.1 Bug #9 fix: fully remove openclaw-mem0 plugin entry
    # and allow-list membership (previously just set enabled:
    # false, which left the plugin auto-discoverable).
    # ─────────────────────────────────────────────────────────
    if 'openclaw-mem0' in entries:
        del entries['openclaw-mem0']
        print('    Removed: openclaw-mem0 plugin entry (was enabled: False, now fully removed)')

    # memory-bridge plugin
    if 'memory-bridge' not in entries and 'ari-memory-bridge' not in entries:
        entries['memory-bridge'] = {
            'enabled': True,
            'config': {}
        }
        print('    Added: memory-bridge plugin')
    else:
        print('    memory-bridge plugin already configured')

    # auto-skill-capture plugin
    if 'auto-skill-capture' not in entries:
        entries['auto-skill-capture'] = {
            'enabled': True,
            'config': {
                'captureEnabled': True,
                'recallEnabled': False,
                'outputDir': 'skills',
                'extractionModel': '$EXTRACTION_MODEL',
                'generationModel': '$GENERATION_MODEL',
                'provider': '$SKILL_PROVIDER'
            }
        }
        print('    Added: auto-skill-capture plugin')
    else:
        print('    auto-skill-capture plugin already configured')

    # ─────────────────────────────────────────────────────────
    # v3.2.1 Bug #1 fix: always set enabled: True on memory-core.
    # Previously the installer only added the dreaming config,
    # leaving memory-core disabled (plugin wouldn't load) on
    # fresh installs where memory-core wasn't pre-present.
    # ─────────────────────────────────────────────────────────
    mc = entries.get('memory-core', {})
    mc['enabled'] = True  # <-- THE FIX
    if not mc.get('config', {}).get('dreaming', {}).get('enabled'):
        mc.setdefault('config', {})['dreaming'] = dreaming_config()
        print('    Configured: memory-core (enabled: true) + Dreaming (daily 4 AM ET)')
    else:
        print('    memory-core already configured; ensured enabled: true')
    entries['memory-core'] = mc

    # ─────────────────────────────────────────────────────────
    # v3.2.1 Bug #3 fix: set plugins.slots.memory = memory-core
    # so the gateway actually activates memory-core as the memory
    # provider. Without this, memory-core logs as "disabled (memory
    # slot set to X)" even if enabled: true is set.
    # ─────────────────────────────────────────────────────────
    slots = plugins.setdefault('slots', {})
    if slots.get('memory') != 'memory-core':
        slots['memory'] = 'memory-core'
        print('    Set: plugins.slots.memory = memory-core')

    # memory-wiki plugin
    if 'memory-wiki' not in entries:
        entries['memory-wiki'] = memory_wiki_config()
        print('    Added: memory-wiki plugin (bridge mode)')
    else:
        print('    memory-wiki plugin already configured')

    # ─────────────────────────────────────────────────────────
    # v3.2.1 Bug #4 fix: ensure all FlipClaw plugins are in the
    # plugins.allow list. Previously only memory-wiki was added,
    # so memory-core/memory-bridge/auto-skill-capture were
    # silently dropped on workspaces with a pre-existing allow list.
    # ─────────────────────────────────────────────────────────
    allow = plugins.get('allow', [])
    # Only enforce allow list membership if one is already configured.
    # Empty allow list means "allow all" in OpenClaw.
    if allow:
        for name in ['memory-core', 'memory-wiki', 'memory-bridge', 'auto-skill-capture']:
            if name not in allow:
                allow.append(name)
                print(f'    Added to plugins.allow: {name}')
        # Also remove openclaw-mem0 from allow list if present
        if 'openclaw-mem0' in allow:
            allow.remove('openclaw-mem0')
            print('    Removed from plugins.allow: openclaw-mem0')
        plugins['allow'] = allow

    # ─────────────────────────────────────────────────────────
    # v3.2.1 Bug #12 fix: ensure plugins.load.paths includes the
    # workspace extensions dir in BOTH configs. Previously this was
    # only done for state-dir configs, which meant workspace-only
    # installs couldn't find memory-bridge/auto-skill-capture on
    # gateway startup. Gateway log: "plugin not found: memory-bridge".
    # ─────────────────────────────────────────────────────────
    load = plugins.setdefault('load', {})
    paths = load.setdefault('paths', [])
    ext_path = '$WORKSPACE/extensions'
    if ext_path not in paths:
        paths.append(ext_path)
        print(f'    Added to plugins.load.paths: {ext_path}')

    # ─────────────────────────────────────────────────────────────
    # Configure continuation-skip (agents.defaults.contextInjection)
    # ─────────────────────────────────────────────────────────────
    agents = d.setdefault('agents', {})
    defaults = agents.setdefault('defaults', {})
    if defaults.get('contextInjection') != 'continuation-skip':
        defaults['contextInjection'] = 'continuation-skip'
        print('    Set: contextInjection = continuation-skip')

    # ─────────────────────────────────────────────────────────────
    # Configure memorySearch (hybrid Gemini search)
    # ─────────────────────────────────────────────────────────────
    ms = defaults.get('memorySearch', {})
    if not ms.get('enabled'):
        defaults['memorySearch'] = {
            'enabled': True,
            'sources': ['memory', 'sessions'],
            'experimental': {'sessionMemory': True},
            'provider': '$EMBEDDING_PROVIDER',
            'model': '$EMBEDDING_MODEL',
            'sync': {
                'onSessionStart': True,
                'onSearch': True,
                'watch': True,
                'watchDebounceMs': 1500,
                'sessions': {
                    'deltaBytes': 25000,
                    'deltaMessages': 15,
                    'postCompactionForce': True
                }
            },
            'query': {
                'maxResults': 8,
                'hybrid': {
                    'enabled': True,
                    'vectorWeight': 0.7,
                    'textWeight': 0.3,
                    'candidateMultiplier': 4,
                    'mmr': {'enabled': True, 'lambda': 0.7},
                    'temporalDecay': {'enabled': True, 'halfLifeDays': 30}
                }
            },
            'cache': {'enabled': True, 'maxEntries': 50000},
            'extraPaths': ['skills']
        }
        print('    Configured: memorySearch (hybrid Gemini search)')
    else:
        # Just ensure skills are in extraPaths
        if 'skills' not in ms.get('extraPaths', []):
            ms.setdefault('extraPaths', []).append('skills')
            defaults['memorySearch'] = ms
            print('    Added skills to existing memorySearch.extraPaths')
        else:
            print('    memorySearch already configured')

    # Write back
    with open(target_path, 'w') as f:
        json.dump(d, f, indent=2)
PYEOF

        # ─────────────────────────────────────────────────────────
        # v3.2.1 Bug #6/#7 fix: Gemini API key handling.
        # If --gemini-key was provided, write it to openclaw.json env.vars.
        # Otherwise, detect whether a key is already present and warn the
        # user if not (memory search falls back to keyword-only without it).
        # ─────────────────────────────────────────────────────────
        STATE_DIR_CONFIG="$HOME/.openclaw/openclaw.json"
        if [ -n "$GEMINI_KEY" ]; then
            python3 << PYEOF
import json
import os
targets = ['$OC_CONFIG']
if os.path.exists('$STATE_DIR_CONFIG') and '$STATE_DIR_CONFIG' != '$OC_CONFIG':
    targets.append('$STATE_DIR_CONFIG')
for target in targets:
    with open(target) as f:
        d = json.load(f)
    env_vars = d.setdefault('env', {}).setdefault('vars', {})
    env_vars['GEMINI_API_KEY'] = '$GEMINI_KEY'
    env_vars['GOOGLE_AI_API_KEY'] = '$GEMINI_KEY'
    with open(target, 'w') as f:
        json.dump(d, f, indent=2)
    print(f'  Wrote GEMINI_API_KEY to: {target}')
PYEOF
        else
            HAS_GEMINI=$(python3 -c "
import json
d = json.load(open('$OC_CONFIG'))
env_vars = d.get('env', {}).get('vars', {})
print('yes' if ('GEMINI_API_KEY' in env_vars or 'GOOGLE_AI_API_KEY' in env_vars) else 'no')
" 2>/dev/null)
            if [ "$HAS_GEMINI" = "no" ]; then
                echo ""
                echo -e "  ${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
                echo -e "  ${YELLOW}│ WARNING: No Gemini API key found in openclaw.json env.vars  │${NC}"
                echo -e "  ${YELLOW}│                                                             │${NC}"
                echo -e "  ${YELLOW}│ Memory search will fall back to keyword-only mode without   │${NC}"
                echo -e "  ${YELLOW}│ hybrid semantic (vector) search until you add one.          │${NC}"
                echo -e "  ${YELLOW}│                                                             │${NC}"
                echo -e "  ${YELLOW}│ Get a free Gemini API key:                                  │${NC}"
                echo -e "  ${YELLOW}│   https://aistudio.google.com/apikey                        │${NC}"
                echo -e "  ${YELLOW}│                                                             │${NC}"
                echo -e "  ${YELLOW}│ Then add to env.vars in openclaw.json:                      │${NC}"
                echo -e "  ${YELLOW}│   \"GEMINI_API_KEY\": \"your-key-here\",                        │${NC}"
                echo -e "  ${YELLOW}│   \"GOOGLE_AI_API_KEY\": \"your-key-here\"                      │${NC}"
                echo -e "  ${YELLOW}│                                                             │${NC}"
                echo -e "  ${YELLOW}│ Or re-run installer with --gemini-key \"your-key-here\"       │${NC}"
                echo -e "  ${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
                echo ""
            else
                echo "  Gemini API key detected in openclaw.json"
            fi
        fi
    else
        echo "  Would configure: plugins + memorySearch in openclaw.json"
    fi
fi

# ──────────────────────────────────────────────────────────────
# Step 7: Create initial memory files (never overwrite)
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 7: Initial memory files${NC}"

if [ "$DRY_RUN" = false ]; then
    # MEMORY.md — only if it doesn't exist
    if [ ! -f "$WORKSPACE/MEMORY.md" ]; then
        cat > "$WORKSPACE/MEMORY.md" << MEMEOF
# ${AGENT_NAME} — Core Memory

**Created:** $(date +%Y-%m-%d) | **Agent:** ${AGENT_NAME} | **Port:** ${PORT}

## People

## Infrastructure

## Business Rules

## Decisions

## Lessons Learned
MEMEOF
        echo "  Created: MEMORY.md"
    else
        echo "  Exists: MEMORY.md (preserved)"
    fi

    # Structured memory files — only create if missing
    for topic in infrastructure people decisions business-context lessons-learned; do
        FILE="$WORKSPACE/memory/${topic}.md"
        if [ ! -f "$FILE" ]; then
            TITLE=$(echo "$topic" | sed 's/-/ /g; s/\b\(.\)/\u\1/g')
            echo "# ${TITLE}" > "$FILE"
            echo "" >> "$FILE"
            echo "  Created: memory/${topic}.md"
        fi
    done

    # Capture log
    if [ ! -f "$WORKSPACE/skills/.auto-skill-capture/capture-log.md" ]; then
        touch "$WORKSPACE/skills/.auto-skill-capture/capture-log.md"
        echo "  Created: capture-log.md"
    fi

    # Version marker
    echo "$TOOLKIT_VERSION" > "$WORKSPACE/.toolkit-version"
    echo "  Written toolkit version: $TOOLKIT_VERSION"

    # Install params — saved for safe future updates
    # If already exists (combined install runs memory first), preserve existing and update model fields
    PARAMS_FILE="$WORKSPACE/.flipclaw-install.json"
    if [ -f "$PARAMS_FILE" ]; then
        python3 - << PYEOF
import json
from datetime import datetime, timezone

with open('$PARAMS_FILE') as f:
    p = json.load(f)

prev_version = p.get('flipclaw_version', 'unknown')
p['models'] = {
    'capture_model': '$CAPTURE_MODEL',
    'capture_provider': '$CAPTURE_PROVIDER',
    'writer_model': '$WRITER_MODEL',
    'writer_provider': '$WRITER_PROVIDER',
    'extraction_model': '$EXTRACTION_MODEL',
    'generation_model': '$GENERATION_MODEL',
    'skill_provider': '$SKILL_PROVIDER',
    'embedding_provider': '$EMBEDDING_PROVIDER',
    'embedding_model': '$EMBEDDING_MODEL'
}
p['openclaw_version'] = '$OPENCLAW_VERSION'
p['flipclaw_version'] = '$TOOLKIT_VERSION'

if prev_version != '$TOOLKIT_VERSION':
    history = p.get('update_history', [])
    history.append({
        'from': prev_version,
        'to': '$TOOLKIT_VERSION',
        'at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'openclaw_version': '$OPENCLAW_VERSION',
        'trigger': 'install-memory',
    })
    p['update_history'] = history[-50:]

with open('$PARAMS_FILE', 'w') as f:
    json.dump(p, f, indent=2)
PYEOF
        echo "  Updated model params in .flipclaw-install.json"
    else
        python3 - << PYEOF
import json
from datetime import datetime, date, timezone
p = {
    'flipclaw_version': '$TOOLKIT_VERSION',
    'openclaw_version': '$OPENCLAW_VERSION',
    'installed_at': date.today().isoformat(),
    'workspace': '$WORKSPACE',
    'agent_name': '$AGENT_NAME',
    'port': '$PORT',
    'claude_home': '',
    'user_id': '',
    'session_source': 'claude-code',
    'shared': False,
    'with_mcp': False,
    'models': {
        'capture_model': '$CAPTURE_MODEL',
        'capture_provider': '$CAPTURE_PROVIDER',
        'writer_model': '$WRITER_MODEL',
        'writer_provider': '$WRITER_PROVIDER',
        'extraction_model': '$EXTRACTION_MODEL',
        'generation_model': '$GENERATION_MODEL',
        'skill_provider': '$SKILL_PROVIDER',
        'embedding_provider': '$EMBEDDING_PROVIDER',
        'embedding_model': '$EMBEDDING_MODEL'
    },
    'update_history': [{
        'from': 'fresh-install',
        'to': '$TOOLKIT_VERSION',
        'at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'openclaw_version': '$OPENCLAW_VERSION',
        'trigger': 'install-memory',
    }]
}
with open('$PARAMS_FILE', 'w') as f:
    json.dump(p, f, indent=2)
PYEOF
        echo "  Created .flipclaw-install.json (install params saved for future updates)"
    fi
else
    echo "  Would create initial files (MEMORY.md, structured memory, capture log)"
fi

# ──────────────────────────────────────────────────────────────
# Step 8: Set up cron jobs
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 8: Memory consolidation (Dreaming)${NC}"

echo "  Memory consolidation is now handled by memory-core Dreaming (built-in)."
echo "  Dreaming auto-manages its own cron schedule on gateway startup."
echo "  No manual cron jobs needed for memory-writer, curation, or reindex."
echo ""
echo "  Dreaming phases:"
echo "    - Light: dedup/consolidate recent daily facts"
echo "    - Deep: promote well-recalled facts to MEMORY.md"
echo "    - REM: pattern detection and narrative synthesis → DREAMS.md"
echo "  Schedule: daily at 4 AM (configurable via openclaw.json)"
echo ""
echo "  NOTE: memory-writer.py is kept on disk for manual backfill only."
echo "  curate-memory-prompt.md is kept as reference for manual curation."

# ── Upstream patch reconciliation ─────────────────────────────────────
#
# Call the patch registry runner, which consults scripts/upstream-patches.json
# to install workaround artifacts matching the installed OpenClaw version
# (or remove ones that are no longer needed). This replaces the previous
# inline dreaming-cron-heal block and makes version handling declarative.

PATCH_RUNNER_ARGS=(--workspace "$WORKSPACE" --port "$PORT" --toolkit-dir "$TOOLKIT_DIR")
if [ "$DRY_RUN" = true ]; then
    PATCH_RUNNER_ARGS+=(--dry-run)
fi

bash "$TOOLKIT_DIR/scripts/apply-upstream-patches.sh" "${PATCH_RUNNER_ARGS[@]}" || {
    echo -e "  ${YELLOW}[WARN]${NC} Upstream patch reconciliation reported failures — review above"
}

# ──────────────────────────────────────────────────────────────
# Step 9: Verify installation
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 9: Verification${NC}"

if [ "$DRY_RUN" = true ]; then
    echo "  Skipped (dry run)"
else
    PASS=0
    FAIL=0

    check() {
        if [ "$2" = "pass" ]; then
            echo -e "  ${GREEN}[OK]${NC} $1"
            ((PASS++))
        else
            echo -e "  ${RED}[!!]${NC} $1 — $3"
            ((FAIL++))
        fi
    }

    if [ -f "$WORKSPACE/scripts/incremental-memory-capture.py" ]; then check "Incremental capture script" "pass"; else check "Incremental capture" "fail" "not found"; fi
    if [ -f "$WORKSPACE/scripts/memory-writer.py" ]; then check "Memory writer script (legacy manual backfill)" "pass"; else check "Memory writer script (legacy manual backfill)" "warn" "not found"; fi
    if [ -f "$WORKSPACE/scripts/upstream-patches.json" ]; then check "Upstream patch registry" "pass"; else check "Upstream patch registry" "fail" "not found"; fi
    if [ -f "$WORKSPACE/scripts/apply-upstream-patches.sh" ] && [ -x "$WORKSPACE/scripts/apply-upstream-patches.sh" ]; then check "Upstream patch runner" "pass"; else check "Upstream patch runner" "fail" "not found or not executable"; fi
    if [ -f "$WORKSPACE/scripts/lockutil.py" ]; then check "Lock utility" "pass"; else check "Lock utility" "fail" "not found"; fi
    if [ -f "$WORKSPACE/scripts/curate-memory-prompt.md" ]; then check "Curation prompt" "pass"; else check "Curation prompt" "fail" "not found"; fi
    if [ -f "$WORKSPACE/scripts/index-daily-logs-prompt.md" ]; then check "Index prompt" "pass"; else check "Index prompt" "fail" "not found"; fi
    if [ -f "$WORKSPACE/extensions/memory-bridge/index.ts" ]; then check "Memory bridge extension" "pass"; else check "Memory bridge" "fail" "not found"; fi
    if [ -f "$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py" ]; then check "Skill extractor" "pass"; else check "Skill extractor" "fail" "not found"; fi
    if [ -f "$WORKSPACE/MEMORY.md" ]; then check "MEMORY.md" "pass"; else check "MEMORY.md" "fail" "not found"; fi
    if [ -d "$WORKSPACE/memory/session-cache" ]; then check "Session cache directory" "pass"; else check "Session cache" "fail" "not found"; fi
    if [ -d "$WORKSPACE/skills" ]; then check "Skills directory" "pass"; else check "Skills directory" "fail" "not found"; fi

    echo ""
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
fi

# ──────────────────────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────────────────────

echo ""
echo "============================================"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN complete — no changes made${NC}"
else
    echo -e "${GREEN}Memory system installed!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Restart the OpenClaw gateway: pm2 restart ${AGENT_NAME,,}"
    echo "  2. Start a conversation — the memory bridge will capture facts"
    echo "  3. Check daily log: cat $WORKSPACE/memory/$(date +%Y-%m-%d).md"
    echo ""
    if [ "$EXISTING_SYSTEM" = "mem0" ]; then
        echo -e "  ${YELLOW}NOTE: Mem0 has been disabled. If you need to re-enable it:${NC}"
        echo "  Restore from backup: cp $BACKUP_DIR/openclaw.json $OC_CONFIG"
    fi
    echo ""
    echo "  To add Claude Code integration, run:"
    echo "    bash $TOOLKIT_DIR/install-claude-code.sh --agent-name $AGENT_NAME --workspace $WORKSPACE --port $PORT"
    echo ""
    echo -e "  ${BLUE}If FlipClaw saves you time:${NC}"
    echo "  ★  Star it on GitHub — https://github.com/bbesner/flipclaw"
    echo "     It helps others find the project."
    echo ""
    echo "  Built by Brad Besner · Ultraweb Labs"
fi
echo "============================================"
