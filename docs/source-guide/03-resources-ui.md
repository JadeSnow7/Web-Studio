# 03 资源、网页与界面

核对日期：2026-09-27，依据当前工作区源码静态阅读，未运行构建或测试。返回[指南首页](README.md)。

涉及文件：[ResourceModel.swift](../../Web%20Studio/ResourceModel.swift)、[WebRuntime.swift](../../Web%20Studio/WebRuntime.swift)、[NativeResourceHost.swift](../../Web%20Studio/NativeResourceHost.swift)、[WorkspaceSplitView.swift](../../Web%20Studio/WorkspaceSplitView.swift)、[ContentView.swift](../../Web%20Studio/ContentView.swift)、[StartPageView.swift](../../Web%20Studio/StartPageView.swift)、[StudioDesign.swift](../../Web%20Studio/StudioDesign.swift)。

## 1. 资源模型

| 类型 | 说明 |
| --- | --- |
| `ResourceKind` | `.web`、`.localTerminal`、`.sshTerminal` |
| `ResourceLifecycle` | `idle`、`starting`、`running`、`exited`、`failed`、`interrupted`、`closed` |
| `ResourceLocation` | `web(URL?)`、`localTerminal(directory:)`、`ssh(host:user:port:)` |
| `ResourceRecord` | `id`、`kind`、`groupID`（所属空间）、`title`、`location`、`lifecycle`、`errorMessage`、`readCapabilities`、`customTitle`（用户重命名，优先显示）、`runtimeInstanceID` |
| `ResourceSnapshot` | 有界读取结果，见第 3 节 |

`runtimeInstanceID` 在每次启动终端或创建网页运行时重新生成。界面发起的结束、重启、修复目录等操作会捕获它（`StudioModel.TerminalActionCapture`），避免旧请求作用到重启后的会话。

## 2. `ResourceStore`

每个 `WorkspaceSession` 一个，持有该空间全部资源记录和运行时：

- `records`（`@Published`）与 `order`；`resources` 按顺序返回记录。
- `runtimes`：网页资源的 `WebTabRuntime`，**懒创建**。
- `terminalSessions`：终端资源的 `TerminalSession`，并订阅其状态与当前目录。
- 回调 `onCommit`、`onOpenInNewTab`、`onStateChange`、`onShutdown` 由 `StudioModel.bindSession` 设置。
- `launchTerminalProcesses = false` 时只登记不启动进程，供测试使用。

| API | 行为 |
| --- | --- |
| `restoreDescriptor` / `restoreDescriptors` | 只登记描述，状态 `idle`，不启动任何东西 |
| `registerWeb` | 登记网页；此时不创建 `WKWebView` |
| `registerLocalTerminal` | 校验目录存在（否则 `failed`），创建 `TerminalSession`，按需 `startLocal` |
| `registerSSH` | 创建会话并 `startSSH`，known_hosts 为 `~/.web-studio-known_hosts` |
| `startResource` | 启动已恢复的终端描述，可改用新目录；返回新的实例 ID |
| `runtime(for:)` / `existingRuntime(for:)` | 前者按需创建网页运行时并接回调；后者只查不建 |
| `remove` | 拆除网页运行时、异步关闭终端并移除记录 |
| `endResourceSession` | 等待终端关闭完成（`closeSession` 幂等） |
| `shutdown()` | 单次执行：`onShutdown`（清理 Agent）→ 以 interrupted 关闭全部终端并等待 → 拆除运行时 → 清空记录 |
| `liveTerminalCount` | 启动中或运行中的终端数，用于关闭/退出提示 |

终端状态到记录状态的映射（`terminalStateMapping`）：`starting`/`running`/`interrupted` 一一对应；`failed(msg)` 带错误；SSH 的 `exited(255)` 映射为 `interrupted` 并提示连接失败；其他退出为 `exited`。

## 3. 有界读取 `ResourceStore.read`

默认上限 12,000 字符（调用方只能更小）。Agent 预览再在此之上施加总预算，见 [05](05-agent.md)。

| 资源 | 读取方式 | 截断 |
| --- | --- | --- |
| 终端 | `session.renderedText()`，去尾部空白 | 保留**尾部**；附带 `knownDirectory`、`lifecycle`、`runtimeErrorMessage`；SSH 的 `sourceURL` 为 `ssh://user@host:port` |
| 网页 | 需已有运行时；`WebTabRuntime.readSnapshot` 在 `.defaultClient` 内容世界执行 JS，按 `Intl.Segmenter` 字素计数，5 秒超时 | 保留**头部**；读取期间发生导航则失败 |

读取完成后会再次确认记录仍存在、运行时未被替换，否则返回失败快照。`ResourceSnapshot` 字段：`resourceID`、`collectedAt`、`text`、`isTruncated`、`errorMessage`、`sourceURL`、`title`、`range`、`knownDirectory`、`lifecycle`、`runtimeErrorMessage`、`instanceID`。

