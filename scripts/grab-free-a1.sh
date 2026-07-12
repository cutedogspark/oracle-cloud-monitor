#!/bin/bash
# Oracle Cloud Free Tier — Grab ARM A1.Flex resources
# Automatically retry creating instances until successful
#
# Usage: ./scripts/grab-free-a1.sh
# Copy env.example to .env and fill in your settings first

set -euo pipefail
export SUPPRESS_LABEL_WARNING=True

# Cross-platform Python detection (some environments have only python, not python3)
if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1 && python --version 2>&1 | grep -q "Python 3"; then
    PYTHON=python
else
    echo "❌ Python 3 not found, please install first: ./scripts/install-tools.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ .env file not found. Please copy env.example and fill in settings:"
    echo "   cp env.example .env"
    exit 1
fi
source "$ENV_FILE"
source "${SCRIPT_DIR}/notify.sh"

# Validate required variables
for var in COMPARTMENT_ID AVAILABILITY_DOMAIN SUBNET_ID IMAGE_ID SSH_KEY_FILE DISPLAY_NAME OCPUS MEMORY BOOT_SIZE; do
    if [ -z "${!var:-}" ]; then
        echo "❌ .env missing setting: $var"
        exit 1
    fi
done

# === Check Account Type (Pay As You Go) ===
echo "▸ Checking account type..."
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
    echo "  ⚠️  Account Type: ${PAYMENT_MODEL:-UNKNOWN} (Not Pay As You Go)"
    echo "══════════════════════════════════════════════════"
    echo ""
    echo "  Your account is currently not Pay As You Go (PAYG)."
    echo ""
    echo "  ┌─ Free Trial ─────────────────────────────────────┐"
    echo "  │ • 30-day trial period with \$300 USD credit          │"
    echo "  │ • After trial ends, non-Always Free resources will be deleted   │"
    echo "  │ • ARM A1 instances may be reclaimed after trial ends           │"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─ Pay As You Go ────────────────────────────────────┐"
    echo "  │ • Always Free resources are permanently free                   │"
    echo "  │ • ARM A1 (4 OCPU / 24GB) will not be reclaimed          │"
    echo "  │ • Charges apply only when exceeding free tier limits                        │"
    echo "  │ • Credit card required, but no automatic charges                │"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""
    echo "  Recommendation: Upgrade to PAYG to ensure grabbed instances will not be reclaimed."
    echo "  Upgrade method: OCI Console → Billing → Upgrade to Paid"
    echo ""
    read -rp "  Continue grabbing resources anyway? (y/N) " answer
    if [[ ! "${answer,,}" =~ ^y ]]; then
        echo "  Cancelled."
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

