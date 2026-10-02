# P2 原生关闭决策（设置表单修复后）

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

UI coder 独占 ContentView、WindowLifecycle、Web_StudioApp 和 WorkspaceIntegrationTests。

1. `performCloseWorkspace` 当前没有传 resolver，因此保存失败后无交互而静默取消。改成返回 Bool 的 async 可测试入口，可注入 resolver，生产默认原生重试/取消/不保存对话框。只有 true 才切换或创建fallback。
2. 临时空间的单关闭、窗口关闭、应用退出统一处理：保留会话级影响汇总；临时配置有保存命名/不保存/取消选择。先完成所有决策再进入批量 core 关闭，任一取消不停止观察或终止任何运行时。已输入命名本身可保留，但不产生cleanup。不要只处理单关闭。
3. 保存失败统一原生 resolver；当前重试可由core重新saveNow执行；调用方须接受 false 并退出关闭中状态。普通model测试不得弹NSAlert，使用注入closure。
4. 修复恢复前已有工作：core负责Registry；UI继续保留launchTerminalProcesses原值。
5. 新增明确测试，至少model关闭保存失败cancel返回false且继续编辑；再次retry成功；窗口批处理注入resolver取消不关闭/不创建新session。

这些必须在启动P3前完成。Parse仅证明语法，主线程统一Xcode测试。
