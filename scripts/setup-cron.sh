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
scp -q ~/.oci/oci_api_key.pem "$REMOTE":~/.oci/oci_api_key.pem
scp -q ~/.oci/oci_api_key_public.pem "$REMOTE":~/.oci/oci_api_key_public.pem

echo "▸ 複製腳本..."
scp -q "$ENV_FILE" "$REMOTE":~/oci-monitor/.env
scp -q "$SCRIPT_DIR/check-cost.sh" "$SCRIPT_DIR/cost-guard.sh" "$SCRIPT_DIR/oci-report.sh" "$REMOTE":~/oci-monitor/scripts/

# 5. 設定權限
echo "▸ 設定權限..."
ssh "$REMOTE" "chmod 600 ~/.oci/oci_api_key.pem ~/.oci/config && chmod +x ~/oci-monitor/scripts/*.sh"

# 6. 確認 OCI CLI PATH
OCI_PATH=$(ssh "$REMOTE" "which oci 2>/dev/null || echo ~/bin/oci")
echo "  OCI CLI: $OCI_PATH"

# 在腳本開頭加入 PATH
ssh "$REMOTE" "for f in ~/oci-monitor/scripts/*.sh; do
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
# 使用者可依自己的時區調整
ssh "$REMOTE" "crontab -l 2>/dev/null | grep -v 'oci-monitor' | grep -v '^#.*OCI' > /tmp/cron_backup 2>/dev/null || true
cat >> /tmp/cron_backup <<'CRON'
# OCI 花費通知（每天 3 次）
0 0,6,12 * * * \$HOME/oci-monitor/scripts/check-cost.sh >> \$HOME/oci-monitor/logs/check-cost.log 2>&1
# OCI 花費守衛（每小時）
0 * * * * \$HOME/oci-monitor/scripts/cost-guard.sh >> \$HOME/oci-monitor/logs/cost-guard.log 2>&1
CRON
crontab /tmp/cron_backup && rm /tmp/cron_backup"

echo "  ✅ cron 已設定"

# 9. 驗證
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
