# ZCode

## 1. 基本信息

| 项 | 值 |
|---|---|
| Agent ID | `zcode` |
| 工具本体 | ZCode（Z.AI 出品的 Agentic Coding 工具，桌面版 3.10.2，内含 CLI 核心 0.16.5） |
| 驱动模型 | GLM 系列（Z.AI Coding Plan），默认 `zai/GLM-5.3-Flash` |
| 类型 | coding-agent（具备文件读写、Shell、Git、网络能力） |
| 目录 | `F:\AtoA\agents\zcode\` |
| 接口脚本 | `invoke.ps1` |
| 本文档角色说明 | 本 Agent 不承担固定角色（brain/executor/reviewer/analyzer 均由调用方按任务指定） |

## 2. 当前安装 / 运行环境

- 操作系统：Windows 10 x64（win32 10.0.19045）
- ZCode 桌面版安装位置：`C:\Program Files\ZCode\`
- CLI 核心文件：`C:\Program Files\ZCode\resources\glm\zcode.cjs`（版本 0.16.5，由 `--version` 实测确认）
- Node.js：v24.15.0，位于 PATH（`node` 命令直接可用）
- 桌面端已登录 Z.AI Coding Plan（凭据位于 `~\.zcode\v2\credentials.json`）
- **重要**：headless CLI 与桌面端的登录状态不互通（实测确认，见第 15 节），headless 运行需要单独的一次性配置，见第 4 节与第 16 节。

## 3. 原生调用方式

可执行入口（无独立的 `zcode.exe` 命令，需通过 node 启动）：

```text
node "C:\Program Files\ZCode\resources\glm\zcode.cjs" [command] [options]
```

与 headless 相关的原生参数（均经 `--help` 与**逐一实测**确认。注意：本版本 help 文本与实际解析器不一致，以下区分「实际可用」与「help 有但解析器拒绝」）：

实测解析器接受的参数：

| 参数 | 说明 |
|---|---|
| `--prompt <text>`（别名 `-p` 接位置参数） | 非交互执行单个 prompt，不打开 TUI |
| `--cwd <path>` | 指定工作目录（原生支持，优先使用） |
| `--attach <path>` | 附加本地文件到 prompt，可重复传入 |
| `--mode <mode>` | 权限模式：`build` / `edit` / `plan` / `yolo`（`--prompt` 下默认 `yolo`） |
| `--disallowed-tools <list>` | 工具黑名单 |
| `--verbose` | 输出诊断详情 |
| `--target <text>` | 设置会话目标（与 `--prompt` 互斥，实测报错提示） |
| `--locale <locale>` | 界面语言 |
| `--resume <sessionId>` / `-c` | 恢复历史会话 / 继续最近会话（未逐一验证运行效果，解析器接受） |
| `--json` | 尽可能输出机器可读 JSON |
| `--no-color` | 关闭 ANSI 颜色 |
| `login` / `logout` | Z.AI OAuth 登录 / 注销（写入/清除共享凭据与全局配置） |
| `doctor` / `version` | 诊断 / 版本号 |

help 中列出但**解析器实际拒绝**（报 `Unknown option`，勿使用）：

| 参数 | help 描述（未实现） |
|---|---|
| `--max-turns <n>` | headless 最大模型轮数 |
| `--allowed-tools <list>` | 工具白名单 |
| `--permission-mode <mode>` | 权限模式旧别名 |
| `--settings <path>` | 从指定文件加载用户配置 |

另注意：`--help` 文本中列出的 `--settings <path>` 参数同样未被解析器接受，属于 help 与实现不一致，不要依赖。

## 4. 非交互调用方式

基本形式：

```powershell
node "C:\Program Files\ZCode\resources\glm\zcode.cjs" --prompt "任务文本" --cwd "工作目录" --mode yolo --no-color
```

实测确认的行为：

- `--prompt` 直接运行单轮任务并输出到 stdout，全程无交互。
- prompt 不能通过 stdin 管道传入（`echo x | zcode -p` 会报参数缺失）。
- 无 prompt 直接启动会尝试打开 TUI，在本机桌面安装形态下报 `Cannot find package '@zcode/tui'`，因此 headless 必须始终显式传 `--prompt`。
- 长任务文本受 Windows 命令行长度限制（约 32k 字符），超长时应改用 `--attach <TaskFile>` + 短 prompt 的方式传递。

**模型配置前置条件**（headless 与桌面端登录不互通，实测确认）：

- headless 运行时 CLI 要求 `~\.zcode\cli\config.json` 中存在显式模型提供方配置，否则报错
  `Model config is missing`。
- 配置存在但缺少 API key 时报错 `Model provider is missing an API key`。CLI 的 headless 运行时
  不会读取桌面端共享 OAuth 凭据（逆向其加载逻辑并实测确认）。
- 因此首次使用 headless 模式前必须完成以下任一一次性配置：
  1. 在终端执行 `node "C:\Program Files\ZCode\resources\glm\zcode.cjs" login`，按提示在浏览器完成一次 Z.AI OAuth。该命令会用 OAuth 换取 API key 并写入全局 `~\.zcode\cli\config.json`（provider `zai`，anthropic 协议，baseURL `https://api.z.ai/api/anthropic`）。
  2. 或将一个 Z.AI Coding Plan API key（格式 `id.secret`，CLI 会将其用作请求签名凭据）保存到 `F:\AtoA\agents\zcode\api-key.txt`。`invoke.ps1` 检测到该文件后会自动生成本地隔离配置（位于本目录 `home\` 下），不会触碰全局配置。

`invoke.ps1` 会按「全局配置已就绪 → api-key.txt → 明确报配置错误并给出修复指引」的顺序自动选择，调用方无需关心。

## 5. 工作目录处理

- CLI 原生支持 `--cwd <path>`，`invoke.ps1` 始终使用该原生方式，并把子进程的 WorkingDirectory 也设为 Workspace。
- 未传 `-Workspace` 时默认为调用方的当前目录。
- Workspace 目录不存在时 `invoke.ps1` 直接报错退出（不会静默创建），避免调用方拼错路径导致任务在错误位置执行。
- 约定：Agent 只应修改 Workspace 内的文件；`F:\AtoA` 是通信与控制目录，不是项目工作目录。

## 6. Task 输入方式

- TaskFile 必须是 UTF-8 文本文件，内容即完整任务描述。
- `invoke.ps1` 读取 TaskFile 全文后按 Mode 包装成 prompt：
  - 内容 ≤ 约 26k 字符：直接内联进 `--prompt`；
  - 超过该长度：改用 `--attach <TaskFile>` 传递，`--prompt` 只保留模式约束与文件路径说明（规避 Windows 命令行长度上限）。
- stdin 不可用（CLI 不支持），调用方必须使用 TaskFile。

## 7. 输出方式

- Agent 原生输出为自由文本（stdout）。`--json` 参数在部分场景可输出 JSON，但不保证所有输出结构化，因此按 `structured_output: false` 处理。
- 无论原生输出形式如何，`invoke.ps1` 保证最终结果写入 `-OutputFile`，统一格式：

```text
Agent: zcode
Mode: execute|review|analyze
Status: success|failed
Started: yyyy-MM-dd HH:mm:ss
Finished: yyyy-MM-dd HH:mm:ss
Exit Code: <统一退出码及原始CLI退出码>
Task File: <TaskFile 路径>
Workspace: <Workspace 路径>

