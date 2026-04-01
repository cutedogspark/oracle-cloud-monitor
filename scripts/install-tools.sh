#!/bin/bash
# Oracle Cloud Monitor — 跨平台工具安裝腳本
# 支援: macOS (ARM/Intel), Linux (AMD64), Windows (WSL2)
#
# 用法: ./scripts/install-tools.sh

set -euo pipefail

# === 偵測平台 ===
detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin)
            PLATFORM="macos"
            ;;
        Linux)
            # 偵測是否在 WSL 底下
            if grep -qi microsoft /proc/version 2>/dev/null; then
                PLATFORM="wsl"
            else
                PLATFORM="linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "❌ 不支援原生 Windows 命令列，請使用 WSL2："
            echo "   1. 開啟 PowerShell (系統管理員)"
            echo "   2. 執行: wsl --install"
            echo "   3. 重新開機後在 WSL 裡執行此腳本"
            exit 1
            ;;
        *)
            echo "❌ 不支援的作業系統: $os"
            exit 1
            ;;
    esac

    case "$arch" in
        arm64|aarch64) ARCH="arm64" ;;
        x86_64|amd64)  ARCH="amd64" ;;
        *)
            echo "❌ 不支援的架構: $arch"
            exit 1
            ;;
    esac

    echo "  平台: $PLATFORM ($ARCH)"
}

# === 檢查指令是否存在 ===
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# === 安裝 Python3 ===
install_python3() {
    if has_cmd python3; then
        echo "  ✅ Python3 已安裝: $(python3 --version 2>&1)"
        return
    fi

    # 某些 Windows/Linux 環境只有 python 沒有 python3
    if has_cmd python; then
        local ver
        ver=$(python --version 2>&1)
        if echo "$ver" | grep -q "Python 3"; then
            echo "  ✅ Python 已安裝 ($ver)，但缺少 python3 指令"
            echo "  ℹ️  建議建立 symlink: sudo ln -s \$(which python) /usr/local/bin/python3"
            return
        fi
    fi

    echo "  安裝 Python3..."
    case "$PLATFORM" in
        macos)
            if has_cmd brew; then
                brew install python3
            else
                echo "  ❌ 請先安裝 Homebrew: https://brew.sh"
                echo "     或直接下載 Python: https://www.python.org/downloads/"
                return 1
            fi
            ;;
        linux|wsl)
            if has_cmd apt-get; then
                sudo apt-get update -qq && sudo apt-get install -y -qq python3
            elif has_cmd dnf; then
                sudo dnf install -y python3
            elif has_cmd yum; then
                sudo yum install -y python3
            elif has_cmd pacman; then
                sudo pacman -Sy --noconfirm python
            else
                echo "  ❌ 無法自動安裝 Python3，請手動安裝"
                return 1
            fi
            ;;
    esac
    echo "  ✅ Python3 安裝完成"
}

# === 安裝 curl ===
install_curl() {
    if has_cmd curl; then
        echo "  ✅ curl 已安裝"
        return
    fi

    echo "  安裝 curl..."
    case "$PLATFORM" in
        macos)
            # macOS 預設有 curl
            echo "  ❌ macOS 應內建 curl，請檢查 PATH"
            return 1
            ;;
        linux|wsl)
            if has_cmd apt-get; then
                sudo apt-get update -qq && sudo apt-get install -y -qq curl
            elif has_cmd dnf; then
                sudo dnf install -y curl
            elif has_cmd yum; then
                sudo yum install -y curl
            elif has_cmd pacman; then
                sudo pacman -Sy --noconfirm curl
            fi
            ;;
    esac
    echo "  ✅ curl 安裝完成"
}

# === 安裝 OCI CLI ===
install_oci_cli() {
    if has_cmd oci; then
        echo "  ✅ OCI CLI 已安裝: $(oci --version 2>&1)"
        return
    fi

    # 檢查 ~/bin/oci（OCI CLI 預設安裝位置）
    if [ -x "$HOME/bin/oci" ]; then
        echo "  ✅ OCI CLI 已安裝在 ~/bin/oci"
        echo "  ℹ️  請加入 PATH: export PATH=\$HOME/bin:\$PATH"
        return
    fi

    echo "  安裝 OCI CLI..."
    echo "  （安裝過程會詢問幾個問題，可直接按 Enter 使用預設值）"
    echo ""

    bash -c "$(curl -sL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

    # 確認安裝結果
    if has_cmd oci || [ -x "$HOME/bin/oci" ]; then
        echo ""
        echo "  ✅ OCI CLI 安裝完成"
        echo "  ℹ️  如果 oci 指令找不到，請重新開啟終端或執行:"
        echo "     export PATH=\$HOME/bin:\$PATH"
    else
        echo "  ❌ OCI CLI 安裝可能失敗，請檢查上方輸出"
        return 1
    fi
}

# === 設定 OCI API Key ===
setup_oci_config() {
    if [ -f "$HOME/.oci/config" ]; then
        echo "  ✅ OCI config 已存在 (~/.oci/config)"

        # 驗證連線
        echo "  驗證 OCI 連線..."
        local oci_cmd="oci"
        has_cmd oci || oci_cmd="$HOME/bin/oci"

        if SUPPRESS_LABEL_WARNING=True $oci_cmd iam region list --query 'data[0].name' --output json >/dev/null 2>&1; then
            echo "  ✅ OCI API 連線正常"
        else
            echo "  ⚠️  OCI API 連線失敗，請檢查 config 和 API key"
            echo "     重新設定: oci setup config"
        fi
        return
    fi

    echo ""
    echo "  需要設定 OCI API Key。"
    echo "  請準備好以下資訊（在 OCI Console 取得）："
    echo "    - Tenancy OCID"
    echo "    - User OCID"
    echo "    - Region (例如 ap-osaka-1)"
    echo ""
    read -rp "  是否現在設定? (y/N) " answer
    if [[ "${answer,,}" == "y" ]]; then
        local oci_cmd="oci"
        has_cmd oci || oci_cmd="$HOME/bin/oci"
        $oci_cmd setup config
        echo ""
        echo "  ✅ 設定完成！請到 OCI Console → Profile → API Keys 上傳公鑰："
        echo "     cat ~/.oci/oci_api_key_public.pem"
    else
        echo "  ⏭️  跳過。之後可執行: oci setup config"
    fi
}

