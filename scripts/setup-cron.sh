#!/bin/bash
# 在遠端 OCI 實例上設定監控排程
#
# 用法:
#   ./scripts/setup-cron.sh <user@host>
#
# 此腳本會：
# 1. 在遠端安裝 OCI CLI
# 2. 複製 .env、config、API key 和監控腳本
# 3. 設定 cron 排程

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [ -z "${1:-}" ]; then
    echo "用法: $0 <user@host>"
    echo "範例: $0 opc@161.33.42.91"
    exit 1
fi

REMOTE="$1"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ 找不到 .env"
    exit 1
fi
source "$ENV_FILE"

echo "=== OCI 監控排程安裝器 ==="
echo "目標: $REMOTE"
echo ""

# 1. 檢查連線
echo "▸ 檢查 SSH 連線..."
ssh -o ConnectTimeout=10 "$REMOTE" "echo OK" || { echo "❌ 無法連線到 $REMOTE"; exit 1; }

# 2. 安裝 OCI CLI
echo "▸ 檢查/安裝 OCI CLI..."
ssh "$REMOTE" "which oci >/dev/null 2>&1 || (which ~/bin/oci >/dev/null 2>&1) || \
    (echo '  安裝 OCI CLI...' && curl -sL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh | bash -s -- --accept-all-defaults >/dev/null 2>&1 && echo '  ✅ OCI CLI 安裝完成')"

# 3. 建立目錄
echo "▸ 建立遠端目錄..."
ssh "$REMOTE" "mkdir -p ~/.oci ~/oci-monitor/scripts ~/oci-monitor/logs"

# 4. 複製檔案
echo "▸ 複製設定檔..."
scp -q ~/.oci/config "$REMOTE":~/.oci/config

