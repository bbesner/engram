#!/bin/bash
# ============================================================================
# Combined Installer — Memory System + Claude Code Integration
#
# Runs install-memory.sh first, then install-claude-code.sh.
# All arguments are passed through to both installers.
#
# Usage:
#   bash install.sh --agent-name "MyAgent" --workspace /home/user/agent --port 3050
#   bash install.sh --agent-name "Bot" --workspace /path --port 3050 --user employee1 --shared --with-mcp
# ============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo "============================================"
echo -e "${BLUE}Full Installation — Memory + Claude Code${NC}"
echo "============================================"
echo ""

# ── Phase 1: Memory System ──

echo -e "${BLUE}Phase 1: Installing memory system...${NC}"
echo ""

# Split args: some flags are memory-installer-only, some are Claude-Code-only.
# Passing an unrecognized flag to either sub-installer makes it hard-exit, so
# we build MEMORY_ARGS and CLAUDE_ARGS explicitly here.
MEMORY_ARGS=()
CLAUDE_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        # Claude-Code-only flags — strip from MEMORY_ARGS
        --user|--claude-home)
            CLAUDE_ARGS+=("$1" "$2"); shift 2 ;;
        --shared|--with-mcp)
            CLAUDE_ARGS+=("$1"); shift ;;
        # Memory-installer-only flags — strip from CLAUDE_ARGS
        --capture-model|--capture-provider|--writer-model|--writer-provider|\
        --extraction-model|--generation-model|--embedding-provider|--embedding-model|\
        --gemini-key)
            MEMORY_ARGS+=("$1" "$2"); shift 2 ;;
        # Shared flags — pass to both
        *)
            MEMORY_ARGS+=("$1")
            CLAUDE_ARGS+=("$1")
            shift ;;
    esac
done

bash "$SCRIPT_DIR/install-memory.sh" "${MEMORY_ARGS[@]}"
MEMORY_EXIT=$?

if [ $MEMORY_EXIT -ne 0 ]; then
    echo ""
    echo -e "${RED}Memory system installation failed (exit code $MEMORY_EXIT)${NC}"
    echo "Fix the issues above before continuing."
    exit $MEMORY_EXIT
fi

echo ""
echo "────────────────────────────────────────────"
echo ""

# ── Phase 2: Claude Code Integration ──

echo -e "${BLUE}Phase 2: Installing Claude Code integration...${NC}"
echo ""

bash "$SCRIPT_DIR/install-claude-code.sh" "${CLAUDE_ARGS[@]}"
CLAUDE_EXIT=$?

if [ $CLAUDE_EXIT -ne 0 ]; then
    echo ""
    echo -e "${RED}Claude Code integration failed (exit code $CLAUDE_EXIT)${NC}"
    echo "The memory system was installed successfully."
    echo "Fix the issues above and re-run install-claude-code.sh separately."
    exit $CLAUDE_EXIT
fi

echo ""
echo "============================================"
echo -e "${GREEN}Full installation complete!${NC}"
echo ""
echo "Both the memory system and Claude Code integration are installed."
echo "============================================"
