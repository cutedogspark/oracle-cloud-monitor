#!/bin/bash
# OCI Boot Volume 自動備份 — 建立 Boot Volume Backup 並輪替舊備份
# Always Free 提供 5 個免費備份額度，保留最新 5 個
#
# 用法:
#   ./scripts/backup-instance.sh              # 互動模式：選擇實例、確認備份
#   ./scripts/backup-instance.sh --auto       # 自動模式：備份第一台運行中的實例（cron 用）
#   ./scripts/backup-instance.sh <instance-id> # 直接指定實例備份（不需確認）
#
# 建議 cron: 每 3 小時
#   0 */3 * * * ~/oci-monitor/scripts/backup-instance.sh --auto

export SUPPRESS_LABEL_WARNING=True

# 跨平台 Python 偵測
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
source "${SCRIPT_DIR}/notify.sh"

LOG_FILE="${PROJECT_DIR}/logs/backup-instance.log"
mkdir -p "$(dirname "$LOG_FILE")"

# Always Free 上限 5 個備份
BACKUP_KEEP=${BACKUP_KEEP:-5}
BACKUP_FREE_LIMIT=5
BACKUP_TYPE=${BACKUP_TYPE:-INCREMENTAL}
BACKUP_PREFIX="auto-backup"
COMPARTMENT="${COMPARTMENT_ID:-$TENANCY_ID}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# === 解析參數 ===
AUTO_MODE=false
INSTANCE_ID=""

case "${1:-}" in
    --auto)
        AUTO_MODE=true
        ;;
    ocid1.*)
        INSTANCE_ID="$1"
        AUTO_MODE=true
        ;;
    "")
        AUTO_MODE=false
        ;;
    *)
        echo "用法:"
        echo "  $0              # 互動模式"
        echo "  $0 --auto       # 自動模式（cron 用）"
        echo "  $0 <instance-id> # 指定實例"
        exit 1
        ;;
esac

