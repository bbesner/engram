#!/bin/bash
# ============================================================================
# Memory System Installer
# Version: 3.0.0 (2026-04-09)
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

echo "============================================"
echo -e "${BLUE}Memory System Installer${NC}"
echo "Toolkit version: $TOOLKIT_VERSION"
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
# Step 2: Back up existing data
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Step 2: Back up existing data${NC}"

BACKUP_DIR="$(dirname "$WORKSPACE")/backups/memory-pre-install-$(date +%Y%m%d-%H%M%S)"

if [ "$DRY_RUN" = false ]; then
    mkdir -p "$BACKUP_DIR"

    # Back up existing memory files
    if [ -d "$WORKSPACE/memory" ]; then
        cp -r "$WORKSPACE/memory" "$BACKUP_DIR/memory" 2>/dev/null
        echo "  Backed up: memory/ → $BACKUP_DIR/memory/"
    fi

    # Back up MEMORY.md
    if [ -f "$WORKSPACE/MEMORY.md" ]; then
        cp "$WORKSPACE/MEMORY.md" "$BACKUP_DIR/MEMORY.md"
        echo "  Backed up: MEMORY.md"
    fi

    # Back up openclaw.json
    if [ -f "$OC_CONFIG" ]; then
        cp "$OC_CONFIG" "$BACKUP_DIR/openclaw.json"
        echo "  Backed up: openclaw.json"
    fi

    # Back up skills
    if [ -d "$WORKSPACE/skills" ]; then
        cp -r "$WORKSPACE/skills" "$BACKUP_DIR/skills" 2>/dev/null
        echo "  Backed up: skills/"
    fi

    echo "  Backup location: $BACKUP_DIR"
else
    echo "  Would back up to: $BACKUP_DIR"
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
    "$WORKSPACE/wiki"
    "$WORKSPACE/skills"
    "$WORKSPACE/skills/.auto-skill-capture"
    "$WORKSPACE/agents/main/sessions"
    "$WORKSPACE/scripts"
    "$WORKSPACE/scripts/.archived"
    "$WORKSPACE/extensions/memory-bridge"
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
    fi
done

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
else
    echo "  Would install: incremental-memory-capture.py (model: $CAPTURE_MODEL)"
    echo "  Would install: memory-writer.py (legacy manual backfill only, model: $WRITER_MODEL)"
    echo "  Would install: curate-memory-prompt.md (legacy manual reference)"
    echo "  Would install: index-daily-logs-prompt.md"
    echo "  Would install: lockutil.py"
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
    if [ "$DRY_RUN" = false ]; then
        python3 << PYEOF
import json

with open('$OC_CONFIG') as f:
    d = json.load(f)

plugins = d.setdefault('plugins', {})
entries = plugins.setdefault('entries', {})

# Disable Mem0 if present
if 'openclaw-mem0' in entries:
    entries['openclaw-mem0']['enabled'] = False
    print('  Disabled: openclaw-mem0 plugin')

# Add memory-bridge plugin
if 'memory-bridge' not in entries and 'ari-memory-bridge' not in entries:
    entries['memory-bridge'] = {
        'enabled': True,
        'config': {}
    }
    print('  Added: memory-bridge plugin')
else:
    print('  memory-bridge plugin already configured')

# Add auto-skill-capture plugin
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
    print('  Added: auto-skill-capture plugin')
else:
    print('  auto-skill-capture plugin already configured')

# Configure memory-core Dreaming
mc = entries.get('memory-core', {})
if not mc.get('config', {}).get('dreaming', {}).get('enabled'):
    mc.setdefault('config', {})['dreaming'] = {
        'enabled': True,
        'frequency': '0 4 * * *',
        'timezone': 'America/New_York',
        'verboseLogging': True,
        'storage': {'mode': 'both', 'separateReports': True},
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
    entries['memory-core'] = mc
    print('  Configured: memory-core Dreaming (daily 4 AM)')
else:
    print('  memory-core Dreaming already configured')

# Configure Memory Wiki (bridge mode)
if 'memory-wiki' not in entries:
    entries['memory-wiki'] = {
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
    print('  Added: memory-wiki plugin (bridge mode)')
else:
    print('  memory-wiki plugin already configured')

# Add memory-wiki to plugins.allow if not present
allow = plugins.get('allow', [])
if 'memory-wiki' not in allow:
    allow.append('memory-wiki')
    plugins['allow'] = allow
    print('  Added memory-wiki to plugins.allow')

# Configure continuation-skip
agents = d.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
if defaults.get('contextInjection') != 'continuation-skip':
    defaults['contextInjection'] = 'continuation-skip'
    print('  Configured: contextInjection = continuation-skip')

# Configure memorySearch
agents = d.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})
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
    print('  Configured: memorySearch (hybrid Gemini search)')
else:
    # Just ensure skills are in extraPaths
    if 'skills' not in ms.get('extraPaths', []):
        ms.setdefault('extraPaths', []).append('skills')
        defaults['memorySearch'] = ms
        print('  Added skills to existing memorySearch.extraPaths')
    else:
        print('  memorySearch already configured')

with open('$OC_CONFIG', 'w') as f:
    json.dump(d, f, indent=2)
PYEOF
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
fi
echo "============================================"
