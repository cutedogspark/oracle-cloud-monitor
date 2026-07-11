#!/bin/bash
# OCI Boot Volume Auto Backup — Creates Boot Volume Backup and rotates old backups
# Always Free provides 5 free backup slots, keeps the latest 5
#
# Usage:
#   ./scripts/backup-instance.sh              # Interactive mode: select instance, confirm backup
#   ./scripts/backup-instance.sh --auto       # Auto mode: backup first running instance (for cron)
#   ./scripts/backup-instance.sh <instance-id> # Directly specify instance for backup (no confirmation)
#
# Suggested cron: every 3 hours
#   0 */3 * * * ~/oci-monitor/scripts/backup-instance.sh --auto

export SUPPRESS_LABEL_WARNING=True

# Cross-platform Python detection
if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1 && python --version 2>&1 | grep -q "Python 3"; then
    PYTHON=python
else
    echo "❌ Python 3 not found"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ .env not found"
    exit 1
fi
source "$ENV_FILE"
source "${SCRIPT_DIR}/notify.sh"

LOG_FILE="${PROJECT_DIR}/logs/backup-instance.log"
mkdir -p "$(dirname "$LOG_FILE")"

# Always Free limit: 5 backups
BACKUP_KEEP=${BACKUP_KEEP:-5}
BACKUP_FREE_LIMIT=5
BACKUP_TYPE=${BACKUP_TYPE:-INCREMENTAL}
BACKUP_PREFIX="auto-backup"
COMPARTMENT="${COMPARTMENT_ID:-$TENANCY_ID}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# === Parse arguments ===
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
        echo "Usage:"
        echo "  $0              # Interactive mode"
        echo "  $0 --auto       # Auto mode (for cron)"
        echo "  $0 <instance-id> # Specify instance"
        exit 1
        ;;
esac

# === Check if any backup is in progress ===
# Query all backups with CREATING state (including those from other machines or scheduled tasks)
check_backup_in_progress() {
    log "Checking if any backup is in progress..."

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

        log "$creating_count backups in progress, skipping this backup:"
        log "$detail"

        if [ "$AUTO_MODE" = false ]; then
            echo ""
            echo "  ⚠️  $creating_count backups in progress:"
            echo "$detail"
            echo ""
            echo "  Please wait for completion before running backup."
        fi
        exit 0
    fi

    log "No backups in progress, continuing"
}

# === Check backup count and delete oldest if at limit ===
check_and_free_backup_slot() {
    log "Checking backup count (free limit: $BACKUP_FREE_LIMIT)..."

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

    log "Current backup count: $available_count / $BACKUP_FREE_LIMIT"

    if [ "$available_count" -ge "$BACKUP_FREE_LIMIT" ] 2>/dev/null; then
        # Get oldest backup
        local oldest_id oldest_name
        oldest_id=$(echo "$available_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
        oldest_name=$(echo "$available_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data'][0]['display-name'])" 2>/dev/null)

        log "Free limit reached, deleting oldest backup: $oldest_name"

        if [ "$AUTO_MODE" = false ]; then
            echo ""
            echo "  ⚠️  Backup count reached free limit ($available_count/$BACKUP_FREE_LIMIT)"
            echo "  Will delete oldest backup: $oldest_name"
            echo ""
            read -rp "  Confirm deletion? (Y/n): " del_confirm
            case "$del_confirm" in
                [nN]) echo "  Cancelled."; exit 0 ;;
            esac
        fi

        oci bv boot-volume-backup delete \
            --boot-volume-backup-id "$oldest_id" \
            --force 2>/dev/null

        if [ $? -eq 0 ]; then
            log "Deleted: $oldest_name"
            # Wait for deletion to take effect
            sleep 5
        else
            log "ERROR: Failed to delete oldest backup: $oldest_name"
            send_notify "OCI Backup Failed" "Cannot delete oldest backup to free slot: $oldest_name" "high"
            exit 1
        fi
    fi
}

# === Get instance list ===
get_instances_json() {
    oci compute instance list \
        --compartment-id "$COMPARTMENT" \
        --lifecycle-state RUNNING \
        --all \
        --output json 2>/dev/null
}

