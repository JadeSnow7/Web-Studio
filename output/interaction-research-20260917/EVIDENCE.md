# 调研范围、Spec 与证据

> 2026-09-26：本文是 9 月 17 日调研范围与出处记录。B 路线已选定并实现 B1 核心；后续代码及验收不属于此次调研证据，见 [当前状态](../../STATUS.md)。

日期：2026-09-17。流程：Veriflow L1，研究与设计说明，主线程自审；没有委派实现。

## Spec v1

- 来源：用户要求对 Web Studio 交互进行深度调研，整理待选方案。
- 目标：使用户能比较不同交互组织方式、决定后续设计方向。
- 交付物：现状与问题地图；官方产品资料对照；至少三套可比较方案；具体流程和边界；建议顺序与验证计划。
- 成功条件：每套方案说明适用场景、行为、收益、成本和依赖；现状有代码或观察依据；建议与实现清楚区分。
- 不变量：保留已有产品与性能工作；不修改产品源码、既有设计契约；不连接 SSH、发送 AI 内容或结束运行资源；不提交、推送或发布。
- 未决项：用户优先场景未获得补充回答，按全局工作流覆盖，并把导航、状态和键盘作为共同维度；主路线、连续对话和持久化范围保持 proposed。
- 权威产物：同目录 REPORT.md；代码事实绑定 evidence/baseline.json 的路径与 SHA-256。方案版本为研究提案，不替代仓库 UX-CONTRACT.md。

## 基线与核查

HEAD：`ced7edc25bd6ab6434712ce4da0b4bd16afad499`。

读取 README、完整 DESIGN 和 UX-CONTRACT、premium-ui 配置、资源/视图模型、地址和命令路由、分组与分屏、Agent 状态和界面、起始页、应用与窗口关闭路径，以及相关测试名称。13 个主要来源文件的哈希、HEAD、完整已跟踪/未跟踪工作区列表与命令退出码保存在 [baseline.json](</Users/huaodong/workspace/Web Studio/output/interaction-research-20260917/evidence/baseline.json>)。

开始时终端迁移记录已有修改，性能计划、性能记录及若干证据是未跟踪文件；均不属于本研究修改范围。全量路径以 baseline.json 为准。

| 代码来源 | 支持的事实 | 证据性质 |
| --- | --- | --- |
| ContentView.swift：selectResource、split、selectGroup | 选择已显示资源转移焦点；默认分屏在全局集合找候选；分组选择第一项 | 静态路径核查，未现场构造跨组分屏 |
| ContentView.swift：close、closePane、performClose | 资源与视图关闭分离；运行终端有终止提示 | 静态路径核查，未结束真实终端 |
| ContentView.swift：availableCommands、parseAddress | 命令目录与名称匹配；地址支持 Web/SSH/路径 | 静态 + 命令面板/SSH 入口现场观察 |
| AgentController.swift：canSend、readPreview、send、retry、newChat | 显式预览；12,000/48,000 字符限额；单次请求；原请求重试；清空状态 | 静态核查，未调用真实模型 |
| AgentViews.swift：header、composer、资源/预览面板 | 新建按钮直接调用 newChat；准备流程分散；配置缺失提示 | 静态 + 空状态现场观察 |
| StartPageView.swift、StudioModel.pinnedDestinations | 起始入口和当前会话内固定地址 | 静态 + 首页观察，未退出应用验证 |
| StudioLayoutPlan、WorkspaceSplitView | 窗口级布局；440pt 主内容预算；双视图 180pt 几何下限 | 静态核查，未测最小窗实际可读性 |
| Web_StudioApp.swift、WindowLifecycle.swift、UX-CONTRACT | 退出/关闭拥有资源的清理边界；无进程恢复承诺 | 静态核查 |

## 原生界面观察记录

工具：cua_repl。目标：`com.huaodong.Web-Studio`，窗口标题 Web Studio。应用启动路径、编译时间和源 revision 未绑定，因此下面是运行实例观察，不能当作当前 HEAD 的完整验收。

这是从本次工具回执整理的观察记录，不是原始 AX 全量归档；原始工具回执与首页截图在当前对话中。

