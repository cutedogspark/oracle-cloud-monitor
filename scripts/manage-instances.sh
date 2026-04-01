#!/bin/bash
# 互動式 OCI 實例管理 — 列出 VM 並選擇關閉
#
# 用法: ./scripts/manage-instances.sh

set -euo pipefail
export SUPPRESS_LABEL_WARNING=True

if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1 && python --version 2>&1 | grep -q "Python 3"; then
    PYTHON=python
else
    echo "❌ 找不到 Python 3"
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

echo "▸ 查詢 ${REGION} 的實例..."
echo ""

INSTANCES=$(oci compute instance list \
    --compartment-id "$COMPARTMENT_ID" \
    --output json \
    --query 'data[?("lifecycle-state" != `TERMINATED`)]' 2>/dev/null)

if [ -z "$INSTANCES" ] || [ "$INSTANCES" = "[]" ] || [ "$INSTANCES" = "null" ]; then
    echo "目前沒有運行中的實例。"
    exit 0
fi

# 查詢每個實例的公網 IP 並格式化顯示
echo "▸ 查詢公網 IP..."
DISPLAY=$($PYTHON -c "
import sys, json, subprocess, os

instances = json.load(sys.stdin)
if not instances:
    print('NO_INSTANCES')
    sys.exit(0)

env = {**os.environ, 'SUPPRESS_LABEL_WARNING': 'True'}

for i, inst in enumerate(instances, 1):
    ocid = inst['id']
    state = inst['lifecycle-state']
    marker = {'RUNNING': '🟢', 'STOPPED': '🔴', 'STOPPING': '🟡', 'STARTING': '🟡', 'PROVISIONING': '🟡'}.get(state, '⚪')
    name = inst.get('display-name', 'N/A')
    shape = inst.get('shape', 'N/A')
    ocpus = inst.get('shape-config', {}).get('ocpus', '?')
    mem = inst.get('shape-config', {}).get('memory-in-gbs', '?')
    created = inst.get('time-created', '')[:10]

    ip = 'N/A'
    try:
        r = subprocess.run(
            ['oci', 'compute', 'instance', 'list-vnics',
             '--instance-id', ocid, '--output', 'json'],
            capture_output=True, text=True, env=env)
        vnics = json.loads(r.stdout).get('data', [])
        if vnics and vnics[0].get('public-ip'):
            ip = vnics[0]['public-ip']
    except Exception:
        pass

    print(f'  {i}) {marker} {name}')
    print(f'     狀態: {state}  |  IP: {ip}')
    print(f'     規格: {shape} ({ocpus} OCPU / {mem}GB)')
    print(f'     建立: {created}')
    print(f'     OCID: {ocid}')
    print()
" <<< "$INSTANCES")

if [ "$DISPLAY" = "NO_INSTANCES" ]; then
    echo "目前沒有運行中的實例。"
    exit 0
fi

COUNT=$($PYTHON -c "import sys,json; print(len(json.load(sys.stdin)))" <<< "$INSTANCES")

echo "═══════════════════════════════════════"
echo "  找到 ${COUNT} 個實例 (Region: ${REGION})"
echo "═══════════════════════════════════════"
echo ""
echo "$DISPLAY"

read -rp "輸入要終止的編號 (多個用逗號分隔，q 取消): " choice

if [[ "$choice" =~ ^[qQ]$ ]] || [ -z "$choice" ]; then
    echo "已取消。"
    exit 0
fi

# 解析選擇
IFS=',' read -ra SELECTIONS <<< "$choice"

TARGETS=$($PYTHON -c "
import sys, json

instances = json.load(sys.stdin)
selections = '${choice}'.replace(' ', '').split(',')

for s in selections:
    try:
        idx = int(s) - 1
        if 0 <= idx < len(instances):
            inst = instances[idx]
            print(f\"{inst['id']}|{inst['display-name']}|{inst['lifecycle-state']}\")
    except ValueError:
        pass
" <<< "$INSTANCES")

if [ -z "$TARGETS" ]; then
    echo "❌ 無效的選擇。"
    exit 1
fi

echo ""
echo "⚠️  即將終止以下實例："
echo ""
while IFS='|' read -r ocid name state; do
    echo "  - $name ($state)"
done <<< "$TARGETS"

echo ""
read -rp "確定要終止嗎？此操作無法復原 (yes/N): " confirm

if [ "$confirm" != "yes" ]; then
    echo "已取消。"
    exit 0
fi

echo ""
while IFS='|' read -r ocid name state; do
    echo "▸ 終止 $name ..."
    if oci compute instance terminate \
        --instance-id "$ocid" \
        --preserve-boot-volume false \
        --force 2>/dev/null; then
        echo "  ✅ $name 已送出終止請求"
    else
        echo "  ❌ $name 終止失敗"
    fi
done <<< "$TARGETS"

echo ""
echo "完成。實例將在幾分鐘內完全終止。"