Summary:            <- Agent 的原始完整输出（失败时为部分输出或错误摘要）
Changed Files:      <- Agent 在输出中列出的变更文件
Commands / Tests:   <- 实际执行的命令与测试
Errors:             <- 失败原因 / CLI stderr 尾部；成功时为 None
Notes:              <- 补充说明
```

- 任务失败（包括超时、配置缺失）同样会写 OutputFile，不会静默失败。

## 8. invoke.ps1 使用方法

```powershell
F:\AtoA\agents\zcode\invoke.ps1 `
    -TaskFile "<任务文件路径>" `
    -OutputFile "<结果文件路径>" `
    -Workspace "<项目工作目录>" `
    -Mode "execute|review|analyze"
```

可选参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-TimeoutSeconds` | 1800 | 运行超时（秒），超时强制终止并记为 failed |
| `-MaxTurns` | 300 | 预留参数；当前 CLI 版本解析器拒绝 `--max-turns`，故不会传递给 CLI |

环境变量覆盖：`ZCODE_CLI_PATH`（CLI 路径）、`ZCODE_A2A_MODEL`（模型 id，默认 `GLM-5.3-Flash`）。

调用方无需了解任何原生 CLI 参数。

## 9. execute 模式

- 权限映射：CLI `--mode yolo`（工具调用自动放行，headless 必需），prompt 中明确允许在工作区内读写文件、执行 Shell/Git 命令。
- 适用：实际编码、修复、生成文件、运行测试等有副作用的任务。
- 输出要求：prompt 中已要求 Agent 在最终回复末尾按 `Summary / Changed Files / Commands / Tests / Errors / Notes` 结构汇报，`invoke.ps1` 将其原样嵌入 OutputFile 的 Summary 字段。

