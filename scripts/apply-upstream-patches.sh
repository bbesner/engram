#!/usr/bin/env bash
# ============================================================================
# FlipClaw — Apply/Remove Upstream OpenClaw Workaround Patches
#
# Reads scripts/upstream-patches.json, compares each patch's version range
# against the installed OpenClaw version, and either installs or removes
# the workaround artifacts accordingly.
#
# This is the single source of truth for "what workarounds does this install
# need." Called by install-memory.sh during fresh installs and by
# flipclaw-update.sh on every update, so OpenClaw version upgrades
# automatically trigger workaround removal without re-running the installer.
#
# Usage:
#   apply-upstream-patches.sh \
#     --workspace /path/to/agent \
#     --port 3050 \
#     --toolkit-dir /tmp/flipclaw-install \
#     [--dry-run]
#
# Exit codes:
#   0  — all patches reconciled successfully
#   1  — fatal error (missing prerequisite, invalid registry)
#   2  — one or more patches failed to apply/remove (non-fatal; reported)
# ============================================================================

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

WORKSPACE=""
PORT=""
TOOLKIT_DIR=""
DRY_RUN=false
REGISTRY_FILE=""

# ──────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace)    WORKSPACE="$2"; shift 2 ;;
        --port)         PORT="$2"; shift 2 ;;
        --toolkit-dir)  TOOLKIT_DIR="$2"; shift 2 ;;
        --registry)     REGISTRY_FILE="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        --help)
            sed -n '1,25p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}" >&2
            exit 1
            ;;
    esac
done

if [ -z "$WORKSPACE" ] || [ -z "$PORT" ]; then
    echo -e "${RED}--workspace and --port are required${NC}" >&2
    exit 1
fi

# Registry defaults to the toolkit-dir copy for fresh installs,
# or to the installed workspace copy for update runs.
if [ -z "$REGISTRY_FILE" ]; then
    if [ -n "$TOOLKIT_DIR" ] && [ -f "$TOOLKIT_DIR/scripts/upstream-patches.json" ]; then
        REGISTRY_FILE="$TOOLKIT_DIR/scripts/upstream-patches.json"
    elif [ -f "$WORKSPACE/scripts/upstream-patches.json" ]; then
        REGISTRY_FILE="$WORKSPACE/scripts/upstream-patches.json"
    else
        echo -e "${RED}Cannot locate upstream-patches.json — pass --registry or --toolkit-dir${NC}" >&2
        exit 1
    fi
fi

if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}jq is required for patch registry processing${NC}" >&2
    exit 1
fi

if ! command -v openclaw >/dev/null 2>&1; then
    echo -e "${RED}openclaw CLI not found in PATH${NC}" >&2
    exit 1
fi

# ──────────────────────────────────────────────────────────────
# Detect installed OpenClaw version
# ──────────────────────────────────────────────────────────────

INSTALLED_VERSION=$(openclaw --version 2>/dev/null | grep -oE '2026\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$INSTALLED_VERSION" ]; then
    echo -e "${YELLOW}Could not detect OpenClaw version — assuming worst-case and applying all workarounds${NC}"
    INSTALLED_VERSION="0.0.0"
fi

# ──────────────────────────────────────────────────────────────
# Version comparison helper
#
# version_ge "$a" "$b" → returns 0 if a >= b, 1 otherwise.
# Works for dotted versions like 2026.4.9 / 2026.4.10.
# ──────────────────────────────────────────────────────────────

version_ge() {
    local a="$1"
    local b="$2"
    [ "$a" = "$b" ] && return 0
    local first
    first=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)
    [ "$first" = "$b" ] && return 0 || return 1
}

# ──────────────────────────────────────────────────────────────
# Gateway reachability check (for cron operations)
# ──────────────────────────────────────────────────────────────

gateway_reachable() {
    curl -sf "http://localhost:${PORT}/health" >/dev/null 2>&1
}

# ──────────────────────────────────────────────────────────────
# Patch install / remove primitives
# ──────────────────────────────────────────────────────────────

install_script() {
    local patch_id="$1"
    local script_rel="$2"
    local template_rel="$3"
    local executable="$4"

    local src=""
    if [ -n "$TOOLKIT_DIR" ] && [ -f "$TOOLKIT_DIR/$template_rel" ]; then
        src="$TOOLKIT_DIR/$template_rel"
    elif [ -f "$WORKSPACE/$template_rel" ]; then
        src="$WORKSPACE/$template_rel"
    else
        echo -e "    ${RED}[FAIL]${NC} script template not found: $template_rel"
        return 1
    fi

    local dest="$WORKSPACE/$script_rel"
    mkdir -p "$(dirname "$dest")"

    if [ "$DRY_RUN" = true ]; then
        echo "    [DRY] would install $script_rel (from $src)"
        return 0
    fi

    sed -e "s|{{WORKSPACE}}|$WORKSPACE|g" \
        -e "s|{{PORT}}|$PORT|g" \
        "$src" > "$dest"
    if [ "$executable" = "true" ]; then
        chmod +x "$dest"
    fi
    echo -e "    ${GREEN}[OK]${NC}   installed $script_rel"
    return 0
}

