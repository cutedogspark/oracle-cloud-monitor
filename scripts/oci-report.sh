#!/bin/bash
# OCI 資源報表 — 查詢帳戶下的資源使用狀況
#
# 用法:
#   ./scripts/oci-report.sh              # 完整報表
#   ./scripts/oci-report.sh instances     # 只看實例
#   ./scripts/oci-report.sh cost          # 只看花費
#   ./scripts/oci-report.sh volumes       # 只看儲存
#   ./scripts/oci-report.sh network       # 只看網路
#   ./scripts/oci-report.sh images        # 列出可用映像檔（建立實例時需要）
#   ./scripts/oci-report.sh limits        # 查看免費額度上限

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

SECTION="${1:-all}"

separator() {
    echo ""
    echo "══════════════════════════════════════════"
    echo "  $1"
    echo "══════════════════════════════════════════"
}

# === 實例 ===
report_instances() {
    separator "Compute Instances"

    echo ""
    echo "▸ Running"
    oci compute instance list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --lifecycle-state RUNNING \
        --all \
        --query 'data[].{"Name":"display-name","Shape":shape,"OCPU":"shape-config"."ocpus","RAM(GB)":"shape-config"."memory-in-gbs","Created":"time-created"}' \
        --output table 2>/dev/null || echo "  (none or query failed)"

    echo ""
    echo "▸ Stopped"
    oci compute instance list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --lifecycle-state STOPPED \
        --all \
        --query 'data[].{"Name":"display-name","Shape":shape,"OCPU":"shape-config"."ocpus","RAM(GB)":"shape-config"."memory-in-gbs"}' \
        --output table 2>/dev/null || echo "  (none or query failed)"

    # 免費額度統計
    echo ""
    echo "▸ ARM A1 Free Tier Usage"
    oci compute instance list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --lifecycle-state RUNNING \
        --all \
        --output json 2>/dev/null | $PYTHON -c "
import sys, json
instances = json.load(sys.stdin).get('data', [])
a1_ocpus = 0
a1_memory = 0
micro_count = 0
for inst in instances:
    shape = inst.get('shape', '')
    sc = inst.get('shape-config', {})
    if 'A1' in shape:
        a1_ocpus += sc.get('ocpus', 0)
        a1_memory += sc.get('memory-in-gbs', 0)
    elif 'Micro' in shape:
        micro_count += 1
print(f'  ARM A1:  {a1_ocpus:.0f}/4 OCPU, {a1_memory:.0f}/24 GB RAM')
print(f'  E2 Micro: {micro_count}/2 instances')
" 2>/dev/null
}

# === 花費 ===
report_cost() {
    separator "Monthly Cost"

    START=$(date -u +"%Y-%m-01T00:00:00Z")
    END=$(date -u -v+1m +"%Y-%m-01T00:00:00Z" 2>/dev/null || date -u -d "+1 month" +"%Y-%m-01T00:00:00Z")

    oci usage-api usage-summary request-summarized-usages \
        --tenant-id "$TENANCY_ID" \
        --time-usage-started "$START" \
        --time-usage-ended "$END" \
        --granularity MONTHLY \
        --output json 2>/dev/null | $PYTHON -c "
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

month = '$(date +%Y-%m)'
print(f'  {month} Total: \${total:.4f} USD')
if total == 0:
    print('  ✅ All within Free Tier')
else:
    print()
    for svc, amt in sorted(services.items(), key=lambda x: -x[1]):
        print(f'    {svc}: \${amt:.4f}')
" 2>/dev/null
}

# === 儲存 ===
report_volumes() {
    separator "Storage"

    echo ""
    echo "▸ Boot Volumes"
    oci bv boot-volume list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --all \
        --query 'data[].{"Name":"display-name","Size(GB)":"size-in-gbs","State":"lifecycle-state"}' \
        --output table 2>/dev/null || echo "  (query failed)"

    echo ""
    echo "▸ Block Volumes"
    oci bv volume list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --all \
        --query 'data[].{"Name":"display-name","Size(GB)":"size-in-gbs","State":"lifecycle-state"}' \
        --output table 2>/dev/null || echo "  (none or query failed)"

    echo ""
    echo "▸ Free Tier Storage Usage"
    oci bv boot-volume list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --all \
        --output json 2>/dev/null | $PYTHON -c "
import sys, json
vols = json.load(sys.stdin).get('data', [])
total = sum(v.get('size-in-gbs', 0) for v in vols)
print(f'  Boot Volumes: {total}/200 GB')
" 2>/dev/null

    oci bv volume list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --all \
        --output json 2>/dev/null | $PYTHON -c "
import sys, json
try:
    vols = json.load(sys.stdin).get('data', [])
    total = sum(v.get('size-in-gbs', 0) for v in vols)
    count = len(vols)
    print(f'  Block Volumes: {count}/2 volumes, {total}/200 GB')
except:
    print('  Block Volumes: 0/2 volumes, 0/200 GB')
" 2>/dev/null
}