## 4. 网页运行时 `WebTabRuntime`

- 配置（`makeConfiguration`）：共享默认网站数据存储；已知主机升级 HTTPS；媒体需用户操作才播放；UA 后缀 `WebStudio/1.0`；开启手势、缩放和 `isInspectable`。
- 状态：KVO 观察 `url`、`title`、`isLoading`、`estimatedProgress`、`canGoBack`、`canGoForward`，写入 `WebNavigationState`；只有值变化时才触发 `onStateChange`。
- 不重复加载：`load(_:)` 在 URL 未变时直接返回；`navigationGeneration` 用来使读取和截图失效。
- 导航策略 `route(for:isLinkActivation:)`：允许 `http`、`https`、`about`、`blob`；`mailto`、`tel`、`sms`、`facetime`、`webcal` 等只在用户点击链接时交给系统打开；其余取消。
- 弹窗：`createWebViewWith` 总返回 nil，允许的 URL 经 `onOpenInNewTab` 在同一空间新建网页资源。
- JS 对话框：`NSAlert` 标题使用来源主机名，页面无法冒充应用；有窗口时以 sheet 显示。文件选择使用 `NSOpenPanel`。
- 网页进程崩溃：状态变为失败，提示网页无响应。

工具栏顶部取色：`PageChromeBackdrop`（StudioDesign.swift）每 900ms 尝试调用 `capturePageChromeSnapshot()`。仅在无错误、未加载、无进行中截图、应用活跃、窗口为 key 时截取顶部最多 120pt、宽 512px 的快照，模糊后置于半透明遮罩下；开启“减少透明度”时清除。`StudioModel.activeWebRuntime` 不会因此创建运行时。

## 5. 布局与分栏

- 模型：`WorkspaceLayout { primary, secondary?, splitRatio }`，面板 `PaneState { id, resourceID?, isFocused }`，归 `WorkspaceSession.layout`，`StudioModel.layout` 只是代理。
- 操作（`StudioModel`）：`selectResource`、`split`、`showResource`、`showResourceOnRight`、`splitWithNewWeb`、`splitWithNewTerminal`、`focusPane`、`focusCurrentPaneContent`、`closePane`、`returnToSinglePane`、`swapPanes`、`setSplitRatio`。
- 规则：一个资源同一时刻只挂在一个面板；选择已显示的资源只会聚焦其面板；关闭面板不关闭资源。
- `WorkspaceSplitView` → `NativeWorkspaceSplit`（`NSViewRepresentable`）：协调器持有一个 `NSSplitView`，每个**面板 ID** 对应一个 `NSHostingView`，只替换其 `rootView`；最小面板宽 180pt；拖动分隔条后异步写回比例；本地鼠标监视器按点击位置聚焦面板。

原生视图不重建的机制：`WKWebView` 归 `WebTabRuntime`，终端视图归 `TerminalSession`。SwiftUI 侧的 `WebViewHost`、`TerminalNativeView` 只调用 `NativeResourceContainer.mount(view)`：已在本容器则直接返回，否则从旧父视图移除后加入并约束四边；拆除时只在视图仍属于本容器时才移除。因此分栏、交换、切换资源不会丢失网页历史、滚动位置或终端进程。

## 6. `StudioModel`：窗口门面

`StudioModel` 是每个窗口一个的 `ObservableObject`，大部分属性代理活动会话：

| 属性 | 来源 |
| --- | --- |
| `session` | 活动 `WorkspaceSession` |
| `groups` | `registry` 中未归档的空间（历史命名 group 即工作空间） |
| `tabs` | `session.resourceStore` 的投影（历史命名 tab 即资源） |
| `layout`、`selectedTabID` | 会话布局；焦点面板的资源 |
| `tabStripVisible`、`agentsVisible`、`pinnedDestinations`、`recentResourceIDs` | 会话字段 |
| `agentController`、`providerSettings`、`panels` | 会话、Registry、窗口协调器 |

窗口本地状态（不持久化）：网页导航状态缓存、提示信息、紧凑模式（宽度 < 1100pt）、地址栏编辑状态、命令面板查询与搜索结果、侧栏宽 220 / Agent 宽 300。

### 地址栏

⌘L 聚焦 AppKit 地址栏（`NativeAddressField`）。`StudioModel.parseAddress` 的规则：

| 输入 | 结果 |
| --- | --- |
| `terminal`、`terminal://`、`terminal://path`、绝对路径、`~`、`~/…` | 本地终端 |
| `ssh://[user@]host[:port]`、`user@host[:port]` | SSH（默认端口 22） |
| 其他 | 网页，缺省补 `https://` |

对网页资源输入网址会在原资源导航；终端和 SSH 目的地、以及在终端资源上输入网址，都会在同一空间新建资源。

### 面板（`PanelCoordinator`，位于 ResourceModel.swift）