## 10. review 模式

- 权限映射：CLI `--mode plan`（只读权限模式，阻止文件修改）+ prompt 包装「你当前只负责审核，不要主动修改任何文件」。
- 适用：代码审查、变更评审、方案评审。
- OutputFile 中 `Changed Files` 由 Agent 按约定填写 `None (read-only mode)`。

## 11. analyze 模式

- 权限映射：与 review 相同（`--mode plan` + 只读 prompt 包装）。
- 适用：架构分析、问题定位、信息调研、风险评估等只读分析任务。
- 与 review 的区别仅是任务语义（评审已有结论/变更 vs. 开放性分析），权限约束一致。

## 12. 文件 / Shell / Git / 网络权限

| 能力 | 支持 | 说明 |
|---|---|---|
| 文件读 | ✅ | 受当前权限模式约束 |
| 文件写 | ✅（execute）/ ❌（review、analyze） | review/analyze 由 plan 模式 + prompt 双重约束 |
| Shell | ✅ | 完整本地 Shell；execute 下可执行任意命令，review/analyze 下应仅执行只读命令 |
| Git | ✅ | 依赖系统 Git；本 Agent 不修改全局 Git 配置 |
| 网络 | ✅ | 模型 API 调用本身需要网络；Agent 亦可通过工具/Shell 访问网络 |

