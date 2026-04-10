#!/bin/bash
# Claude Code Post-Update Health Check
# Run this after any Claude Code CLI update to verify the memory integration is intact.
# Usage: bash {{WORKSPACE}}/scripts/claude-code-update-check.sh

set +e  # Don't exit on errors — we handle them with check()

# Paths baked in at install time by the installer via sed substitution
WORKSPACE="{{WORKSPACE}}"
CLAUDE_HOME="{{CLAUDE_HOME}}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
WARN=0
FAIL=0

check() {
    local label="$1"
    local status="$2"  # pass, warn, fail
    local detail="$3"
    case "$status" in
        pass) echo -e "  ${GREEN}[PASS]${NC} $label"; ((PASS++)) ;;
        warn) echo -e "  ${YELLOW}[WARN]${NC} $label — $detail"; ((WARN++)) ;;
        fail) echo -e "  ${RED}[FAIL]${NC} $label — $detail"; ((FAIL++)) ;;
    esac
}

echo "========================================"
echo "Claude Code Memory Integration — Health Check"
echo "$(date '+%Y-%m-%d %H:%M %Z')"
echo "========================================"
echo ""

# 1. Check Claude Code version
echo "1. Claude Code Version"
CC_VERSION=$(claude --version 2>/dev/null || echo "not found")
echo "   Version: $CC_VERSION"
echo ""