# === Prepare Reserved Public IP ===
echo "▸ Checking Reserved Public IP..."
RESERVED_IP_JSON=$(oci network public-ip list \
    --compartment-id "$COMPARTMENT_ID" \
    --scope REGION --lifetime RESERVED --all \
    --output json 2>/dev/null) || RESERVED_IP_JSON=""

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
        --public-ip-id "$RESERVED_IP_ID" --output json 2>/dev/null) || true
    RESERVED_IP_ADDR=$(echo "$RESERVED_IP_GET" | $PYTHON -c "
import sys,json
try: print(json.load(sys.stdin)['data']['ip-address'])
except: print('')
" 2>/dev/null)
    echo "  ✅ Found existing Reserved IP: $RESERVED_IP_ADDR"
else
    echo "  No existing Reserved IP, creating..."
    RESERVED_RESULT=$(oci network public-ip create \
        --compartment-id "$COMPARTMENT_ID" \
        --lifetime RESERVED \
        --display-name "${DISPLAY_NAME}-ip" \
        --output json 2>/dev/null) || true
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
        echo "  ❌ Failed to create Reserved IP"
        echo "  $RESERVED_RESULT"
        exit 1
    fi
    echo "  ✅ Created Reserved IP: $RESERVED_IP_ADDR"
fi

# shape-config passed via file:// to avoid JSON quote issues
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
log "Starting to grab ARM A1.Flex ($OCPUS OCPU / ${MEMORY}GB RAM)"
log "Name: $DISPLAY_NAME"
log "Region: $REGION"
log "Retry every ${RETRY_INTERVAL} seconds"
log "=========================================="

attempt=0
while true; do
    attempt=$((attempt + 1))
    log "--- Attempt $attempt ---"

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
        --output json 2>&1) || true

    # Success: Response contains lifecycle-state
    if echo "$result" | grep -q '"lifecycle-state"'; then
        log "✅ $DISPLAY_NAME created successfully!"

        INSTANCE_ID=$(echo "$result" | $PYTHON -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',d)['id'])")
        log "Instance OCID: $INSTANCE_ID"

        # === Bind Reserved Public IP ===
        log "▸ Waiting for instance to enter RUNNING state..."
        for w in $(seq 1 30); do
            STATE=$(oci compute instance get --instance-id "$INSTANCE_ID" \
                --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "")
            [ "$STATE" = "RUNNING" ] && break
            log "  Status: ${STATE:-UNKNOWN}, waiting 10 seconds... ($w/30)"
            sleep 10
        done

        log "▸ Getting VNIC information..."
        VNIC_ID=""
        for w in $(seq 1 10); do
            VNIC_ID=$(oci compute instance list-vnics \
                --instance-id "$INSTANCE_ID" --output json 2>/dev/null \
                | $PYTHON -c "import sys,json; d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')" 2>/dev/null)
            [ -n "$VNIC_ID" ] && break
            log "  VNIC not ready yet, waiting 5 seconds... ($w/10)"
            sleep 5
        done

        if [ -z "$VNIC_ID" ]; then
            log "❌ Unable to get VNIC, please manually bind Reserved IP"
            break
        fi

        PRIVATE_IP_ID=$(oci network private-ip list \
            --vnic-id "$VNIC_ID" --output json 2>/dev/null \
            | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])")

        log "▸ Binding Reserved IP: $RESERVED_IP_ADDR"
        oci network public-ip update \
            --public-ip-id "$RESERVED_IP_ID" \
            --private-ip-id "$PRIVATE_IP_ID" \
            --output json >/dev/null 2>&1

        PUBLIC_IP="$RESERVED_IP_ADDR"
        log "Fixed Public IP: $PUBLIC_IP"

        send_notify \
            "OCI A1 grabbed successfully!" \
            "$DISPLAY_NAME ($OCPUS OCPU / ${MEMORY}GB) created successfully!IP: ${PUBLIC_IP} Attempt ${attempt}" \
            "urgent"
        log "📨 Notification sent"
        break
    fi

    # Parse error
    parsed=$(echo "$result" | parse_error)
    error_code=$(echo "$parsed" | cut -d'|' -f1)
    error_msg=$(echo "$parsed" | cut -d'|' -f2)

    if [ -z "$error_msg" ]; then
        error_msg=$(echo "$result" | tail -3)
    fi

    if echo "$error_msg" | grep -qi "capacity"; then
        log "⚠️  [Out of capacity] $error_msg"
        log "Waiting ${RETRY_INTERVAL} seconds before retry..."
        sleep "$RETRY_INTERVAL"
    elif [ "$error_code" = "TooManyRequests" ]; then
        wait_time=$((RETRY_INTERVAL * 2))
        log "🚫 [Rate limited] Requests too frequent! Waiting ${wait_time} seconds..."
        sleep "$wait_time"
    elif echo "$error_msg" | grep -qi "timed\|timeout\|connection"; then
        log "⏳ [Timeout] Connection timed out，Waiting ${RETRY_INTERVAL} seconds before retry..."
        sleep "$RETRY_INTERVAL"
    else
        log "❌ Failed: ${error_code:+$error_code: }$error_msg"
        log "Waiting ${RETRY_INTERVAL} seconds before retry..."
        sleep "$RETRY_INTERVAL"
    fi
done

log "=========================================="
log "Complete!"
log "=========================================="
