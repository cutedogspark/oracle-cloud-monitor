#!/bin/bash
# 共用通知函式 — 供其他腳本 source 使用
# ONS email 為預設，ntfy.sh 為選填
#
# 用法（在其他腳本中）:
#   source "$(dirname "$0")/notify.sh"
#   send_notify "標題" "內容" "優先級(optional)"

# 確保 oci CLI 在 PATH 中（OCI CLI 預設安裝在 ~/bin）
if [ -d "$HOME/bin" ]; then
    export PATH="$HOME/bin:$PATH"
fi

# 發送通知（ONS email + ntfy.sh）
# $1: title
# $2: message body
# $3: priority (low/default/high/urgent)，預設 default
send_notify() {
    local title="$1"
    local body="$2"
    local priority="${3:-default}"
    local sent=0
    local configured=0

    # 1. ONS email（預設）
    if [ -n "${ONS_TOPIC_ID:-}" ]; then
        configured=1
        oci ons message publish \
            --topic-id "$ONS_TOPIC_ID" \
            --title "$title" \
            --body "$body" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "[notify] ONS email sent: $title"
            sent=1
        else
            echo "[notify] ONS email failed: $title" >&2
        fi
    fi

    # 2. ntfy.sh（選填）
    if [ -n "${NTFY_TOPIC:-}" ]; then
        configured=1
        local ntfy_tags="bell"
        case "$priority" in
            urgent) ntfy_tags="rotating_light" ;;
            high)   ntfy_tags="warning" ;;
            low)    ntfy_tags="white_check_mark" ;;
        esac

        curl -sf \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -H "Tags: $ntfy_tags" \
            -d "$body" \
            "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "[notify] ntfy sent: $title"
            sent=1
        else
            echo "[notify] ntfy failed: $title" >&2
        fi
    fi

    # 設定與發送結果判斷
    if [ $configured -eq 0 ]; then
        echo "[notify] WARNING: 未設定任何通知方式（ONS_TOPIC_ID 和 NTFY_TOPIC 都是空的）" >&2
        echo "[notify] 請在 .env 中至少設定一個通知管道" >&2
    elif [ $sent -eq 0 ]; then
        echo "[notify] WARNING: 已設定的通知管道全部發送失敗，請檢查 OCI 設定或網路" >&2
    fi
}
