# 源码与文档状态审查

日期：2026-09-26，Asia/Shanghai。主线程自审，Veriflow L1。用户要求审查已有代码并将文档更新到最新状态。本轮交付为文档同步与审查证据，未修改产品或测试源码；因此没有委派源码实施。没有运行新构建、XCTest、GUI、性能试验或外部服务验证，也没有提交/推送/合并/发布。

## 范围与成功条件

审查应用装配、空间/窗口所有权、配置读写恢复、关闭、导航与创建、问题/快照契约、终端编译目标及性能候选状态。用代码符号、Xcode 配置、实际原始执行输出和哈希核对文档。成功条件是当前文档不再把已实现能力写成计划、不把历史测试当成当前全量通过，链接可用或明确标记失效，并保留原有工作。

本轮是面向文档准确性的代码审查，不是逐行全仓缺陷或安全扫描；未由此宣称产品不存在其他问题。上游资料、冻结合同、归档证据及包内说明按其版本保留，分类入口见 [文档清单](../../DOCUMENTATION.md)。

## 发现并修正的差异

| 原文问题 | 当前源码/证据依据 | 本轮处理 |
| --- | --- | --- |
| B 路线仍“方案待选择/待实施”，架构仍写目录恢复和整批关闭在集成 | WorkspaceSession、Registry、Repository、SaveController、Coordinator 已装配，B1 和 review-fixes 有执行证据 | 更新方案状态、架构与 B1 摘要，保留最初方案正文和冻结输入 |
| README 主要指向 107 项早期测试，B1 摘要只保留 UI 初始化超时 | 后续完整 XCTest 已进入断言并失败；9 月 19 日专项 163 项通过 | 建立按版本/范围排列的验证时间线，明确全量 UI 未证明修复 |
| 归档、延迟创建、诊断只在修复子记录中说明 | WindowCoordinator.cleanupPreparedWorkspace、StudioModel.performWorkspaceAction、Registry.rescanDirectory、diagnosticEntries | 同步 README、架构及统一状态；UX 已有正确修复合同，保持 |
| 性能计划仍“仅新增计划”，且把新问题当作清空历史 | W0/W1 已部分执行并交付测试包；AgentController.newQuestion 保留旧问题，newChat 是不同方法 | 更新阶段状态和 W5 测量假设，移除失效源码行号 |
| 布局归属和 Ghostty 构建设置说明不精确 | WorkspaceSession.layout；pbxproj 使用 `$(GHOSTTY_KIT_PATH)/GhosttyKit.xcframework` | 明确 StudioModel 的代理关系；路径须为 framework 父目录 |
| Vendor VT 说明仍称扩展 IME 完全待验 | M2 人工记录已有版本限定的 IME、普通朗读回执 | 更新说明，保留完整辅助功能与迁移缺口 |
| 历史交接、旧验收中的“当前”“待派发”容易误读 | 原文件各自日期/阶段，后续实现已存在 | 添加历史时点导航；失效 `/private/tmp` 证据路径明确标注 |

## 原始输出与源码绑定

- 初始 HEAD、dirty 列表、已有 tracked diff、1954 个文件哈希分别保存在 baseline-status.txt、baseline.patch、baseline-sha256.json。它们是审查前基线，不能用于覆盖或回滚用户工作。
- 组合 `p4-final-source-hashes-02.json` 的 56 项与 review-fixes/final-integrity.json 的四项产品源码覆盖及新增专项测试，得到 57 项。当前逐项匹配；原 255 项测试仍是修复前的运行事实，不能因此自动升级成修复后的完整测试。
- 亲自读取 review-fixes/evidence/main-final-regression.json 的实际 argv、stdout、stderr 和 exit_code=0；stdout 明确为 163 tests in 17 suites passed。原生证据单独限定三条流程，截图仅在当时会话中观察，没有本地截图工件。
- 9 月 18 日完整 XCTest 的原临时文件已不存在。通过原执行会话的工具回执摘录恢复顶层汇总 273/261/12、模型日志 260/25 和 AX 窗口数 0，见 [历史回执摘录](xctest-history-excerpts.json)。这是历史二手载体，不是当前运行，也不是重新解析 xcresult。
- 生产 TerminalMetalRenderer 仍匹配 W1 中的 `44f7702330e5b4f5dde3ec817ed4f79017c3733afa09aaa3225c57a7cfe44c0d`；Xcode 中默认目标和 `WEB_STUDIO_VT` 目标继续分开。测试包仅为当时候选交付。

## 文档验证

[validation.json](validation.json) 记录文档链接、源码/脚本与冻结证据保护核查。当前文档新增的仓库内链接必须存在；历史临时路径不伪造恢复。构建命令只按现有脚本、scheme 和路径做静态复核，没有运行下载/重建/测试。没有验证外部网站链接的新鲜度；原调研中的外部资料继续属于原日期的引用。

当前工作区含早先大批未提交修改，不能用 git diff 总量当作本轮修改量。此次增量清单见 [changed-files.json](changed-files.json)，不包含早先产品源码 diff。原 evidence、inputs、SPEC、JSON task-state 和包内文档保持不变；旧全仓验证指纹不因本轮文档变化自动续期。