# === 檢查是否有備份正在進行中 ===
# 查詢所有狀態為 CREATING 的備份（包含其他機器或排程觸發的）
check_backup_in_progress() {
    log "檢查是否有備份正在進行中..."

    local creating_json
    creating_json=$(oci bv boot-volume-backup list \
        --compartment-id "$COMPARTMENT" \
        --lifecycle-state CREATING \
        --all \
        --output json 2>/dev/null)

    local creating_count
    creating_count=$(echo "$creating_json" | $PYTHON -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null)

    if [ "$creating_count" -gt 0 ] 2>/dev/null; then
        local detail
        detail=$(echo "$creating_json" | $PYTHON -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
for b in data:
    name = b.get('display-name', 'N/A')
    created = b.get('time-created', 'N/A')[:19].replace('T', ' ')
    print(f'  • {name} (started: {created})')
" 2>/dev/null)

        log "有 $creating_count 個備份正在進行中，跳過本次備份:"
        log "$detail"

        if [ "$AUTO_MODE" = false ]; then
            echo ""
            echo "  ⚠️  有 $creating_count 個備份正在進行中："
            echo "$detail"
            echo ""
            echo "  請等待完成後再執行備份。"
        fi
        exit 0
    fi

    log "沒有進行中的備份，繼續"
}

# === 檢查備份數量並在達上限時刪除最舊的 ===
check_and_free_backup_slot() {
    log "檢查備份數量（免費上限: $BACKUP_FREE_LIMIT 個）..."

    local available_json
    available_json=$(oci bv boot-volume-backup list \
        --compartment-id "$COMPARTMENT" \
        --lifecycle-state AVAILABLE \
        --all \
        --sort-by TIMECREATED \
        --sort-order ASC \
        --output json 2>/dev/null)

    local available_count
    available_count=$(echo "$available_json" | $PYTHON -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null)

    log "目前備份數量: $available_count / $BACKUP_FREE_LIMIT"

    if [ "$available_count" -ge "$BACKUP_FREE_LIMIT" ] 2>/dev/null; then
        # 取得最舊的備份
        local oldest_id oldest_name
        oldest_id=$(echo "$available_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
        oldest_name=$(echo "$available_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data'][0]['display-name'])" 2>/dev/null)

        log "已達免費上限，刪除最舊的備份: $oldest_name"

        if [ "$AUTO_MODE" = false ]; then
            echo ""
            echo "  ⚠️  備份數量已達免費上限 ($available_count/$BACKUP_FREE_LIMIT)"
            echo "  將刪除最舊的備份: $oldest_name"
            echo ""
            read -rp "  確認刪除？(Y/n): " del_confirm
            case "$del_confirm" in
                [nN]) echo "  已取消。"; exit 0 ;;
            esac
        fi

        oci bv boot-volume-backup delete \
            --boot-volume-backup-id "$oldest_id" \
            --force 2>/dev/null

        if [ $? -eq 0 ]; then
            log "已刪除: $oldest_name"
            # 等待刪除生效
            sleep 5
        else
            log "ERROR: 刪除最舊備份失敗: $oldest_name"
            send_notify "OCI Backup Failed" "Cannot delete oldest backup to free slot: $oldest_name" "high"
            exit 1
        fi
    fi
}

# === 取得實例列表 ===
get_instances_json() {
    oci compute instance list \
        --compartment-id "$COMPARTMENT" \
        --lifecycle-state RUNNING \
        --all \
        --output json 2>/dev/null
}

# === 互動模式：選擇實例 ===
interactive_select() {
    echo ""
    echo "══════════════════════════════════════════"
    echo "  OCI Boot Volume 備份工具"
    echo "══════════════════════════════════════════"
    echo ""

    local instances_json
    instances_json=$(get_instances_json)

    local count
    count=$(echo "$instances_json" | $PYTHON -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null)

    if [ "$count" = "0" ] || [ -z "$count" ]; then
        echo "  沒有運行中的實例。"
        exit 0
    fi

    # 列出實例
    echo "$instances_json" | $PYTHON -c "
import sys, json

data = json.load(sys.stdin).get('data', [])
print(f'  運行中的實例（共 {len(data)} 台）：')
print()
for i, inst in enumerate(data, 1):
    name = inst.get('display-name', 'N/A')
    shape = inst.get('shape', 'N/A')
    sc = inst.get('shape-config', {})
    ocpus = sc.get('ocpus', 'N/A')
    memory = sc.get('memory-in-gbs', 'N/A')
    created = inst.get('time-created', 'N/A')[:19].replace('T', ' ')
    print(f'  [{i}] {name}')
    print(f'      Shape: {shape} | OCPU: {ocpus} | RAM: {memory} GB')
    print(f'      Created: {created}')
    print(f'      ID: {inst[\"id\"]}')
    print()
" 2>/dev/null

    # 選擇實例
    if [ "$count" = "1" ]; then
        INSTANCE_ID=$(echo "$instances_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
        local name
        name=$(echo "$instances_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data'][0]['display-name'])" 2>/dev/null)
        echo "  只有一台實例，自動選擇: $name"
    else
        read -rp "  請選擇要備份的實例 [1-${count}]: " selection
        INSTANCE_ID=$(echo "$instances_json" | $PYTHON -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
idx = int('$selection') - 1
if 0 <= idx < len(data):
    print(data[idx]['id'])
else:
    print('INVALID')
" 2>/dev/null)
        if [ "$INSTANCE_ID" = "INVALID" ] || [ -z "$INSTANCE_ID" ]; then
            echo "  ❌ 無效的選擇"
            exit 1
        fi
    fi

    # 查詢現有備份
    echo ""
    echo "  ── 現有備份 ──"
    local existing
    existing=$(oci bv boot-volume-backup list \
        --compartment-id "$COMPARTMENT" \
        --lifecycle-state AVAILABLE \
        --all \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --output json 2>/dev/null)

    echo "$existing" | $PYTHON -c "
import sys, json

data = json.load(sys.stdin).get('data', [])
if not data:
    print('  （目前沒有備份）')
else:
    for b in data:
        name = b.get('display-name', 'N/A')
        size = b.get('size-in-gbs', 'N/A')
        btype = b.get('type', 'N/A')
        created = b.get('time-created', 'N/A')[:19].replace('T', ' ')
        print(f'  • {name} ({size} GB, {btype}, {created})')
    print(f'  共 {len(data)}/{$BACKUP_FREE_LIMIT} 個（Always Free 上限 $BACKUP_FREE_LIMIT 個）')
" 2>/dev/null

    # 選擇備份類型
    echo ""
    echo "  備份類型："
    echo "    [1] INCREMENTAL — 增量備份（較快、較小）"
    echo "    [2] FULL        — 完整備份（較慢、較大，還原更可靠）"
    echo ""
    read -rp "  請選擇備份類型 [1/2]（預設 1）: " type_choice
    case "$type_choice" in
        2) BACKUP_TYPE="FULL" ;;
        *) BACKUP_TYPE="INCREMENTAL" ;;
    esac

    # 確認
    local inst_name
    inst_name=$(oci compute instance get \
        --instance-id "$INSTANCE_ID" \
        --query 'data."display-name"' \
        --raw-output 2>/dev/null)

    echo ""
    echo "  ── 確認 ──"
    echo "  實例:     $inst_name"
    echo "  備份類型: $BACKUP_TYPE"
    echo "  保留數量: $BACKUP_KEEP（免費上限 $BACKUP_FREE_LIMIT 個）"
    echo ""
    read -rp "  開始備份？(Y/n): " confirm
    case "$confirm" in
        [nN]) echo "  已取消。"; exit 0 ;;
    esac
}

# === 自動模式：取得第一台實例 ===
auto_select() {
    if [ -z "$INSTANCE_ID" ]; then
        INSTANCE_ID=$(oci compute instance list \
            --compartment-id "$COMPARTMENT" \
            --lifecycle-state RUNNING \
            --all \
            --query 'data[0].id' \
            --raw-output 2>/dev/null)

        if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
            log "ERROR: 找不到運行中的實例"
            send_notify "OCI Backup Failed" "No running instance found" "high"
            exit 1
        fi
    fi
}

