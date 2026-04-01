#!/bin/bash
# SSH Login Alert via ntfy.sh
# 透過 PAM 在 SSH 登入時觸發通知
#
# 安裝方式（需要 root）：
#   sudo cp scripts/ssh-login-notify.sh /usr/local/bin/
#   sudo chmod +x /usr/local/bin/ssh-login-notify.sh
#   echo 'session optional pam_exec.so seteuid /usr/local/bin/ssh-login-notify.sh' | sudo tee -a /etc/pam.d/sshd

if [ "$PAM_TYPE" != "open_session" ]; then
    exit 0
fi

# 載入 .env 設定
ENV_FILE="$HOME/oci-monitor/.env"
if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

# 檢查是否啟用
if [ "${SSH_NOTIFY_ENABLED:-true}" != "true" ]; then
    exit 0
fi

NTFY_TOPIC="${NTFY_TOPIC:-my-oci-notify}"
SSH_NOTIFY_PRIORITY="${SSH_NOTIFY_PRIORITY:-high}"

HOSTNAME=$(hostname)
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
SRC_IP="${PAM_RHOST:-unknown}"

curl -sf \
    -H "Title: SSH Login: ${HOSTNAME}" \
    -H "Priority: ${SSH_NOTIFY_PRIORITY}" \
    -H "Tags: key,warning" \
    -d "User: ${PAM_USER}
From: ${SRC_IP}
Time: ${TIMESTAMP}" \
    "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 &

exit 0
