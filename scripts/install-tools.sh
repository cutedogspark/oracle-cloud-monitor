#!/bin/bash
# Oracle Cloud Monitor — Cross-platform tool installation script
# Supports: macOS (ARM/Intel), Linux (AMD64), Windows (WSL2)
#
# Usage: ./scripts/install-tools.sh

set -euo pipefail

# === Detect Platform ===
detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin)
            PLATFORM="macos"
            ;;
        Linux)
            # Detect if running under WSL
            if grep -qi microsoft /proc/version 2>/dev/null; then
                PLATFORM="wsl"
            else
                PLATFORM="linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "❌ Native Windows command line not supported, please use WSL2:"
            echo "   1. Open PowerShell (Administrator)"
            echo "   2. Run: wsl --install"
            echo "   3. After reboot, run this script in WSL"
            exit 1
            ;;
        *)
            echo "❌ Unsupported operating system: $os"
            exit 1
            ;;
    esac

    case "$arch" in
        arm64|aarch64) ARCH="arm64" ;;
        x86_64|amd64)  ARCH="amd64" ;;
        *)
            echo "❌ Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    echo "  Platform: $PLATFORM ($ARCH)"
}

# === Check if command exists ===
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# === Install Python3 ===
install_python3() {
    if has_cmd python3; then
        echo "  ✅ Python3 installed: $(python3 --version 2>&1)"
        return
    fi

    # Some Windows/Linux environments only have python, not python3
    if has_cmd python; then
        local ver
        ver=$(python --version 2>&1)
        if echo "$ver" | grep -q "Python 3"; then
            echo "  ✅ Python installed ($ver), but missing python3 command"
            echo "  ℹ️  Suggest creating symlink: sudo ln -s \$(which python) /usr/local/bin/python3"
            return
        fi
    fi

    echo "  Installing Python3..."
    case "$PLATFORM" in
        macos)
            if has_cmd brew; then
                brew install python3
            else
                echo "  ❌ Please install Homebrew first: https://brew.sh"
                echo "     Or download Python directly: https://www.python.org/downloads/"
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
                echo "  ❌ Cannot automatically install Python3, please install manually"
                return 1
            fi
            ;;
    esac
    echo "  ✅ Python3 installation complete"
}

# === Install curl ===
install_curl() {
    if has_cmd curl; then
        echo "  ✅ curl installed"
        return
    fi

    echo "  Installing curl..."
    case "$PLATFORM" in
        macos)
            # macOS comes with curl by default
            echo "  ❌ macOS should have curl built-in, check PATH"
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
    echo "  ✅ curl installation complete"
}

# === Install OCI CLI ===
install_oci_cli() {
    if has_cmd oci; then
        echo "  ✅ OCI CLI installed: $(oci --version 2>&1)"
        return
    fi

    # Check ~/bin/oci (OCI CLI default install location)
    if [ -x "$HOME/bin/oci" ]; then
        echo "  ✅ OCI CLI installed at ~/bin/oci"
        echo "  ℹ️  Please add to PATH: export PATH=\$HOME/bin:\$PATH"
        return
    fi

    echo "  Installing OCI CLI..."
    echo "  (Installation will ask a few questions, press Enter to accept defaults)"
    echo ""

    bash -c "$(curl -sL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

    # Verify installation
    if has_cmd oci || [ -x "$HOME/bin/oci" ]; then
        echo ""
        echo "  ✅ OCI CLI installation complete"
        echo "  ℹ️  If oci command is not found, reopen terminal or run:"
        echo "     export PATH=\$HOME/bin:\$PATH"
    else
        echo "  ❌ OCI CLI installation may have failed, check output above"
        return 1
    fi
}

# === Configure OCI API Key ===
setup_oci_config() {
    if [ -f "$HOME/.oci/config" ]; then
        echo "  ✅ OCI config already exists (~/.oci/config)"

        # Verify connection
        echo "  Verifying OCI connection..."
        local oci_cmd="oci"
        has_cmd oci || oci_cmd="$HOME/bin/oci"

        if SUPPRESS_LABEL_WARNING=True $oci_cmd iam region list --query 'data[0].name' --output json >/dev/null 2>&1; then
            echo "  ✅ OCI API connection OK"
        else
            echo "  ⚠️  OCI API connection failed, check config and API key"
            echo "     Re-run: oci setup config"
        fi
        return
    fi

    echo ""
    echo "  OCI API Key configuration required."
    echo "  Please prepare the following (from OCI Console):"
    echo "    - Tenancy OCID"
    echo "    - User OCID"
    echo "    - Region (e.g., ap-osaka-1)"
    echo ""
    read -rp "  Configure now? (y/N) " answer
    if [[ "${answer,,}" == "y" ]]; then
        local oci_cmd="oci"
        has_cmd oci || oci_cmd="$HOME/bin/oci"
        $oci_cmd setup config
        echo ""
        echo "  ✅ Configuration complete! Upload public key to OCI Console → Profile → API Keys:"
        echo "     cat ~/.oci/oci_api_key_public.pem"
    else
        echo "  ⏭️  Skipped. Run later with: oci setup config"
    fi
}

