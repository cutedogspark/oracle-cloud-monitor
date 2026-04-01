#!/bin/bash
# Oracle Cloud Free Tier — 搶 ARM A1.Flex 資源
# 自動重試建立實例，直到搶到為止
#
# 用法: ./scripts/grab-free-a1.sh
# 需先複製 env.example → .env 並填入你的設定

set -euo pipefail
export SUPPRESS_LABEL_WARNING=True

# 跨平台 Python 偵測（某些環境只有 python 沒有 python3）
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
    echo "❌ 找不到 .env，請先複製 env.example 並填入設定："
    echo "   cp env.example .env"
    exit 1
fi
source "$ENV_FILE"
source "${SCRIPT_DIR}/notify.sh"

# 驗證必要變數
for var in COMPARTMENT_ID AVAILABILITY_DOMAIN SUBNET_ID IMAGE_ID SSH_KEY_FILE DISPLAY_NAME OCPUS MEMORY BOOT_SIZE; do
    if [ -z "${!var:-}" ]; then
        echo "❌ .env 缺少設定: $var"
        exit 1
    fi
done

# === 檢查帳戶類型 (Pay As You Go) ===
echo "▸ 檢查帳戶類型..."
PAYMENT_MODEL=$(oci organizations subscription list \
    --compartment-id "$TENANCY_ID" \
    --output json 2>/dev/null | $PYTHON -c "
import sys, json
try:
    items = json.load(sys.stdin)['data']['items']
    active = [i for i in items if i.get('lifecycle-state') == 'ACTIVE']
    if active:
        print(active[0].get('payment-model', 'UNKNOWN'))
    else:
        print('UNKNOWN')
except:
    print('UNKNOWN')
" 2>/dev/null)

if [ "$PAYMENT_MODEL" != "PAYG" ]; then
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "  ⚠️  帳戶類型: ${PAYMENT_MODEL:-UNKNOWN} (非 Pay As You Go)"
    echo "══════════════════════════════════════════════════"
    echo ""
    echo "  你的帳戶目前不是 Pay As You Go (PAYG)。"
    echo ""
    echo "  ┌─ Free Trial（免費試用）──────────────────────┐"
    echo "  │ • 30 天試用期，含 \$300 USD 免費額度           │"
    echo "  │ • 試用期結束後，非 Always Free 資源會被刪除   │"
    echo "  │ • ARM A1 實例可能在試用結束後被回收           │"
    echo "  └──────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─ Pay As You Go（隨用隨付）──────────────────┐"
    echo "  │ • Always Free 資源永久免費                   │"
    echo "  │ • ARM A1 (4 OCPU / 24GB) 不會被回收          │"
    echo "  │ • 超出免費額度才會收費                        │"
    echo "  │ • 需綁定信用卡，但不會主動扣款                │"
    echo "  └──────────────────────────────────────────────┘"
    echo ""
    echo "  建議：升級為 PAYG 以確保搶到的實例不會被回收。"
    echo "  升級方式：OCI Console → Billing → Upgrade to Paid"
    echo ""
    read -rp "  是否仍要繼續搶資源？(y/N) " answer
    if [[ ! "${answer,,}" =~ ^y ]]; then
        echo "  已取消。"
        exit 0
    fi
    echo ""
else
    echo "  ✅ 帳戶類型: Pay As You Go (PAYG)"
fi

SHAPE="VM.Standard.A1.Flex"
RETRY_INTERVAL=30
LOG_FILE="${PROJECT_DIR}/logs/grab-free-a1.log"
mkdir -p "$(dirname "$LOG_FILE")"

# === 準備 Reserved Public IP ===
echo "▸ 檢查 Reserved Public IP..."
RESERVED_IP_JSON=$(oci network public-ip list \
    --compartment-id "$COMPARTMENT_ID" \
    --scope REGION --lifetime RESERVED \
    --output json 2>&1) || RESERVED_IP_JSON=""

RESERVED_IP_ID=""
if [ -n "$RESERVED_IP_JSON" ]; then
    RESERVED_IP_ID=$(echo "$RESERVED_IP_JSON" | $PYTHON -c "
import sys, json
try:
    ips = json.load(sys.stdin).get('data', [])
    avail = [ip for ip in ips if ip['lifecycle-state'] in ('AVAILABLE', 'ASSIGNED')]
    print(avail[0]['id'] if avail else '')
except:
    print('')
" 2>/dev/null)
fi

if [ -n "$RESERVED_IP_ID" ]; then
    RESERVED_IP_GET=$(oci network public-ip get \
        --public-ip-id "$RESERVED_IP_ID" --output json 2>&1) || true
    RESERVED_IP_ADDR=$(echo "$RESERVED_IP_GET" | $PYTHON -c "
import sys,json
try: print(json.load(sys.stdin)['data']['ip-address'])
except: print('')
" 2>/dev/null)
    echo "  ✅ 找到現有 Reserved IP: $RESERVED_IP_ADDR"
else
    echo "  沒有現有的 Reserved IP，正在建立..."
    RESERVED_RESULT=$(oci network public-ip create \
        --compartment-id "$COMPARTMENT_ID" \
        --lifetime RESERVED \
        --display-name "${DISPLAY_NAME}-ip" \
        --output json 2>&1) || true
    RESERVED_IP_ID=$(echo "$RESERVED_RESULT" | $PYTHON -c "
import sys,json
try: print(json.load(sys.stdin)['data']['id'])
except: print('')
" 2>/dev/null)
    RESERVED_IP_ADDR=$(echo "$RESERVED_RESULT" | $PYTHON -c "
import sys,json
try: print(json.load(sys.stdin)['data']['ip-address'])
except: print('')
" 2>/dev/null)
    if [ -z "$RESERVED_IP_ID" ]; then
        echo "  ❌ 建立 Reserved IP 失敗"
        echo "  $RESERVED_RESULT"
        exit 1
    fi
    echo "  ✅ 已建立 Reserved IP: $RESERVED_IP_ADDR"
fi

# shape-config 用 file:// 傳遞，避免 JSON 引號問題
SHAPE_CONFIG_FILE=$(mktemp)
echo "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY}" > "$SHAPE_CONFIG_FILE"
trap "rm -f $SHAPE_CONFIG_FILE" EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

parse_error() {
    $PYTHON -c "
import sys, json, re
raw = sys.stdin.read()
m = re.search(r'\{.*\}', raw, re.DOTALL)
if m:
    d = json.loads(m.group())
    print(d.get('code', ''), end='|')
    print(d.get('message', ''), end='|')
    print(d.get('status', ''))
" 2>/dev/null
}

log "=========================================="
log "開始搶 ARM A1.Flex ($OCPUS OCPU / ${MEMORY}GB RAM)"
log "名稱: $DISPLAY_NAME"
log "Region: $REGION"
log "每 ${RETRY_INTERVAL} 秒重試一次"
log "=========================================="

attempt=0
while true; do
    attempt=$((attempt + 1))
    log "--- 第 $attempt 次嘗試 ---"

    result=$(oci compute instance launch \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --shape "$SHAPE" \
        --shape-config "file://$SHAPE_CONFIG_FILE" \
        --image-id "$IMAGE_ID" \
        --subnet-id "$SUBNET_ID" \
        --display-name "$DISPLAY_NAME" \
        --boot-volume-size-in-gbs "$BOOT_SIZE" \
        --assign-public-ip false \
        --ssh-authorized-keys-file "$SSH_KEY_FILE" \
        --output json 2>&1)

    # 成功：回應中含有 lifecycle-state
    if echo "$result" | grep -q '"lifecycle-state"'; then
        log "✅ $DISPLAY_NAME 建立成功！"

        INSTANCE_ID=$(echo "$result" | $PYTHON -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',d)['id'])")
        log "實例 OCID: $INSTANCE_ID"

        # === 綁定 Reserved Public IP ===
        log "▸ 等待實例進入 RUNNING 狀態..."
        for w in $(seq 1 30); do
            STATE=$(oci compute instance get --instance-id "$INSTANCE_ID" \
                --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "")
            [ "$STATE" = "RUNNING" ] && break
            log "  狀態: ${STATE:-UNKNOWN}，等待 10 秒... ($w/30)"
            sleep 10
        done

        log "▸ 取得 VNIC 資訊..."
        VNIC_ID=""
        for w in $(seq 1 10); do
            VNIC_ID=$(oci compute instance list-vnics \
                --instance-id "$INSTANCE_ID" --output json 2>/dev/null \
                | $PYTHON -c "import sys,json; d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')" 2>/dev/null)
            [ -n "$VNIC_ID" ] && break
            log "  VNIC 尚未就緒，等待 5 秒... ($w/10)"
            sleep 5
        done

        if [ -z "$VNIC_ID" ]; then
            log "❌ 無法取得 VNIC，請手動綁定 Reserved IP"
            break
        fi

        PRIVATE_IP_ID=$(oci network private-ip list \
            --vnic-id "$VNIC_ID" --output json 2>/dev/null \
            | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])")

        log "▸ 綁定 Reserved IP: $RESERVED_IP_ADDR"
        oci network public-ip update \
            --public-ip-id "$RESERVED_IP_ID" \
            --private-ip-id "$PRIVATE_IP_ID" \
            --output json >/dev/null 2>&1

        PUBLIC_IP="$RESERVED_IP_ADDR"
        log "固定公網 IP: $PUBLIC_IP"

        send_notify \
            "OCI A1 搶到了！" \
            "$DISPLAY_NAME ($OCPUS OCPU / ${MEMORY}GB) 建立成功！IP: ${PUBLIC_IP} 第 ${attempt} 次嘗試" \
            "urgent"
        log "📨 已發送通知"
        break
    fi

    # 解析錯誤
    parsed=$(echo "$result" | parse_error)
    error_code=$(echo "$parsed" | cut -d'|' -f1)
    error_msg=$(echo "$parsed" | cut -d'|' -f2)

    if [ -z "$error_msg" ]; then
        error_msg=$(echo "$result" | tail -3)
    fi

    if echo "$error_msg" | grep -qi "capacity"; then
        log "⚠️  [缺貨] $error_msg"
        log "等待 ${RETRY_INTERVAL} 秒後重試..."
        sleep "$RETRY_INTERVAL"
    elif [ "$error_code" = "TooManyRequests" ]; then
        wait_time=$((RETRY_INTERVAL * 2))
        log "🚫 [限流] 請求太頻繁！等待 ${wait_time} 秒..."
        sleep "$wait_time"
    elif echo "$error_msg" | grep -qi "timed\|timeout\|connection"; then
        log "⏳ [超時] 連線逾時，等待 ${RETRY_INTERVAL} 秒後重試..."
        sleep "$RETRY_INTERVAL"
    else
        log "❌ 失敗: ${error_code:+$error_code: }$error_msg"
        log "等待 ${RETRY_INTERVAL} 秒後重試..."
        sleep "$RETRY_INTERVAL"
    fi
done

log "=========================================="
log "完成！"
log "=========================================="
