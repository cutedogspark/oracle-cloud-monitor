#!/bin/bash
# One-click deploy monitoring to remote host
#
# Usage: ./scripts/setup-cron.sh user@host

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

REMOTE_HOST="${1:-}"

if [ -z "$REMOTE_HOST" ]; then
    echo "Usage: $0 user@host"
    echo ""
    echo "Deploy OCI monitoring to remote instance."
    echo "This will:"
    echo "  1. Install OCI CLI on remote host"
    echo "  2. Copy configuration files and scripts"
    echo "  3. Setup cron schedule (hourly cost check, 3 daily notifications)"
    exit 1
fi

echo "═══════════════════════════════════════════"
echo "  OCI Monitor Remote Setup"
echo "═══════════════════════════════════════════"
echo ""
echo "Target: $REMOTE_HOST"
echo ""
