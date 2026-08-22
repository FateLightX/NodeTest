#!/usr/bin/env bash
# 从订阅下载节点，用官方 Mihomo delay API 实测延迟，并把报告推送到 Gist。
# 策略：unified-delay: true、attempts 仅 1 或 3、Hysteria2 最多 3 次且至少 2 次成功取中位数。
set -euo pipefail

SUB_URL="${SUB_URL:-}"
GIST_ID="${GIST_ID:-}"
GIST_TOKEN="${GIST_TOKEN:-}"
TEST_URL="${TEST_URL:-https://www.gstatic.com/generate_204}"
TIMEOUT_MS="${TIMEOUT_MS:-5000}"
CONCURRENCY="${CONCURRENCY:-10}"
ATTEMPTS="${ATTEMPTS:-1}"
THRESHOLD_MS="${THRESHOLD_MS:-400}"   # 只保留延迟不高于该值的节点
MIHOMO_VERSION="${MIHOMO_VERSION:-latest}"
MIHOMO_BIN="${MIHOMO_BIN:-}"          # 测试时可指向本地 mihomo 兼容二进制/桩
API_SECRET="${API_SECRET:-mihomosift-gist-report}"
API_PORT="${API_PORT:-19090}"
LOG_LEVEL="${MIHOMO_LOG_LEVEL:-warning}"
DRY_RUN="${DRY_RUN:-0}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"

if [[ "$ATTEMPTS" != "1" && "$ATTEMPTS" != "3" ]]; then
  echo "ATTEMPTS 仅允许 1 或 3，当前: $ATTEMPTS" >&2
  exit 2
fi
if [[ -z "$SUB_URL" ]]; then
  echo "缺少 SUB_URL（工作流输入或 Secret SUB_URL）" >&2
  exit 2
fi
if [[ "$DRY_RUN" != "1" && -z "$GIST_TOKEN" ]]; then
  echo "缺少 GIST_TOKEN（需要带 gist scope 的经典 PAT）" >&2
  exit 2
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/node-latency-gist.XXXXXX")"
MIHOMO_PID=""
cleanup() {
  if [[ -n "$MIHOMO_PID" ]]; then kill "$MIHOMO_PID" 2>/dev/null || true; fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> 下载订阅: $SUB_URL"
curl -fsSL --retry 3 -o "$WORK_DIR/sub" "$SUB_URL"
# Base64 编码的订阅（如 Sub-Store Base64 输出）先解码。
# 注意：不能直接在管道里 grep -q（pipefail 下 tr 被 SIGPIPE 会令条件为假），
# 先截取前 4096 字节到变量再判断。
probe="$(tr -d '\n\r ' < "$WORK_DIR/sub" | head -c 4096 2>/dev/null || true)"
if LC_ALL=C grep -qE '^[A-Za-z0-9+/]+={0,2}$' <<<"$probe"; then
  echo "==> 检测到 Base64 订阅，解码"
  tr -d '\n\r ' < "$WORK_DIR/sub" | base64 -d > "$WORK_DIR/sub.decoded" && mv "$WORK_DIR/sub.decoded" "$WORK_DIR/sub"
fi

if [[ -n "$MIHOMO_BIN" ]]; then
  bin="$MIHOMO_BIN"
  echo "==> 使用本地 mihomo: $bin"
else
  echo "==> 下载 mihomo ($MIHOMO_VERSION)"
  if [[ "$MIHOMO_VERSION" == "latest" ]]; then
    release_json="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest)"
  else
    release_json="$(curl -fsSL "https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/${MIHOMO_VERSION}")"
  fi
  tag="$(jq -r '.tag_name' <<<"$release_json")"
  asset="$(jq -r --arg tag "$tag" '[.assets[].name
    | select(startswith("mihomo-linux-amd64-")
      and endswith(".gz")
      and (contains("compatible") | not)
      and (contains("-go") | not)
      and contains($tag + ".gz"))]
    | .[0] // empty' <<<"$release_json")"
  if [[ -z "$asset" ]]; then
    echo "未找到 mihomo linux-amd64 压缩包资产 (tag=$tag)" >&2
    exit 1
  fi
  curl -fsSL --retry 3 -o "$WORK_DIR/mihomo.gz" "https://github.com/MetaCubeX/mihomo/releases/download/${tag}/${asset}"
  gzip -d "$WORK_DIR/mihomo.gz"
  chmod +x "$WORK_DIR/mihomo"
  bin="$WORK_DIR/mihomo"