# 2. Check SessionEnd hook
# v3.2.1 Bug #10 fix: handle both flat and nested hook structures.
# Claude Code supports two formats:
#   Flat:   { "SessionEnd": [ { "type": "command", "command": "..." } ] }
#   Nested: { "SessionEnd": [ { "hooks": [ { "type": "command", "command": "..." } ] } ] }
# The previous check only looked at se[0].command and missed the nested form.
echo "2. SessionEnd Hook"
SETTINGS="$CLAUDE_HOME/settings.json"
if [ -f "$SETTINGS" ]; then
    HOOK=$(python3 -c "
import json
d = json.load(open('$SETTINGS'))
hooks = d.get('hooks', {})
se = hooks.get('SessionEnd', [])
if not se:
    print('NOT CONFIGURED')
else:
    # Try flat form first (direct command)
    cmd = se[0].get('command', '') if isinstance(se[0], dict) else ''
    # Then try nested form (hooks array inside a matcher entry)
    if not cmd and isinstance(se[0], dict) and 'hooks' in se[0]:
        nested = se[0].get('hooks', [])
        if nested and isinstance(nested[0], dict):
            cmd = nested[0].get('command', '')
    print(cmd or 'NO COMMAND')
" 2>/dev/null)
    if [[ "$HOOK" == *"claude-code-bridge.py"* ]]; then
        check "SessionEnd hook configured" "pass" ""
    elif [[ "$HOOK" == "NOT CONFIGURED" ]]; then
        check "SessionEnd hook" "fail" "Hook missing from settings.json"
    else
        check "SessionEnd hook" "warn" "Hook exists but points to: $HOOK"
    fi
else
    check "settings.json exists" "fail" "File not found at $SETTINGS"
fi

# 3. Check bridge script exists and is executable
echo ""
echo "3. Bridge Script"
BRIDGE="$WORKSPACE/scripts/claude-code-bridge.py"
if [ -f "$BRIDGE" ]; then
    check "Bridge script exists" "pass" ""
    if python3 -c "import ast; ast.parse(open('$BRIDGE').read())" 2>/dev/null; then
        check "Bridge script parses (no syntax errors)" "pass" ""
    else
        check "Bridge script syntax" "fail" "Python syntax error in bridge script"
    fi
else
    check "Bridge script" "fail" "Not found at $BRIDGE"
fi

# 4. Check bridge log for recent activity
echo ""
echo "4. Bridge Activity"
BRIDGE_LOG="$WORKSPACE/logs/claude-code-bridge.jsonl"
if [ -f "$BRIDGE_LOG" ]; then
    LAST_ENTRY=$(tail -1 "$BRIDGE_LOG" 2>/dev/null)
    LAST_TS=$(echo "$LAST_ENTRY" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('ts','unknown'))" 2>/dev/null || echo "unknown")
    check "Bridge log exists (last entry: $LAST_TS)" "pass" ""
else
    check "Bridge log" "warn" "No log file yet — no sessions have been captured"
fi

# 5. Check CLAUDE.md override is in place
echo ""
echo "5. CLAUDE.md Memory Override"
CLAUDE_MD="$(dirname "$WORKSPACE")/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
    if grep -q "Do NOT use Claude Code's built-in memory system" "$CLAUDE_MD" 2>/dev/null; then
        check "CLAUDE.md has memory override" "pass" ""
    else
        check "CLAUDE.md memory override" "fail" "Override text not found — local memory may be active"
    fi
else
    check "CLAUDE.md" "fail" "Root CLAUDE.md not found"
fi

# 6. Check local memory directory isn't being used
echo ""
echo "6. Local Memory Directory"
LOCAL_MEM="$CLAUDE_HOME/projects/-$(echo "$(dirname "$WORKSPACE")" | tr "/" "-")/memory"
if [ -d "$LOCAL_MEM" ]; then
    FILE_COUNT=$(find "$LOCAL_MEM" -name "*.md" -not -name "MEMORY.md" 2>/dev/null | wc -l)
    if [ "$FILE_COUNT" -eq 0 ]; then
        check "No local memory files (only MEMORY.md redirect)" "pass" ""
    else
        check "Local memory files" "warn" "$FILE_COUNT memory files found — Claude Code may be writing locally"
        find "$LOCAL_MEM" -name "*.md" -not -name "MEMORY.md" -exec echo "    {}" \;
    fi
    # Check MEMORY.md is still the redirect
    if grep -q "Do NOT use this directory" "$LOCAL_MEM/MEMORY.md" 2>/dev/null; then
        check "MEMORY.md is redirect" "pass" ""
    else
        check "MEMORY.md content" "warn" "MEMORY.md may have been overwritten with local content"
    fi
else
    check "Local memory directory" "pass" "Directory doesn't exist (good)"
fi

# 7. Check skill extractor is functional
echo ""
echo "7. Auto-Skill-Capture"
EXTRACTOR="$WORKSPACE/extensions/auto-skill-capture/scripts/skill-extractor.py"
if [ -f "$EXTRACTOR" ]; then
    check "Skill extractor exists" "pass" ""
    if python3 -c "import ast; ast.parse(open('$EXTRACTOR').read())" 2>/dev/null; then
        check "Skill extractor parses (no syntax errors)" "pass" ""
    else
        check "Skill extractor syntax" "fail" "Python syntax error"
    fi
else
    check "Skill extractor" "fail" "Not found at $EXTRACTOR"
fi

# 8. Check agent gateway plugin
echo ""
echo "8. Agent Gateway Plugin"
ASC_ENABLED=$(python3 -c "
import json
d = json.load(open('$WORKSPACE/openclaw.json'))
asc = d.get('plugins',{}).get('entries',{}).get('auto-skill-capture',{})
print('enabled' if asc.get('enabled', True) else 'disabled')
" 2>/dev/null || echo "unknown")
if [ "$ASC_ENABLED" = "enabled" ]; then
    check "auto-skill-capture plugin enabled" "pass" ""
else
    check "auto-skill-capture plugin" "warn" "Status: $ASC_ENABLED"
fi

# 9. Check settings.json hasn't been reset (compare with backup)
echo ""
echo "9. Settings Backup Comparison"
BACKUP="$(dirname "$WORKSPACE")/backups/claude-code-settings.json"
if [ -f "$BACKUP" ]; then
    if diff -q "$SETTINGS" "$BACKUP" > /dev/null 2>&1; then
        check "settings.json matches backup" "pass" ""
    else
        check "settings.json changed from backup" "warn" "Run: diff $BACKUP $SETTINGS"
    fi
else
    check "Settings backup" "warn" "No backup found at $BACKUP — create one with: cp $SETTINGS $BACKUP"
fi

# 10. FlipClaw version check
echo ""
echo "10. FlipClaw Version"
INSTALLED_FC_VERSION=$(cat "$WORKSPACE/.toolkit-version" 2>/dev/null | head -1 || echo "unknown")
echo "    Installed: $INSTALLED_FC_VERSION"
LATEST_FC_VERSION=$(curl -sf --max-time 8 "https://raw.githubusercontent.com/bbesner/flipclaw/main/VERSION" | head -1 2>/dev/null)

_fc_version_gte() {
    local a b
    a=$(echo "$1" | sed 's/^v//')
    b=$(echo "$2" | sed 's/^v//')
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$b" ]
}

if [ -z "$LATEST_FC_VERSION" ]; then
    check "FlipClaw version check" "warn" "Could not reach GitHub (offline or rate-limited)"
elif [ "$INSTALLED_FC_VERSION" = "$LATEST_FC_VERSION" ]; then
    check "FlipClaw $INSTALLED_FC_VERSION (up to date)" "pass" ""
elif _fc_version_gte "$INSTALLED_FC_VERSION" "$LATEST_FC_VERSION"; then
    # Installed is ahead of remote — pass (dev machine or feature branch scenario)
    check "FlipClaw $INSTALLED_FC_VERSION (ahead of main $LATEST_FC_VERSION)" "pass" ""
else
    check "FlipClaw update available: $INSTALLED_FC_VERSION → $LATEST_FC_VERSION" "warn" \
        "Run: bash $WORKSPACE/scripts/flipclaw-update.sh"
    # Drop flag file so next session context can surface it
    touch /tmp/flipclaw-update-available 2>/dev/null
fi

# 11. OpenClaw minimum version check
echo ""
echo "11. OpenClaw Version"
MIN_OC_VERSION="2026.4.9"
INSTALLED_OC_VERSION=$(openclaw --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

_version_gte() {
    local a b
    a=$(echo "$1" | sed 's/^v//')
    b=$(echo "$2" | sed 's/^v//')
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" = "$b" ]
}

if [ -z "$INSTALLED_OC_VERSION" ]; then
    check "OpenClaw not detected" "fail" "Install OpenClaw: npm install -g openclaw"
elif _version_gte "$INSTALLED_OC_VERSION" "$MIN_OC_VERSION"; then
    check "OpenClaw $INSTALLED_OC_VERSION (min: $MIN_OC_VERSION)" "pass" ""
else
    check "OpenClaw $INSTALLED_OC_VERSION too old (min: $MIN_OC_VERSION)" "fail" \
        "Upgrade: npm install -g openclaw@latest"
fi

# Summary
echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${YELLOW}$WARN warnings${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo -e "${RED}ACTION REQUIRED: $FAIL check(s) failed. The memory integration may be broken.${NC}"
    echo "Review failures above and fix before continuing."
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}$WARN warning(s). Review above — may need attention.${NC}"
    exit 0
else
    echo ""
    echo -e "${GREEN}All checks passed. Memory integration is healthy.${NC}"
    exit 0
fi
