#!/bin/bash
# 列出指定 Region 所有可用的 ARM (Aarch64) 平台 Image
#
# 用法:
#   ./scripts/list-arm-images.sh              # 列出所有 OS
#   ./scripts/list-arm-images.sh ubuntu        # 篩選 Ubuntu
#   ./scripts/list-arm-images.sh oracle         # 篩選 Oracle Linux

set -euo pipefail
export SUPPRESS_LABEL_WARNING=True

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ 找不到 .env"
    exit 1
fi
source "$ENV_FILE"

SHAPE="VM.Standard.A1.Flex"
FILTER="${1:-}"

echo "Region: $REGION"
echo "Shape:  $SHAPE"
[ -n "$FILTER" ] && echo "篩選:  $FILTER"
echo ""

# 取得所有相容的 image
QUERY='data[*].{"display-name":"display-name", id:id, os:"operating-system", ver:"operating-system-version"}'

RESULT=$(oci compute image list \
    --compartment-id "$COMPARTMENT_ID" \
    --shape "$SHAPE" \
    --sort-by TIMECREATED \
    --all \
    --output json \
    --query "$QUERY" 2>/dev/null)

if [ -z "$RESULT" ] || [ "$RESULT" = "[]" ]; then
    echo "❌ 查無 image"
    exit 1
fi

# 篩選 + 格式化輸出
if command -v python3 >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1 && python --version 2>&1 | grep -q "Python 3"; then
    PYTHON=python
else
    echo "$RESULT"
    exit 0
fi

echo "$RESULT" | $PYTHON -c "
import sys, json

data = json.load(sys.stdin)
filt = '${FILTER}'.lower()

if filt:
    data = [i for i in data if filt in i['os'].lower() or filt in i['display-name'].lower()]

if not data:
    print('查無符合條件的 image')
    sys.exit(0)

# 依 OS 分組
groups = {}
for img in data:
    key = img['os']
    groups.setdefault(key, []).append(img)

for os_name in sorted(groups):
    imgs = groups[os_name]
    print(f'── {os_name} ({len(imgs)}) ──')
    for img in imgs:
        print(f\"  {img['ver']:>10}  {img['display-name']}\")
        print(f\"             {img['id']}\")
    print()
"
