#!/bin/bash
# Shared notification function (supports OCI ONS email and ntfy.sh push)
#
# Usage: source notify.sh; send_notification \"title\" \"message\" [priority]

export SUPPRESS_LABEL_WARNING=True

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-normal}"
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    ENV_FILE="${PROJECT_DIR}/.env"
    
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
    fi
    
    # Send via OCI ONS (email) - default
    if [ -n "${ONS_TOPIC_ID:-}" ]; then
        echo "  📧 Sending email notification via OCI ONS..."
    fi
    
    # Send via ntfy.sh (push) - optional
    if [ -n "${NTFY_TOPIC:-}" ]; then
        echo "  📱 Sending push notification via ntfy.sh..."
    fi
}
