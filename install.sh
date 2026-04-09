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

# Filter out Claude Code-specific flags for the memory installer
MEMORY_ARGS=()
CLAUDE_ARGS=("$@")
SKIP_NEXT=false

for arg in "$@"; do
    if [ "$SKIP_NEXT" = true ]; then
        SKIP_NEXT=false
        continue
    fi
    case "$arg" in
        --user|--claude-home)
            SKIP_NEXT=true  # Skip this and next arg
            ;;
        --shared|--with-mcp)
            ;;  # Skip Claude Code-only flags
        *)
            MEMORY_ARGS+=("$arg")
            ;;
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