安全边界：`invoke.ps1` 只写入 OutputFile、临时文件与本目录 `home\` 沙箱；不修改全局配置、凭据、其他 Agent 目录与用户系统设置。

## 13. 成功与失败判定

- 以 CLI 进程退出码为准：
  - `0` → 任务成功，OutputFile `Status: success`，`invoke.ps1` 退出码 `0`。
  - 非 `0` → 任务失败，OutputFile `Status: failed` 并附 stderr 摘要，`invoke.ps1` 退出码 `4`。
  - 超时：强制终止子进程，记为 failed，`invoke.ps1` 退出码 `4`。
- `invoke.ps1` 统一退出码约定：

| 退出码 | 含义 |
|---|---|
| 0 | 调用成功 |
| 2 | 参数错误（缺参数、TaskFile/Workspace 不存在） |
| 3 | 未配置（headless 模型配置缺失，OutputFile 与错误信息中含修复指引） |
| 4 | Agent 运行失败（CLI 非零退出或超时） |
| 5 | 内部错误（OutputFile 写入失败等） |

- 注意：CLI 的退出码只反映「运行是否正常完成」，不保证业务任务语义成功；调用方应阅读 OutputFile 的 Summary/Errors 做二次确认。

## 14. 常见错误

| 错误 | 原因 | 处理 |
|---|---|---|
| `Model config is missing. Create ~\.zcode\cli\config.json ...` | 未完成 headless 一次性配置 | 见第 4 节；`invoke.ps1`（未配置时）退出码 3 并给出同样指引 |
| `Model provider ... is missing an API key` | 配置了 provider 但没有 API key | 完成 `zcode login` 或提供 `api-key.txt` |
| `ClientRequestSigningV4Error: Client signing credential must contain one separator` | API key 格式不是 `id.secret` | 检查 api-key.txt 内容 |
| `Cannot find package '@zcode/tui'` | 未传 `--prompt` 导致尝试启动 TUI | 始终通过 `invoke.ps1` 调用（其必传 prompt） |
| `Unknown option '--settings'` / `'--max-turns'` / `'--allowed-tools'` / `'--permission-mode'` | CLI help 与解析器实现不一致 | 不要使用这些参数（`invoke.ps1` 已规避） |
| `APICallError [AI_APICallError]: Unauthorized` | API key 无效（测试用占位 key 即返回此错误） | 重新 login 或更换有效 key |
| `Turn execution failed` + 401/403 | API key 失效或额度不足 | 重新 login 或更换 key |
| 超时（`invoke.ps1` 退出码 4，Errors 含 Timeout） | 任务过大或模型响应慢 | 增大 `-TimeoutSeconds`，或拆分任务 |

## 15. 已知限制

1. **headless 首次使用需一次性人工配置**：桌面端已登录 ≠ headless 可用。必须完成一次 `zcode login`（人工在浏览器授权）或提供 API key 文件。在此之前所有调用返回退出码 3。
2. stdin 不可用；超长任务依赖 `--attach` 传递。
3. CLI `--help` 与解析器实现不一致：`--settings`、`--max-turns`、`--allowed-tools`、`--permission-mode` 在 help 中列出但解析器拒绝（均已实测），`invoke.ps1` 已规避。
4. 无独立 `zcode.exe`，依赖 Node.js 与桌面版安装路径；CLI 随桌面版升级可能变化，路径可通过 `ZCODE_CLI_PATH` 覆盖。
5. review/analyze 的只读性由 plan 权限模式与 prompt 约束共同保证，属于运行时约束而非系统级沙箱。
6. TUI 无法在桌面安装形态之外启动（headless-only）。
7. `zcode doctor` 不校验模型配置，配置问题只能在运行时发现。
8. CLI 静态默认模型为 `zai/glm-5.1` / `zai/glm-4.7`（逆向 bundle 常量所得），本 Agent 默认改用与桌面端当前会话一致的 `GLM-5.3-Flash`，可通过 `ZCODE_A2A_MODEL` 覆盖。

## 16. A2A 调用示例

完整示例：

```powershell
F:\AtoA\agents\zcode\invoke.ps1 `
    -TaskFile "F:\AtoA\tasks\task-001.md" `
    -OutputFile "F:\AtoA\tasks\task-001-result.md" `
    -Workspace "F:\Projects\Demo" `
    -Mode "execute"
```

review 示例：

```powershell
F:\AtoA\agents\zcode\invoke.ps1 `
    -TaskFile "F:\AtoA\tasks\task-002-review.md" `
    -OutputFile "F:\AtoA\tasks\task-002-review-result.md" `
    -Workspace "F:\Projects\Demo" `
    -Mode "review"
```

TaskFile 示例内容（`task-001.md`）：

```text
请检查 src/auth/login.py 中的登录逻辑。

目标：
1. 找出空指针风险。
2. 如果 Mode=execute，可以直接修复。
3. 完成后说明修改文件。
4. 运行相关测试。
```

等价的底层原生调用（仅供理解，调用方不应直接使用）：

```text
node "C:\Program Files\ZCode\resources\glm\zcode.cjs" --prompt "<包装后的任务>" --cwd "F:\Projects\Demo" --mode yolo --max-turns 300 --no-color
```