# === Check .env ===
check_env() {
    local project_dir
    project_dir="$(cd "$(dirname "$0")/.." && pwd)"

    if [ -f "$project_dir/.env" ]; then
        echo "  ✅ .env already exists"

        # Check if still contains example values
        if grep -q "xxxxxxxxxxxxxxxxxxxx" "$project_dir/.env" 2>/dev/null; then
            echo "  ⚠️  .env contains example values, edit to fill in real OCIDs:"
            echo "     vim $project_dir/.env"
        fi
    else
        if [ -f "$project_dir/env.example" ]; then
            cp "$project_dir/env.example" "$project_dir/.env"
            echo "  ✅ .env created (copied from env.example)"
            echo "  ⚠️  Please edit .env to fill in your OCI configuration:"
            echo "     vim $project_dir/.env"
        else
            echo "  ❌ env.example not found"
        fi
    fi
}

# === Check Account Type ===
check_account_type() {
    local project_dir oci_cmd tenancy_id python_cmd
    project_dir="$(cd "$(dirname "$0")/.." && pwd)"

    if [ ! -f "$project_dir/.env" ]; then
        echo "  ⏭️  Skipped (.env not configured)"
        return
    fi
    source "$project_dir/.env"

    oci_cmd="oci"
    has_cmd oci || oci_cmd="$HOME/bin/oci"

    if ! has_cmd "$oci_cmd"; then
        echo "  ⏭️  Skipped (OCI CLI not installed)"
        return
    fi

    # Detect Python
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
        echo "  ✅ Account type: Pay As You Go (PAYG)"
    elif [ "$payment_model" = "UNKNOWN" ]; then
        echo "  ⚠️  Unable to verify account type"
        echo "     Please check OCI Console → Billing to confirm Pay As You Go status"
    else
        echo "  ⚠️  Account type: $payment_model (not PAYG)"
        echo ""
        echo "     Difference between Free Trial and Pay As You Go:"
        echo "     ┌──────────────────┬──────────────┬────────────────────┐"
        echo "     │                  │ Free Trial   │ Pay As You Go      │"
        echo "     ├──────────────────┼──────────────┼────────────────────┤"
        echo "     │ Credits          │ \$300 / 30 days │ Always Free permanent │"
        echo "     │ After grabbing ARM A1 │ Reclaimed after trial │ Permanently retained │"
        echo "     │ Overage charges  │ No (suspended at expiry) │ Charged for overage │"
        echo "     │ Credit card required │ Not required │ Required           │"
        echo "     └──────────────────┴──────────────┴────────────────────┘"
        echo ""
        echo "     Recommended to upgrade to PAYG to ensure grabbed instances are not reclaimed."
        echo "     Upgrade path: OCI Console → Billing → Upgrade to Paid"
    fi
}

# === Check SSH Key ===
check_ssh_key() {
    local project_dir
    project_dir="$(cd "$(dirname "$0")/.." && pwd)"

    if [ -f "$project_dir/.env" ]; then
        source "$project_dir/.env"
    fi

    local key_file="${SSH_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
    # Expand $HOME
    key_file=$(eval echo "$key_file")

    if [ -f "$key_file" ]; then
        echo "  ✅ SSH public key exists: $key_file"
    else
        echo "  ⚠️  SSH public key does not exist: $key_file"
        echo "     Generate new SSH key: ssh-keygen -t rsa -b 4096"
        echo "     Or modify SSH_KEY_FILE in .env to point to existing public key"
    fi
}

# === Main ===
echo ""
echo "═══════════════════════════════════════════"
echo "  Oracle Cloud Monitor — Tool Installation Check"
echo "═══════════════════════════════════════════"
echo ""

echo "▸ Detect platform"
detect_platform

echo ""
echo "▸ Check / Install Python3"
install_python3

echo ""
echo "▸ Check / Install curl"
install_curl

echo ""
echo "▸ Check / Install OCI CLI"
install_oci_cli

echo ""
echo "▸ Check OCI configuration"
setup_oci_config

echo ""
echo "▸ Check .env configuration file"
check_env

echo ""
echo "▸ Check account type"
check_account_type

echo ""
echo "▸ Check SSH Key"
check_ssh_key

echo ""
echo "═══════════════════════════════════════════"
echo "  Installation check complete!"
echo ""
echo "  Next steps:"
echo "    1. Verify .env configuration is correct"
echo "    2. View resource reports: ./scripts/oci-report.sh"
echo "    3. Grab ARM A1:    ./scripts/grab-free-a1.sh"
echo "═══════════════════════════════════════════"
echo ""