remove_script() {
    local patch_id="$1"
    local script_rel="$2"
    local path="$WORKSPACE/$script_rel"

    if [ ! -e "$path" ]; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "    [DRY] would remove $script_rel (no longer needed)"
        return 0
    fi

    rm -f "$path"
    echo -e "    ${GREEN}[OK]${NC}   removed $script_rel (upstream fix present)"
    return 0
}

cron_exists() {
    local cron_name="$1"
    if ! gateway_reachable; then
        return 2   # unknown — cannot check
    fi
    OPENCLAW_CONFIG_PATH="$WORKSPACE/openclaw.json" openclaw cron list 2>/dev/null \
        | grep -qF "$cron_name"
}

install_cron() {
    local patch_id="$1"
    local name description cron tz session wake system_event
    name=$(echo "$2" | jq -r '.name')
    description=$(echo "$2" | jq -r '.description')
    cron=$(echo "$2" | jq -r '.cron')
    tz=$(echo "$2" | jq -r '.tz')
    session=$(echo "$2" | jq -r '.session')
    wake=$(echo "$2" | jq -r '.wake')
    system_event=$(echo "$2" | jq -r '.system_event_template' | sed "s|{{WORKSPACE}}|$WORKSPACE|g")

    if ! gateway_reachable; then
        echo -e "    ${YELLOW}[SKIP]${NC} gateway not reachable — cannot register cron '$name'"
        echo "           After starting the gateway, re-run: bash $WORKSPACE/scripts/apply-upstream-patches.sh --workspace $WORKSPACE --port $PORT"
        return 0
    fi

    case $(cron_exists "$name"; echo $?) in
        0)
            echo "    [OK]   cron '$name' already present"
            return 0
            ;;
        2)
            echo -e "    ${YELLOW}[WARN]${NC} gateway unreachable, skipping cron install"
            return 0
            ;;
    esac

    if [ "$DRY_RUN" = true ]; then
        echo "    [DRY] would register cron '$name' ($cron, $tz)"
        return 0
    fi

    if OPENCLAW_CONFIG_PATH="$WORKSPACE/openclaw.json" openclaw cron add \
        --name "$name" \
        --description "$description" \
        --cron "$cron" \
        --tz "$tz" \
        --session "$session" \
        --wake "$wake" \
        --system-event "$system_event" \
        >/dev/null 2>&1; then
        echo -e "    ${GREEN}[OK]${NC}   registered cron '$name' ($cron, $tz)"
        return 0
    else
        echo -e "    ${RED}[FAIL]${NC} failed to register cron '$name'"
        return 1
    fi
}

remove_cron() {
    local patch_id="$1"
    local cron_name="$2"

    if ! gateway_reachable; then
        echo -e "    ${YELLOW}[SKIP]${NC} gateway not reachable — cannot remove cron '$cron_name'"
        echo "           After starting the gateway, re-run this script."
        return 0
    fi

    if ! cron_exists "$cron_name"; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "    [DRY] would remove cron '$cron_name' (upstream fix present)"
        return 0
    fi

    # Resolve cron id by name, then delete
    local cron_id
    cron_id=$(OPENCLAW_CONFIG_PATH="$WORKSPACE/openclaw.json" openclaw cron list --json 2>/dev/null \
        | jq -r ".[] | select(.name == \"$cron_name\") | .id" | head -1)

    if [ -z "$cron_id" ] || [ "$cron_id" = "null" ]; then
        echo -e "    ${YELLOW}[WARN]${NC} could not resolve id for cron '$cron_name' — leaving in place"
        return 0
    fi

    if OPENCLAW_CONFIG_PATH="$WORKSPACE/openclaw.json" openclaw cron remove "$cron_id" >/dev/null 2>&1; then
        echo -e "    ${GREEN}[OK]${NC}   removed cron '$cron_name' (upstream fix present)"
        return 0
    else
        echo -e "    ${RED}[FAIL]${NC} failed to remove cron '$cron_name'"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────
# Main reconciliation loop
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Upstream patch reconciliation${NC}"
echo "  Registry:  $REGISTRY_FILE"
echo "  OpenClaw:  $INSTALLED_VERSION"
echo "  Workspace: $WORKSPACE"
if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}[DRY RUN — no changes will be made]${NC}"
fi
echo ""

FAILURES=0
PATCH_IDS=$(jq -r '.patches | keys[]' "$REGISTRY_FILE")
if [ -z "$PATCH_IDS" ]; then
    echo "  No patches defined in registry."
    exit 0
