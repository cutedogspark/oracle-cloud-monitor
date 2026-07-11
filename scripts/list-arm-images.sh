#!/bin/bash
# List all available ARM (Aarch64) platform Images for specified Region
#
# Usage:
#   ./scripts/list-arm-images.sh              # List all OS
#   ./scripts/list-arm-images.sh ubuntu        # Filter Ubuntu
#   ./scripts/list-arm-images.sh oracle         # Filter Oracle Linux

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

SHAPE="VM.Standard.A1.Flex"
FILTER="${1:-}"

echo "Region: $REGION"
echo "Shape:  $SHAPE"
[ -n "$FILTER" ] && echo "Filter:  $FILTER"
echo ""

# Get all compatible images
