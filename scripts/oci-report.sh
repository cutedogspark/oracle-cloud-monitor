#!/bin/bash
# Resource report - view instances, cost, storage, network, etc.
#
# Usage:
#   ./scripts/oci-report.sh           # All reports
#   ./scripts/oci-report.sh instances # Instances only
#   ./scripts/oci-report.sh cost      # Cost only
#   etc.

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

REPORT_TYPE="${1:-all}"

echo "═══════════════════════════════════════════"
echo "  OCI Resource Report"
echo "═══════════════════════════════════════════"
echo ""