面板互斥，打开时捕获目标资源/面板和原第一响应者，关闭时恢复焦点。`panelContent` 实际渲染的面板：`commands`（`CommandPalette`）、`groupEditor`、`resourceEditor`、`providerSettings`、`startEntry`、`agentResources`、`agentPreview`、`agentRunDetails`。`destination` 枚举值仍在但已无入口，见 [07](07-code-reading-notes.md)。

### 命令面板

⌘K 打开。`paletteCommands` = 资源搜索结果（`selectWorkspaceResource`，跨空间搜索配置描述，不启动进程、不读取内容）+ `availableCommands`（当前可执行的 `StudioCommandAction`）。`execute` 先确认捕获的目标仍存在，否则报目标已关闭而不是改用新的当前资源。

### 菜单快捷键（`StudioCommands`）

| 菜单项 | 快捷键 |
| --- | --- |
| 新建网页 / 新建终端 | ⌘T / ⌘⇧T |
| 在文件夹中新建终端… | — |
| 关闭资源（有面板时先关面板） | ⌘W |
| 打开目标…（聚焦地址栏） / 命令面板… | ⌘L / ⌘K |
| 下一个 / 上一个资源 | ⌃Tab / ⌃⇧Tab |
| 资源 1–9（⌘9 为最后一个） | ⌘1…⌘9 |
| 后退 / 前进 / 重新加载或停止 | ⌘[ / ⌘] / ⌘R |
| 分屏 / 聚焦另一面板 / 关闭聚焦面板 / 单面板 / 交换面板 | ⌘⌥\ / ⌘⌥O / ⌘⌥W / ⌘⌥1 / ⌘⌥⇧S |
| 缩小左侧 / 放大左侧 / 重置比例 | ⌘⌥[ / ⌘⌥] / ⌘⌥0 |
| 切换侧边栏 / 切换问答 | ⌘⌥S / ⌘⌥A |

`WindowKeyRouter` 在 `WKWebView` 之前拦截 ⌘L、⌘K 和 Esc（IME 组字时 Esc 放行）。

## 7. `ContentView.swift` 类型地图

| 类型 | 说明 |
| --- | --- |
| `StudioDestination` | 界面层目的地：`blank`、`terminal`、`web`、`ssh` |
| `StudioGroup`、`StudioTab` | 空间与资源的兼容投影 |
| `StudioCommandAction`、`StudioCommand`、`WorkspaceResourceSearchResult` | 命令模型 |
| `StudioModel` | 窗口门面（上文） |
| `StudioLayoutPlan` | 纯函数布局求解：紧凑阈值 1100pt，主区域最小 440，侧栏 96–320，Agent 220–360 |
| `ContentView` | 窗口内容：侧栏 + 内容 + Agent 面板、面板浮层、工具栏；关闭中整体禁用 |
| `WindowKeyRouter` | 快捷键本地监视器 |
| `StudioWindowRoot` | 窗口根视图，持有 `StudioModel` |
| `StudioAddressField`、`AddressTextField`、`NativeAddressField` | 地址栏 |
| `StudioToolbar` | 工作空间选择器、导航、地址栏、命令、诊断、布局菜单、问答开关 |
| `TabStrip`、`ResourceRow`、`SplitResourcePicker` | 侧栏、资源行（右键菜单：重命名、结束会话、左右显示、复制到空间、加入问答）、分屏选择 |
| `GroupEditor`、`ResourceEditor` | 空间与资源编辑表单 |
| `TabContent` | 包装 `WorkspaceSplitView` |
| `TerminalSessionView`、`TerminalStartPlaceholder`、`TerminalNativeView` | 终端外壳、启动/修复目录占位、原生视图挂载 |
| `CommandSearchField`、`CommandPalette` | 命令面板 |
| `WorkspaceDiagnosticsView` | 配置诊断列表（重新扫描、定位文件） |
| `DisconnectedPlaceholder`、`DestinationPopover` | 未使用 |

`StartPageView.swift`：空白网页显示的起始页（新建网页/终端/SSH、常用入口网格、最多 5 个最近资源）和 `StartEntryView`（添加常用入口，复用 `parseAddress`）。

## 8. 设计 token（`StudioDesign`）

| 组 | 值 |
| --- | --- |
| `Spacing` | row 8、control 12、panel 16、inset 20 |
| `Radius` | row 6、panel 10 |
| `Motion` | hover/press 0.12s、selection 0.16s、panel/message 0.18s；开启“减弱动态效果”时无动画 |
| `Color` | 系统语义色：窗口背景、控件背景、强调色低透明度填充、红/橙错误与警告 |

材质修饰符 `studioGlassSurface`、`studioGlassCapsule`、`studioGlassButton`、`studioFieldSurface` 基于 `StudioBackdrop`（`NSVisualEffectView`），“减少透明度”时回退为不透明表面。视觉规范见 [DESIGN.md](../../DESIGN.md)。
