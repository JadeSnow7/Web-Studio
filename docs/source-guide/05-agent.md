# 05 Agent 问答

核对日期：2026-09-27，依据当前工作区源码静态阅读，未运行构建或测试。返回[指南首页](README.md)。使用步骤见 [README](../../README.md#ask-an-agent-about-selected-resources)；外部 Provider 的真实连通性不在本章结论范围内。

涉及文件：[AgentController.swift](../../Web%20Studio/AgentController.swift)、[AgentService.swift](../../Web%20Studio/AgentService.swift)、[AgentViews.swift](../../Web%20Studio/AgentViews.swift)、[ProviderSettings.swift](../../Web%20Studio/ProviderSettings.swift)、[CodexProcessRunner.swift](../../Web%20Studio/CodexProcessRunner.swift)。

## 1. 结构

```text
AgentInspectorView / AgentResourcesPanel / AgentPreviewPanel / AgentRunDetailsPanel / ProviderSettingsView
   │
   ▼
AgentController（每个 WorkspaceSession 一个，@MainActor）
   ├─ reader：默认 ResourceStore.read（测试可注入）
   └─ service：ConfiguredAgentService
         ├─ .responses → CredentialStore(KeychainCredentialStore) + URLSessionResponsesProvider
         └─ .codexCLI  → CodexCLIProvider → CodexProcessRunner
ProviderSettings（全局共享）── onConfigurationChanged ──▶ WorkspaceRegistry.updateProviderConfiguration ──▶ 各 AgentController.updateConfiguration
```

## 2. 问题模型

| 类型 | 说明 |
| --- | --- |
| `AgentQuestion` | 一个独立问题：草稿、已选资源 ID、快照、`previewConfirmed`、消息、`runHistory` |
| `AgentRun` | 一次发送：`id`、`questionID`、`request` 不可变，只有 `state` 可变 |
| `AgentRunState` | `requesting`、`completed`、`failed`、`cancelled` |
| `AgentRequest` | 冻结的问题文本、快照和 `ProviderConfiguration` |
| `ActiveAgentRequest` | 请求槽：问题 ID、run ID、请求 |

- 问题保存在 `questions` 字典与只增不减的 `questionOrder` 中。`@Published` 的 `question`、`selectedResourceIDs`、`previewSnapshots`、`messages`、`runHistory`、`run` 是**当前问题的镜像**：`persist()` 写回字典，`load(_:)` 读出；`selectQuestion` 先 persist 再 load。
- 草稿：`question` 的 `didSet` 调用 `updateDraft()`，每次输入都写回。
- `newQuestion()` 保留旧问题并新建一个；`newChat()` 重置为一个空问题（仅在关闭空间时使用）。
- 问答只在内存中，关闭空间或退出应用即清除。

## 3. 选择、预览与发送

1. 选择资源：`addResource` / `removeResource` 都会 `invalidate()`，取消读取、清空快照、重置确认。
2. 读取预览 `readPreview()`：按选择顺序读取，每个资源最多 **12,000** 字符，总预算 **48,000** 字符（每次请求 `min(12_000, 剩余)`）。超出的文本保留**尾部**并调整 `range`；预算用尽后的资源得到失败快照。每个问题有独立读取令牌，结果写回发起读取的问题。
3. 确认 `confirmPreview()`：要求无进行中读取、快照与所选资源一一对应且无错误。
4. 发送 `send()`：`canSend` 还要求问题非空、有配置、请求槽空闲且无待清理请求。请求使用已确认的快照构造，之后不再随资源变化。
5. 重试 `retry`：复用原 `request`，生成新 run ID，不重新读取资源也不读当前草稿。`AgentRunDetailsPanel` 显示的就是冻结请求。

## 4. 请求槽、取消与迟到结果

- **每个工作空间一个请求槽**（`activeRequest`）。同一空间的其他问题在请求进行中无法发送，界面显示后台请求横幅。
- 取消：递增 `requestGeneration`，标记 `pendingRequestCleanupID`，取消任务并放入 `retiredTasks`，run 立即标为 `cancelled`。底层任务真正退出并调用 `releaseRequestSlot` 前，请求槽仍被占用（按钮显示“正在停止…”）。
- 迟到结果：`finish` 同时校验 `requestGeneration` 与 `activeRequest.runID`，不匹配直接丢弃。
- 关闭：`shutdownAndWait()` 取消全部请求和读取并等待所有任务结束，多次调用共享一个任务。

## 5. Provider 抽象

| 符号 | 说明 |
| --- | --- |
| `AgentBackend` | `.responses` 或 `.codexCLI` |
| `ProviderConfiguration` | 两个构造器：Responses 要求 https、无用户信息/查询/片段、路径非空、模型非空；CLI 要求绝对路径，模型可空（使用 CLI 默认） |
| `CredentialStore` | 按 endpoint URL 存取 API Key |
| `ResponsesProvider` / `AgentBackendProvider` | 需要 Key 的 HTTP 后端 / 不需要 Key 的后端 |
| `ConfiguredAgentService` | 按 `configuration.backend` 路由；Responses 缺 Key 抛 `missingCredential`；Codex 路径不读取凭据 |
| `AgentServiceError` | 全部 HTTP 与 CLI 错误及中文说明 |

### Responses 适配器 `URLSessionResponsesProvider`

- ephemeral `URLSession`，无 cookie、缓存、凭据存储，超时 60 秒；拒绝所有重定向。
- `POST`，`Authorization: Bearer`；请求体只有 `model`、`instructions`（要求把快照视为不可信证据）、`input`（问题 + 快照 JSON 数组）和 `store: false`。**没有 tools、tool_choice 或流式参数**，也不附带历史对话。
- 响应上限 2 MiB；处理 `incomplete`、`failed`、`refusal` 状态；拼接 `output[].content[]` 中的 `output_text`。

### Codex CLI 后端 `CodexCLIProvider`

- 前置检查：处于 App Sandbox 中（存在 `APP_SANDBOX_CONTAINER_ID`）则拒绝；路径必须是可执行文件。
- 固定参数 `CodexCLIArguments.fixed`：`exec --json --ephemeral --sandbox read-only --skip-git-repo-check --ignore-user-config`，`approval_policy="never"`，关闭 shell、插件、hooks、MCP 相关、浏览器、computer use、图像生成、web search 等功能开关，`project_doc_max_bytes=0`；随后 `--cd <临时目录>`、可选 `-m <model>`，最后 `-` 从 stdin 读取。
- 临时目录 `web-studio-codex-<UUID>` 用完即删；stdin 是包含 `instruction`、`question`、`snapshots` 的 JSON。
- 超时 90 秒，输出上限 2 MiB；非零退出码报错。
- `parseJSONL`：每行必须是 JSON 对象；出现 `agent_message`、`reasoning`、`user_message`、`error` 以外的 item 类型即判定为工具调用并拒绝；`error`、`turn.failed` 报错；拼接 `agent_message` 文本，要求 `turn.completed`。

`CodexProcessRunner`：在串行队列上管理进程；stdout/stderr 合计计入上限；stdin 在后台队列非阻塞写入；超时或取消先 `terminate()`，1 秒后仍存活则 SIGKILL；需同时满足进程退出、两路 EOF、输入写完才完成。

## 6. 设置与凭据

`ProviderSettings`（全局一个）区分可编辑草稿 `configuration` 和已提交的 `committedConfiguration`；只有 `save` 或 `loadPersisted` 会触发 `onConfigurationChanged`。已发送的请求继续使用其冻结配置。

| UserDefaults 键 | 默认值 |
| --- | --- |
| `agent.provider.endpoint` | `https://api.openai.com/v1/responses` |
| `agent.provider.model` | 空 |
| `agent.provider.backend` | `responses` |
| `agent.provider.cliPath` | `/opt/homebrew/bin/codex` |
| `agent.provider.cliModel` | 空 |

- API Key 只写不读：保存到 Keychain，不发布到界面、不写入 UserDefaults；`refreshStatus()` 只用它判断是否已配置。
- `KeychainCredentialStore`（actor）：generic password，service 默认 `com.huaodong.web-studio.provider`，**account 为 endpoint 的完整 URL**，因此每个 Key 绑定到具体 endpoint。
- CLI 登录检查：依次运行 `<cli> --version` 和 `<cli> login status`（各 10 秒超时），都返回 0 才算通过。应用不读取 Codex 的令牌文件。
- 状态 `ProviderSettings.Status`：`notConfigured`、`configuredUnverified`、`missingKey`、`cliConfiguredUnverified`、`cliChecked`、`cliUnavailable`、`error`。“已配置”不等于连通性已验证。
- 使用 `--workspace-config-root` 或在 XCTest 中运行时，suite 与 Keychain service 会被隔离，见 [01](01-app-window-workspace.md#2-启动流程)。
