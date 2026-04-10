#!/usr/bin/env bash
# ensure-dreaming-cron.sh
#
# Workaround for an OpenClaw bug (observed in 2026.4.x): memory-core's
# reconcileShortTermDreamingCronJob removes the managed "Memory Dreaming Promotion"
# cron on every gateway restart, even when dreaming.enabled=true in openclaw.json.
# This script detects the missing cron and recreates it with the correct
# [managed-by=memory-core.short-term-promotion] tag and payload so it will fire at
# 4 AM ET (or whatever schedule the deep-dreaming config specifies) and trigger
# the dreaming pipeline.
#
# Wired up via an OpenClaw cron job (created by install-memory.sh) that fires
# shortly after the nightly restart and runs this script via Ari's exec tool.
#
# Manual usage:
#   /path/to/workspace/scripts/ensure-dreaming-cron.sh
#
# Exit codes:
#   0 - cron exists or was successfully created
#   1 - gateway not reachable
#   2 - failed to create cron

set -euo pipefail

WORKSPACE="{{WORKSPACE}}"
GATEWAY_PORT="{{PORT}}"

export OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$WORKSPACE/openclaw.json}"
LOG_FILE="${LOG_FILE:-/tmp/ensure-dreaming-cron.log}"
GATEWAY_HEALTH="http://localhost:${GATEWAY_PORT}/health"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"
}

# Wait up to 60s for the gateway to be reachable
for i in $(seq 1 12); do
  if curl -sf "$GATEWAY_HEALTH" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq 12 ]; then
    log "gateway $GATEWAY_HEALTH not reachable after 60s"
    exit 1
  fi
  sleep 5
done

cd "$WORKSPACE"

# Check for managed dreaming cron by name
existing=$(OPENCLAW_CONFIG_PATH="$OPENCLAW_CONFIG_PATH" openclaw cron list 2>/dev/null \
  | grep -c "Memory Dreaming Promo" || true)

if [ "$existing" -ge 1 ]; then
  log "dreaming cron present (count=$existing); nothing to do"
  exit 0
fi

log "dreaming cron missing; recreating"

# Recreate the managed dreaming cron with the correct tag, schedule, and payload.
# This matches what memory-core.reconcileShortTermDreamingCronJob.buildManagedDreamingCronJob
# would produce internally if the bug were not present.
if OPENCLAW_CONFIG_PATH="$OPENCLAW_CONFIG_PATH" openclaw cron add \
    --name "Memory Dreaming Promotion" \
    --description "[managed-by=memory-core.short-term-promotion] Promote weighted short-term recalls into MEMORY.md (limit=10, minScore=0.300, minRecallCount=3, minUniqueQueries=2, recencyHalfLifeDays=14, maxAgeDays=90)." \
    --cron "0 4 * * *" \
    --tz "America/New_York" \
    --session main \
    --wake next-heartbeat \
    --system-event "__openclaw_memory_core_short_term_promotion_dream__" \
    --json >> "$LOG_FILE" 2>&1; then
  log "dreaming cron recreated successfully"
  exit 0
else
  log "ERROR: failed to recreate dreaming cron"
  exit 2
fi
