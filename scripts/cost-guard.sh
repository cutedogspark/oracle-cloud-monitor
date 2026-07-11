#!/bin/bash
# OCI Cost Guard — Automatically stop all instances when limit exceeded
# Recommended to be executed hourly by cron
#
# Usage: ./scripts/cost-guard.sh

export SUPPRESS_LABEL_WARNING=True

# Cross-platform Python detection
if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1 && python --version 2>&1 | grep -q "Python 3"; then
    PYTHON=python
else
    echo "❌ Python 3 not found, please install first: ./scripts/install-tools.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ .env file not found"
    exit 1
fi
source "$ENV_FILE"
source "${SCRIPT_DIR}/notify.sh"

COST_LIMIT="${COST_LIMIT:-1.0}"
LOG_FILE="${PROJECT_DIR}/logs/cost-guard.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

get_current_cost() {
    local start_date end_date cost
    start_date=$(date -u +"%Y-%m-01T00:00:00Z")
    end_date=$(date -u -v+1m +"%Y-%m-01T00:00:00Z" 2>/dev/null || date -u -d "+1 month" +"%Y-%m-01T00:00:00Z")

    cost=$(oci usage-api usage-summary request-summarized-usages \
        --tenant-id "$TENANCY_ID" \
        --time-usage-started "$start_date" \
        --time-usage-ended "$end_date" \
        --granularity MONTHLY \
        --output json 2>/dev/null | $PYTHON -c "
import sys, json
d = json.load(sys.stdin)['data']
total = sum((i.get('computed-amount', 0) or 0) for i in d.get('items', []))
print(f'{total:.4f}')
" 2>/dev/null)

    echo "${cost:-0.00}"
}

stop_all_instances() {
    log "🚨 ALERT: Cost \$${1} exceeds \$${COST_LIMIT}! Stopping all instances..."

    local instances count
    instances=$(oci compute instance list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --lifecycle-state RUNNING \
        --all \
        --query 'data[].{id:id,"name":"display-name"}' \
        --output json 2>/dev/null)

    count=$(echo "$instances" | $PYTHON -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)

    if [ "$count" = "0" ] || [ -z "$count" ]; then
        log "No running instances to stop"
        return
    fi

    echo "$instances" | $PYTHON -c "
import sys, json
for inst in json.load(sys.stdin):
    print(inst['id'] + '|' + inst['name'])
" 2>/dev/null | while IFS='|' read -r instance_id name; do
        log "Stopping: $name ($instance_id)"
        oci compute instance action --instance-id "$instance_id" --action STOP --force 2>&1 >> "$LOG_FILE"
    done

    send_notify \
        "OCI Cost Guard TRIGGERED" \
        "Monthly cost: \$${1} USD (limit: \$${COST_LIMIT}). All ${count} instances have been STOPPED!" \
        "urgent"

    log "All instances stopped"
}

# === Main ===
current_cost=$(get_current_cost)
log "Cost check: \$${current_cost} / \$${COST_LIMIT}"

exceeded=$($PYTHON -c "print('yes' if float('${current_cost}') >= ${COST_LIMIT} else 'no')" 2>/dev/null)

if [ "$exceeded" = "yes" ]; then
    stop_all_instances "$current_cost"
else
    log "Cost OK"
fi
