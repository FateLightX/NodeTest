# NodeTest

GitHub Action 定时用官方 Mihomo 内核实测订阅节点延迟，把延迟合格的节点以 Mihomo（Clash YAML）格式推送到 Gist。支持 Clash YAML 和 Base64 两种订阅格式。

## 工作原理

1. 从订阅 URL 下载节点（自动识别 Base64 编码并解码）。
2. 下载官方 Mihomo 内核（linux/amd64），生成临时配置启动，包含 `unified-delay: true`、IP 形式 DoH、`redir-host`。
3. 通过官方 `GET /proxies/{name}/delay` API 逐节点测速，排除 Selector/URLTest/Direct/Reject 等内置分组。
4. 把延迟不高于保留阈值（默认 400ms）的节点按原始顺序、原始字段输出为 `proxies:` 列表，推送到 Gist（每次覆盖更新同一个 Gist，或首次自动创建）；本轮没有合格节点时跳过更新，保留 Gist 上一次内容。

测速策略与主程序保持一致：

- 普通节点 `attempts` 仅接受 1 或 3；3 次需要全部成功并取中位数。
- Hysteria2 最多测试 3 次、至少 2 次成功才接受，取有效结果的中位数；单次超时最低 8000ms。
- 支持并发测试（默认 10），单节点超时默认 5000ms，保留阈值默认 400ms。

## 使用方法

把本仓库部署到 GitHub（或复制 `scripts/` 和 `.github/workflows/` 到任意仓库），然后配置以下 Secrets：

| Secret | 必需 | 说明 |
| --- | --- | --- |
| `SUB_URL` | 是 | 订阅 URL（Clash YAML 或 Base64） |
| `GIST_TOKEN` | 是 | 带 `gist` scope 的经典 Personal Access Token |
| `GIST_ID` | 否 | 已有 Gist ID；留空则首次运行时自动创建 |

配置完成后：

1. 手动触发一次验证：Actions → **NodeTest** → **Run workflow**（可调整测速 URL、超时、并发、测试次数；订阅和 Gist ID 始终从 Secrets 读取；勾选 `dry_run` 只生成报告不上传）。
2. 确认报告正常后，工作流会按默认计划每天 01:00 UTC 自动运行（`0 1 * * *`）。

## Actions 历史清理

工作流还包含一个独立的清理任务，每 3 天（UTC `0 3 */3 * *`）自动删除本仓库旧的 Actions 运行记录：

- 保留最近 10 次运行，删除更早的记录（当前正在运行的记录不会被删）。
- 清理只在该定时触发时执行，手动触发或每 6 小时测速时不会误删。
- 删除动作使用 `gh api` 的 `DELETE /repos/{owner}/{repo}/actions/runs/{id}`，job 级权限为 `actions: write`。
- 想全删（不留最近记录）可把 `KEEP` 改为 `0`；想保留更多改为 `20` 等。

## Gist 内容

Gist 只包含一个文件：

- `Nodes`：Sub-Store 风格订阅（`proxies:` 下每个节点一行 JSON），列出测速合格（延迟 ≤ 阈值）的节点，保留原始字段（Hysteria2 的 `ports`/`mport`/`hop-interval`/`udp-mtu`/`sni` 等不重写）和原始顺序。

拿到 Gist 的 raw 地址后，可直接作为 Clash/Mihomo 订阅链接使用。

## 手动运行脚本

在任意 Linux/macOS 机器（需 `curl`、`jq`、`gzip`）上：

```sh
SUB_URL="https://..." GIST_TOKEN="ghp_..." bash scripts/node-latency-gist.sh
```

参数说明：

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SUB_URL` | — | 订阅 URL（必填） |
| `GIST_TOKEN` | — | 带 `gist` scope 的 PAT（dry-run 可省） |
| `GIST_ID` | — | 已有 Gist ID，留空自动创建 |
| `TEST_URL` | `https://www.gstatic.com/generate_204` | 测速 URL |
| `TIMEOUT_MS` | `5000` | 单节点超时毫秒 |
| `CONCURRENCY` | `10` | 并发测试数 |
| `ATTEMPTS` | `1` | 普通节点测试次数（1 或 3） |
| `THRESHOLD_MS` | `400` | 保留阈值：只输出延迟不高于该值的节点 |
| `MIHOMO_VERSION` | `latest` | Mihomo 内核版本（如 `v1.19.30`） |
| `MIHOMO_BIN` | — | 本地 mihomo 二进制路径（跳过下载，便于测试） |
| `DRY_RUN` | `0` | `1` 时仅生成报告到 `.gist-preview/`，不上传 |

## 注意

- 测到的延迟反映 GitHub Actions 运行器所在网络的出口实测值，不代表本机或目标网络表现，适合做趋势监控而非精准排序。
- 全部节点都失败或超阈值时，跳过 Gist 更新，避免把上一次的好订阅覆盖成空列表。
- Gist 为私有（`public: false`），只有持有链接或已登录的账号可见；Action 日志不输出订阅地址、Gist ID、Gist URL 或 mihomo 原始日志。
- `GIST_TOKEN` 只应授予 `gist` scope，不要使用有完整仓库权限的令牌。
