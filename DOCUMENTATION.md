# 文档索引与维护边界

核对日期：2026-09-26。当前状态以 [STATUS.md](STATUS.md) 为总入口；源码行为以 Swift 实现和 Xcode 目标配置为准。此次逐项分类仓库 Markdown，并同步面向当前产品的说明。历史报告保留原结论及版本，原始执行证据、冻结 Spec/输入、第三方许可证和测试包内文件不改写为新结果。

## 当前阅读顺序

| 目的 | 文档 |
| --- | --- |
| 判断实现、验证与交付状态 | [当前状态](STATUS.md) |
| 使用、配置及构建 | [README](README.md) |
| 源码结构、所有权与调用链 | [源码架构指南](docs/source-guide/README.md) |
| 原生视觉与组件所有权 | [DESIGN](DESIGN.md) |
| 操作、生命周期与资料发送契约 | [UX-CONTRACT](UX-CONTRACT.md) |
| B1 数据与模块结构 | [架构](records/WORKSPACE-B1-20260917/ARCHITECTURE.md) |
| B1 完整验收标准与后续修复 | [验收协议](records/WORKSPACE-B1-20260917/ACCEPTANCE.md)、[修复结果](records/WORKSPACE-B1-20260917/review-fixes/task-summary.md) |
| VT 与性能路线 | [迁移状态](output/terminal-vt-migration/STATUS.md)、[性能计划](PERFORMANCE-PLAN.md)、[执行进度](records/PERF-20260917/task-summary.md) |
| 本次文档审查与限制 | [审查记录](records/DOCS-20260926/REVIEW.md) |

## 冻结资料的解释

- `records/**/evidence/`、`output/**/evidence/` 保存实测、失败、源码快照和当时的工具版本；其中 Markdown 也属于历史证据。旧 `task-state.json` 的 revision/Spec 关系不因本轮文档调整重新盖章。文档变更后不能把旧全仓指纹说成当前验收通过。
- `records/WORKSPACE-B1-20260917/SPEC.md`、`inputs/B-Plan-v1.md` 保留原合同和原方案输入；它们描述目标与当时的实施顺序，执行现状通过摘要和本索引查询。原方案的可读副本已补状态导航，不再与冻结输入宣称当前逐字一致。
- `handoffs/` 是原派发历史；“待派发”“待修复”只描述当时阶段。当前代码已实现的内容见架构、摘要和修复记录。
- `work-log.md`、`HISTORY.md` 是追加型历史；PID、GUI 状态和远端提交检查仅在记录时间成立。
- `output/test-releases/` 保留实际交付包及其文档，与压缩包 hash 绑定。它不是当前源码的新构建。
- `Vendor/ghostty/ghostty/doc/` 是上游工具文档，不是 Web Studio 产品说明；许可证原文、证据目录内冻结技能副本、浏览器工具临时输出不做产品状态改写。

## 产品文档清单

下表列出非证据、非冻结输入及非包内 Markdown。完整分类见 [机器可读清单](records/DOCS-20260926/document-inventory.json)。

