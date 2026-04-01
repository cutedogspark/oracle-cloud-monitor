#!/bin/bash
# OCI 花費通知 — 查詢當月花費並發送通知
# 建議由 cron 定期執行（例如每天 3 次）
#
# 用法: ./scripts/check-cost.sh

export SUPPRESS_LABEL_WARNING=True

# 跨平台 Python 偵測
if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1 && python --version 2>&1 | grep -q "Python 3"; then
    PYTHON=python
else
    echo "❌ 找不到 Python 3，請先安裝: ./scripts/install-tools.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ 找不到 .env"
    exit 1
fi
source "$ENV_FILE"
source "${SCRIPT_DIR}/notify.sh"

LOG_FILE="${PROJECT_DIR}/logs/check-cost.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# === 查詢本月花費 ===
START=$(date -u +"%Y-%m-01T00:00:00Z")
END=$(date -u -v+1m +"%Y-%m-01T00:00:00Z" 2>/dev/null || date -u -d "+1 month" +"%Y-%m-01T00:00:00Z")

cost_json=$(oci usage-api usage-summary request-summarized-usages \
    --tenant-id "$TENANCY_ID" \
    --time-usage-started "$START" \
    --time-usage-ended "$END" \
    --granularity MONTHLY \
    --output json 2>/dev/null)

if [ -z "$cost_json" ]; then
    log "ERROR: Failed to query OCI usage API"
    send_notify "OCI Cost Check Failed" "Failed to query OCI usage API at $(date)" "high"
    exit 1
fi

# 解析花費明細
cost_detail=$(echo "$cost_json" | $PYTHON -c "
import sys, json

data = json.load(sys.stdin)['data']
items = data.get('items', [])
total = 0.0
services = {}

for item in items:
    amt = float(item.get('computed-amount', 0) or 0)
    total += amt
    svc = item.get('service', 'Unknown')
    if amt != 0:
        services[svc] = services.get(svc, 0) + amt

print(f'TOTAL:{total:.4f}')
for svc, amt in sorted(services.items(), key=lambda x: -x[1]):
    print(f'  {svc}: \${amt:.4f}')
" 2>/dev/null)

total=$(echo "$cost_detail" | head -1 | cut -d: -f2)
detail=$(echo "$cost_detail" | tail -n+2)

# === 查詢運行中的實例 ===
instances=$(oci compute instance list \
    --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
    --lifecycle-state RUNNING \
    --all \
    --query 'data[].{"name":"display-name",shape:shape}' \
    --output json 2>/dev/null | $PYTHON -c "
import sys, json
try:
    for inst in json.load(sys.stdin):
        print(f\"  {inst['name']} ({inst['shape']})\")
except:
    print('  (query failed)')
" 2>/dev/null)

# === 組合訊息 ===
month=$(date +"%Y-%m")
now=$(date '+%Y-%m-%d %H:%M')

message="OCI ${month} Monthly Cost: \$${total} USD
Time: ${now}

Running Instances:
${instances}
"

if [ -n "$detail" ] && [ "$total" != "0.0000" ]; then
    message="${message}
Cost Breakdown:
${detail}
"
fi

if $PYTHON -c "exit(0 if float('${total}') == 0 else 1)" 2>/dev/null; then
    priority="low"
    title="OCI Daily Report: \$0 (Free)"
else
    priority="high"
    title="OCI Daily Report: \$${total} USD"
fi

log "$message"

# === 發送通知 ===
send_notify "$title" "$message" "$priority"

log "Done"
