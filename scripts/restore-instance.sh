#!/bin/bash
# OCI Boot Volume 還原 — 從備份還原實例
#
# 用法:
#   ./scripts/restore-instance.sh                # 互動模式：列出備份讓你選
#   ./scripts/restore-instance.sh <backup-id>    # 直接指定備份 OCID 還原
#
# 還原流程：
#   1. 終止現有實例（保留 Boot Volume 以防萬一）
#   2. 從備份建立新的 Boot Volume
#   3. 用新的 Boot Volume 啟動新實例
#   4. 重新綁定 Reserved IP（如有）
#   5. 確認成功後刪除舊的 Boot Volume

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

LOG_FILE="${PROJECT_DIR}/logs/restore-instance.log"
mkdir -p "$(dirname "$LOG_FILE")"

COMPARTMENT="${COMPARTMENT_ID:-$TENANCY_ID}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $1"
    exit 1
}

# === 列出可用備份 ===
list_backups() {
    echo ""
    echo "══════════════════════════════════════════"
    echo "  可用的 Boot Volume Backups"
    echo "══════════════════════════════════════════"
    echo ""

    local backups_json
    backups_json=$(oci bv boot-volume-backup list \
        --compartment-id "$COMPARTMENT" \
        --lifecycle-state AVAILABLE \
        --all \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --output json 2>/dev/null)

    if [ -z "$backups_json" ]; then
        die "無法查詢備份列表"
    fi

    local count
    count=$(echo "$backups_json" | $PYTHON -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null)

    if [ "$count" = "0" ]; then
        echo "  沒有可用的備份。"
        echo "  請先執行 ./scripts/backup-instance.sh 建立備份。"
        exit 0
    fi

    echo "$backups_json" | $PYTHON -c "
import sys, json

data = json.load(sys.stdin).get('data', [])
print(f'  共 {len(data)} 個備份：')
print()
print(f'  {'#':<4} {'名稱':<40} {'大小':>6} {'類型':<12} {'建立時間'}')
print(f'  {'─'*4} {'─'*40} {'─'*6} {'─'*12} {'─'*20}')

for i, b in enumerate(data, 1):
    name = b.get('display-name', 'N/A')
    size = b.get('size-in-gbs', 'N/A')
    btype = b.get('type', 'N/A')
    created = b.get('time-created', 'N/A')[:19].replace('T', ' ')
    print(f'  {i:<4} {name:<40} {size:>4}GB {btype:<12} {created}')

print()
print('  OCID 列表（複製用）：')
for i, b in enumerate(data, 1):
    print(f'  [{i}] {b[\"id\"]}')
" 2>/dev/null

    echo "$backups_json"
}

# === 選擇備份 ===
select_backup() {
    local backups_json="$1"

    echo ""
    read -rp "  請輸入編號 (1-N) 或貼上備份 OCID: " selection

    if [[ "$selection" =~ ^ocid1\. ]]; then
        BACKUP_ID="$selection"
    elif [[ "$selection" =~ ^[0-9]+$ ]]; then
        BACKUP_ID=$(echo "$backups_json" | $PYTHON -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
idx = int('$selection') - 1
if 0 <= idx < len(data):
    print(data[idx]['id'])
else:
    print('INVALID')
" 2>/dev/null)
        if [ "$BACKUP_ID" = "INVALID" ] || [ -z "$BACKUP_ID" ]; then
            die "無效的編號: $selection"
        fi
    else
        die "無效的輸入: $selection"
    fi
}

# === 確認備份資訊 ===
confirm_backup() {
    local backup_json
    backup_json=$(oci bv boot-volume-backup get \
        --boot-volume-backup-id "$BACKUP_ID" \
        --output json 2>/dev/null)

    if [ -z "$backup_json" ]; then
        die "無法取得備份資訊: $BACKUP_ID"
    fi

    BACKUP_NAME=$(echo "$backup_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data']['display-name'])" 2>/dev/null)
    BACKUP_SIZE=$(echo "$backup_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data']['size-in-gbs'])" 2>/dev/null)
    BACKUP_STATE=$(echo "$backup_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data']['lifecycle-state'])" 2>/dev/null)
    BACKUP_CREATED=$(echo "$backup_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data']['time-created'][:19])" 2>/dev/null)

    if [ "$BACKUP_STATE" != "AVAILABLE" ]; then
        die "備份狀態不可用: $BACKUP_STATE"
    fi

    echo ""
    echo "══════════════════════════════════════════"
    echo "  還原確認"
    echo "══════════════════════════════════════════"
    echo ""
    echo "  備份名稱: $BACKUP_NAME"
    echo "  備份大小: ${BACKUP_SIZE} GB"
    echo "  建立時間: $BACKUP_CREATED"
    echo ""
    echo "  還原設定:"
    echo "    實例名稱: ${DISPLAY_NAME}"
    echo "    Shape:    VM.Standard.A1.Flex"
    echo "    OCPU:     ${OCPUS}"
    echo "    RAM:      ${MEMORY} GB"
    echo "    AD:       ${AVAILABILITY_DOMAIN}"
    echo ""
    echo "  ⚠️  此操作將："
    echo "    1. 終止現有實例（舊 Boot Volume 會保留）"
    echo "    2. 從備份建立新的 Boot Volume"
    echo "    3. 啟動新的實例"
    echo "    4. 還原完成後刪除舊的 Boot Volume"
    echo ""

    read -rp "  確定要還原嗎？(yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "  已取消。"
        exit 0
    fi
}

# === 取得現有實例資訊 ===
get_current_instance() {
    CURRENT_INSTANCE_ID=$(oci compute instance list \
        --compartment-id "$COMPARTMENT" \
        --lifecycle-state RUNNING \
        --all \
        --query 'data[0].id' \
        --raw-output 2>/dev/null)

    if [ -n "$CURRENT_INSTANCE_ID" ] && [ "$CURRENT_INSTANCE_ID" != "null" ]; then
        CURRENT_INSTANCE_NAME=$(oci compute instance get \
            --instance-id "$CURRENT_INSTANCE_ID" \
            --query 'data."display-name"' \
            --raw-output 2>/dev/null)

        # 取得舊 Boot Volume ID
        OLD_BOOT_VOLUME_ID=$(oci compute boot-volume-attachment list \
            --compartment-id "$COMPARTMENT" \
            --availability-domain "$AVAILABILITY_DOMAIN" \
            --instance-id "$CURRENT_INSTANCE_ID" \
            --query 'data[?("lifecycle-state"=='"'"'ATTACHED'"'"')].{id:"boot-volume-id"}|[0].id' \
            --raw-output 2>/dev/null)

        # 取得現有 Public IP
        local vnic_id
        vnic_id=$(oci compute instance list-vnics \
            --instance-id "$CURRENT_INSTANCE_ID" \
            --query 'data[0].id' \
            --raw-output 2>/dev/null)

        if [ -n "$vnic_id" ] && [ "$vnic_id" != "null" ]; then
            CURRENT_PUBLIC_IP=$(oci network private-ip list \
                --vnic-id "$vnic_id" \
                --query 'data[0].id' \
                --raw-output 2>/dev/null)

            RESERVED_IP_ID=$(oci network public-ip list \
                --compartment-id "$COMPARTMENT" \
                --scope REGION \
                --all \
                --query 'data[?("lifecycle-state"=='"'"'ASSIGNED'"'"')].id|[0]' \
                --raw-output 2>/dev/null)
        fi

        log "現有實例: $CURRENT_INSTANCE_NAME ($CURRENT_INSTANCE_ID)"
        log "舊 Boot Volume: $OLD_BOOT_VOLUME_ID"
        [ -n "$RESERVED_IP_ID" ] && [ "$RESERVED_IP_ID" != "null" ] && log "Reserved IP: $RESERVED_IP_ID"
    fi
}

# === Step 1: 終止現有實例 ===
terminate_current_instance() {
    if [ -z "$CURRENT_INSTANCE_ID" ] || [ "$CURRENT_INSTANCE_ID" = "null" ]; then
        log "沒有運行中的實例，跳過終止步驟"
        return
    fi

    log "Step 1: 終止現有實例 $CURRENT_INSTANCE_NAME..."
    # preserve-boot-volume=true 保留舊 Boot Volume 以防萬一
    oci compute instance terminate \
        --instance-id "$CURRENT_INSTANCE_ID" \
        --preserve-boot-volume true \
        --force 2>/dev/null

    if [ $? -ne 0 ]; then
        die "終止實例失敗"
    fi

    # 等待實例完全終止
    log "  等待實例終止..."
    local max_wait=300
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        local state
        state=$(oci compute instance get \
            --instance-id "$CURRENT_INSTANCE_ID" \
            --query 'data."lifecycle-state"' \
            --raw-output 2>/dev/null)

        if [ "$state" = "TERMINATED" ]; then
            log "  實例已終止"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""

    if [ $elapsed -ge $max_wait ]; then
        die "等待實例終止超時"
    fi
}

# === Step 2: 從備份建立新 Boot Volume ===
create_boot_volume_from_backup() {
    log "Step 2: 從備份建立新 Boot Volume..."

    local result
    result=$(oci bv boot-volume create \
        --compartment-id "$COMPARTMENT" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --boot-volume-backup-id "$BACKUP_ID" \
        --display-name "${DISPLAY_NAME} (Boot Volume)" \
        --vpus-per-gb 10 \
        --output json 2>&1)

    if [ $? -ne 0 ]; then
        die "建立 Boot Volume 失敗: $result"
    fi

    NEW_BOOT_VOLUME_ID=$(echo "$result" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
    log "  新 Boot Volume: $NEW_BOOT_VOLUME_ID"

    # 等待 Boot Volume 可用
    log "  等待 Boot Volume 就緒..."
    local max_wait=600
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        local state
        state=$(oci bv boot-volume get \
            --boot-volume-id "$NEW_BOOT_VOLUME_ID" \
            --query 'data."lifecycle-state"' \
            --raw-output 2>/dev/null)

        if [ "$state" = "AVAILABLE" ]; then
            log "  Boot Volume 就緒"
            break
        elif [ "$state" = "FAULTY" ] || [ "$state" = "TERMINATED" ]; then
            die "Boot Volume 狀態異常: $state"
        fi
        sleep 15
        elapsed=$((elapsed + 15))
        echo -n "."
    done
    echo ""

    if [ $elapsed -ge $max_wait ]; then
        die "等待 Boot Volume 就緒超時"
    fi
}

# === Step 3: 啟動新實例 ===
launch_new_instance() {
    log "Step 3: 啟動新實例..."

    # 讀取 SSH 公鑰
    local ssh_key
    if [ -f "${SSH_KEY_FILE}" ]; then
        ssh_key=$(cat "${SSH_KEY_FILE}")
    else
        die "找不到 SSH 公鑰: ${SSH_KEY_FILE}"
    fi

    local result
    result=$(oci compute instance launch \
        --compartment-id "$COMPARTMENT" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --shape "VM.Standard.A1.Flex" \
        --shape-config "{\"ocpus\": ${OCPUS}, \"memoryInGBs\": ${MEMORY}}" \
        --display-name "$DISPLAY_NAME" \
        --source-boot-volume-id "$NEW_BOOT_VOLUME_ID" \
        --subnet-id "$SUBNET_ID" \
        --metadata "{\"ssh_authorized_keys\": \"${ssh_key}\"}" \
        --assign-public-ip false \
        --output json 2>&1)

    if [ $? -ne 0 ]; then
        die "啟動實例失敗: $result"
    fi

    NEW_INSTANCE_ID=$(echo "$result" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
    log "  新實例: $NEW_INSTANCE_ID"

    # 等待實例運行
    log "  等待實例啟動..."
    local max_wait=300
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        local state
        state=$(oci compute instance get \
            --instance-id "$NEW_INSTANCE_ID" \
            --query 'data."lifecycle-state"' \
            --raw-output 2>/dev/null)

        if [ "$state" = "RUNNING" ]; then
            log "  實例已啟動"
            break
        elif [ "$state" = "TERMINATED" ] || [ "$state" = "FAULTY" ]; then
            die "實例啟動失敗: $state"
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""

    if [ $elapsed -ge $max_wait ]; then
        die "等待實例啟動超時"
    fi
}

# === Step 4: 綁定 Reserved IP ===
assign_reserved_ip() {
    if [ -z "$RESERVED_IP_ID" ] || [ "$RESERVED_IP_ID" = "null" ]; then
        log "Step 4: 沒有 Reserved IP，使用自動分配的 IP"

        # 取得 ephemeral IP
        local vnic_id
        vnic_id=$(oci compute instance list-vnics \
            --instance-id "$NEW_INSTANCE_ID" \
            --query 'data[0].id' \
            --raw-output 2>/dev/null)

        NEW_PUBLIC_IP=$(oci network vnic get \
            --vnic-id "$vnic_id" \
            --query 'data."public-ip"' \
            --raw-output 2>/dev/null)
        return
    fi

    log "Step 4: 綁定 Reserved IP..."

    # 取得新實例的 Private IP
    local vnic_id private_ip_id
    # 需等待 VNIC 就緒
    sleep 10
    vnic_id=$(oci compute instance list-vnics \
        --instance-id "$NEW_INSTANCE_ID" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null)

    private_ip_id=$(oci network private-ip list \
        --vnic-id "$vnic_id" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null)

    # 更新 Reserved IP 綁定
    oci network public-ip update \
        --public-ip-id "$RESERVED_IP_ID" \
        --private-ip-id "$private_ip_id" \
        --force 2>/dev/null

    if [ $? -eq 0 ]; then
        NEW_PUBLIC_IP=$(oci network public-ip get \
            --public-ip-id "$RESERVED_IP_ID" \
            --query 'data."ip-address"' \
            --raw-output 2>/dev/null)
        log "  Reserved IP 已綁定: $NEW_PUBLIC_IP"
    else
        log "WARNING: Reserved IP 綁定失敗，請手動處理"
    fi
}

# === Step 5: 清理舊 Boot Volume ===
cleanup_old_boot_volume() {
    if [ -z "$OLD_BOOT_VOLUME_ID" ] || [ "$OLD_BOOT_VOLUME_ID" = "null" ]; then
        return
    fi

    echo ""
    echo "  舊的 Boot Volume 已保留: $OLD_BOOT_VOLUME_ID"
    echo "  確認新實例正常後，可手動刪除："
    echo "    oci bv boot-volume delete --boot-volume-id $OLD_BOOT_VOLUME_ID --force"
    echo ""
    read -rp "  要現在刪除舊 Boot Volume 嗎？(yes/no): " del_confirm

    if [ "$del_confirm" = "yes" ]; then
        log "Step 5: 刪除舊 Boot Volume..."
        oci bv boot-volume delete \
            --boot-volume-id "$OLD_BOOT_VOLUME_ID" \
            --force 2>/dev/null

        if [ $? -eq 0 ]; then
            log "  舊 Boot Volume 已刪除"
        else
            log "WARNING: 刪除舊 Boot Volume 失敗，請手動處理"
        fi
    else
        log "Step 5: 保留舊 Boot Volume（記得手動清理以避免超出免費額度）"
    fi
}

# === Main ===
echo ""
echo "══════════════════════════════════════════"
echo "  OCI Boot Volume 還原工具"
echo "══════════════════════════════════════════"

BACKUP_ID="${1:-}"

if [ -z "$BACKUP_ID" ]; then
    # 互動模式：列出備份讓使用者選
    backups_json=$(list_backups)

    # 取得純 JSON 部分（最後一行）
    backups_data=$(echo "$backups_json" | $PYTHON -c "
import sys, json
lines = sys.stdin.read()
# 找到 JSON 開頭
idx = lines.rfind('{\"data\"')
if idx >= 0:
    print(lines[idx:])
" 2>/dev/null)

    # 重新顯示列表（因為 list_backups 的輸出被 capture 了）
    oci bv boot-volume-backup list \
        --compartment-id "$COMPARTMENT" \
        --lifecycle-state AVAILABLE \
        --all \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --output json 2>/dev/null | $PYTHON -c "
import sys, json

data = json.load(sys.stdin).get('data', [])
if not data:
    print('  沒有可用的備份。')
    sys.exit(1)

print(f'  共 {len(data)} 個備份：')
print()
for i, b in enumerate(data, 1):
    name = b.get('display-name', 'N/A')
    size = b.get('size-in-gbs', 'N/A')
    btype = b.get('type', 'N/A')
    created = b.get('time-created', 'N/A')[:19].replace('T', ' ')
    print(f'  [{i}] {name}')
    print(f'      Size: {size} GB | Type: {btype} | Created: {created}')
    print(f'      OCID: {b[\"id\"]}')
    print()
" 2>/dev/null

    if [ $? -ne 0 ]; then
        echo "  沒有可用的備份。請先執行 ./scripts/backup-instance.sh"
        exit 0
    fi

    echo ""
    read -rp "  請輸入編號 (1-N) 或貼上備份 OCID: " selection

    if [[ "$selection" =~ ^ocid1\. ]]; then
        BACKUP_ID="$selection"
    elif [[ "$selection" =~ ^[0-9]+$ ]]; then
        BACKUP_ID=$(oci bv boot-volume-backup list \
            --compartment-id "$COMPARTMENT" \
            --lifecycle-state AVAILABLE \
            --all \
            --sort-by TIMECREATED \
            --sort-order DESC \
            --output json 2>/dev/null | $PYTHON -c "
import sys, json
data = json.load(sys.stdin).get('data', [])
idx = int('$selection') - 1
if 0 <= idx < len(data):
    print(data[idx]['id'])
else:
    print('INVALID')
" 2>/dev/null)

        if [ "$BACKUP_ID" = "INVALID" ] || [ -z "$BACKUP_ID" ]; then
            die "無效的編號: $selection"
        fi
    else
        die "無效的輸入: $selection"
    fi
fi

# 確認備份
confirm_backup

# 取得現有實例
get_current_instance

# 執行還原
echo ""
log "========== 開始還原 =========="
terminate_current_instance
create_boot_volume_from_backup
launch_new_instance
assign_reserved_ip

# 結果
echo ""
echo "══════════════════════════════════════════"
echo "  ✅ 還原完成！"
echo "══════════════════════════════════════════"
echo ""
echo "  實例名稱: $DISPLAY_NAME"
echo "  實例 ID:  $NEW_INSTANCE_ID"
echo "  Public IP: ${NEW_PUBLIC_IP:-N/A}"
echo "  還原來源: $BACKUP_NAME ($BACKUP_CREATED)"
echo ""

# 清理舊 Boot Volume
cleanup_old_boot_volume

# 發送通知
message="Instance restored successfully!
Name: $DISPLAY_NAME
IP: ${NEW_PUBLIC_IP:-N/A}
From backup: $BACKUP_NAME ($BACKUP_CREATED)
Time: $(date '+%Y-%m-%d %H:%M')"

send_notify "OCI Restore OK: $DISPLAY_NAME" "$message" "high"
log "========== 還原完成 =========="