# 依本機 config 取出實際 key_file 路徑來複製（避免寫死檔名與 config 不一致）
LOCAL_KEY=$(grep -E '^key_file' ~/.oci/config | head -1 | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s#^~#$HOME#")
if [ -z "$LOCAL_KEY" ] || [ ! -f "$LOCAL_KEY" ]; then
    echo "❌ 無法從 ~/.oci/config 找到有效的 key_file（取得: '${LOCAL_KEY:-空}'）"
    exit 1
fi
scp -q "$LOCAL_KEY" "$REMOTE":~/.oci/oci_api_key.pem
scp -q ~/.oci/oci_api_key_public.pem "$REMOTE":~/.oci/oci_api_key_public.pem 2>/dev/null || true

# 改寫遠端 config 的 key_file 為遠端絕對路徑（本機路徑在 VM 上不存在會導致 OCI 查詢全失敗）
ssh "$REMOTE" 'sed -i "s#^key_file=.*#key_file=$HOME/.oci/oci_api_key.pem#" ~/.oci/config'

echo "▸ 複製腳本..."
scp -q "$ENV_FILE" "$REMOTE":~/oci-monitor/.env
scp -q "$SCRIPT_DIR/notify.sh" "$SCRIPT_DIR/check-cost.sh" "$SCRIPT_DIR/cost-guard.sh" "$SCRIPT_DIR/oci-report.sh" "$SCRIPT_DIR/ssh-login-notify.sh" "$SCRIPT_DIR/backup-instance.sh" "$REMOTE":~/oci-monitor/scripts/

# 5. 設定權限
echo "▸ 設定權限..."
ssh "$REMOTE" "chmod 600 ~/.oci/oci_api_key.pem ~/.oci/config && chmod +x ~/oci-monitor/scripts/*.sh"

# 6. 確認 OCI CLI PATH
OCI_PATH=$(ssh "$REMOTE" "which oci 2>/dev/null || echo ~/bin/oci")
echo "  OCI CLI: $OCI_PATH"

# 在腳本開頭加入 PATH（排除 ssh-login-notify.sh，它有自己的 PAM PATH 處理）
ssh "$REMOTE" "for f in ~/oci-monitor/scripts/*.sh; do
    case \"\$f\" in *ssh-login-notify*) continue ;; esac
    if ! grep -q 'HOME/bin' \"\$f\" 2>/dev/null; then
        sed -i '2a export PATH=\$HOME/bin:\$PATH' \"\$f\"
    fi
done"

# 7. 測試
echo "▸ 測試 OCI CLI..."
ssh "$REMOTE" "export PATH=\$HOME/bin:\$PATH && export SUPPRESS_LABEL_WARNING=True && oci iam region list --query 'data[0].name' --output json" 2>/dev/null && echo "  ✅ OCI CLI 正常"

# 8. 詢問時區並設定 cron
echo ""
echo "▸ 設定 cron 排程..."
REMOTE_TZ=$(ssh "$REMOTE" "timedatectl 2>/dev/null | grep 'Time zone' | awk '{print \$3}'" 2>/dev/null || echo "UTC")
echo "  遠端時區: $REMOTE_TZ"

# 預設使用 UTC 0:00/3:00/9:00（對應 JST 9/12/18）
# 清除舊版 (~/.oci/) 和現有 oci-monitor 的 cron 項目
ssh "$REMOTE" "crontab -l 2>/dev/null | grep -v 'oci-monitor' | grep -v '\.oci/check-oci-cost' | grep -v '\.oci/cost-guard' | grep -v '^#.*OCI' > /tmp/cron_backup 2>/dev/null || true
cat >> /tmp/cron_backup <<'CRON'
# OCI 花費通知（每天 3 次）
0 0,3,9 * * * \$HOME/oci-monitor/scripts/check-cost.sh >> \$HOME/oci-monitor/logs/check-cost.log 2>&1
# OCI 花費守衛（每小時）
0 * * * * \$HOME/oci-monitor/scripts/cost-guard.sh >> \$HOME/oci-monitor/logs/cost-guard.log 2>&1
# OCI Boot Volume 自動備份（每 3 小時）
0 */3 * * * \$HOME/oci-monitor/scripts/backup-instance.sh --auto >> \$HOME/oci-monitor/logs/backup-instance.log 2>&1
CRON
crontab /tmp/cron_backup && rm /tmp/cron_backup"

echo "  ✅ cron 已設定"

# 9. 清理舊版腳本
echo ""
echo "▸ 清理舊版腳本 (~/.oci/ 中的監控腳本)..."
ssh "$REMOTE" "
    for f in check-oci-cost.sh cost-guard.sh check-oci-cost.log cost-guard.log; do
        if [ -f \"\$HOME/.oci/\$f\" ]; then
            mv \"\$HOME/.oci/\$f\" \"\$HOME/.oci/\${f}.bak\"
            echo \"  已備份: ~/.oci/\$f -> ~/.oci/\${f}.bak\"
        fi
    done
"

# 10. 安裝 SSH 登入通知
echo ""
echo "▸ 設定 SSH 登入通知..."
ssh "$REMOTE" "
    # 複製腳本到系統路徑
    sudo cp ~/oci-monitor/scripts/ssh-login-notify.sh /usr/local/bin/ssh-login-notify.sh
    sudo chmod +x /usr/local/bin/ssh-login-notify.sh

    # 檢查 PAM 是否已設定
    if grep -q 'ssh-login-notify' /etc/pam.d/sshd 2>/dev/null; then
        echo '  ✅ PAM 已設定（ssh-login-notify）'
    else
        echo 'session optional pam_exec.so seteuid /usr/local/bin/ssh-login-notify.sh' | sudo tee -a /etc/pam.d/sshd >/dev/null
        echo '  ✅ PAM 設定完成'
    fi
"

# 11. 驗證
echo ""
echo "▸ 目前 cron 排程:"
ssh "$REMOTE" "crontab -l"

echo ""
echo "=========================================="
echo "✅ 安裝完成！"
echo ""
echo "  監控腳本: ~/oci-monitor/scripts/"
echo "  日誌檔案: ~/oci-monitor/logs/"
echo "  通知頻道: https://ntfy.sh/${NTFY_TOPIC}"
echo ""
echo "  手動測試:"
echo "    ssh $REMOTE 'bash ~/oci-monitor/scripts/check-cost.sh'"
echo "    ssh $REMOTE 'bash ~/oci-monitor/scripts/cost-guard.sh'"
echo "    ssh $REMOTE 'bash ~/oci-monitor/scripts/oci-report.sh'"
echo "=========================================="