# === 網路 ===
report_network() {
    separator "Network"

    echo ""
    echo "▸ VCN"
    oci network vcn list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --all \
        --query 'data[].{"Name":"display-name","CIDR":"cidr-block","State":"lifecycle-state"}' \
        --output table 2>/dev/null || echo "  (query failed)"

    echo ""
    echo "▸ Subnets"
    oci network subnet list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --all \
        --query 'data[].{"Name":"display-name","CIDR":"cidr-block","Public":"prohibit-public-ip-on-vnic"}' \
        --output table 2>/dev/null || echo "  (query failed)"

    echo ""
    echo "▸ Public IPs"
    oci network public-ip list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --scope REGION \
        --all \
        --query 'data[].{"IP":"ip-address","Lifetime":"lifetime","State":"lifecycle-state"}' \
        --output table 2>/dev/null || echo "  (none or query failed)"
}

# === 可用映像檔 ===
report_images() {
    separator "Available Images (for instance launch)"

    echo ""
    echo "▸ Oracle Linux (ARM - aarch64)"
    oci compute image list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --shape "$( echo 'VM.Standard.A1.Flex')" \
        --all \
        --query 'data[?"operating-system"==`Oracle Linux`].{"Name":"display-name","OCID":id}' \
        --output table 2>/dev/null | head -20

    echo ""
    echo "▸ Ubuntu (ARM - aarch64)"
    oci compute image list \
        --compartment-id "${COMPARTMENT_ID:-$TENANCY_ID}" \
        --shape "VM.Standard.A1.Flex" \
        --all \
        --query 'data[?"operating-system"==`Canonical Ubuntu`].{"Name":"display-name","OCID":id}' \
        --output table 2>/dev/null | head -20
}

# === 免費額度上限 ===
report_limits() {
    separator "OCI Always Free Tier Limits"

    echo ""
    echo "  ┌─────────────────────────────────────────────────┐"
    echo "  │ Resource                  │ Free Tier Limit      │"
    echo "  ├─────────────────────────────────────────────────┤"
    echo "  │ ARM A1.Flex Compute       │ 4 OCPU / 24 GB RAM  │"
    echo "  │ E2.1.Micro Compute       │ 2 instances          │"
    echo "  │ Boot Volume Storage       │ 200 GB total         │"
    echo "  │ Block Volume Storage      │ 2 vol / 200 GB total │"
    echo "  │ Object Storage            │ 20 GB                │"
    echo "  │ Outbound Data Transfer    │ 10 TB/month          │"
    echo "  │ Load Balancer             │ 1 (10 Mbps)          │"
    echo "  │ Monitoring                │ 500M ingestion       │"
    echo "  │ Notifications             │ 1M per month         │"
    echo "  │ Logging                   │ 10 GB/month          │"
    echo "  └─────────────────────────────────────────────────┘"
    echo ""
    echo "  ℹ️  ARM 資源可分配在多台實例上，但總和不能超過 4 OCPU / 24 GB"
    echo "  ℹ️  Boot Volume 包含所有實例的開機磁碟，加總不能超過 200 GB"
}

# === 帳戶類型 ===
report_account() {
    separator "Account Type"

    local payment_model start_date end_date
    local sub_json
    sub_json=$(oci organizations subscription list \
        --compartment-id "$TENANCY_ID" \
        --output json 2>/dev/null)

    if [ -z "$sub_json" ]; then
        echo "  (無法查詢帳戶類型)"
        return
    fi

    eval "$($PYTHON -c "
import sys, json
try:
    items = json.load(sys.stdin)['data']['items']
    active = [i for i in items if i.get('lifecycle-state') == 'ACTIVE']
    if active:
        s = active[0]
        print(f\"payment_model='{s.get('payment-model', 'UNKNOWN')}'\")
        print(f\"start_date='{s.get('start-date', 'N/A')[:10]}'\")
        print(f\"end_date='{s.get('end-date', 'N/A')[:10]}'\")
    else:
        print(\"payment_model='UNKNOWN'\")
except:
    print(\"payment_model='UNKNOWN'\")
" <<< "$sub_json" 2>/dev/null)"

    echo ""
    if [ "$payment_model" = "PAYG" ]; then
        echo "  ✅ Plan: Pay As You Go (PAYG)"
        echo "     Always Free 資源永久免費，超出免費額度才收費"
    elif [ "$payment_model" = "PROMO" ] || [ "$payment_model" = "FREE" ]; then
        echo "  ⚠️  Plan: $payment_model (免費試用)"
        echo "     開始: ${start_date:-N/A}"
        echo "     到期: ${end_date:-N/A}"
        echo ""
        echo "     ⚠️  試用期結束後，非 Always Free 資源（含搶到的 ARM A1）可能被回收！"
        echo "     建議升級為 PAYG: OCI Console → Billing → Upgrade to Paid"
    else
        echo "  ℹ️  Plan: $payment_model"
        echo "     開始: ${start_date:-N/A}"
        echo "     到期: ${end_date:-N/A}"
    fi
}

# === Main ===
echo ""
echo "  OCI Resource Report — $(date '+%Y-%m-%d %H:%M:%S')"

case "$SECTION" in
    instances)  report_instances ;;
    cost)       report_cost ;;
    volumes)    report_volumes ;;
    network)    report_network ;;
    images)     report_images ;;
    limits)     report_limits ;;
    account)    report_account ;;
    all)
        report_account
        report_instances
        report_cost
        report_volumes
        report_network
        report_limits
        ;;
    *)
        echo "Usage: $0 [instances|cost|volumes|network|images|limits|account|all]"
        exit 1
        ;;
esac

echo ""