fi

# 解析订阅，把节点内联写入 mihomo 配置（与主程序 buildMihomoConfig 同思路，
# 避免 file provider 在新版 mihomo 上不加载的问题）
export SUB_PATH="$WORK_DIR/sub" CONFIG_PATH="$WORK_DIR/config.yaml" API_PORT API_SECRET LOG_LEVEL
python3 - <<'PY'
import os
import sys

try:
    import yaml
except ImportError:
    sys.exit("缺少 PyYAML，请先运行: pip3 import pyyaml")

class QuotedStr(str):
    pass

def _quoted_str_representer(dumper, data):
    return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='"')

yaml.SafeDumper.add_representer(QuotedStr, _quoted_str_representer)
yaml.add_representer(QuotedStr, _quoted_str_representer)

def _fix_short_ids(proxies):
    for p in proxies:
        ro = p.get("reality-opts")
        if isinstance(ro, dict) and "short-id" in ro:
            sid = ro["short-id"]
            if sid is not None and not isinstance(sid, QuotedStr):
                ro["short-id"] = QuotedStr(str(sid))

sub_path = os.environ["SUB_PATH"]
config_path = os.environ["CONFIG_PATH"]
api_port = os.environ["API_PORT"]
api_secret = os.environ["API_SECRET"]
log_level = os.environ["LOG_LEVEL"]

with open(sub_path) as f:
    sub = yaml.safe_load(f)
if not isinstance(sub, dict) or not isinstance(sub.get("proxies"), list) or not sub["proxies"]:
    sys.exit("订阅不是 Clash/Mihomo YAML 格式（缺少 proxies 列表），请检查 SUB_URL")

# 过滤掉 mihomo 无法解析的坏节点，避免单个节点导致整个配置加载失败
import re
def _valid_proxy(p):
    if not isinstance(p, dict):
        return False
    # REALITY short-id 必须是空串或 0-16 位十六进制
    reality = p.get("reality-opts") or {}
    sid = reality.get("short-id", "")
    if not isinstance(sid, str) or (sid != "" and len(sid) > 16):
        return False
    if sid and not re.fullmatch(r"[0-9a-fA-F]*", sid):
        return False
    return True

_total = len(sub["proxies"])
sub["proxies"] = [p for p in sub["proxies"] if _valid_proxy(p)]
_skipped = _total - len(sub["proxies"])
if _skipped:
    print(f"==> 跳过 {_skipped} 个无效节点（REALITY short ID 格式错误）")

config = {
    "mixed-port": 7890,
    "allow-lan": False,
    "mode": "rule",
    "log-level": log_level,
    "ipv6": False,
    "unified-delay": True,
    "tcp-concurrent": True,
    "external-controller": f"127.0.0.1:{api_port}",
    "secret": api_secret,
    "dns": {
        "enable": True,
        "listen": "127.0.0.1:1053",
        "enhanced-mode": "redir-host",
        "nameserver": ["https://8.8.8.8/dns-query", "https://1.1.1.1/dns-query"],
        "proxy-server-nameserver": ["https://8.8.8.8/dns-query", "https://1.1.1.1/dns-query"],
        "fake-ip-filter": ["*.lan", "*.local"],
    },
    "proxies": sub["proxies"],
    "rules": ["MATCH,DIRECT"],
}
_fix_short_ids(sub["proxies"])
with open(config_path, "w") as f:
    yaml.safe_dump(config, f, sort_keys=False, allow_unicode=True, default_flow_style=False)
print(f"==> 订阅节点 {len(sub['proxies'])} 个已写入 mihomo 配置")
PY

echo "==> 启动 mihomo"
(cd "$WORK_DIR" && MIHOMO_LOG_LEVEL="$LOG_LEVEL" "$bin" -d "$WORK_DIR" -f "$WORK_DIR/config.yaml" > mihomo.log 2>&1) &
MIHOMO_PID=$!

