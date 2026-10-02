# IT-P1：会话内工作空间与窗口所有权

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

状态：待 P0 主线程流程审查后派发。用户已要求「开始执行」；主线程负责 Spec、架构、验收和报告。你不是唯一写入者，保留现有终端/性能/研究记录，不回退他人修改。

## 合同与所有权

先读 SPEC.md、ARCHITECTURE.md、ACCEPTANCE.md、P0-FLOWS.md 和 P0 审查记录。Spec 是 B1-SPEC-2（或主线程派发时明确的新版）；不得因旧测试期待空分组自动建网页而保留该行为。

你独占任务状态 IT-P1.file_scope，以及为满足 P1 必要的 WorkspaceSplitView.swift、StartPageView.swift、AgentViews.swift、ProviderSettings.swift、AgentController.swift（仅生命周期等待/配置传播）与相关测试；这些补充路径由主线程派发前同步到 state。只改会话内隔离、窗口归属和生命周期需要的代码，不实施 P2 磁盘格式和 P3 问题历史重构。README、DESIGN、UX-CONTRACT 在同阶段准确说明已实现范围。Xcode 使用文件系统同步组，通常不需改工程文件；确实需要时先报主线程。

禁止修改 Vendor、终端实现/渲染器、性能脚本；不 commit/push/merge/deploy。新源码头部导入与现有风格一致，保持原生系统字体/语义样式。遵循 SwiftUI 与 Swift Concurrency 技能；当前工程 Swift language mode 5.0，主应用默认 MainActor，工具链 Xcode 27 / Swift 6.4，不能把这些混同成 Swift 6 language mode。

## 结果与架构边界

1. WorkspaceSession 拥有一个 ResourceStore、独立布局/焦点、常用入口/最近项、AI controller/草稿和面板可见偏好。切换空间不销毁这些对象、不重建终端、不取消其请求。空空间保持空，首次空间为「临时空间」。
2. WindowCoordinator 拥有该窗口载入的 session；应用级 Registry 维护目录/单一窗口归属，避免全局强引用使窗口关闭后空间继续存活。StudioModel 可保留为视图/命令适配面，以减少无关 UI 改写，但不要把所有空间重新共用一个 store/AgentController。测试能注入独立 Registry，避免测试间全局污染。
3. 主应用使用共享 Registry；同窗口选择空间恢复其状态，他窗口选择已有空间激活原窗口并选中该空间，不创建第二份 runtime。窗口激活通过可测试的回调/弱窗口引用桥接。重复打开/关闭幂等，closing 空间不能重复装载。
4. PanelCoordinator 属于窗口。切换先撤销未提交地址输入、关闭临时命令面板；名称/目录/Provider 等表单草稿要保留或要求处理，不能静默丢弃。捕获 workspace/resource/pane 身份，目标不存在则报错或取消。延迟 Web navigation/title/state 回调只能更新原空间。
5. 只显示当前空间资源；顶部可访问全部空间，空空间可建网页/终端/SSH，关闭最后资源不制造替代网页。分隔比例及最后焦点随空间保存；native host 切换只 detach，不结束会话。
6. P1 先提供内存空间新建/命名/切换/关闭；跨退出保存与归档目录在 P2 落地前明确未实现，不显示「已保存」或模拟持久化。应用原有 grouped API/测试兼容投影可暂留，但用户不再把分组理解成空间内部第二层。
7. 关闭汇总列空间名称及实际 starting/running 终端、请求数量。取消不产生关闭副作用；确认一次后 shutdown 全部本窗 session（含隐藏空间）并等待既有 resource-close tasks。全局退出汇总一次、清理所有窗口；一条关闭任务可重入，不能重复释放或遗漏 AI。
8. Provider 设置与 Keychain 维持现有权威，更新配置用于各空间下一次请求，已发送的 request 不变。每个 controller 的回调绑定自己，不根据当前活动空间写入。

## SwiftUI 观察与迟到回调检查

沿用现有 ObservableObject 装配时，嵌套 session/store/agent 的变更不会自动传递到 StudioModel；明确订阅活动引用或让子视图直接观察对应所有者。切换本身必须触发视图重新绑定；不要仅把字段改成 computed 而遗漏通知。AgentPanel 初始化拿到的 controller 必须随空间身份变更，View 局部表单状态不得串空间。不要为本任务无关地迁移整个应用观察框架。

## 必要测试

- A/B store、AgentController、layout、draft 独立；切换后运行时引用、resource ID、pane ID/ratio/focus、草稿、常用入口不变。
- 延迟 provider 在切 B 后完成只写 A；关闭 A 后迟到结果不能进入新 A/session。
- 空空间选择、最后资源关闭不创建 blank resource；更新原有明确冲突的测试，保留路由/快照/终端回归。
- 两个 coordinator 共用 Registry，重复打开产生定位结果且构造计数不增加；关闭释放归属，可重新载入；测试不依赖真实 NSApp.keyWindow。
- 关闭当前 B 时 A 的终端和 AI 均进入影响摘要及清理；重复 close 等同一任务；原 store.closeAndWait 路径保留。
- 延迟 split resize/Web state 回调发生在空间切换后不能改写 B；Provider 草稿切换不丢。

已核验的离线依赖缓存为 /private/tmp/web-studio-b1-packages，传 -clonedSourcePackagesDirPath 及 -disableAutomaticPackageResolution；第一次沙箱构建因SwiftPM/Clang用户缓存写权限失败，需使用工具批准的构建执行权限。默认scheme基线已构建成功，79项测试/3 suites通过，原始记录见 evidence/p1-baseline-*.execution.json。

构建默认 Web Studio scheme；运行受影响的 Web_StudioTests、AgentControllerTests、ResourceReadTests 和新增 WorkspaceTests。用 launchTerminalProcesses:false、injected provider 覆盖模型测试；真实 Shell/Web UI 由主线程后续验收，不能用模拟结果冒充。

## 证据与回报

使用 record_execution.py --repo . --state records/WORKSPACE-B1-20260917/task-state.json 保存构建/测试命令到 evidence/p1-*。在开始记录前通知主线程暂停规范文件修改；产品内容改变后重跑受影响检查。构建产物使用 /private/tmp/web-studio-b1-build，测试结果包使用唯一的新 /private/tmp/web-studio-b1-*.xcresult 路径。

返回实际修改路径、设计取舍、原始输出/退出码/测试数、文档同步、未验证项，以及 P2 所需描述导入/快照导出/手动启动端口建议。完成只报「实现待审查」。遇到实施细节自主解决；只有改变 Spec 或跨出所有权范围才提请主线程决策。
