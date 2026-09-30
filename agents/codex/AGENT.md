# Codex

## 1. 基本信息

- 标准名称：`codex`
- 类型：coding-agent
- 独立目录：`F:\AtoA\agents\codex\`
- 本目录只描述和封装 Codex CLI，不绑定长期角色。每次任务可由调用方指定为 brain、executor、reviewer 或 analyzer。

## 2. 当前安装 / 运行环境

- 当前实测命令：`codex`，来源为当前用户的 npm 安装路径。
- 当前实测版本：`codex-cli 0.145.0`。
- 运行环境：Windows PowerShell。
- 当前可用的认证方式取决于本机 Codex CLI 的已保存登录状态或调用时提供的 API 凭据；本 Agent 不读取、写入或复制凭据。

## 3. 原生调用方式

主要命令是：

```powershell
codex exec [OPTIONS] [PROMPT]
```

当前版本实测支持：

- `codex exec "任务 Prompt"`：非交互执行。
- `codex exec -`：从 stdin 读取完整 Prompt。
- `--cd <DIR>`：指定工作目录。
- `--sandbox read-only|workspace-write|danger-full-access`：指定沙箱权限。
- `--output-last-message <FILE>` / `-o <FILE>`：写出最终 Agent 消息。
- `--json`：输出 JSONL 事件流。
- `--output-schema <FILE>`：要求结构化最终响应。
- `--ephemeral`：不持久化本次运行的会话文件。
- `--skip-git-repo-check`：允许在非 Git 目录运行。

## 4. 非交互调用方式

Codex 支持可靠的非交互入口 `codex exec`。Prompt 可以作为参数传入，也可以使用 `codex exec -` 从 stdin 读取。执行进度通常写入 stderr，最终 Agent 消息写入 stdout；本封装使用 `-o` 保存最终消息，并单独记录 stdout/stderr 以便生成统一结果。

## 5. 工作目录处理

`invoke.ps1` 将传入的 `-Workspace` 解析为绝对路径，并通过原生 `codex exec --cd <Workspace>` 设置 Codex 的工作目录。脚本不会把 `F:\AtoA` 自动当作业务项目目录。

## 6. Task 输入方式

调用方把完整 UTF-8 文本任务写入 `-TaskFile`。脚本读取该文件，并把内容拼接到内部 Prompt 中；调用方无需了解 Codex 的原生 Prompt 参数。

Codex 原生也支持 stdin，但本统一接口使用 TaskFile，以便外部调度器稳定重试、留存和审计任务内容。

## 7. 输出方式

脚本把 Codex 的最终消息写入 `-OutputFile`，并统一生成以下字段：

```text
Agent:
Mode:
Status:

Summary:

Changed Files:

Commands / Tests:

Errors:

Notes:
```

如果 Codex 启动失败、认证失败或返回非零退出码，脚本仍会尽量生成 `Status: failed` 的结果文件。

## 8. invoke.ps1 使用方法

```powershell
F:\AtoA\agents\codex\invoke.ps1 `
    -TaskFile "F:\AtoA\tasks\task-001.md" `
    -OutputFile "F:\AtoA\tasks\task-001-result.md" `
    -Workspace "F:\Projects\Demo" `
    -Mode "execute"
```

必需参数：`TaskFile`、`OutputFile`、`Workspace`、`Mode`。

允许的 `Mode`：`execute`、`review`、`analyze`。

## 9. execute 模式

使用 `workspace-write` 沙箱。Prompt 会要求 Codex 按任务执行必要的文件修改、命令和测试，并在最终消息中说明结果。是否修改哪些文件仍由本次 TaskFile 决定。

## 10. review 模式

使用 `read-only` 沙箱。Prompt 会明确要求只审核、不修改文件，并报告发现的问题、风险、证据和建议。

## 11. analyze 模式

使用 `read-only` 沙箱。Prompt 会明确要求只分析、不修改文件，并给出分析结论、依据和建议的下一步。

## 12. 文件 / Shell / Git / 网络权限

- 文件读取：支持，权限受 Codex 沙箱和 Workspace 约束。
- 文件写入：支持，但只有 `execute` 模式使用 `workspace-write`；`review` 和 `analyze` 使用只读沙箱。
- Shell：支持，实际可执行命令受 Codex 权限策略和本机环境影响。
- Git：支持调用本机 Git；Codex CLI 的 Git 仓库检查由封装显式跳过，因此非 Git Workspace 也可运行。
- 网络：`unknown`。本封装未启用 `--search`，网络能力取决于本机 Codex 配置、权限和任务环境。
- 鉴权：需要当前 Codex CLI 已保存登录状态，或外部安全地提供可用凭据；不要把凭据写入 TaskFile、输出文件或仓库。

## 13. 成功与失败判定

- `0`：Codex CLI 返回成功，结果文件中的 `Status` 为 `success`。
- 非 `0`：启动、认证、执行或其他错误，结果文件中的 `Status` 为 `failed`。
- `OutputFile` 中的 `Errors` 和 `Notes` 会保留可见的失败原因或 stderr 摘要。

## 14. 常见错误

- 找不到 `codex`：Codex CLI 未安装或不在当前 PowerShell 的 PATH 中。
- 认证失败：需要先在本机完成 Codex CLI 登录，或在受控环境中配置凭据。
- Workspace 不存在：脚本会在调用前拒绝该任务。
- TaskFile 不存在或不是 UTF-8 文本：脚本会返回失败结果。
- 任务需要写文件但 Mode 是 `review` / `analyze`：只读沙箱会阻止修改，这是预期行为。
- 模型或权限策略拒绝命令：脚本保留非零退出码，不会伪装成成功。

## 15. 已知限制

- 当前封装输出统一 Markdown 文本，不把原生 JSONL 事件逐条写入 `OutputFile`；原生 JSON/Schema 能力已确认但未暴露为统一接口参数。
- 网络访问未由封装主动开启，因此不能承诺每个环境都可联网。
- 认证状态依赖调用机器，脚本不会替调用方登录。
- 运行时的 `OutputFile` 可以位于 Agent 目录之外，这是统一接口的设计要求；安装阶段没有修改其他 Agent 目录。
- 超时控制未在当前 Codex CLI 选项中确认，调用方如需硬超时应由外层进程管理。

## 16. A2A 调用示例

```powershell
F:\AtoA\agents\codex\invoke.ps1 `
    -TaskFile "F:\AtoA\tasks\task-001.md" `
    -OutputFile "F:\AtoA\tasks\task-001-result.md" `
    -Workspace "F:\Projects\Demo" `
    -Mode "execute"
```

