#!/bin/bash
# ============================================================================
# Claude Code ↔ OpenClaw Memory Integration Installer
# Version: 3.2.0 (2026-04-10)
#
# Installs the memory integration pipeline that connects Claude Code CLI
# to an OpenClaw agent's memory system. Supports three deployment modes:
#
#   1. Single user + existing OpenClaw agent
#   2. New deployment from scratch (fresh server)
#   3. Shared agent + multiple Claude Code users
#
# Usage:
#   bash install-claude-code.sh --agent-name "MyAgent" --workspace /home/user/agent --port 3050
#   bash install-claude-code.sh --agent-name "TeamBot" --workspace /path --port 3050 --user employee1 --shared
#   bash install.sh --check   # Verify existing installation
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
    Linux)  IS_MACOS=false ;;
    *)      IS_MACOS=false ;;
esac

# Portable readlink -f (macOS doesn't have it)
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
USER_ID=""
SHARED=false
CHECK_ONLY=false
CLAUDE_HOME=""
DRY_RUN=false
SKIP_OPENCLAW_CONFIG=false
WITH_MCP=false

usage() {
    echo "Usage: bash install.sh [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  --agent-name NAME    Name of the OpenClaw agent (e.g., MyAgent, TeamBot)"
    echo "  --workspace PATH     Absolute path to the agent workspace"
    echo "  --port PORT          OpenClaw gateway port number"
    echo ""
    echo "Optional:"
    echo "  --user ID            User identifier for multi-user setups (e.g., employee1)"
    echo "  --shared             Shared workspace mode (multiple Claude Code users)"
    echo "  --claude-home PATH   Override Claude Code config dir (default: ~/.claude)"
    echo "  --with-mcp           Install MCP server for remote Claude Code access"
    echo "  --skip-openclaw      Skip OpenClaw config changes (for existing agents)"
    echo "  --dry-run            Show what would be done without making changes"
    echo "  --check              Verify existing installation health"
    echo "  --help               Show this help"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent-name) AGENT_NAME="$2"; shift 2 ;;
        --workspace) WORKSPACE="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --user) USER_ID="$2"; shift 2 ;;
        --shared) SHARED=true; shift ;;
        --claude-home) CLAUDE_HOME="$2"; shift 2 ;;
        --with-mcp) WITH_MCP=true; shift ;;
        --skip-openclaw) SKIP_OPENCLAW_CONFIG=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --check) CHECK_ONLY=true; shift ;;
        --help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Set defaults
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
if [ -n "$USER_ID" ]; then
    SESSION_SOURCE="claude-code-${USER_ID}"
else
    SESSION_SOURCE="claude-code"
fi

# Validate
if [ "$CHECK_ONLY" = true ]; then
    if [ -z "$WORKSPACE" ]; then
        echo -e "${RED}--workspace required for --check${NC}"
        exit 1
    fi
    if [ -f "$WORKSPACE/scripts/claude-code-update-check.sh" ]; then
        exec bash "$WORKSPACE/scripts/claude-code-update-check.sh"
    else
        echo -e "${RED}Health check script not found at $WORKSPACE/scripts/claude-code-update-check.sh${NC}"
        exit 1
    fi
fi

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
    echo "FlipClaw requires OpenClaw $MIN_OPENCLAW_VERSION or later."
    echo ""
    echo "Upgrade OpenClaw:"
    echo "  npm install -g openclaw@latest"
    exit 1
fi

# Pre-flight: verify memory pipeline is installed
if [ ! -f "$WORKSPACE/scripts/incremental-memory-capture.py" ]; then
    echo -e "${RED}============================================${NC}"
    echo -e "${RED}Memory pipeline not found!${NC}"
    echo ""
    echo "  The Claude Code integration requires the memory pipeline to be installed first."
    echo "  Missing: $WORKSPACE/scripts/incremental-memory-capture.py"
    echo ""
    echo "  Options:"
    echo "    1. Run install-memory.sh first:"
    echo "       bash $(dirname "$0")/install-memory.sh --agent-name $AGENT_NAME --workspace $WORKSPACE --port $PORT"
    echo ""
    echo "    2. Run the combined installer (installs both):"
    echo "       bash $(dirname "$0")/install.sh --agent-name $AGENT_NAME --workspace $WORKSPACE --port $PORT"
    echo -e "${RED}============================================${NC}"
    exit 1
