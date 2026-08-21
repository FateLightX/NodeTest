#!/usr/bin/env bash
# 动态查找包含指定文件名的 Gist 并更新；不存在则自动创建（Sub-Store 方式）。
# 用法: ./scripts/update-nodes-gist.sh <本地文件> [Gist内文件名，默认 Nodes]
set -euo pipefail

INPUT="${1:?用法: $0 <本地文件> [Gist文件名]}"
GIST_NAME="${2:-Nodes}"
[ -f "$INPUT" ] || { echo "错误: 文件不存在: $INPUT" >&2; exit 1; }

# 1. 动态查找包含该文件名的 Gist
GIST_ID="$(gh api --paginate gists \
  -q ".[] | select(.files[\"$GIST_NAME\"] != null) | .id" | head -n1 || true)"

if [ -n "$GIST_ID" ]; then
  # 2a. 已存在 -> PATCH 覆盖同一个文件，地址不变
  jq -n --arg f "$GIST_NAME" --rawfile c "$INPUT" \
    '{files:{($f):{content:$c}}}' |
  gh api -X PATCH "gists/$GIST_ID" --input - -q .id > /dev/null
  echo "已更新 Gist: $GIST_ID"
else
  # 2b. 不存在 -> 自动创建 secret Gist（Sub-Store Artifacts 方式）
  GIST_ID="$(jq -n --arg f "$GIST_NAME" --rawfile c "$INPUT" \
    '{description:"Nodes Artifacts Repository",public:false,files:{($f):{content:$c}}}' |
  gh api gists --input - -q .id)"
  echo "已创建 Gist: $GIST_ID"
fi

# 3. 输出固定 raw 地址（用户名动态取，不写死）
OWNER="$(gh api "gists/$GIST_ID" -q .owner.login)"
echo "固定地址: https://gist.githubusercontent.com/$OWNER/$GIST_ID/raw/$GIST_NAME"