# === Interactive mode: select instance ===
interactive_select() {
    echo ""
    echo "══════════════════════════════════════════"
    echo "  OCI Boot Volume Backup Tool"
    echo "══════════════════════════════════════════"
    echo ""

    local instances_json
    instances_json=$(get_instances_json)

    local count
    count=$(echo "$instances_json" | $PYTHON -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null)

    if [ "$count" = "0" ] || [ -z "$count" ]; then
        echo "  No running instances."
        exit 0
    fi

    # List instances
    echo "$instances_json" | $PYTHON -c "
import sys, json

data = json.load(sys.stdin).get('data', [])
print(f'  Running instances (total: {len(data)}):')
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

    # Select instance
    if [ "$count" = "1" ]; then
        INSTANCE_ID=$(echo "$instances_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
        local name
        name=$(echo "$instances_json" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data'][0]['display-name'])" 2>/dev/null)
        echo "  Only one instance, auto-selecting: $name"
    else
        read -rp "  Select instance to backup [1-${count}]: " selection
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
            echo "  ❌ Invalid selection"
            exit 1
        fi
    fi

    # Query existing backups
    echo ""
    echo "  ── Existing Backups ──"
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
    print('  (No backups currently)')
else:
    for b in data:
        name = b.get('display-name', 'N/A')
        size = b.get('size-in-gbs', 'N/A')
        btype = b.get('type', 'N/A')
        created = b.get('time-created', 'N/A')[:19].replace('T', ' ')
        print(f'  • {name} ({size} GB, {btype}, {created})')
    print(f'  Total: {len(data)}/{$BACKUP_FREE_LIMIT} (Always Free limit: $BACKUP_FREE_LIMIT)')
" 2>/dev/null

    # Select backup type
    echo ""
    echo "  Backup Type:"
    echo "    [1] INCREMENTAL — Incremental backup (faster, smaller)"
    echo "    [2] FULL        — Full backup (slower, larger, more reliable restore)"
    echo ""
    read -rp "  Select backup type [1/2] (default 1): " type_choice
    case "$type_choice" in
        2) BACKUP_TYPE="FULL" ;;
        *) BACKUP_TYPE="INCREMENTAL" ;;
    esac

    # Confirmation
    local inst_name
    inst_name=$(oci compute instance get \
        --instance-id "$INSTANCE_ID" \
        --query 'data."display-name"' \
        --raw-output 2>/dev/null)

    echo ""
    echo "  ── Confirmation ──"
    echo "  Instance:   $inst_name"
    echo "  Backup Type: $BACKUP_TYPE"
    echo "  Retention:   $BACKUP_KEEP (free limit: $BACKUP_FREE_LIMIT)"
    echo ""
    read -rp "  Start backup? (Y/n): " confirm
    case "$confirm" in
        [nN]) echo "  Cancelled."; exit 0 ;;
    esac
}

# === Auto mode: get first instance ===
auto_select() {
    if [ -z "$INSTANCE_ID" ]; then
        INSTANCE_ID=$(oci compute instance list \
            --compartment-id "$COMPARTMENT" \
            --lifecycle-state RUNNING \
            --all \
            --query 'data[0].id' \
            --raw-output 2>/dev/null)

        if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
            log "ERROR: No running instances found"
            send_notify "OCI Backup Failed" "No running instance found" "high"
            exit 1
        fi
    fi
}

# === Execute backup ===
do_backup() {
    INSTANCE_NAME=$(oci compute instance get \
        --instance-id "$INSTANCE_ID" \
        --query 'data."display-name"' \
        --raw-output 2>/dev/null)

    log "Starting backup: $INSTANCE_NAME ($INSTANCE_ID)"

    # Get Boot Volume ID
    BOOT_VOLUME_ID=$(oci compute boot-volume-attachment list \
        --compartment-id "$COMPARTMENT" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --instance-id "$INSTANCE_ID" \
        --query 'data[?("lifecycle-state"=='"'"'ATTACHED'"'"')].{id:"boot-volume-id"}|[0].id' \
        --raw-output 2>/dev/null)

    if [ -z "$BOOT_VOLUME_ID" ] || [ "$BOOT_VOLUME_ID" = "null" ]; then
        log "ERROR: Boot Volume not found"
        send_notify "OCI Backup Failed" "Cannot find boot volume for $INSTANCE_NAME" "high"
        exit 1
    fi

    log "Boot Volume: $BOOT_VOLUME_ID"

    # Create backup
    BACKUP_NAME="${BACKUP_PREFIX}-${INSTANCE_NAME}-$(date '+%Y%m%d-%H%M')"
    log "Creating backup: $BACKUP_NAME (type: $BACKUP_TYPE)"

    backup_result=$(oci bv boot-volume-backup create \
        --boot-volume-id "$BOOT_VOLUME_ID" \
        --display-name "$BACKUP_NAME" \
        --type "$BACKUP_TYPE" \
        --output json 2>&1)

    if [ $? -ne 0 ]; then
        log "ERROR: Backup creation failed: $backup_result"
        send_notify "OCI Backup Failed" "Failed to create backup for $INSTANCE_NAME
Error: $backup_result" "urgent"
        exit 1
    fi

    BACKUP_ID=$(echo "$backup_result" | $PYTHON -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null)
    log "Backup created: $BACKUP_ID"

    # Wait for backup completion (max 30 minutes)
    log "Waiting for backup to complete..."
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
                log "Backup completed: $BACKUP_NAME"
                break
                ;;
            FAULTY|TERMINATED)
                log "ERROR: Backup failed, state: $state"
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
        log "WARNING: Backup timeout (still in progress: $BACKUP_ID)"
    fi

    # Backup size
    BACKUP_SIZE=$(oci bv boot-volume-backup get \
        --boot-volume-backup-id "$BACKUP_ID" \
        --query 'data."size-in-gbs"' \
        --raw-output 2>/dev/null)
}

# === Send notification and result ===
send_result() {
    # Query final backup count
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
        echo "  ✅ Backup completed!"
        echo "══════════════════════════════════════════"
        echo ""
        echo "  Instance:    $INSTANCE_NAME"
        echo "  Backup Name: $BACKUP_NAME"
        echo "  Backup Size: ${BACKUP_SIZE:-N/A} GB"
        echo "  Backup Type: $BACKUP_TYPE"
        echo "  Current Backups: ${final_count:-N/A} / $BACKUP_FREE_LIMIT"
        echo ""
    fi

    log "Backup process completed"
}

# === Main ===
if [ "$AUTO_MODE" = true ]; then
    auto_select
else
    interactive_select
fi

# Pre-backup check: any backup in progress
check_backup_in_progress

# Pre-backup check: if at free limit, delete oldest first
check_and_free_backup_slot

# Execute backup
do_backup
send_result