# === 檢查 .env ===
check_env() {
    local project_dir
    project_dir="$(cd "$(dirname "$0")/.." && pwd)"

    if [ -f "$project_dir/.env" ]; then
        echo "  ✅ .env 已存在"

        # 檢查是否還有範例值
        if grep -q "xxxxxxxxxxxxxxxxxxxx" "$project_dir/.env" 2>/dev/null; then
            echo "  ⚠️  .env 含有範例值，請編輯填入真實的 OCID："
            echo "     vim $project_dir/.env"
        fi
    else
        if [ -f "$project_dir/env.example" ]; then
            cp "$project_dir/env.example" "$project_dir/.env"
            echo "  ✅ 已建立 .env（從 env.example 複製）"
            echo "  ⚠️  請編輯 .env 填入你的 OCI 設定："
            echo "     vim $project_dir/.env"
        else
            echo "  ❌ 找不到 env.example"
        fi
    fi
}

# === 檢查帳戶類型 ===
check_account_type() {
    local project_dir oci_cmd tenancy_id python_cmd
    project_dir="$(cd "$(dirname "$0")/.." && pwd)"

    if [ ! -f "$project_dir/.env" ]; then
        echo "  ⏭️  跳過（未設定 .env）"
        return
    fi
    source "$project_dir/.env"

    oci_cmd="oci"
    has_cmd oci || oci_cmd="$HOME/bin/oci"

    if ! has_cmd "$oci_cmd"; then
        echo "  ⏭️  跳過（OCI CLI 未安裝）"
        return
    fi

    # 偵測 Python
    python_cmd="python3"
    has_cmd python3 || python_cmd="python"

    local payment_model
    payment_model=$(SUPPRESS_LABEL_WARNING=True $oci_cmd organizations subscription list \
        --compartment-id "$TENANCY_ID" \
        --output json 2>/dev/null | $python_cmd -c "
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

    if [ "$payment_model" = "PAYG" ]; then
        echo "  ✅ 帳戶類型: Pay As You Go (PAYG)"
    elif [ "$payment_model" = "UNKNOWN" ]; then
        echo "  ⚠️  無法確認帳戶類型"
        echo "     請到 OCI Console → Billing 確認是否為 Pay As You Go"
    else
        echo "  ⚠️  帳戶類型: $payment_model (非 PAYG)"
        echo ""
        echo "     Free Trial 與 Pay As You Go 的差異："
        echo "     ┌──────────────────┬──────────────┬────────────────────┐"
        echo "     │                  │ Free Trial   │ Pay As You Go      │"
        echo "     ├──────────────────┼──────────────┼────────────────────┤"
        echo "     │ 免費額度         │ \$300 / 30天  │ Always Free 永久   │"
        echo "     │ ARM A1 搶到後    │ 試用結束回收 │ 永久保留           │"
        echo "     │ 超額收費         │ 不會（到期停）│ 超出部分收費      │"
        echo "     │ 需要信用卡       │ 不需要       │ 需要               │"
        echo "     └──────────────────┴──────────────┴────────────────────┘"
        echo ""
        echo "     建議升級為 PAYG 以確保搶到的實例不會被回收。"
        echo "     升級方式：OCI Console → Billing → Upgrade to Paid"
    fi
}

# === 檢查 SSH Key ===
check_ssh_key() {
    local project_dir
    project_dir="$(cd "$(dirname "$0")/.." && pwd)"

    if [ -f "$project_dir/.env" ]; then
        source "$project_dir/.env"
    fi

    local key_file="${SSH_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
    # 展開 $HOME
    key_file=$(eval echo "$key_file")

    if [ -f "$key_file" ]; then
        echo "  ✅ SSH 公鑰存在: $key_file"
    else
        echo "  ⚠️  SSH 公鑰不存在: $key_file"
        echo "     產生新的 SSH Key: ssh-keygen -t rsa -b 4096"
        echo "     或修改 .env 中的 SSH_KEY_FILE 指向現有的公鑰"
    fi
}

# === Main ===
echo ""
echo "═══════════════════════════════════════════"
echo "  Oracle Cloud Monitor — 工具安裝檢查"
echo "═══════════════════════════════════════════"
echo ""

echo "▸ 偵測平台"
detect_platform

echo ""
echo "▸ 檢查 / 安裝 Python3"
install_python3

echo ""
echo "▸ 檢查 / 安裝 curl"
install_curl

echo ""
echo "▸ 檢查 / 安裝 OCI CLI"
install_oci_cli

echo ""
echo "▸ 檢查 OCI 設定"
setup_oci_config

echo ""
echo "▸ 檢查 .env 設定檔"
check_env

echo ""
echo "▸ 檢查帳戶類型"
check_account_type

echo ""
echo "▸ 檢查 SSH Key"
check_ssh_key

echo ""
echo "═══════════════════════════════════════════"
echo "  安裝檢查完成！"
echo ""
echo "  下一步："
echo "    1. 確認 .env 設定正確"
echo "    2. 查看資源報表: ./scripts/oci-report.sh"
echo "    3. 搶 ARM A1:    ./scripts/grab-free-a1.sh"
echo "═══════════════════════════════════════════"
echo ""