| 文件 | 本轮处理 |
| --- | --- |
| [DESIGN.md](DESIGN.md) | 已同步的当前入口 |
| [docs/source-guide/README.md](docs/source-guide/README.md) | 新增：源码架构指南（2026-09-27） |
| [docs/source-guide/01-app-window-workspace.md](docs/source-guide/01-app-window-workspace.md) | 新增：源码架构指南（2026-09-27） |
| [docs/source-guide/02-persistence.md](docs/source-guide/02-persistence.md) | 新增：源码架构指南（2026-09-27） |
| [docs/source-guide/03-resources-ui.md](docs/source-guide/03-resources-ui.md) | 新增：源码架构指南（2026-09-27） |
| [docs/source-guide/04-terminal.md](docs/source-guide/04-terminal.md) | 新增：源码架构指南（2026-09-27） |
| [docs/source-guide/05-agent.md](docs/source-guide/05-agent.md) | 新增：源码架构指南（2026-09-27） |
| [docs/source-guide/06-build-test-scripts.md](docs/source-guide/06-build-test-scripts.md) | 新增：源码架构指南（2026-09-27） |
| [docs/source-guide/07-code-reading-notes.md](docs/source-guide/07-code-reading-notes.md) | 新增：源码架构指南（2026-09-27） |
| [PERFORMANCE-PLAN.md](PERFORMANCE-PLAN.md) | 已同步的当前入口 |
| [README.md](README.md) | 已同步的当前入口 |
| [STATUS.md](STATUS.md) | 已同步的当前入口 |
| [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) | 核对后保留，按原范围使用 |
| [UX-CONTRACT.md](UX-CONTRACT.md) | 已同步的当前入口 |
| [Vendor/GhosttyVT/README.md](Vendor/GhosttyVT/README.md) | 已同步的当前入口 |
| [output/adaptive-toolbar/acceptance.md](output/adaptive-toolbar/acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/address-toolbar-acceptance.md](output/address-toolbar-acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/codex-cli/acceptance.md](output/codex-cli/acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/frosted-glass/acceptance.md](output/frosted-glass/acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/ghostty-integration-acceptance.md](output/ghostty-integration-acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/imagegen/terminal-theme-20260916/prompts.md](output/imagegen/terminal-theme-20260916/prompts.md) | 历史调研、设计或验收（已标时点） |
| [output/interaction-research-20260917/B-WORKSPACE-PLAN.md](output/interaction-research-20260917/B-WORKSPACE-PLAN.md) | 历史调研、设计或验收（已标时点） |
| [output/interaction-research-20260917/EVIDENCE.md](output/interaction-research-20260917/EVIDENCE.md) | 历史调研、设计或验收（已标时点） |
| [output/interaction-research-20260917/REPORT.md](output/interaction-research-20260917/REPORT.md) | 历史调研、设计或验收（已标时点） |
| [output/motion/acceptance.md](output/motion/acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/seamless-toolbar/acceptance.md](output/seamless-toolbar/acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/six-features-acceptance.md](output/six-features-acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/ssh-passwordless-2026-09-13.md](output/ssh-passwordless-2026-09-13.md) | 历史调研、设计或验收（已标时点） |
| [output/start-chat/acceptance.md](output/start-chat/acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/terminal-automation-2026-09-13.md](output/terminal-automation-2026-09-13.md) | 历史调研、设计或验收（已标时点） |
| [output/terminal-vt-migration/ACCEPTANCE.md](output/terminal-vt-migration/ACCEPTANCE.md) | 已同步的当前入口 |
| [output/terminal-vt-migration/GUI-20260916.md](output/terminal-vt-migration/GUI-20260916.md) | 核对后保留，按原范围使用 |
| [output/terminal-vt-migration/HISTORY.md](output/terminal-vt-migration/HISTORY.md) | 追加型历史记录（保留） |
| [output/terminal-vt-migration/M2-CURRENT-RESULTS.md](output/terminal-vt-migration/M2-CURRENT-RESULTS.md) | 已同步的当前入口 |
| [output/terminal-vt-migration/MANUAL-ACCEPTANCE.md](output/terminal-vt-migration/MANUAL-ACCEPTANCE.md) | 已同步的当前入口 |
| [output/terminal-vt-migration/SKILL-OBSERVATIONS.md](output/terminal-vt-migration/SKILL-OBSERVATIONS.md) | 追加型历史记录（保留） |
| [output/terminal-vt-migration/STATUS.md](output/terminal-vt-migration/STATUS.md) | 已同步的当前入口 |
| [output/terminal-vt-migration/handoffs/performance-tooling.md](output/terminal-vt-migration/handoffs/performance-tooling.md) | 历史派发（已补当前导航） |
| [output/terminal-vt-migration/handoffs/resume-plan.md](output/terminal-vt-migration/handoffs/resume-plan.md) | 历史派发（已补当前导航） |
| [output/terminal-vt-migration/task-summary.md](output/terminal-vt-migration/task-summary.md) | 已同步的当前入口 |
| [output/terminal-vt-migration/work-log.md](output/terminal-vt-migration/work-log.md) | 追加型历史记录（保留） |
| [output/transparent-toolbar/acceptance.md](output/transparent-toolbar/acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/uniform-frost/acceptance.md](output/uniform-frost/acceptance.md) | 历史调研、设计或验收（已标时点） |
| [output/ux-consistency/acceptance.md](output/ux-consistency/acceptance.md) | 历史调研、设计或验收（已标时点） |
| [records/PERF-20260917/W0-RESULTS.md](records/PERF-20260917/W0-RESULTS.md) | 核对后保留，按原范围使用 |
| [records/PERF-20260917/W1-RESULTS.md](records/PERF-20260917/W1-RESULTS.md) | 核对后保留，按原范围使用 |
| [records/PERF-20260917/handoffs/w0-coder.md](records/PERF-20260917/handoffs/w0-coder.md) | 历史派发（已补当前导航） |
| [records/PERF-20260917/handoffs/w1-coder.md](records/PERF-20260917/handoffs/w1-coder.md) | 历史派发（已补当前导航） |
| [records/PERF-20260917/task-summary.md](records/PERF-20260917/task-summary.md) | 已同步的当前入口 |
| [records/PERF-20260917/work-log.md](records/PERF-20260917/work-log.md) | 追加型历史记录（保留） |
| [records/WORKSPACE-B1-20260917/ACCEPTANCE.md](records/WORKSPACE-B1-20260917/ACCEPTANCE.md) | 已同步的当前入口 |
| [records/WORKSPACE-B1-20260917/ARCHITECTURE.md](records/WORKSPACE-B1-20260917/ARCHITECTURE.md) | 已同步的当前入口 |
| [records/WORKSPACE-B1-20260917/B1-RESULTS.md](records/WORKSPACE-B1-20260917/B1-RESULTS.md) | 已同步的当前入口 |
| [records/WORKSPACE-B1-20260917/P0-FLOWS.md](records/WORKSPACE-B1-20260917/P0-FLOWS.md) | 核对后保留，按原范围使用 |
| [records/WORKSPACE-B1-20260917/SPEC.md](records/WORKSPACE-B1-20260917/SPEC.md) | 冻结合同、输入、证据或包内文档（保留） |
| [records/WORKSPACE-B1-20260917/handoffs/P0-coder.md](records/WORKSPACE-B1-20260917/handoffs/P0-coder.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P1-coder.md](records/WORKSPACE-B1-20260917/handoffs/P1-coder.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P2-close-preparation.md](records/WORKSPACE-B1-20260917/handoffs/P2-close-preparation.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P2-coder.md](records/WORKSPACE-B1-20260917/handoffs/P2-coder.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P2-core-review-blockers.md](records/WORKSPACE-B1-20260917/handoffs/P2-core-review-blockers.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P2-native-close-decisions.md](records/WORKSPACE-B1-20260917/handoffs/P2-native-close-decisions.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P2-repository-final-guards.md](records/WORKSPACE-B1-20260917/handoffs/P2-repository-final-guards.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P2-repository.md](records/WORKSPACE-B1-20260917/handoffs/P2-repository.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P2-runtime.md](records/WORKSPACE-B1-20260917/handoffs/P2-runtime.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P2-save-integration.md](records/WORKSPACE-B1-20260917/handoffs/P2-save-integration.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P2-ui-integration.md](records/WORKSPACE-B1-20260917/handoffs/P2-ui-integration.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P3-coder.md](records/WORKSPACE-B1-20260917/handoffs/P3-coder.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P3-compact-terminal.md](records/WORKSPACE-B1-20260917/handoffs/P3-compact-terminal.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P3-copy-service.md](records/WORKSPACE-B1-20260917/handoffs/P3-copy-service.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P3-navigation-ui.md](records/WORKSPACE-B1-20260917/handoffs/P3-navigation-ui.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P3-question-and-copy.md](records/WORKSPACE-B1-20260917/handoffs/P3-question-and-copy.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P3-question-core.md](records/WORKSPACE-B1-20260917/handoffs/P3-question-core.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P3-question-ui.md](records/WORKSPACE-B1-20260917/handoffs/P3-question-ui.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/handoffs/P4-native-ui-tests.md](records/WORKSPACE-B1-20260917/handoffs/P4-native-ui-tests.md) | 历史派发（已补当前导航） |
| [records/WORKSPACE-B1-20260917/review-fixes/ACCEPTANCE.md](records/WORKSPACE-B1-20260917/review-fixes/ACCEPTANCE.md) | 核对后保留，按原范围使用 |
| [records/WORKSPACE-B1-20260917/review-fixes/task-summary.md](records/WORKSPACE-B1-20260917/review-fixes/task-summary.md) | 已同步的当前入口 |
| [records/WORKSPACE-B1-20260917/review-fixes/work-log.md](records/WORKSPACE-B1-20260917/review-fixes/work-log.md) | 追加型历史记录（保留） |
| [records/WORKSPACE-B1-20260917/task-summary.md](records/WORKSPACE-B1-20260917/task-summary.md) | 已同步的当前入口 |
| [records/WORKSPACE-B1-20260917/work-log.md](records/WORKSPACE-B1-20260917/work-log.md) | 追加型历史记录（保留） |
