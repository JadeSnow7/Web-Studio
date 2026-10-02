# P2d：持久化和手动启动的原生入口

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

待 P2b 修复审查、P2c 签名发布后派发给 coder_p0_repair。独占 ContentView.swift、WorkspaceSplitView.swift、WindowLifecycle.swift、Web_StudioApp.swift、WorkspaceModelTests.swift；经主线程指示修复 Web_StudioTests.swift/ResourceReadTests.swift 中无效目录 fixture。不得改 Repository/Configuration/Session/Registry/Coordinator/SaveController/ResourceModel/AgentController。单写者，保留现有修改，不提交，不整文件格式化。

- 消费 core coder 的保存/恢复 API，不复制一套目录或保存状态。应用使用 Application Support 下 Web Studio/Workspaces；支持 --workspace-config-root PATH 明确隔离验收目录。测试不启用默认真实磁盘。
- AppDelegate 的默认装配也必须识别 XCTest 宿主，不扫描或创建用户真实空间目录；测试使用 Registry 的 nil repository 或显式临时根。不能只在模型测试里注入，却让测试宿主 SwiftUI root 同时恢复真实配置和网页。
- StudioWindowRoot 启动异步恢复，保留空临时界面直到结果；避免每窗口创建多个恢复实例。选择未载入项时显示载入状态/错误，迟到选择不覆盖用户新动作。跨窗口定位沿用 P1 行为。
- 顶部空间菜单/侧栏可新建命名空间、命名保存临时空间、改名、选/清除空间目录、关闭、归档；归档列表恢复并打开。新建表单取消不得留下悄悄自动保存的“新空间”。按现有原生面板风格，不加常驻内容标题栏。
- 新建本地终端默认使用 session.directory；未关联目录才用用户主目录。明确指定目录优先；失效关联目录保留原值并进入可修复错误，不静默换 Home。文件夹选择的迟到结果必须绑定发起时的 workspace/pane。
- 空间保存状态持续可见：临时/保存中/已保存/未保存错误。错误附重试，详细错误可读；不可只用可消失toast。
- 当前内存-only关闭文案全部替换为实际配置语义。窗口/退出一次汇总所有loaded空间，保存失败选择可重试/取消/不保存再关闭；取消不清理任何尚未关闭的资源。别先把代理的closing锁永久设true再取消导致无法二次关闭。测试可注入确认/失败选择避免NSAlert挂住宿主。
- 恢复的Shell/SSH描述页显示启动/连接按钮，明确不自动恢复进程。启动前绑定原workspace/resource身份；点击异步结果不能改当前另一空间。结束会话保留描述、关闭资源删除，UI菜单区分；会话结束后再次手动启动生成新实例。错误目录提供重新选择/编辑，而非退回Home。
- 所有本次增加的自有文案简中；全应用既有英文统一归P3，不扩展本子任务到问答或整体UX重构。
- NativeAddressField delegate 的 insertNewline/submit 必须检查 field editor 的 hasMarkedText，中文输入法确认候选时不能直接导航。现有 updateNSView 中的 marked-text 保护不能替代提交路径的保护。
- 核查 fixture：有效目录用 FileManager.temporaryDirectory 或实际 mktemp；无效目录测试保持明确failed断言。不得删除失败用例来获得通过。

测试覆盖加载/保存可见模型状态、异步选择守卫、取消关闭保留、命名/目录操作、手动启动绑定原owner。完整Xcode由主线程等共享修订稳定后统一录证；此阶段可parse。完成回报文件/端口/验证/未满足项，文档由主线程同步。

## 临时空间关闭提示

关闭含内容或问答的临时空间时明确“保存配置后关闭 / 不保存关闭 / 取消”，保存仅保存资源/布局，问答仍会清空。窗口/应用汇总中包含所有临时空间，先完成这些保存/丢弃选择与命名（或提供明确取消后命名路径），再调用整批核心关闭；不能清理一个临时空间后另一个取消。空且无草稿的临时空间不必重复提示。原生UI直接绑定core Bool返回，cancel时保留窗口和全部会话。准备/清理期间禁用编辑入口，状态显示正在关闭。
