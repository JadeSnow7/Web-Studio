# B1 结构与实施顺序

核对日期：2026-09-26。B1 的 WorkspaceSession、WorkspaceRegistry、WindowCoordinator、WorkspaceRepository、WorkspaceSaveController 和独立问题核心均已落地；目录恢复、整批关闭和原生入口已集成。9 月 19 日进一步修复跨窗口归档、未加载空间创建和配置诊断。当前结果见 [task-summary.md](task-summary.md) 与 [后续修复](review-fixes/task-summary.md)，完整产品验收仍未完成。目标见 [Spec](SPEC.md)，接口字段以 Swift 类型为权威。

## 实施前基线与改动原因

| 已核对位置 | 实施前行为 | B1 改动原因 |
| --- | --- | --- |
| ContentView.swift / StudioWindowRoot、StudioModel.init | 每窗口一个 model，同时拥有全部分组、布局、ResourceStore、AgentController 和 PanelCoordinator | 窗口展示与空间状态需分离 |
| ContentView.swift / selectGroup、addGroup | 空分组/新分组自动创建网页 | B1 空空间保持空，⌘T 才显式建网页 |
| ResourceModel.swift / registerLocalTerminal、registerSSH | 建描述、建 session、启动进程在同一入口 | 描述恢复不能进入这个启动入口 |
| WindowLifecycle.swift / WindowDelegateProxy | 清理当前 model 的单个 store | 新结构必须枚举本窗口全部载入空间 |
| Web_StudioApp.swift / StudioApplicationDelegate | 汇总 ResourceStore 终端并等待 shutdownAll | 需纳入空间保存、AI 请求和一次全局关闭意图 |
| AgentController.swift / newChat | 取消请求并清空草稿、选择、预览和历史 | 新问题需保留旧问题，切换不得清空或改写回调目标 |
| ContentView.swift / move；ResourceModel.swift / ResourceSnapshot | 直接更新 groupID；快照只有资源身份 | 改为复制入口；追加实例身份以区分重启后的来源 |

## 状态所有权与调用方向

应用装配拥有一个 WorkspaceRegistry 和持久化端口；窗口拥有 WindowCoordinator，后者强持有自己载入的 WorkspaceSession。Registry 只维护目录及可失效的窗口定位信息，不强持有关闭后的窗口或 session。

每个 WorkspaceSession 强持有一个 ResourceStore、自己的 WorkspaceLayout、常用入口和 AgentController。AgentController 保存独立问题草稿、来源、预览、问题记录及单请求调度状态；取消后的底层请求尚未退出时继续占用请求槽。WorkspaceSaveController 独立观察纯配置投影并弱引用 Session，由 Registry 负责装配和保存状态转发；不复制终端后端或 WKWebView。

PanelCoordinator 归窗口；每次打开捕获 workspaceID/resourceID/paneID。切换空间先处理表单和临时交互，再改变活动引用。旧目标失效只报错/取消，不使用新的 selectedTabID 替代。

运行调用链：原生 View/Commands → StudioModel / WindowCoordinator → WorkspaceSession → ResourceStore / AgentController；保存由 session 的配置投影进入 Repository；加载结果经过纯描述校验再交 session。运行时回调携带空间、资源、实例/请求身份返回原所有者。

源码依赖方向：领域描述不依赖 WebKit/AppKit、Provider 或磁盘路径；session/协调层依赖领域及持久化端口；JSON Repository 实现端口；应用入口装配具体实现。沿用项目当前主线程 UI 隔离，串行持久化工作移出 UI 状态对象；当前 WorkspaceRepository 是 actor；WorkspaceSaveController 在 MainActor 上观察并合并配置变化，通过异步 writer 调用 Repository。

Provider 配置及 Keychain 保留现有持久化权威；设置变更传播给载入空间用于未来请求，已发送请求继续使用冻结配置。设置编辑中的未提交草稿必须由窗口保留或在切换前明确处理。

## 生命周期、并发与故障

| 边界 | 转换与并发规则 | 消费者与核验 |
| --- | --- | --- |
| 打开空间 | 先保留加载候选；成功后占用唯一窗口归属并切换。读取失败保持旧活动空间 | 顶部切换器、侧栏、⌘K；双窗口重复打开测试 |
| 恢复资源 | decode/validate → 待启动描述；不创建 terminal session，不调用 Provider | 启动恢复、搜索；注入启动工厂计数 0，配真实进程观察 |
| 启动资源 | 待启动/已结束 → starting → running/error；连续点击共用启动结果，closing 时拒绝 | 待启动页、终端菜单；并发启动与实例代次测试 |
| 保存 | 脏配置 generation → 串行写入 → 对应 revision 已保存；旧完成回执不能清掉新脏状态 | 资源、布局、名称、入口、网页提交；交错写入/失败注入 |
| 问题 | 每题独立草稿/来源/预览；空间级一个请求槽；迟到回调核对 requestID 和代次 | AI 面板/隐藏状态/历史；延迟 fake provider 与取消测试 |
| 关闭 | 准备关闭 → 保存与确认 → closing → closed/failed；重复调用等待同一任务 | 空间、窗口、应用共用编排；包含隐藏空间和已有关闭任务 |