# === 執行備份 ===
do_backup() {
    INSTANCE_NAME=$(oci compute instance get \
        --instance-id "$INSTANCE_ID" \
        --query 'data."display-name"' \
        --raw-output 2>/dev/null)

    log "開始備份: $INSTANCE_NAME ($INSTANCE_ID)"

    # 取得 Boot Volume ID
    BOOT_VOLUME_ID=$(oci compute boot-volume-attachment list \
        --compartment-id "$COMPARTMENT" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --instance-id "$INSTANCE_ID" \
        --query 'data[?("lifecycle-state"=='"'"'ATTACHED'"'"')].{id:"boot-volume-id"}|[0].id' \
        --raw-output 2>/dev/null)

    if [ -z "$BOOT_VOLUME_ID" ] || [ "$BOOT_VOLUME_ID" = "null" ]; then
        log "ERROR: 找不到 Boot Volume"
        send_notify "OCI Backup Failed" "Cannot find boot volume for $INSTANCE_NAME" "high"
        exit 1
    fi

    log "Boot Volume: $BOOT_VOLUME_ID"

    # 建立備份
    BACKUP_NAME="${BACKUP_PREFIX}-${INSTANCE_NAME}-$(date '+%Y%m%d-%H%M')"
    log "建立備份: $BACKUP_NAME (type: $BACKUP_TYPE)"

    backup_result=$(oci bv boot-volume-backup create \
        --boot-volume-id "$BOOT_VOLUME_ID" \
        --display-name "$BACKUP_NAME" \
        --type "$BACKUP_TYPE" \
        --output json 2>&1)

    if [ $? -ne 0 ]; then
        log "ERROR: 備份建立失敗: $backup_result"
        send_notify "OCI Backup Failed" "Failed to create backup for $INSTANCE_NAME
Error: $backup_result" "urgent"
        exit 1
    fi

    BACKUP_ID=$(echo "$backup_result" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
    log "備份已建立: $BACKUP_ID"

    # 等待備份完成（最多 30 分鐘）
    log "等待備份完成..."
    local max_wait=1800
    local wait_interval=60
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        state=$(oci bv boot-volume-backup get \
            --boot-volume-backup-id "$BACKUP_ID" \
            --query 'data."lifecycle-state"' \
            --raw-output 2>/dev/null)

        case "$state" in
            AVAILABLE)
                log "備份完成: $BACKUP_NAME"
                break
                ;;
            FAULTY|TERMINATED)
                log "ERROR: 備份失敗，狀態: $state"
                send_notify "OCI Backup Failed" "Backup $BACKUP_NAME ended with state: $state" "urgent"
                exit 1
                ;;
            *)
                if [ "$AUTO_MODE" = false ]; then
                    echo -n "."
                fi
                sleep $wait_interval
                elapsed=$((elapsed + wait_interval))
                ;;
        esac
    done

    if [ "$AUTO_MODE" = false ]; then
        echo ""
    fi

    if [ $elapsed -ge $max_wait ]; then
        log "WARNING: 備份超時（仍在進行中: $BACKUP_ID）"
    fi

    # 備份大小
    BACKUP_SIZE=$(oci bv boot-volume-backup get \
        --boot-volume-backup-id "$BACKUP_ID" \
        --query 'data."size-in-gbs"' \
        --raw-output 2>/dev/null)
}

# === 發送通知與結果 ===
send_result() {
    # 查詢最終備份數量
    local final_count
    final_count=$(oci bv boot-volume-backup list \
        --compartment-id "$COMPARTMENT" \
        --lifecycle-state AVAILABLE \
        --all \
        --query 'length(data)' \
        --raw-output 2>/dev/null)

    local message="Instance: $INSTANCE_NAME
Backup: $BACKUP_NAME
Size: ${BACKUP_SIZE:-N/A} GB
Type: $BACKUP_TYPE
Total: ${final_count:-N/A} / $BACKUP_FREE_LIMIT
Time: $(date '+%Y-%m-%d %H:%M')"

    send_notify "OCI Backup OK: $INSTANCE_NAME" "$message" "low"

    if [ "$AUTO_MODE" = false ]; then
        echo ""
        echo "══════════════════════════════════════════"
        echo "  ✅ 備份完成！"
        echo "══════════════════════════════════════════"
        echo ""
        echo "  實例:     $INSTANCE_NAME"
        echo "  備份名稱: $BACKUP_NAME"
        echo "  備份大小: ${BACKUP_SIZE:-N/A} GB"
        echo "  備份類型: $BACKUP_TYPE"
        echo "  目前備份: ${final_count:-N/A} / $BACKUP_FREE_LIMIT"
        echo ""
    fi

    log "備份流程完成"
}

# === Main ===
if [ "$AUTO_MODE" = true ]; then
    auto_select
else
    interactive_select
fi

# 備份前檢查：是否有正在進行中的備份
check_backup_in_progress

# 備份前檢查：是否已達免費上限，達到則先刪最舊的
check_and_free_backup_slot

# 執行備份
do_backup
send_result
