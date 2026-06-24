#!/bin/bash
# SSH Login Alert — 透過 PAM 在 SSH 登入時觸發通知
# 預設使用 ONS email，ntfy.sh 為選填
#
# 安裝方式（需要 root）：
#   sudo cp scripts/ssh-login-notify.sh /usr/local/bin/
#   sudo chmod +x /usr/local/bin/ssh-login-notify.sh
#   echo 'session optional pam_exec.so seteuid /usr/local/bin/ssh-login-notify.sh' | sudo tee -a /etc/pam.d/sshd

if [ "$PAM_TYPE" != "open_session" ]; then
    exit 0
fi

# PAM 環境下 PATH 和 HOME 可能未正確設定
export PATH="/usr/local/bin:/usr/bin:/bin:/snap/bin:$PATH"
PAM_USER_HOME=$(getent passwd "${PAM_USER}" | cut -d: -f6)
# oci CLI 以 $HOME 解析 ~/.oci/config，PAM 觸發時 HOME 可能為空而誤抓 /root/.oci/config
export HOME="$PAM_USER_HOME"

# 載入 .env 設定
ENV_FILE="${PAM_USER_HOME}/oci-monitor/.env"
if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

# 檢查是否啟用
if [ "${SSH_NOTIFY_ENABLED:-true}" != "true" ]; then
    exit 0
fi

HOSTNAME=$(hostname)
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
SRC_IP="${PAM_RHOST:-unknown}"
SSH_NOTIFY_PRIORITY="${SSH_NOTIFY_PRIORITY:-high}"

TITLE="SSH Login: ${HOSTNAME}"
BODY="User: ${PAM_USER}
From: ${SRC_IP}
Time: ${TIMESTAMP}"

# 1. ONS email（預設）
if [ -n "${ONS_TOPIC_ID:-}" ]; then
    OCI_CMD="oci"
    command -v oci >/dev/null 2>&1 || OCI_CMD="${PAM_USER_HOME}/bin/oci"
    SUPPRESS_LABEL_WARNING=True $OCI_CMD ons message publish \
        --topic-id "$ONS_TOPIC_ID" \
        --title "$TITLE" \
        --body "$BODY" >/dev/null 2>&1 &
fi

# 2. ntfy.sh（選填）
if [ -n "${NTFY_TOPIC:-}" ]; then
    curl -sf \
        -H "Title: $TITLE" \
        -H "Priority: ${SSH_NOTIFY_PRIORITY}" \
        -H "Tags: key,warning" \
        -d "$BODY" \
        "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 &
fi

# 等待背景程序完成，避免 PAM 提前終止子程序
wait
exit 0
