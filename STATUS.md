# Web Studio 当前实现与验证状态

核对日期：2026-09-26（Asia/Shanghai）。范围为本地工作区，HEAD 为 `ced7edc25bd6ab6434712ce4da0b4bd16afad499`，含未提交 B1 实现和后续修复。此次为源码、文档及已有证据审查，没有新跑构建、XCTest、GUI 或性能实验，也没有核查远端 CI。

## 已落地的代码

| 能力 | 当前行为 | 代码权威 |
| --- | --- | --- |
| 工作空间与窗口 | 一个空间最多归属一个窗口；窗口可载入多个空间；切换保持各自资源、布局和问题状态 | `WorkspaceSession`、`WorkspaceRegistry`、`WindowCoordinator` |
| 配置持久化 | 命名空间自动保存，500ms 合并；schema 1；revision 冲突检查、文件锁、临时文件替换与备份恢复 | `WorkspaceConfiguration`、`WorkspaceRepository`、`WorkspaceSaveController` |
| 恢复与故障 | 默认位于 `~/Library/Application Support/Web Studio/Workspaces`；恢复配置、不恢复进程或问题；损坏/未来版本诊断可定位文件与重扫 | `Web_StudioApp`、`WorkspaceRegistry`、`ContentView` |
| 导航与关闭 | 配置搜索、复制入口、显式双视图；整批关闭先准备保存再清理；单空间归档后宿主保持可用 | `StudioModel`、`WindowCoordinator`、`WindowLifecycle` |
| AI 问题 | 各问题独立草稿与来源；显式读取、确认；每资源 12,000 字符、总计 48,000；每空间一个底层请求槽 | `AgentController`、`AgentService`、`AgentViews` |
| 终端目标 | `Web Studio` 使用 GhosttyKit；`Web Studio VT` 通过 `WEB_STUDIO_VT` 使用 libghostty-vt、应用自有 PTY/CoreText/Metal 前端 | Xcode target 配置、`TerminalSession`、`TerminalVTSession` |

重启后终端待启动、SSH 待连接；网页按需重载。运行时、网页表单和 AI 正文/快照不跨退出恢复。网站登录数据沿用共享 WebKit 存储。B1.1 问答持久化、连续对话、运行时跨窗口迁移和执行型 Agent 尚未实现。

## 验证证据与缺口

| 检查点 | 已有结果 | 适用范围 |
| --- | --- | --- |
| B1 核心实现，9 月 18 日前的最终检查点 | 255 项 / 23 套件通过；局部原生多空间、进程与恢复走查 | [原始执行](records/WORKSPACE-B1-20260917/evidence/p4-final-model-tests-02.execution.json)，早于后续四文件修复 |
| 9 月 18 日完整 XCTest 重跑 | xcresult 顶层汇总 273 项：261 通过、12 失败；模型日志单列 260 项 / 25 套件通过 | UI 已进入断言；首屏复测 AX 窗口数为 0。模型日志与 xcresult 汇总口径不同，不自行相加；[历史回执摘录](records/DOCS-20260926/xctest-history-excerpts.json) |
| 9 月 19 日 F1/F2/F3 修复 | 专项 12 项、受影响回归 163 项 / 17 套件通过；三条原生流程通过 | [修复结果](records/WORKSPACE-B1-20260917/review-fixes/task-summary.md)；不是完整 UI 自动化重跑 |
| 9 月 26 日源码核对 | 57 个源码/测试文件与 B1 最终清单及后续修复清单组合一致 | [本次审查](records/DOCS-20260926/REVIEW.md)；哈希一致不构成新运行验收 |
| VT M2 | 已有有界 GUI/TUI/SSH、IME 用户回执和部分 VoiceOver 回执 | [迁移状态](output/terminal-vt-migration/STATUS.md)；完整辅助功能、性能门槛和 M3 未完成 |
| 性能 W0/W1 | 工具试采与离屏候选实验部分完成；W1 热提交 CPU 中位数降幅 77.3%–82.4% | [W1 结果](records/PERF-20260917/W1-RESULTS.md)仅限离屏负载；真实 App 完成配对为 0；未采用到生产源码 |

9 月 18 日的 `/private/tmp` XCTest 日志和结果包未在此次核查中找到；这里保留的是原执行会话中的工具输出摘录，不能当作本轮重跑。9 月 19 日修复不证明上述 12 项 UI 失败已解决。当前完整 B1 验收仍为 **undetermined**：真实 SSH/外部 Provider、B1 中文 IME/VoiceOver、用户理解度、精确大窗口样本及完整 A01–A16 尚无完整通过证据。早期终端/CLI 的成功记录只适用于其旧二进制和场景。

## 性能与交付

W0 全应用基线未完成；W1 字体复用候选只存在于隔离实验和已交付的本机测试包；W2–W5 尚未落地。生产 `TerminalMetalRenderer.swift` 仍与原哈希一致。默认后端未切换，M3 未执行。

9 月 17 日已交付 arm64、ad-hoc 签名的 [VT 本机测试包说明](output/test-releases/2026.09.17-test1/Web%20Studio%20VT%20Test%202026.09.17/README.md)。这不表示生产采用、正式发布、Developer ID 签名或公证，也不证明包含后来 B1 修复。当前 B1 和后续修复仍在未提交工作区；此次未提交、推送、合并或发布，远端状态未刷新。

文档入口与历史资料分类见 [DOCUMENTATION.md](DOCUMENTATION.md)。