fi

echo "============================================"
echo -e "${BLUE}Claude Code ↔ OpenClaw Memory Integration${NC}"
echo "Toolkit version: $TOOLKIT_VERSION"
echo "OpenClaw:        $OPENCLAW_VERSION (min: $MIN_OPENCLAW_VERSION)"
echo "============================================"
echo ""
echo "  Agent name:     $AGENT_NAME"
echo "  Workspace:      $WORKSPACE"
echo "  Gateway port:   $PORT"
echo "  User ID:        ${USER_ID:-"(default — single user)"}"
echo "  Session source: $SESSION_SOURCE"
echo "  Shared mode:    $SHARED"
echo "  Claude home:    $CLAUDE_HOME"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN — no changes will be made${NC}"
    echo ""
fi

# ──────────────────────────────────────────────────────────────
# Step 1: Create directory structure
# ──────────────────────────────────────────────────────────────

echo -e "${BLUE}Step 1: Directory structure${NC}"

DIRS=(
    "$WORKSPACE/memory"
    "$WORKSPACE/memory/session-cache"
    "$WORKSPACE/skills"
    "$WORKSPACE/skills/.auto-skill-capture"
    "$WORKSPACE/agents/$SESSION_SOURCE/sessions"
    "$WORKSPACE/agents/main/sessions"
    "$WORKSPACE/scripts"
    "$WORKSPACE/extensions/auto-skill-capture/scripts"
    "$WORKSPACE/extensions/auto-skill-capture/config"
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
    else
        echo "  Exists: $dir"
    fi
done

# ──────────────────────────────────────────────────────────────
# Step 2: Install scripts (parameterized)
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 2: Install scripts${NC}"

install_script() {
    local src="$1"
    local dst="$2"
    local description="$3"

    if [ "$DRY_RUN" = true ]; then
        echo "  Would install: $dst ($description)"
        return
    fi

    cp "$src" "$dst"
    chmod +x "$dst"
    echo "  Installed: $dst ($description)"
}

# lockutil.py — no parameterization needed
install_script "$TOOLKIT_DIR/scripts/lockutil.py" "$WORKSPACE/scripts/lockutil.py" "Lock utility"

# Parameterized scripts
if [ "$DRY_RUN" = false ]; then
    # claude-code-bridge.py
    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|{{SESSION_SOURCE}}|$SESSION_SOURCE|g" \
        -e "s|{{RATE_LIMIT}}|20|g" \
        "$TOOLKIT_DIR/scripts/claude-code-bridge.py" > "$WORKSPACE/scripts/claude-code-bridge.py"
    chmod +x "$WORKSPACE/scripts/claude-code-bridge.py"
    echo "  Installed: $WORKSPACE/scripts/claude-code-bridge.py (bridge)"

    # claude-code-sweep.py
    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|{{SESSION_SOURCE}}|$SESSION_SOURCE|g" \
        -e "s|{{CLAUDE_HOME}}|$CLAUDE_HOME|g" \
        "$TOOLKIT_DIR/scripts/claude-code-sweep.py" > "$WORKSPACE/scripts/claude-code-sweep.py"
    chmod +x "$WORKSPACE/scripts/claude-code-sweep.py"
    echo "  Installed: $WORKSPACE/scripts/claude-code-sweep.py (sweep)"

    # claude-code-update-check.sh
    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|{{CLAUDE_HOME}}|$CLAUDE_HOME|g" \
        -e "s|{{AGENT_NAME}}|$AGENT_NAME|g" \
        "$TOOLKIT_DIR/scripts/claude-code-update-check.sh" > "$WORKSPACE/scripts/claude-code-update-check.sh"
    chmod +x "$WORKSPACE/scripts/claude-code-update-check.sh"
    echo "  Installed: $WORKSPACE/scripts/claude-code-update-check.sh (health check)"

    # claude-code-turn-capture.py (per-turn memory capture via Stop hook)
    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|{{CLAUDE_HOME}}|$CLAUDE_HOME|g" \
        "$TOOLKIT_DIR/scripts/claude-code-turn-capture.py" > "$WORKSPACE/scripts/claude-code-turn-capture.py"
    chmod +x "$WORKSPACE/scripts/claude-code-turn-capture.py"
    echo "  Installed: $WORKSPACE/scripts/claude-code-turn-capture.py (per-turn capture)"

    # flipclaw-update.sh (self-service updater)
    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        "$TOOLKIT_DIR/scripts/flipclaw-update.sh" > "$WORKSPACE/scripts/flipclaw-update.sh"
    chmod +x "$WORKSPACE/scripts/flipclaw-update.sh"
    echo "  Installed: $WORKSPACE/scripts/flipclaw-update.sh (updater)"
else
    echo "  Would install: claude-code-bridge.py (bridge)"
    echo "  Would install: claude-code-sweep.py (sweep)"
    echo "  Would install: claude-code-update-check.sh (health check)"
    echo "  Would install: claude-code-turn-capture.py (per-turn capture)"
    echo "  Would install: flipclaw-update.sh (updater)"
fi

# ──────────────────────────────────────────────────────────────
# Step 3: Install auto-skill-capture extension
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 3: Auto-skill-capture extension${NC}"

EXT_DIR="$WORKSPACE/extensions/auto-skill-capture"

for f in index.ts openclaw.plugin.json package.json; do
    src="$TOOLKIT_DIR/extensions/auto-skill-capture/$f"
    if [ -f "$src" ]; then
        if [ "$DRY_RUN" = false ]; then
            sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" "$src" > "$EXT_DIR/$f"
            echo "  Installed: $EXT_DIR/$f"
        else
            echo "  Would install: $EXT_DIR/$f"
        fi
    fi
done

# skill-extractor.py
if [ "$DRY_RUN" = false ]; then
    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        "$TOOLKIT_DIR/scripts/skill-extractor.py" > "$EXT_DIR/scripts/skill-extractor.py"
    chmod +x "$EXT_DIR/scripts/skill-extractor.py"
    echo "  Installed: $EXT_DIR/scripts/skill-extractor.py"
else
    echo "  Would install: $EXT_DIR/scripts/skill-extractor.py"
fi

# ──────────────────────────────────────────────────────────────
# Step 4: Configure Claude Code
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 4: Configure Claude Code${NC}"

# Generate settings.json hook
SETTINGS_FILE="$CLAUDE_HOME/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
    echo "  Existing settings.json found — checking for SessionEnd hook"
    HAS_HOOK=$(python3 -c "
import json
d = json.load(open('$SETTINGS_FILE'))
hooks = d.get('hooks', {})
se = hooks.get('SessionEnd', [])
print('yes' if se else 'no')
" 2>/dev/null || echo "no")

    if [ "$HAS_HOOK" = "yes" ]; then
        echo -e "  ${YELLOW}SessionEnd hook already exists — skipping (check manually)${NC}"
    else
        if [ "$DRY_RUN" = false ]; then
            # Add hook to existing settings
            python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    d = json.load(f)
hooks = d.setdefault('hooks', {})
hooks['Stop'] = [{'hooks': [{'type': 'command', 'command': 'python3 $WORKSPACE/scripts/claude-code-turn-capture.py', 'timeout': 30, 'async': True}]}]
hooks['SessionEnd'] = [{'hooks': [{'type': 'command', 'command': 'python3 $WORKSPACE/scripts/claude-code-bridge.py'}]}]
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(d, f, indent=2)
print('  Added SessionEnd hook to existing settings.json')
"
        else
            echo "  Would add SessionEnd hook to settings.json"
        fi
    fi
else
    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$CLAUDE_HOME"
        python3 -c "
import json
d = {
    'hooks': {
        'Stop': [{'hooks': [{'type': 'command', 'command': 'python3 $WORKSPACE/scripts/claude-code-turn-capture.py', 'timeout': 30, 'async': True}]}],
        'SessionEnd': [{'hooks': [{'type': 'command', 'command': 'python3 $WORKSPACE/scripts/claude-code-bridge.py'}]}]
    }
}
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(d, f, indent=2)
"
        echo "  Created: $SETTINGS_FILE"
    else
        echo "  Would create: $SETTINGS_FILE"
    fi
fi

# Backup settings
BACKUP_DIR="$(dirname "$WORKSPACE")/backups"
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$BACKUP_DIR"
    cp "$SETTINGS_FILE" "$BACKUP_DIR/claude-code-settings.json" 2>/dev/null
    echo "  Backed up settings to: $BACKUP_DIR/claude-code-settings.json"
fi

# Configure CLAUDE.md — append memory integration section or create new
WORKING_DIR="$(dirname "$WORKSPACE")"
CLAUDE_MD_PATH="$WORKING_DIR/CLAUDE.md"
INTEGRATION_MARKER="CLAUDE-CODE-MEMORY-INTEGRATION"

if [ -f "$CLAUDE_MD_PATH" ]; then
    # CLAUDE.md exists — check if our section is already there
    if grep -q "$INTEGRATION_MARKER" "$CLAUDE_MD_PATH" 2>/dev/null; then
        echo "  CLAUDE.md already has memory integration section — skipping"
    elif [ "$DRY_RUN" = false ]; then
        # Append our section to the existing file
        echo "" >> "$CLAUDE_MD_PATH"
        echo "<!-- BEGIN CLAUDE-CODE-MEMORY-INTEGRATION -->" >> "$CLAUDE_MD_PATH"
        sed -e "s|{{AGENT_NAME}}|$AGENT_NAME|g" \
            -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
            -e "s|{{PORT}}|$PORT|g" \
            -e "s|{{SESSION_SOURCE}}|$SESSION_SOURCE|g" \
            "$TOOLKIT_DIR/templates/CLAUDE-append.md.template" >> "$CLAUDE_MD_PATH"
        echo "  Appended memory integration section to existing CLAUDE.md"
    else
        echo "  Would append memory integration section to existing CLAUDE.md"
    fi
elif [ "$DRY_RUN" = false ]; then
    # No CLAUDE.md — create from full template
    sed -e "s|{{AGENT_NAME}}|$AGENT_NAME|g" \
        -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|{{PORT}}|$PORT|g" \
        -e "s|{{SESSION_SOURCE}}|$SESSION_SOURCE|g" \
        -e "s|{{DATE}}|$(date +%Y-%m-%d)|g" \
        "$TOOLKIT_DIR/templates/CLAUDE.md.template" > "$CLAUDE_MD_PATH"
    echo "  Created: $CLAUDE_MD_PATH"
else
    echo "  Would create: $CLAUDE_MD_PATH"
fi

# Set up local memory redirect
PROJECTS_DIR="$CLAUDE_HOME/projects/-$(echo "$WORKING_DIR" | tr '/' '-')/memory"
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$PROJECTS_DIR"
    cat > "$PROJECTS_DIR/MEMORY.md" << MEMEOF
# Memory Redirect

Do NOT use this directory for memory storage. ${AGENT_NAME}'s memory system is the single source of truth.

Search memory:
\`\`\`bash
cd $WORKSPACE && OPENCLAW_CONFIG_PATH=$WORKSPACE/openclaw.json openclaw memory search "query" --max-results 5
\`\`\`

See $CLAUDE_MD_PATH for full details.
MEMEOF
    echo "  Created memory redirect: $PROJECTS_DIR/MEMORY.md"
fi

# ──────────────────────────────────────────────────────────────
# Step 5: Configure OpenClaw (optional)
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 5: OpenClaw configuration${NC}"

OPENCLAW_CONFIG="$WORKSPACE/openclaw.json"

if [ "$SKIP_OPENCLAW_CONFIG" = true ]; then
    echo "  Skipped (--skip-openclaw flag)"
elif [ ! -f "$OPENCLAW_CONFIG" ]; then
    echo -e "  ${YELLOW}No openclaw.json found at $OPENCLAW_CONFIG — skipping${NC}"
    echo "  You'll need to manually add the auto-skill-capture plugin config"
else
    if [ "$DRY_RUN" = false ]; then
        python3 << PYEOF
import json

with open('$OPENCLAW_CONFIG') as f:
    d = json.load(f)

# Add auto-skill-capture plugin
plugins = d.setdefault('plugins', {})
entries = plugins.setdefault('entries', {})
if 'auto-skill-capture' not in entries:
    entries['auto-skill-capture'] = {
        'enabled': True,
        'config': {
            'captureEnabled': True,
            'recallEnabled': False,
            'outputDir': 'skills',
            'extractionModel': 'gpt-5.4-mini',
            'generationModel': 'gpt-5.4-mini',
            'provider': 'openai'
        }
    }
    print('  Added auto-skill-capture plugin')
else:
    print('  auto-skill-capture plugin already configured')

# Add skills to semantic index
agents = d.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
ms = defaults.setdefault('memorySearch', {})
if 'skills' not in ms.get('extraPaths', []):
    ms.setdefault('extraPaths', []).append('skills')
    print('  Added skills to memorySearch.extraPaths')
else:
    print('  skills already in memorySearch.extraPaths')

with open('$OPENCLAW_CONFIG', 'w') as f:
    json.dump(d, f, indent=2)
PYEOF
    else
        echo "  Would add auto-skill-capture plugin and extraPaths to openclaw.json"
    fi
fi

# ──────────────────────────────────────────────────────────────
# Step 6: Shared mode setup (if applicable)
# ──────────────────────────────────────────────────────────────

if [ "$SHARED" = true ]; then
    echo ""
    echo -e "${BLUE}Step 6: Shared mode permissions${NC}"

    if [ "$DRY_RUN" = false ]; then
        SHARED_GROUP="${AGENT_NAME,,}-shared"

        if [ "$IS_MACOS" = true ]; then
            # macOS: use dseditgroup for group management
            if ! dscl . -read /Groups/"$SHARED_GROUP" > /dev/null 2>&1; then
                sudo dseditgroup -o create "$SHARED_GROUP" 2>/dev/null && echo "  Created group: $SHARED_GROUP" || echo "  Could not create group (may need sudo)"
            else
                echo "  Group exists: $SHARED_GROUP"
            fi

            sudo chgrp -R "$SHARED_GROUP" "$WORKSPACE" 2>/dev/null
            sudo chmod -R g+rwX "$WORKSPACE" 2>/dev/null
            echo "  Set group permissions on workspace"
            echo ""
            echo -e "  ${YELLOW}IMPORTANT: Add each user to the group:${NC}"
            echo "    sudo dseditgroup -o edit -a employee1 -t user $SHARED_GROUP"
            echo "    sudo dseditgroup -o edit -a employee2 -t user $SHARED_GROUP"
            echo "    sudo dseditgroup -o edit -a employee3 -t user $SHARED_GROUP"
        else
            # Linux: use groupadd/usermod
            if ! getent group "$SHARED_GROUP" > /dev/null 2>&1; then
                sudo groupadd "$SHARED_GROUP" 2>/dev/null && echo "  Created group: $SHARED_GROUP" || echo "  Could not create group (may need sudo)"
            else
                echo "  Group exists: $SHARED_GROUP"
            fi

            sudo chgrp -R "$SHARED_GROUP" "$WORKSPACE" 2>/dev/null
            sudo chmod -R g+rwX "$WORKSPACE" 2>/dev/null
            sudo chmod g+s "$WORKSPACE" "$WORKSPACE/memory" "$WORKSPACE/skills" "$WORKSPACE/agents" "$WORKSPACE/logs" 2>/dev/null
            echo "  Set group permissions on workspace"
            echo ""
            echo -e "  ${YELLOW}IMPORTANT: Add each user to the group:${NC}"
            echo "    sudo usermod -aG $SHARED_GROUP employee1"
            echo "    sudo usermod -aG $SHARED_GROUP employee2"
            echo "    sudo usermod -aG $SHARED_GROUP employee3"
        fi
    else
        echo "  Would set up shared group permissions"
    fi
fi

# ──────────────────────────────────────────────────────────────
# Step 6b: MCP Server (if --with-mcp)
# ──────────────────────────────────────────────────────────────

if [ "$WITH_MCP" = true ]; then
    echo ""
    echo -e "${BLUE}Step 6b: MCP Server${NC}"

    MCP_DIR="$WORKSPACE/mcp-server"
    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$MCP_DIR"

        # Copy and parameterize server
        sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
            "$TOOLKIT_DIR/mcp-server/server.mjs" > "$MCP_DIR/server.mjs"
        cp "$TOOLKIT_DIR/mcp-server/package.json" "$MCP_DIR/package.json"
        echo "  Installed: $MCP_DIR/server.mjs"

        # Install dependencies
        echo "  Installing MCP SDK..."
        cd "$MCP_DIR" && npm install --silent 2>/dev/null && cd - > /dev/null
        echo "  Dependencies installed"

        # Add MCP server config to Claude Code settings
        python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    d = json.load(f)
mcp = d.setdefault('mcpServers', {})
mcp['${AGENT_NAME,,}-memory'] = {
    'command': 'node',
    'args': ['$MCP_DIR/server.mjs'],
    'env': {
        'OPENCLAW_WORKSPACE': '$WORKSPACE',
        'OPENCLAW_CONFIG_PATH': '$WORKSPACE/openclaw.json'
    }
}
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(d, f, indent=2)
print('  Added MCP server to Claude Code settings')
"
        echo ""
        echo -e "  ${GREEN}MCP server installed!${NC}"
        echo "  Claude Code will automatically start it when you use memory tools."
        echo ""
        echo "  For remote access via SSH tunnel:"
        echo "    ssh -L 8500:localhost:8500 user@server"
        echo "    Then configure your local Claude Code to use the MCP server."
    else
        echo "  Would install MCP server to $MCP_DIR"
    fi
fi

# ──────────────────────────────────────────────────────────────
# Step 7: Create initial files
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 7: Initial files${NC}"

if [ "$DRY_RUN" = false ]; then
    # MEMORY.md if it doesn't exist
    if [ ! -f "$WORKSPACE/MEMORY.md" ]; then
        cat > "$WORKSPACE/MEMORY.md" << MEMORYEOF
# ${AGENT_NAME} — Core Memory

## Overview
- Agent: ${AGENT_NAME}
- Gateway port: ${PORT}
- Workspace: ${WORKSPACE}
- Created: $(date +%Y-%m-%d)

## People

## Infrastructure

## Business Rules

## Decisions
MEMORYEOF
        echo "  Created: $WORKSPACE/MEMORY.md"
    else
        echo "  Exists: $WORKSPACE/MEMORY.md"
    fi

    # Skill capture index
    if [ ! -f "$WORKSPACE/skills/.auto-skill-capture/capture-log.md" ]; then
        touch "$WORKSPACE/skills/.auto-skill-capture/capture-log.md"
        echo "  Created: capture-log.md"
    fi

    # Version marker for sync tracking
    echo "$TOOLKIT_VERSION" > "$WORKSPACE/.toolkit-version"
    echo "  Written toolkit version marker: $TOOLKIT_VERSION"

    # Install params — merge Claude Code fields into existing file (or create if standalone install)
    PARAMS_FILE="$WORKSPACE/.flipclaw-install.json"
    python3 - << PYEOF
import json, os
from datetime import date

from datetime import datetime, timezone

PARAMS_FILE = '$PARAMS_FILE'
if os.path.exists(PARAMS_FILE):
    with open(PARAMS_FILE) as f:
        p = json.load(f)
else:
    p = {
        'flipclaw_version': '$TOOLKIT_VERSION',
        'openclaw_version': '$OPENCLAW_VERSION',
        'installed_at': date.today().isoformat(),
        'workspace': '$WORKSPACE',
        'agent_name': '$AGENT_NAME',
        'port': '$PORT',
        'models': {},
        'update_history': []
    }

prev_version = p.get('flipclaw_version', 'unknown')
p['agent_name'] = '$AGENT_NAME'
p['port'] = '$PORT'
p['claude_home'] = '$CLAUDE_HOME'
p['user_id'] = '$USER_ID'
p['session_source'] = '$SESSION_SOURCE'
p['shared'] = $( [ "$SHARED" = true ] && echo "True" || echo "False" )
p['with_mcp'] = $( [ "$WITH_MCP" = true ] && echo "True" || echo "False" )
p['flipclaw_version'] = '$TOOLKIT_VERSION'
p['openclaw_version'] = '$OPENCLAW_VERSION'

if prev_version != '$TOOLKIT_VERSION':
    history = p.get('update_history', [])
    # Avoid duplicate if memory installer already appended this transition
    if not (history and history[-1].get('from') == prev_version and history[-1].get('to') == '$TOOLKIT_VERSION'):
        history.append({
            'from': prev_version,
            'to': '$TOOLKIT_VERSION',
            'at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'openclaw_version': '$OPENCLAW_VERSION',
            'trigger': 'install-claude-code',
        })
        p['update_history'] = history[-50:]

with open(PARAMS_FILE, 'w') as f:
    json.dump(p, f, indent=2)
PYEOF
    echo "  Saved install params to .flipclaw-install.json"
fi

# ──────────────────────────────────────────────────────────────
# Step 8: Verify installation
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 8: Verification${NC}"

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

    if [ -f "$WORKSPACE/scripts/claude-code-bridge.py" ]; then check "Bridge script" "pass"; else check "Bridge script" "fail" "not found"; fi
    if [ -f "$WORKSPACE/scripts/lockutil.py" ]; then check "Lock utility" "pass"; else check "Lock utility" "fail" "not found"; fi
    if [ -f "$WORKSPACE/scripts/claude-code-sweep.py" ]; then check "Sweep script" "pass"; else check "Sweep script" "fail" "not found"; fi
    if [ -f "$WORKSPACE/scripts/claude-code-update-check.sh" ]; then check "Health check" "pass"; else check "Health check" "fail" "not found"; fi
    if [ -f "$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py" ]; then check "Skill extractor" "pass"; else check "Skill extractor" "fail" "not found"; fi
    if [ -d "$WORKSPACE/agents/$SESSION_SOURCE/sessions" ]; then check "Session directory ($SESSION_SOURCE)" "pass"; else check "Session directory" "fail" "not found"; fi

    if [ -f "$SETTINGS_FILE" ]; then
        if grep -q "claude-code-bridge" "$SETTINGS_FILE" 2>/dev/null; then check "SessionEnd hook" "pass"; else check "SessionEnd hook" "fail" "not in settings.json"; fi
    else
        check "settings.json" "fail" "file not found"
    fi

    [ -f "$CLAUDE_MD_PATH" ] && check "CLAUDE.md" "pass" || check "CLAUDE.md" "fail" "not found"

    echo ""
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
fi

# ──────────────────────────────────────────────────────────────
# Step 9: Set up cron jobs (health check + sweep)
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 9: Cron jobs${NC}"

if [ "$DRY_RUN" = false ]; then
    # Check if OpenClaw gateway is reachable for cron setup
    OC_CONFIG="$WORKSPACE/openclaw.json"
    if [ -f "$OC_CONFIG" ]; then
        GW_PORT=$(python3 -c "import json; print(json.load(open('$OC_CONFIG')).get('gateway',{}).get('port',''))" 2>/dev/null)
        GW_HEALTHY=$(curl -s -m 3 "http://localhost:$GW_PORT/health" 2>/dev/null | grep -qi "ok" && echo "yes" || echo "no")

        if [ "$GW_HEALTHY" = "yes" ]; then
            echo "  Gateway is healthy — setting up cron jobs via OpenClaw"

            # Request cron setup via system event
            cd "$WORKSPACE" && OPENCLAW_CONFIG_PATH="$OC_CONFIG" OPENCLAW_GATEWAY_URL="ws://127.0.0.1:$GW_PORT" \
                openclaw system event --text "Set up two cron jobs for Claude Code memory integration:

1. Name: 'claude-code-health-check'
   Schedule: every 6 hours
   Command: bash $WORKSPACE/scripts/claude-code-update-check.sh
   On failure: notify the owner via available channels (Telegram, SMS, etc.)

2. Name: 'claude-code-session-sweep'
   Schedule: every 4 hours
   Command: python3 $WORKSPACE/scripts/claude-code-sweep.py
   Purpose: catches sessions the SessionEnd hook missed

Both should use systemEvent kind. Do not create duplicates if they already exist." 2>/dev/null | tail -1

            echo "  Cron job setup requested (agent will process asynchronously)"
        else
            echo -e "  ${YELLOW}Gateway not reachable (port $GW_PORT) — skipping cron setup${NC}"
            echo "  Set up cron jobs manually after the gateway is running:"
            echo "    - Health check: every 6 hours — bash $WORKSPACE/scripts/claude-code-update-check.sh"
            echo "    - Session sweep: every 4 hours — python3 $WORKSPACE/scripts/claude-code-sweep.py"
        fi
    else
        echo -e "  ${YELLOW}No openclaw.json — skipping cron setup${NC}"
        echo "  Set up cron jobs manually after configuring OpenClaw"
    fi
else
    echo "  Would set up cron jobs: health check (6h) + session sweep (4h)"
fi

# ──────────────────────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────────────────────

echo ""
echo "============================================"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN complete — no changes made${NC}"
    echo "Remove --dry-run to install for real."
else
    echo -e "${GREEN}Installation complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Restart the OpenClaw gateway: pm2 restart ${AGENT_NAME,,}"
    echo "  2. Run the health check: bash $WORKSPACE/scripts/claude-code-update-check.sh"
    echo "  3. Start a Claude Code session and verify the bridge fires on exit"
    if [ "$SHARED" = true ]; then
        echo "  4. Add users to the shared group (see Step 6 output above)"
    fi
fi
echo "============================================"
