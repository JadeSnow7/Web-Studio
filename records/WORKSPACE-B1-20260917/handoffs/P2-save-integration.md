# P2c：保存控制器与空间配置集成

> 文档状态标注（2026-09-26）：本文保留原日期、原版本的派发约束与交接记录，不是当前待执行清单。当前实现、后续修复和验收缺口见 [状态总览](../../../STATUS.md)。

待 P2a/P2b 公共 API 稳定后派发。coder_workspace_core 独占 WorkspaceSession.swift、WorkspaceRegistry.swift、WindowCoordinator.swift、新 WorkspaceSaveController.swift、新 WorkspaceSaveControllerTests.swift、新 WorkspaceRestorationTests.swift。不修改 ContentView、WindowLifecycle、Web_StudioApp、WorkspaceSplitView、ResourceModel、AgentController。另一 coder 将消费你的公开端口，主线程拥有记录与共享文档。保留所有已有修改，不提交，不整文件格式化。

先回报下游要用的实际签名；Swift 源为权威，本文描述必须满足的语义。

## 会话与保存

- WorkspaceSession 提供纯配置导出与配置构造。资源恢复使用 restoreDescriptors，不注册即启动。pane/resource/pin IDs、顺序、自定义名、目录与偏好往返；临时空间命名后变为保存空间。recent 是当前载入内存，AI/输出/runtime 身份不进入配置。
- 配置观察与保存控制器分离。纯配置发生变化才增加 generation，运行态/标题回调等未改变配置的通知不得触发写入。Combine objectWillChange 是变更前发出，延迟到当前同步修改之后再快照，不能保存旧值。关闭 flush 直接读取最新快照，不依赖未运行的观察回调。
- 一个空间一条串行保存队列，500ms 合并；旧写回执更新磁盘 revision，但不能把更晚配置标记已保存。dirty/saving/saved/error 持续可观察；错误不因重新安排 debounce 消失。显式重试才可清除为成功，新的写入失败仍保留最新内存配置。
- 保存服务可注入受控延迟/失败端口，以实际顺序测试旧写完成后新改动仍 dirty、下一写使用新 revision。不能在 MainActor 做文件 IO。
- flush 在关闭清理前 await，失败可重试、取消关闭、不保存关闭。discard 先停止队列并等待已发出的写入，读取/保留最后实际成功版本，再释放运行时；不得在 discard 返回后偷偷保存排队的新修改。临时空间无配置写入。

## 目录与装配端口

- Registry 默认无 repository（模型测试不触碰用户磁盘）；应用显式注入 repository。启动异步扫描目录一次，只实例化上次活动非归档空间；其它空间按打开动作异步加载。没有配置时保留原空临时空间。
- 目录保存已关闭空间；关闭删除 loaded/session/owner，保存项仍可再次打开为全新 Session/Store/Controller。临时关闭后消失。
- 单窗口归属检查必须跨异步 load 保持：多个窗口同时 open 同一 ID 最终只有一个拥有实例。取消/关闭窗口、快速切换的迟到 load 不得覆盖当前选择或创建无主运行时。提供明确 loading/error 状态，未知 schema/损坏项可呈现只读诊断。
- 记录 lastActivatedAt 用于下次恢复；启动不把所有空间都激活。已归档项不进入常用目录，提供归档目录和恢复方法。归档先成功保存 archived=true 才关闭；失败取消则保留当前会话，失败选择不保存关闭不能假称归档成功。
- 关闭空间/窗口/退出在开始不可逆 cleanup 前统一准备保存。取消时所有尚未清理的会话保持可用；窗口/退出先准备整批空间，全部通过后才 close。提供依赖注入的保存失败选择器供 UI 展示重试/取消/不保存。不能直接从模型服务弹 NSAlert。
- 原来的 closeWorkspace/closeAll 幂等、隐藏空间清理、single-owner 规则继续成立。新增关闭准备阶段不能让新会话越过 closeAll 封锁；取消解除临时封锁。

## 必需检查与交接

控制保存代次测试；命名临时空间；配置纯值往返；保存空间 close→reopen 新对象且 0 Shell/SSH 工厂；启动仅最后空间实例化；关闭失败取消不 shutdown；discard 后无晚写且重开上次保存；归档恢复；两个窗口同时 open 单owner；关闭时迟到 load 无泄漏。注入测试根和 IO 闭包，不修改真实应用目录。

向 UI coder 交接：启动恢复函数；目录与诊断属性；saved/dirty/error 状态；命名/目录更新；保存/重试；open saved；archive/unarchive；批量 prepare-close 与关闭取消的返回值；如何绑定窗口与应用 resolver。主线程统一测试，不在另一 coder 修改源码时运行完整 Xcode。

## 主线程补充审查边界

- 整批准备先收集重试/取消/不保存的决定，全批允许关闭后才永久停止各保存队列。若 A 选“不保存”、B 选“取消”，A 仍是可用会话且保存控制器不能被永久停用。取消后的再次关闭也必须正常。
- 应用退出同时封锁各窗口的创建/载入入口，所有窗口均通过保存准备之后才清理第一个会话。不能逐窗口准备并立即清理，之后另一窗口才取消。
- 配置打开的迟到结果在最终 attach 前复核窗口仍可载入、ID 的最新 owner 和选择代次；过期选择不覆盖用户后来选的空间。未采用的纯配置可以丢弃，未采用的新 Session 不得泄漏运行时。
- 恢复本身工厂计数为零；生产 Session 允许将来用户明确启动终端，所以不要把 convenience init 的测试默认 false 误带入生产恢复。
- 空间级请求计数使用 AgentController.isRequesting，而非当前题的 run.state。关闭后保留磁盘目录但丢弃全部内存问答。
