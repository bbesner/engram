#!/usr/bin/env bash
# wiki-daily-ingest.sh
#
# FlipClaw workaround for OpenClaw wiki bridge bug (Known Issue #2).
#
# OpenClaw's wiki bridge listArtifacts() returns 0 artifacts, a regression
# reintroduced in OpenClaw 2026.4.11 after being fixed in 2026.4.10. This
# means the wiki never auto-populates from memory-core's public artifact
# export. This script works around the bug by manually ingesting daily logs,
# dreaming reports, and core memory into the wiki via `openclaw wiki ingest`.
#
# Usage:
#   wiki-daily-ingest.sh --workspace /home/ubuntu/ari
#   WORKSPACE=/home/ubuntu/ari wiki-daily-ingest.sh
#   cd /home/ubuntu/ari && wiki-daily-ingest.sh
#
# Designed to be run daily via OpenClaw cron or system crontab. Idempotent --
# re-ingesting an already-ingested file updates it in place.
#
# Exit codes:
#   0 - all existing files ingested (or nothing to ingest)
#   1 - workspace not found or invalid
#   2 - openclaw wiki ingest failed for one or more files

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
WORKSPACE="${WORKSPACE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      WORKSPACE="$2"
      shift 2
      ;;
    --workspace=*)
      WORKSPACE="${1#--workspace=}"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: wiki-daily-ingest.sh [--workspace /path/to/workspace]" >&2
      exit 1
      ;;
  esac
done

# Default to current directory if not set
WORKSPACE="${WORKSPACE:-$(pwd)}"

# ---------------------------------------------------------------------------
# Validate workspace
# ---------------------------------------------------------------------------
if [[ ! -d "$WORKSPACE" ]]; then
  echo "ERROR: workspace directory not found: $WORKSPACE" >&2
  exit 1
fi

if [[ ! -f "$WORKSPACE/openclaw.json" ]]; then
  echo "ERROR: no openclaw.json found in workspace: $WORKSPACE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Setup logging
# ---------------------------------------------------------------------------
LOG_DIR="$WORKSPACE/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/wiki-daily-ingest.log"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Dates
# ---------------------------------------------------------------------------
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)

# ---------------------------------------------------------------------------
# Build file list
# ---------------------------------------------------------------------------
declare -a FILES_TO_INGEST=()
declare -a TITLES=()

add_if_exists() {
  local filepath="$1"
  local title="$2"
  if [[ -f "$filepath" ]]; then
    FILES_TO_INGEST+=("$filepath")
    TITLES+=("$title")
  fi
}

# Daily logs (today + yesterday)
add_if_exists "$WORKSPACE/memory/$TODAY.md"     "Daily Log $TODAY"
add_if_exists "$WORKSPACE/memory/$YESTERDAY.md" "Daily Log $YESTERDAY"

# Dreaming reports -- light (today + yesterday)
add_if_exists "$WORKSPACE/memory/dreaming/light/$TODAY.md"     "Dreaming Light $TODAY"
add_if_exists "$WORKSPACE/memory/dreaming/light/$YESTERDAY.md" "Dreaming Light $YESTERDAY"

# Dreaming reports -- REM (today + yesterday)
add_if_exists "$WORKSPACE/memory/dreaming/rem/$TODAY.md"     "Dreaming REM $TODAY"
add_if_exists "$WORKSPACE/memory/dreaming/rem/$YESTERDAY.md" "Dreaming REM $YESTERDAY"

# Dreaming reports -- deep (today + yesterday)
add_if_exists "$WORKSPACE/memory/dreaming/deep/$TODAY.md"     "Dreaming Deep $TODAY"
add_if_exists "$WORKSPACE/memory/dreaming/deep/$YESTERDAY.md" "Dreaming Deep $YESTERDAY"

# Core memory (always ingest -- keeps wiki copy current)
add_if_exists "$WORKSPACE/MEMORY.md" "Core Memory"

# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------
if [[ ${#FILES_TO_INGEST[@]} -eq 0 ]]; then
  log "no files to ingest for $TODAY / $YESTERDAY"
  exit 0
fi

log "starting wiki ingest: ${#FILES_TO_INGEST[@]} file(s) for $TODAY / $YESTERDAY"

ERRORS=0

for i in "${!FILES_TO_INGEST[@]}"; do
  file="${FILES_TO_INGEST[$i]}"
  title="${TITLES[$i]}"

  if cd "$WORKSPACE" && OPENCLAW_CONFIG_PATH="$WORKSPACE/openclaw.json" \
      openclaw wiki ingest "$file" --title "$title" >> "$LOG_FILE" 2>&1; then
    log "ingested: $file (title: $title)"
  else
    log "ERROR: failed to ingest: $file (title: $title)"
    ERRORS=$((ERRORS + 1))
  fi
done

log "wiki ingest complete: ${#FILES_TO_INGEST[@]} attempted, $ERRORS error(s)"

if [[ $ERRORS -gt 0 ]]; then
  exit 2
fi

exit 0