ready=0
for _ in $(seq 1 60); do
  if curl -fsS -m 2 -H "Authorization: Bearer ${API_SECRET}" "http://127.0.0.1:${API_PORT}/proxies" -o "$WORK_DIR/proxies.json" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != "1" ]]; then
  echo "mihomo API 未在 60s 内就绪" >&2
  tail -n 50 "$WORK_DIR/mihomo.log" >&2 || true
  exit 1
fi

# 只测真实节点，排除分组/内置类型
jq -r '.proxies | to_entries[] |
  select((.value.type // "") as $t | ["Selector","URLTest","Fallback","LoadBalance","Relay","Direct","Reject","RejectDrop","Compatible","Pass","PassRule"] | index($t) | not) |
  [(.key | @base64), .value.type] | @tsv' "$WORK_DIR/proxies.json" | grep -v '^$' > "$WORK_DIR/nodes.tsv"

total_nodes="$(wc -l < "$WORK_DIR/nodes.tsv" | tr -d ' ')"
if [[ "$total_nodes" -eq 0 ]]; then
  echo "订阅中没有可测节点" >&2
  tail -n 30 "$WORK_DIR/mihomo.log" >&2 || true
  exit 1
fi
echo "==> 共 $total_nodes 个节点，并发 ${CONCURRENCY}，超时 ${TIMEOUT_MS}ms，attempts=$ATTEMPTS"

cat > "$WORK_DIR/test_node.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
name_b64="$1"
type="$2"
name="$(printf '%s' "$name_b64" | base64 -d)"
fname="${name_b64//[\/+]/_}"   # base64 可含 / 和 +，替换成 _ 避免被当作路径分隔符
enc="$(jq -rn --arg v "$name" '$v|@uri')"
auth="Authorization: Bearer ${API_SECRET}"
base="http://127.0.0.1:${API_PORT}/proxies/${enc}/delay"

timeout_ms="$TIMEOUT_MS"
if [[ "$type" == "hysteria2" && "$timeout_ms" -lt 8000 ]]; then
  timeout_ms=8000
fi
curl_max=$(( timeout_ms / 1000 + 15 ))

if [[ "$type" == "hysteria2" ]]; then
  total=3
  min_ok=2
else
  total="$ATTEMPTS"
  min_ok="$ATTEMPTS"
fi

median() {
  local arr=("$@")
  local sorted=()
  local line
  while IFS= read -r line; do
    sorted+=("$line")
  done < <(printf '%s\n' "${arr[@]}" | sort -n)
  local n=${#sorted[@]}
  if (( n % 2 == 1 )); then
    echo "${sorted[$((n/2))]}"
  else
    echo "$(( (sorted[$((n/2-1))] + sorted[$((n/2))]) / 2 ))"
  fi
}

success=()
err=""
for _ in $(seq 1 "$total"); do
  resp="$(curl -s -m "$curl_max" -H "$auth" "${base}?url=${TEST_URL}&timeout=${timeout_ms}" || true)"
  d="$(jq -r '.delay // empty' <<<"$resp" 2>/dev/null || true)"
  if [[ -n "$d" ]]; then
    success+=("$d")
  else
    err="$(jq -r '.error // "request failed"' <<<"$resp" 2>/dev/null || echo "request failed")"
  fi
done

if [[ "${#success[@]}" -ge "$min_ok" ]]; then
  d="$(median "${success[@]}")"
  jq -nc --arg name "$name" --arg type "$type" --argjson delay "$d" \
    '{name:$name, type:$type, delay:$delay}'
else
  jq -nc --arg name "$name" --arg type "$type" --arg error "${err:-request failed}" \
    '{name:$name, type:$type, delay:null, error:$error}'
fi > "$RESULT_DIR/${RANDOM}-${$}-${fname:0:10}.json"
INNER
chmod +x "$WORK_DIR/test_node.sh"

mkdir -p "$WORK_DIR/results"
export API_SECRET API_PORT TEST_URL TIMEOUT_MS ATTEMPTS RESULT_DIR="$WORK_DIR/results"
xargs -P "$CONCURRENCY" -n 2 "$WORK_DIR/test_node.sh" < "$WORK_DIR/nodes.tsv"

jq -s 'sort_by((.delay // 1000000000000), .name)' "$WORK_DIR"/results/*.json > "$WORK_DIR/node-latency.json"

# 生成 Mihomo 格式输出：只保留 delay <= THRESHOLD_MS 的节点，保留原始字段与顺序
export SUB_PATH="$WORK_DIR/sub" RESULT_PATH="$WORK_DIR/node-latency.json" OUT_PATH="$WORK_DIR/Nodes" THRESHOLD_MS
python3 - <<'PY'
import json
import os
import sys

try:
    import yaml
except ImportError:
    sys.exit("缺少 PyYAML，请先运行: pip3 install --user pyyaml")

sub_path = os.environ["SUB_PATH"]
result_path = os.environ["RESULT_PATH"]
out_path = os.environ["OUT_PATH"]
threshold = int(os.environ["THRESHOLD_MS"])

with open(sub_path) as f:
    sub = yaml.safe_load(f) or {}
proxies = sub.get("proxies") or []
with open(result_path) as f:
    results = {r["name"]: r for r in json.load(f)}

kept = []
for p in proxies:
    name = p.get("name")
    r = results.get(name)
    if r and r.get("delay") is not None and r["delay"] <= threshold:
        kept.append(p)

# 输出 Sub-Store 风格：proxies: 下每个节点一行 JSON（保留原始字段与顺序）
lines = ["proxies:"]
for p in kept:
    lines.append("  - " + json.dumps(p, ensure_ascii=False, separators=(",", ":")))
with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")

total = len(proxies)
print(f"==> 保留 {len(kept)} / {total} 个节点（阈值 {threshold}ms）")
if not kept:
    print("没有延迟合格的节点，跳过 Gist 更新（保留上一次内容）", file=sys.stderr)
    sys.exit(3)
PY

if [[ "$DRY_RUN" == "1" ]]; then
  mkdir -p "$PWD/.gist-preview"
  cp "$WORK_DIR/Nodes" "$PWD/.gist-preview/Nodes"
  echo "DRY_RUN：Nodes 已生成到 $PWD/.gist-preview/Nodes（未上传）"
  exit 0
fi

payload="$(jq -nc \
  --arg desc "Nodes 节点延迟测试 $(date -u '+%Y-%m-%d %H:%M UTC')" \
  --rawfile nodes "$WORK_DIR/Nodes" \
  '{description:$desc, public:false, files:{"Nodes":{content:$nodes}}}')"

if [[ -z "$GIST_ID" ]]; then
  # Sub-Store 方式：先按文件名搜索已有 Gist，找到就更新
  echo "==> 搜索包含文件 'Nodes' 的已有 Gist"
  found_id="$(curl -fsS \
    -H "Authorization: Bearer ${GIST_TOKEN}" \
    "https://api.github.com/gists?per_page=100" | jq -r '
      [.[] | select(.files["Nodes"] != null) | .id] | .[0] // empty')"
  if [[ -n "$found_id" ]]; then
    echo "==> 找到已有 Gist: $found_id，执行 PATCH 更新"
    resp="$(curl -fsS -X PATCH \
      -H "Authorization: Bearer ${GIST_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$payload" "https://api.github.com/gists/${found_id}")"
    echo "已更新 Gist: $(jq -r '.html_url' <<<"$resp")"
  else
    echo "==> 未找到，创建新 Gist"
    resp="$(curl -fsS -X POST \
      -H "Authorization: Bearer ${GIST_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$payload" https://api.github.com/gists)"
    echo "已创建 Gist: $(jq -r '.html_url' <<<"$resp")"
  fi
else
  echo "==> 更新 Gist: $GIST_ID"
  resp="$(curl -fsS -X PATCH \
    -H "Authorization: Bearer ${GIST_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$payload" "https://api.github.com/gists/${GIST_ID}")"
  echo "已更新 Gist: $(jq -r '.html_url' <<<"$resp")"
fi
