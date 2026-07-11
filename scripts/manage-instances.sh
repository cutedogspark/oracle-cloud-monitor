#!/bin/bash
# Interactive instance management (view/terminate)
#
# Usage: ./scripts/manage-instances.sh

set -euo pipefail
export SUPPRESS_LABEL_WARNING=True

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ .env not found"
    exit 1
fi
source "$ENV_FILE"

echo "═══════════════════════════════════════════"
echo "  OCI Instance Management"
echo "═══════════════════════════════════════════"
echo ""
echo "Fetching instances..."
