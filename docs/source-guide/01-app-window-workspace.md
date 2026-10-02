# 01 应用、窗口与工作空间

核对日期：2026-09-27，依据当前工作区源码静态阅读，未运行构建或测试。返回[指南首页](README.md)。

涉及文件：[Web_StudioApp.swift](../../Web%20Studio/Web_StudioApp.swift)、[WindowCoordinator.swift](../../Web%20Studio/WindowCoordinator.swift)、[WindowLifecycle.swift](../../Web%20Studio/WindowLifecycle.swift)、[WorkspaceSession.swift](../../Web%20Studio/WorkspaceSession.swift)、[WorkspaceRegistry.swift](../../Web%20Studio/WorkspaceRegistry.swift)、[ContentView.swift](../../Web%20Studio/ContentView.swift)（`StudioModel`、`StudioWindowRoot`）。

## 1. 核心类型职责

| 类型 | 粒度 | 职责 |
| --- | --- | --- |
| `StudioApplicationDelegate` | 进程 | 解析启动参数，创建唯一的 `WorkspaceRegistry`，处理退出（`applicationShouldTerminate`） |
| `WorkspaceRegistry` | 进程 | 全部工作空间的目录（已载入和仅在磁盘上的）；持有保存控制器；裁决会话归属哪个窗口；加载、归档、复制资源、全局关闭；配置诊断 |
| `WindowCoordinator` | 窗口 | 窗口内已载入的会话（`loadedSessions`）与活动会话；单空间关闭、整窗关闭；加载令牌 |
| `StudioModel` | 窗口 | SwiftUI 视图模型和门面：代理活动会话的字段，承载命令、面板、地址栏、布局操作 |
| `WorkspaceSession` | 工作空间 | 一个空间的运行状态：名称、目录、布局、常用入口、最近资源、面板偏好、`ResourceStore`、`AgentController`；导出/导入配置 |
| `WindowDelegateProxy` | 窗口 | 拦截 `windowShouldClose`，其他委托方法转发给 SwiftUI 原委托 |

## 2. 启动流程

1. `Web_StudioApp`（`@main`）通过 `@NSApplicationDelegateAdaptor` 创建 `StudioApplicationDelegate`。
2. 委托初始化时调用 `StudioLaunchOptions.resolve`，按三种情况创建 `WorkspaceRegistry`：

   | 情况 | 条件 | Provider 偏好 / Keychain | 仓库 |
   | --- | --- | --- | --- |
   | 隔离根目录 | 传入 `--workspace-config-root PATH` | UserDefaults suite 与 Keychain service 为 `com.huaodong.web-studio.provider.<路径 FNV-1a 哈希>`；可用 `--provider-defaults-suite` 覆盖 suite | `WorkspaceRepository(rootURL: PATH)` |
   | XCTest | 检测到 XCTest 环境变量或 `XCTestCase` 类 | 随机 `com.huaodong.web-studio.xctest.<UUID>` | 无，仅内存 |
   | 默认 | 其他 | 标准 UserDefaults、默认 Keychain service | `~/Library/Application Support/Web Studio/Workspaces/` |

3. `WorkspaceRegistry.init` 装配加载闭包，把 `providerSettings.onConfigurationChanged` 接到 `updateProviderConfiguration`（推送到所有已载入会话的 `AgentController`），然后 `providerSettings.loadPersisted()`。
4. 场景：`WindowGroup { StudioWindowRoot(registry:) }`，默认尺寸 1400×860（`--minimum-window` 时 900×560），`.commands { StudioCommands() }`。`ContentView` 另设最小 900×560。
5. 每个窗口的 `StudioWindowRoot` 创建 `@StateObject StudioModel`，通过 `.focusedSceneValue(\.studioModel)` 暴露给菜单命令，并在 `.task` 中调用 `restoreLastActiveWorkspace()`。
6. `StudioModel.init`：创建 `WindowCoordinator` → `registry.create()` 新建名为“临时空间”的临时会话 → `coordinator.open` → 安装回调（`onActivateWindow`、`shouldSelectWorkspace`、`onActiveSessionChanged`）→ 转发 `objectWillChange` → `bindSession` 挂接 `ResourceStore` 回调（`onCommit`、`onOpenInNewTab`、`onStateChange`、`onShutdown`）。
7. 视图进入窗口时，`LifecycleView.viewDidMoveToWindow` 设置 `coordinator.window`（触发 `registry.bindWindow`），设置透明标题栏，并用 `WindowDelegateProxy` 包装原委托。`WindowKeyRouter` 同时安装本地按键监视器。
8. 恢复：`registry.restoreLastActive(in:)` 每个进程只执行一次（仅第一个窗口）。它扫描目录，若当前窗口仍是未改动的空临时空间，则打开 `lastActivatedAt` 最新的非归档命名空间。初始临时空间仍保留在该窗口中。

### 启动参数

| 参数 | 读取位置 | 作用 |
| --- | --- | --- |
| `--workspace-config-root PATH` | `StudioLaunchOptions` | 使用独立配置目录，并隔离 Provider 偏好与 Keychain |
| `--provider-defaults-suite NAME` | `StudioLaunchOptions` | 指定 Provider 偏好的 UserDefaults suite |
| `--appearance-dark` / `--appearance-light` | `Web_StudioApp`（直接读 `ProcessInfo`） | 仅应用内强制外观，dark 优先 |
| `--minimum-window` | `Web_StudioApp` | 默认窗口尺寸 900×560 |

参数值为空或以 `--` 开头时被忽略。源码中其他 `--` 字符串属于 Codex CLI 参数。

## 3. 工作空间生命周期

