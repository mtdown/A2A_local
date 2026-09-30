# codebuddy（CodeBuddy Code / WorkBuddy）

## 1. 基本信息

| 项 | 值 |
|---|---|
| Agent ID | `codebuddy` |
| 产品名 | WorkBuddy（腾讯）桌面版 5.6.2 |
| 底层 CLI | CodeBuddy Code CLI 2.147.0（命令 `codebuddy`，别名 `cbc`） |
| 类型 | coding-agent（具备文件读写、Shell、Git、网络检索能力的通用编码智能体） |
| 目录 | `F:\AtoA\agents\codebuddy\` |
| 角色 | **不绑定任何长期角色**。brain / executor / reviewer / analyzer 由调用方在每次任务开始前指定，本 Agent 只保证"可被稳定调用" |

## 2. 当前安装 / 运行环境

| 项 | 路径 / 值 |
|---|---|
| CLI 入口 | `C:\Program Files\WorkBuddy\resources\app.asar.unpacked\cli\bin\codebuddy`（Node 脚本，无 `.exe`） |
| Node | `C:\Users\origin\.workbuddy\binaries\node\versions\22.22.2-3\node.exe`（系统 node 24.15.0 亦可） |
| 版本证据 | `GET /api/v1/info` → `version: 5.6.2`；`~/.workbuddy/sessions/*.json` → `version: 2.147.0` |
| 网关 | 桌面端每会话自动以 `--serve` 拉起一个 HTTP 网关，端点登记在 `~/.workbuddy/sessions/*.json` 的 `endpoint` 字段 |
| 内置文档 | `codebuddy --help`、网关 `/api/docs`（Swagger UI）、网关 `/api/openapi.json`（117 path / 141 operation，`CodeBuddy Code API (Beta)` v2.147.0） |
| 核实时间 | 2026-09-28，全部结论来自本机实测，非 README 推断 |

## 3. 原生调用方式

```powershell
node "C:\Program Files\WorkBuddy\resources\app.asar.unpacked\cli\bin\codebuddy" [options] [prompt]
```

不带 `-p` 时进入**交互式会话**。常用原生形态：

```powershell
codebuddy                                   # 交互式
codebuddy -p "任务"                          # 非交互：打印结果后退出
codebuddy --serve --port 18789              # 启动 HTTP 网关（Web UI + REST + ACP over SSE）
codebuddy --acp                             # ACP 模式（stdin/stdout，ndJsonStream）
codebuddy --bg --name job1 "任务"            # 后台会话
codebuddy config | mcp | sandbox | plugin | project | doctor | update | install | cleanup | daemon
codebuddy ps | logs | attach | kill | stop | rm | respawn | agents | auto-mode
```

子命令与参数清单以 `codebuddy --help` 为唯一权威来源。

## 4. 非交互调用方式

### 4.1 CLI print 模式（原生支持，本机当前不可用）

```powershell
codebuddy -p --output-format json --permission-mode bypassPermissions --max-turns 40 --no-session-persistence "任务"
```

相关参数：`--output-format text|json|stream-json`、`--input-format text|stream-json`、`--json-schema <schema>`、`--include-partial-messages`、`--tools/--allowedTools/--disallowedTools`、`--model`、`--system-prompt/--system-prompt-file/--append-system-prompt`、`--settings`、`--session-id/-r/-c/--fork-session`、`--add-dir`。

**本机实测**：`-p` 挂住不返回（100s+，stdout/stderr 全空）；历史 stderr 为
`Authentication required. Please use /login command to sign in to your account`。
设置 `ACC_PRODUCT_CONFIG_PATH` 指向桌面端产品配置后仍然挂住（>150s）。
原因：桌面端把凭据通过临时产品配置文件注入子进程，独立启动的 CLI 拿不到。

### 4.2 网关 REST（原生支持，本机可用）

桌面端会话自带的网关无需额外登录，是本机唯一实测可用的通道：

```
GET  /api/v1/health                     探活
GET  /api/v1/info                       版本/cwd/node
GET  /api/v1/sessions/live              当前活会话（sessionId 为空说明 UI 无活跃聊天）
POST /api/v1/runs                       注入任务到活会话      {"text":"…","sender":{"id":"a2a"}}
GET  /api/v1/runs/{runId}               /stream (SSE)  /cancel
GET  /api/v1/sessions/{id}/history      取 requests[].finalReply
POST /api/v1/jobs                       派发全新后台智能体    {"prompt":"…","cwd":"…","permissionMode":"…"}
GET  /api/v1/jobs/{id}/transcript       /stream  /reply  /stop  /respawn
POST /api/v1/acp/connect + GET /api/v1/acp (SSE)              ACP over HTTP
```

鉴权：`Authorization: Bearer <CODEBUDDY_GATEWAY_PASSWORD>`；缺省返回 `AUTH_REQUIRED`。

**实测结论**（2026-09-29 更新）：`runs` 可用，且**不要求会话空闲**——`writerOccupied=true` 时注入的消息照样排队并被回答（当天两次实测均拿到 `finalReply`）；真正的前提只是 `/sessions/live` 返回非空 `sessionId`（桌面端存在活跃聊天）。`jobs` 派发成功但永久停在 `starting…`、transcript 为空（新进程无凭据）。

### 4.3 ACP（Agent Client Protocol）

`--acp`（stdio，默认）/ `--acp-transport streamable-http`；网关侧 `POST /api/v1/acp/connect`。
已在 `--help` 与 OpenAPI 中确认存在，**本机未做端到端实测** → 端到端可用性：`unknown`。

## 5. 工作目录处理

- CLI **没有** `--cwd` 参数；`invoke.ps1` 用两种原生方式保证上下文：
  1. `jobs` 通道在报文里带 `cwd = <Workspace>`（服务端字段，优先）；
  2. `cli` 通道设置 `ProcessStartInfo.WorkingDirectory = <Workspace>`，并在启动前 `Set-Location $Workspace`。
- 提示词中显式声明 Workspace 绝对路径，并要求所有读写相对该目录。
- `F:\AtoA` 是 A2A 通信/控制目录，**不是**业务工作目录；任务未显式要求时不会在其中改业务代码。

## 6. Task 输入方式

- **TaskFile（唯一受支持且已实测）**：UTF-8 文本，`invoke.ps1` 全量读取后嵌入提示词。调用方不需要把长 Prompt 拼进命令行。
- **stdin**：CLI 有 `--input-format stream-json`（配合 `--output-format stream-json`，可 `--replay-user-messages`），但 `invoke.ps1` 未使用 → 经本封装的 stdin 支持：**未实测**。
- 提示词末尾固定要求模型以 `Changed Files / Commands / Tests / Errors / Notes` 四个小节收尾，便于结构化解析。

## 7. 输出方式

- **OutputFile（已实测）**：UTF-8（无 BOM）Markdown，固定字段：

```
Agent / Mode / Status / Summary / Changed Files / Commands / Tests / Errors / Notes
```

  末尾附 `---` 元数据块（started_at、finished_at、task_file、workspace、transport、gateway、run_id、job_id）。
  失败时也一定写 OutputFile，`Status: failed` + `Errors`。
- **结构化输出**：`-Structured` 额外产出同名 `.json`（agent/mode/status/runId/summary/changedFiles/commands/errors/notes）。原生 `--output-format json --json-schema` 的字段名**未实测**（`-p` 从未返回）→ `unknown`。
- 控制台仅打印 `Status: xxx` 与 `OutputFile: xxx`，不回灌正文。

## 8. invoke.ps1 使用方法

```powershell
F:\AtoA\agents\codebuddy\invoke.ps1 `
    -TaskFile    "F:\AtoA\tasks\task-001.md" `
    -OutputFile  "F:\AtoA\tasks\task-001-result.md" `
    -Workspace   "F:\Projects\Demo" `
    -Mode        "execute"
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `-TaskFile` | ✅ | 任务文件路径（UTF-8） |
| `-OutputFile` | ✅ | 结果文件路径，自动建目录 |
| `-Workspace` | ✅ | 允许工作的项目目录 |
| `-Mode` | ⬜ | `execute` / `review` / `analyze`，默认 `execute` |
| `-Transport` | ⬜ | `auto`（默认，runs→jobs）/ `runs` / `jobs` / `cli` |
| `-TimeoutSec` | ⬜ | 等待回复上限，默认 900 |
| `-GatewayUrl` / `-GatewayPassword` | ⬜ | 手工指定网关与 Bearer 口令 |
| `-SelfServe` | ⬜ | 找不到网关时自起一个私有 `--serve`（脚本退出时自动关闭） |
| `-Model` | ⬜ | 指定模型 ID |
| `-Structured` | ⬜ | 额外输出 `.json` |
| `-TraceLog` | ⬜ | 把关键步骤写入跟踪日志，便于排查网关/派发问题 |
| `-IdleWaitSec` / `-JobStartupGraceSec` / `-PollIntervalSec` / `-SessionFreshnessSec` | ⬜ | 轮询与容错阈值 |

退出码：

| Code | 含义 |
|---|---|
| 0 | 成功拿到模型回复并写出 OutputFile |
| 1 | 派发/运行失败（会话忙、jobs 卡启动、CLI 无输出） |
| 2 | 找不到可用网关或鉴权失败 |
| 3 | 超时未拿到回复 |
| 4 | 参数非法（TaskFile 不存在等） |

## 9. execute 模式

- 提示词前缀：`MODE=execute. You MAY create/modify files and MAY run commands inside the workspace...`
- 允许：读写 Workspace 内文件、执行命令与测试、Git 操作。
- `cli` 通道下不附加工具限制；网关通道下由 `permissionMode=bypassPermissions` 派发。

## 10. review 模式

- 前缀：`MODE=review. You MUST NOT modify any file and MUST NOT run side-effecting commands.`
- `cli` 通道追加 `--disallowedTools Edit,Write,MultiEdit,NotebookEdit`。
- 网关通道为**提示词级约束**（无法传递 CLI 参数），因此属于"应当遵守"而非"技术强制"。

## 11. analyze 模式

- 前缀：`MODE=analyze. You MUST NOT modify any file. Read-only investigation only.`
- 与 review 同样处理工具限制；产出聚焦根因/结构/取舍的证据链。

## 12. 文件 / Shell / Git / 网络权限

| 能力 | 状态 | 说明 |
|---|---|---|
| 文件读取 | ✅ | Read / Glob / Grep |
| 文件写入 | ✅ | Write / Edit（review、analyze 模式下被禁用） |
| Shell | ✅ | Bash / PowerShell；经沙箱执行，高风险命令需放行 |
| Git | ✅ | 可用；注意本机 PortableGit 带子目录分支有已知缺陷，写操作建议用 `C:\Program Files\Git\cmd\git` |
| 网络 | ✅ | 通过内置检索/抓取工具可用；出口受本机代理配置影响（GitHub 需 `127.0.0.1:7897`），本封装不额外开关网络 |

## 13. 成功与失败判定

- **成功**：拿到含标记的模型回复 → 解析小节 → 写 OutputFile → `exit 0`。
- **失败**：以下任一情况都写 OutputFile 且返回非 0，绝不伪装成功：
  - 参数非法 → 4
  - 无可用网关 / 鉴权失败 → 2
  - 会话持续忙、`jobs` 超过 `JobStartupGraceSec` 仍无输出、CLI 无输出 → 1
  - 超时未回复 → 3

### 13.1 本机最小调用测试记录（2026-09-28 19:44）

| 用例 | 结果 |
|---|---|
| 参数校验：`-TaskFile` 指向不存在的文件 | ✅ `exit 4`，OutputFile 按规范写出 `Status: failed` |
| 完整链路：TaskFile=`仅回复：A2A interface test passed.` | ⚠️ `exit 1`：TaskFile 读取 ✅、网关发现 ✅（17901）、鉴权 ✅、runs 等待空闲 ❌（无空闲会话）、jobs 派发 ✅（`bc467f33`）→ 35s 内 transcript 仍为空 → 判定 `job_stuck` 并回收任务，OutputFile 按规范写出 |

结论：**封装链路本身已跑通**；唯一没打通的是"拿到模型回复"，卡在本机新起 CLI 进程无凭据（详见第 15 节）。只要存在一个空闲的 WorkBuddy 会话，runs 通道即可返回真实结果。

### 13.2 端到端成功记录（2026-09-29 10:49）

| 用例 | 结果 |
|---|---|
| 前置发现 | 桌面端窗口最小化时 `/sessions/live` 仍返回 `sessionId=null`；重新拉起 WorkBuddy 主窗口后，3426/10941 两个网关出现 live 会话（`writerOccupied=true` 持续不变） |
| 直连试探：`POST /api/v1/runs` → 3426 | ✅ `accepted`，约 8 s 后 `history.requests[]` 出现 `finalReply: "A2A interface test passed."` —— **会话忙（writerOccupied=true）不影响接单**，此前"需空闲"的判断不成立 |
| 完整链路：`invoke.ps1 -Transport runs -GatewayUrl http://127.0.0.1:3426` | ✅ `exit 0`，全程 10.5 s，OutputFile=`a2a-smoke-result-20260929.md`，`Status: success` |

为此对 `invoke.ps1` 做了两处修正：runs 派发不再等待 `writerOccupied=false`（只等 live `sessionId` 出现，超时则报 `no_live_session`）；回复轮询优先用接单时刻的 `sessionId`（`/sessions/live` 可能在等待期间翻转为 null）。

## 14. 常见错误

| 现象 | 原因 | 处理 |
|---|---|---|
| `AUTH_REQUIRED` | 网关需要 Bearer 口令 | `-GatewayPassword` 或 `$env:CODEBUDDY_GATEWAY_PASSWORD`，或 `-SelfServe` |
| 找不到网关 | 没有存活会话 | 开一个 WorkBuddy 会话，或 `-GatewayUrl`，或 `-SelfServe` |
| `no_live_session` | `/sessions/live` 返回 `sessionId=null`（桌面端没有活跃聊天，常见于主窗口最小化/未打开） | 打开或恢复 WorkBuddy 主窗口后重试；脚本默认最多等 `-IdleWaitSec` |
| `job_stuck: starting…` | 新起的 CLI 进程无凭据 | 改用 `runs` 通道，或先解决 headless 登录 |
| `cli_no_result` / 长时间无输出 | headless 登录缺失 | 同上；或 `-Transport runs` |
| `Authentication required. Please use /login` | 独立 CLI 未登录 | 先登录或复用桌面端会话网关 |

## 15. 已知限制

1. `-p` / `--bg` / `/jobs` 等"新起进程"的通道在本机均不可用（凭据未注入子进程），实测表现为挂住或卡在 `starting…`。
2. `runs` 依赖桌面端存在活跃聊天（live `sessionId` 非空）；会话忙闲均可接单。桌面端主窗口最小化可能导致 live 会话消失，此时需先恢复窗口。
3. 后台进程无法跨调用存活（沙箱限制），`-SelfServe` 启动的网关只在同一脚本生命周期内有效。
4. review / analyze 的只读约束在网关通道下是提示词级，不是技术强制。
5. **不支持 MCP Server 模式**：CLI 只能接 MCP（`--mcp-config`），不能被暴露成 MCP 供他人调用。
6. 网关口令在本机没有配置文件留存（仅出现在 `~/.workbuddy/logs`），长期方案是自起 `--serve` 并从其 stdout 读取。
7. ACP 端到端、stdin（`--input-stream-json`）、`--json-schema` 结构化字段：存在但未实测 → `unknown`。

## 16. A2A 调用示例

```powershell
# 创建任务文件（UTF-8）
"仅回复：A2A interface test passed." | Set-Content -Encoding UTF8 F:\AtoA\tasks\task-001.md

# 调用
F:\AtoA\agents\codebuddy\invoke.ps1 `
    -TaskFile   "F:\AtoA\tasks\task-001.md" `
    -OutputFile "F:\AtoA\tasks\task-001-result.md" `
    -Workspace  "F:\AtoA\tasks" `
    -Mode       "execute"

# 判定
$code = $LASTEXITCODE   # 0 = 成功
Get-Content F:\AtoA\tasks\task-001-result.md
```

审核模式示例：

```powershell
F:\AtoA\agents\codebuddy\invoke.ps1 `
    -TaskFile   "F:\AtoA\tasks\review-login.md" `
    -OutputFile "F:\AtoA\tasks\review-login-result.md" `
    -Workspace  "F:\Projects\Demo" `
    -Mode       "review" `
    -Transport  runs
```