| 操作 | 工具回执中的实际结果 |
| --- | --- |
| 查看首页 AX 与截图 | Tasks / Workspace / New Tab；中文三个入口；右侧 Agent；未配置提示；发送禁用 |
| ⌘K | Command palette，Target: New Tab；原生搜索框获焦；显示 New Web Page、New Terminal、Close Tab、Open Destination、New Task Group、Toggle Tab Strip、Toggle Agents |
| Escape | 命令面板消失，焦点回到此前的 New task group |
| 点击资源 | 出现独立资源面板，列出 New Tab、web、未选择；显示选择引导 |
| Escape 后点击预览 | 出现独立预览面板；显示“选择资源后读取预览”；读取按钮禁用 |
| Escape 后打开 Layout | Split 可用；Focus Other Pane、Close Focused Pane、Single Pane 等在单视图时禁用 |
| 退出菜单，点击 SSH 连接 | 地址栏值变为 ssh://，文本被选中；没有显示独立 SSH 表单 |
| Escape | 地址栏恢复空白与原占位文字；未连接 SSH |

最后已退出临时面板和地址编辑，保留原空白资源。未发送内容、创建终端、改变外观设置或关闭用户资源。

## 外部资料

REPORT.md 在相关结论旁保留官方链接。范围包括 Safari 标签组与 Profiles、VS Code 界面/终端/工作空间、Warp Tab Configs/旧配置迁移/恢复、Zed Agent Panel、NN/g 原始可用性原则。

访问日期为本次调研日；文档描述不等于对竞品实际安装版本的现场测试。Warp 的旧搜索摘要与当前页面不同，已按打开页面的 Legacy 提示继续核查 Tab Configs。Apple HIG inspectors 页面读取失败，sidebars 页面正文不足，未把它们作为核心结论证据。

## 检查结果

| 检查 | 状态 | 限定 |
| --- | --- | --- |
| Git HEAD/status 与主要文件读取 | passed | 命令退出码 0；保留脏工作区 |
| premium strict 静态审计 | passed | 0 errors / warnings / violations / unresolved；不是体验验收 |
| 有限原生界面走查 | passed | 仅上表入口/空状态/取消路径；运行应用 revision 未确定 |
| 当前 HEAD 构建、单元测试 | 未运行 | 本次无产品实现；历史测试数量不复用为本次结果 |
| 当前 HEAD 完整 GUI/IME/VoiceOver 验收 | undetermined | 本次未建立版本绑定，未覆盖完整路径 |
| 模型、SSH、退出/恢复链路 | 未运行 | 不以静态分析推定成功 |
| 用户访谈、方案原型、A/B 效率比较 | 未运行 | REPORT 的优先级、相对成本、样本规模都是待校准建议 |
| 主线程事实、方案边界与链接自审 | 完成 | 无独立审查者 |

静态审计实际命令（只读项目，写入临时审计 JSON）：

```sh
python3 /Users/huaodong/.codex/plugins/cache/openai-curated-remote/frontend-design-premium/1.4.0/skills/frontend-design-premium/scripts/audit_project.py . --mode strict --config premium-ui.json --output /private/tmp/web-studio-ux-research-audit-20260917.json
```

实际工作目录：`/Users/huaodong/workspace/Web Studio`。退出码 0。输出副本在 evidence/premium-static-audit.json。后续报告完整性与源文件未变检查见 evidence/verification.json。

## Spec 交付核对

| 要求 | 产物位置 | 判定 |
| --- | --- | --- |
| 现状与问题地图 | REPORT 当前模型、十个问题 | 研究范围内完成 |
| 可追溯外部调研 | REPORT 外部产品对照与近旁链接 | 完成，非竞品实机测试 |
| 至少三套待选交互方案 | REPORT A/B/C 及同场景比较 | 完成，均为 proposed |
| 关键流程和异常边界 | REPORT D1–D6、上下文、关闭/恢复 | 完成提案 |
| 落地次序与验收办法 | REPORT 最后阶段表与任务表 | 完成计划，未执行 |
| 不改变产品及其他任务 | 来源哈希与最终工作区核对 | 见 verification.json |