一个会话只能归属一个窗口。`registry.attach` 拒绝第二个协调器；`WindowCoordinator.open` 和 `registry.openSaved` 发现会话已在其他窗口时，会激活那个窗口并返回 `.locatedExistingWindow`。

`WindowCoordinator` 每次创建、打开、选择、关闭都会递增加载令牌（`issueWorkspaceLoadToken`）；异步加载完成时用 `acceptsWorkspaceLoadToken` 丢弃过期结果。`openSaved` 在 await 前后还会确认活动空间、配置投影和问题未变化。

| 操作 | 调用链 | 说明 |
| --- | --- | --- |
| 新建临时空间 | `StudioModel.createWorkspace` → `prepareWorkspaceSwitch` → `WindowCoordinator.createWorkspace` → `registry.create` | 有保存控制器，但临时空间不保存 |
| 新建命名空间 | `GroupEditor` → `commitWorkspaceEditor` → `createWorkspace(isTemporary: false)` | 创建后立即 `markConfigurationChanged()` 触发首次保存 |
| 临时空间命名 | `registry.rename` → `session.markPersisted()` | 入口：工具栏“命名并保存…”、关闭空间弹窗、窗口/退出时的临时空间确认 |
| 按需加载 | `StudioModel.selectWorkspace` → `coordinator.open`；返回 `.unavailable` 时 → `registry.openSaved` | 等待进行中的资源复制；复用已有加载任务（`loadingTasks`）；记录加载错误、诊断和备份恢复提示；`WorkspaceSession(configuration:)` 只恢复描述 |
| 在未载入空间执行操作 | `StudioModel.performWorkspaceAction` | 加载成功且仍为活动空间后才新建网页/终端；失败或被取代时不会落到其他空间 |
| 切换 | `coordinator.select` → `shouldSelectWorkspace`（`prepareWorkspaceSwitch`）→ `registry.recordActivation` → `onActiveSessionChanged` → `adoptSession` | 临时面板（命令、Agent 资源/预览/详情）自动关闭；表单面板阻止切换；取消地址栏编辑 |
| 归档 | `StudioModel.archiveWorkspace` → `registry.archive` | 已载入：必须是命名空间，先准备关闭并保存，保存失败即取消，成功后 `cleanupPreparedWorkspace`；未载入：直接以 `archived=true` 写盘 |
| 取消归档 | `restoreArchivedWorkspace` → `registry.unarchive` → `selectWorkspace` | 仅对未载入空间 |
| 关闭单个空间 | `StudioModel.closeWorkspace`（弹窗）→ `WindowCoordinator.closeWorkspace` → `registry.prepareSessionClose` → `cleanupWorkspace` | 清理：`registry.beginClosing` →（丢弃时）`discardPendingChanges` → `stopObserving` → `session.close()` → `registry.detach` → `releaseSession`；下一个活动空间取 UUID 字符串最小者 |
| 复制资源到其他空间 | `registry.copyResource` | 已载入目标：内存追加描述；未载入目标：带 `expectedRevision` 写盘，版本冲突报 `WorkspaceCopyError.conflict` |

最后一个空间被归档或关闭后，`StudioModel.reconcileActiveWorkspace` 会为窗口新建临时空间，窗口保持可用。

`WorkspaceSession.close()` 幂等，顺序为：`agentController.shutdownAndWait()` → `agentController.newChat()` → `resourceStore.shutdown()`。

## 4. 窗口关闭与应用退出

### 窗口关闭

`WindowDelegateProxy.windowShouldClose`：

1. 尊重原委托的否决；`closing` 标志防止重入。
2. `coordinator.closeSummary()` 汇总每个已载入空间的名称、运行中终端数、进行中的请求、是否临时。有内容时弹出“关闭此窗口及其工作空间？”。
3. 对每个临时空间调用 `confirmTemporaryWorkspaceClose`，可命名保存、直接关闭或取消。
4. 返回 `false`，在 Task 中执行 `coordinator.closeAll(resolver:)`；成功后调用 `sender.close()`。

`WindowCoordinator.closeAll`：去重 → `isClosing`（界面整体禁用）→ `registry.prepareSessionsClose` → 返回 `nil` 表示取消，恢复界面 → 否则逐个 `cleanupWorkspace` → `isClosed = true`。

### 保存准备（窗口、退出、归档共用）

- `prepareSessionClose` 反复 `controller.saveNow()`。失败时交给 resolver（`makeWorkspaceSaveFailureResolver` 弹窗）：重试、取消或不保存；没有 resolver 时失败即取消。
- `prepareSessionsClose` 对所有会话执行上述步骤，任一取消则整体取消。之后循环直到没有新的未保存改动，再对全部会话 `stopObserving()`，返回需丢弃的 ID 集合。

### 应用退出

`StudioApplicationDelegate.applicationShouldTerminate`：

1. 汇总 `registry.liveSessions`，弹出“退出 Web Studio？”；取消返回 `.terminateCancel`。
2. 逐个确认临时空间。
3. 设置 `terminationInProgress`，Task 中 `await registry.closeAll(resolver:)`，完成后 `reply(toApplicationShouldTerminate:)`；立即返回 `.terminateLater`。

`WorkspaceRegistry.closeAll`：若任一窗口或空间正在关闭，直接返回 `false`；否则所有协调器 `beginClosePreparation()` → `prepareSessionsClose(全部会话)` → 取消时逐个 `cancelClosePreparation()`；成功时每个协调器 `cleanupPreparedWorkspaces`，再关闭无窗口的会话并移除临时目录条目。

### 取消的语义

- 进入清理之前取消，所有会话保持完整运行，`isClosing` 解除。
- 已成功的保存不会回滚；在确认弹窗中命名的临时空间保持已命名、已保存。
- 归档失败会恢复 `archived` 并调用 `cancelClosePreparation()`。