关闭先采集全部空间影响摘要（空间名、终端数、请求数、临时空间及未保存状态），再获得用户在产品 UI 中的关闭选择。取消发生在不可逆清理之前；保存失败不开始静默终止。清理失败保留可重试状态，释放成功后才注销窗口归属。全局退出只弹一次汇总确认。

配置目录从单空间文件元信息派生。Repository 先校验 schema，再解析内容；未知新版本不能被「加载失败→空配置→自动保存」覆盖。写入到临时文件、完整解码回验、保留上一份有效备份后替换。恢复备份时原损坏文件仍保留。期望 revision 防止旧写入覆盖新版本；Repository 使用每空间文件的非阻塞 flock 和 expectedRevision 校验拒绝忙写入/旧版本覆盖；这不等于多实例共享实时运行状态。

新增 schema 不保存运行状态、输出、AI 数据或密钥。schema 1 字段已由 WorkspaceConfiguration Codable 类型及 fixture 定义；后续新 schema 要有迁移 fixture 与回退检查。系统目录选择器取得的目录不可用时报告错误，不自动改写。

## 原实施分期与单写者（历史）

| 阶段 | 有界实现任务 | 前置条件 | 主要可写范围 |
| --- | --- | --- | --- |
| P0 | IT-P0：交互原型与流程稿 | 当前准备合同就绪 | 本任务 prototype/、P0-FLOWS.md；不改应用 |
| P1 | IT-P1：空间/session/窗口所有权及生命周期 | P0 流程核对通过 | 新 WorkspaceSession.swift、WorkspaceRegistry.swift、WindowCoordinator.swift；ContentView、ResourceModel、WindowLifecycle、Web_StudioApp；相关模型测试 |
| P2 | IT-P2：描述加载、手动启动、Repository 和保存反馈 | P1 所有权稳定 | 新 WorkspaceRepository.swift、WorkspacePersistenceTests.swift；P1 相关文件串行接续 |
| P3 | IT-P3：完整导航、问题记录、来源闭环与窄窗 | P1 + P2（保存反馈） | ContentView、StartPageView、AgentViews、AgentController、ResourceModel、NativeResourceHost、WorkspaceSplitView、ProviderSettings（仅配置传播/草稿协调）及相关测试 |
| P4 | IT-P4：端到端验收与缺陷收敛 | P1–P3 本地检查通过 | 独立验收记录/UI 测试；修复按原任务重新分派 |

每个源码文件同一时刻只有一个写入者。优先由 coder 实现；P1 首版审查后拆成核心和界面两个范围，第二个实现代理因 agent thread limit reached 无法启动，主线程按用户 AGENTS 的委派不可用例外接手界面与产品文档，核心继续由 coder 实现。此时主线程对自己编写部分进行自审，不记独立审查。主线程始终拥有 Spec、架构、状态和交接。模型测试改动跟随对应文件；Xcode 项目配置只在新增文件无法自动发现时修改。Vendor、终端后端、性能脚本和其他 records/output 均不在任务范围。

P0 不是像素验收或原生运行证明；P1 不是持久化完成；P2 不证明真实窗口焦点；P3 不证明真实模型或 SSH 成功。P4 分别报告构建、模型、真实进程、真实 UI、SSH 和 Provider 状态。

## 回退边界与后续验收

后续修改先冻结新的源码基线；原 evidence/baseline.json 是实施前历史，不是当前源码。P1–P3 已实现，剩余工作是完整产品验收和已知测试失败的后续诊断。默认目标仍为 GhosttyKit；VT 和性能路线独立。

本轮保留源码归档以便逐文件比较，不用全仓 reset/clean 回退。代码回退只撤回本任务 diff；新空间配置原件与备份保留，旧版本不读取它们。没有旧内存的磁盘来源，模型样本转换不宣称升级恢复旧活动会话。

原分期交接归档见 [保存与恢复](handoffs/P2-save-integration.md)、[原生管理入口](handoffs/P2-ui-integration.md) 和 [独立问题界面](handoffs/P3-question-ui.md)。schema、调用计数和运行时身份相关检查必须覆盖反例，不能只检查最终 UI 看起来正确。
