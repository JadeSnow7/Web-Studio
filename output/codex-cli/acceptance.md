# Codex CLI 接入实机验收

日期：2026-09-13（Asia/Shanghai）。结论：本地验证构建已跑通 Web Studio → 选中网页快照 → Codex CLI → 原生会话回答。

## 实际配置与范围

- 可执行文件：`/opt/homebrew/bin/codex`，实际版本 `codex-cli 0.154.0`。
- Web Studio 设置界面成功检查现有 CLI 登录；没有读取、复制或展示登录凭据。
- 后端：Codex CLI；模型留空，使用 CLI 默认模型。实际解析出的模型名称未另行采集。
- 每次调用在独立临时目录中运行，只读、临时会话，问题和明确选择的快照通过 stdin 传递；忽略 CLI 用户自定义配置并关闭工具等扩展功能。
- 默认项目设置未修改。常规构建仍有 `com.apple.security.app-sandbox=true`；实机 CLI 验证构建仅通过构建参数 `ENABLE_APP_SANDBOX=NO` 生成。这不是沙箱分发版本已支持宿主 CLI 的证明。

## 真实界面证据

合成网页地址为 `http://127.0.0.1:56252/`，标题“Web Studio 实机验证”。网页包含订单 `WS-731`、金额 `128 元`、状态“待发货”、核验标记“松果-4826”。预览界面实际显示完整 74 字符快照及来源、采集时间和资源 ID。

首次问题：

> 请根据网页快照，回答测试订单的编号、总额、状态和核验标记。简短回答。

原生会话实际回答：

> 订单编号：WS-731；总额：128 元；状态：待发货；核验标记：松果-4826。

运行 ID：`EC42C8AE-5D6C-4A25-8B4E-EF0364B06EC6`。运行详情显示 Codex CLI、CLI 默认模型、配置路径和 1 个冻结快照。发送至观察到完整回答约 27.23 秒；这是 UI 观察耗时上界，包含工具调用间隔，不是精确模型延迟。

后续实机检查：

| 场景 | 实际结果 |
| --- | --- |
| 第二次普通请求 | 正确回答订单状态 |
| 运行中点击停止 | 显示“已取消”和重试按钮；随后系统进程检查确认应用无残留直接子进程 |
| 重试后运行中新建对话 | 会话、资源选择及预览清空，恢复开始对话状态 |
| 独立重新启动 `.app` | 保留 Codex CLI 后端、路径和空模型；重新检查登录成功 |
| 临时填写不存在的 CLI 路径 | 显示不可用，未误报登录成功；取消设置后恢复已保存路径 |
| 重启后的真实请求 | 再次准确返回四个网页值；界面恢复发送状态，无迟到旧回答 |

重启后的问题：

> 请从网页快照提取订单编号、金额、状态和核验标记，简短回答。

实际回答：

```text
- 订单编号：WS-731
- 金额：128 元
- 状态：待发货
- 核验标记：松果-4826
```

运行 ID：`25804E35-C285-4AE5-8B94-BA489636E290`，观察耗时上界约 27.18 秒。两次提问均未包含预期字段值。

## 自动验证

- 完整 `Web StudioTests`：124 项、10 个 suite，全部通过，约 9.11 秒。包括 CLI 协议解析、无 Keychain 访问、设置保存/取消、迟到检查结果、非阻塞输入输出、取消、超时和输出上限，以及现有模型、资源、终端、凭据测试。
- 原生 UI 回归：`testAgentBlankReadAndProviderSettingsFlow`、`testAgentComposerDraftSurvivesAdvancedPanelAndNewChat`，2 项全部通过。
- 常规 App Sandbox 构建：通过；签名中的 App Sandbox entitlement 保持 true。
- Premium UI 严格审计：0 findings。
- 任务差异相对开始前备份审查，项目文件与备份一致；`git diff --check` 通过。未处理已有无关修改，未提交或推送。
- 构建中仍有既有 WebRuntime 等代码的并发警告；本次 CLI runner、AgentService、ProviderSettings、AgentController 没有新增编译警告。

证据文件：

- [单元测试日志](/private/tmp/web-studio-codex-acceptance/unit-tests.log)
- [原生 UI 测试日志](/private/tmp/web-studio-codex-acceptance/ui-tests.log)
- [常规构建日志](/private/tmp/web-studio-codex-acceptance/default-build.log)
- [停止后进程检查](/private/tmp/web-studio-codex-acceptance/cancel-process-check.json)
- [UI 静态审计](/private/tmp/web-studio-codex-acceptance/premium-audit.json)
- [验收源码 SHA-256](source-sha256.json)

## 使用与边界

本次打开并验证的应用：`/private/tmp/web-studio-codex-local/Build/Products/Debug/Web Studio.app`。复现构建命令见 README。设置中选择 Codex CLI，选择资源并读取预览后即可提问。

本次证明的是用户显式选择的资源快照问答。没有实现自动网页操作、Shell 操作、文件编辑、隐式多轮历史或生产沙箱桥接；默认沙箱版本的宿主 CLI 运行不在通过范围。网络异常、额度耗尽、登录失效未进行真实故障注入，不作为已验证场景。
