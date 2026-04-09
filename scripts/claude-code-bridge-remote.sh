#!/bin/bash
# Remote Session Capture — called by a remote Claude Code's SessionEnd hook
#
# The remote hook sends the transcript over SSH:
#   cat "$TRANSCRIPT_PATH" | ssh user@server "bash /path/to/workspace/scripts/claude-code-bridge-remote.sh SESSION_ID USER_ID"
#
# This script:
#   1. Saves the transcript from stdin to a temp file
#   2. Feeds it through the local bridge script
#   3. Cleans up

WORKSPACE="{{WORKSPACE}}"
SESSION_ID="${1:?Usage: claude-code-bridge-remote.sh SESSION_ID [USER_ID]}"
USER_ID="${2:-remote}"
SESSION_SOURCE="claude-code-${USER_ID}"

# Portable file size (macOS uses -f%z, Linux uses -c%s)
file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

# Save transcript from stdin
TMP_FILE="$WORKSPACE/logs/.remote-session-${SESSION_ID:0:8}.jsonl"
cat > "$TMP_FILE"

# Check size
SIZE=$(file_size "$TMP_FILE")
if [ "$SIZE" -lt 100 ]; then
    rm -f "$TMP_FILE"
    echo "Remote bridge: transcript too small ($SIZE bytes), skipping"
    exit 0
fi

# Feed through the bridge
echo "{\"session_id\": \"$SESSION_ID\", \"transcript_path\": \"$TMP_FILE\"}" | \
    python3 "$WORKSPACE/scripts/claude-code-bridge.py"

EXIT_CODE=$?

# Clean up
rm -f "$TMP_FILE"

exit $EXIT_CODE