fi

for patch_id in $PATCH_IDS; do
    title=$(jq -r ".patches.\"$patch_id\".title" "$REGISTRY_FILE")
    broken_from=$(jq -r ".patches.\"$patch_id\".broken_from" "$REGISTRY_FILE")
    fixed_in=$(jq -r ".patches.\"$patch_id\".fixed_in" "$REGISTRY_FILE")

    # Determine action: install, remove, or n/a
    action="install"
    reason=""
    if [ "$fixed_in" != "null" ] && version_ge "$INSTALLED_VERSION" "$fixed_in"; then
        action="remove"
        reason="upstream fixed in $fixed_in, installed $INSTALLED_VERSION"
    elif ! version_ge "$INSTALLED_VERSION" "$broken_from"; then
        action="skip"
        reason="not applicable to OpenClaw $INSTALLED_VERSION (bug introduced in $broken_from)"
    else
        reason="applicable to OpenClaw $INSTALLED_VERSION"
    fi

    # Optional: runtime probe to catch regressions when we think it's fixed
    if [ "$action" = "remove" ]; then
        probe_cmd=$(jq -r ".patches.\"$patch_id\".runtime_probe.command // empty" "$REGISTRY_FILE")
        fallback=$(jq -r ".patches.\"$patch_id\".runtime_probe.fallback_on_probe_failure // \"warn_only\"" "$REGISTRY_FILE")
        if [ -n "$probe_cmd" ] && gateway_reachable; then
            if ! OPENCLAW_CONFIG_PATH="$WORKSPACE/openclaw.json" bash -c "$probe_cmd" 2>/dev/null; then
                if [ "$fallback" = "apply_workaround_anyway" ]; then
                    action="install"
                    reason="runtime probe failed despite fixed_in=$fixed_in — applying workaround as safety net"
                else
                    echo -e "  ${YELLOW}[WARN]${NC} $patch_id runtime probe failed; not reapplying workaround (fallback=warn_only)"
                fi
            fi
        fi
    fi

    case "$action" in
        install)
            echo -e "  ${BLUE}[APPLY]${NC} $patch_id"
            echo "          $title"
            echo "          reason: $reason"

            # Install scripts
            script_count=$(jq -r ".patches.\"$patch_id\".artifacts.scripts | length" "$REGISTRY_FILE")
            for ((i=0; i<script_count; i++)); do
                script_path=$(jq -r ".patches.\"$patch_id\".artifacts.scripts[$i].path" "$REGISTRY_FILE")
                template_path=$(jq -r ".patches.\"$patch_id\".artifacts.scripts[$i].template_source" "$REGISTRY_FILE")
                executable=$(jq -r ".patches.\"$patch_id\".artifacts.scripts[$i].executable // false" "$REGISTRY_FILE")
                install_script "$patch_id" "$script_path" "$template_path" "$executable" || FAILURES=$((FAILURES+1))
            done

            # Register cron jobs
            cron_count=$(jq -r ".patches.\"$patch_id\".artifacts.cron_jobs | length" "$REGISTRY_FILE")
            for ((i=0; i<cron_count; i++)); do
                cron_json=$(jq -c ".patches.\"$patch_id\".artifacts.cron_jobs[$i]" "$REGISTRY_FILE")
                install_cron "$patch_id" "$cron_json" || FAILURES=$((FAILURES+1))
            done
            ;;

        remove)
            echo -e "  ${GREEN}[CLEAN]${NC} $patch_id"
            echo "          $title"
            echo "          reason: $reason"

            # Remove scripts
            script_count=$(jq -r ".patches.\"$patch_id\".artifacts.scripts | length" "$REGISTRY_FILE")
            for ((i=0; i<script_count; i++)); do
                script_path=$(jq -r ".patches.\"$patch_id\".artifacts.scripts[$i].path" "$REGISTRY_FILE")
                remove_script "$patch_id" "$script_path" || FAILURES=$((FAILURES+1))
            done

            # Remove cron jobs
            cron_count=$(jq -r ".patches.\"$patch_id\".artifacts.cron_jobs | length" "$REGISTRY_FILE")
            for ((i=0; i<cron_count; i++)); do
                cron_name=$(jq -r ".patches.\"$patch_id\".artifacts.cron_jobs[$i].name" "$REGISTRY_FILE")
                remove_cron "$patch_id" "$cron_name" || FAILURES=$((FAILURES+1))
            done
            ;;

        skip)
            echo -e "  ${BLUE}[N/A]${NC}   $patch_id"
            echo "          $reason"
            ;;
    esac
    echo ""
done

# ──────────────────────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────────────────────

if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}Upstream patch reconciliation complete.${NC}"
    exit 0
else
    echo -e "${YELLOW}Upstream patch reconciliation finished with $FAILURES failure(s) — review output above.${NC}"
    exit 2
fi
