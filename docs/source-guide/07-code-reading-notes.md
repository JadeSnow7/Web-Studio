# 07 源码阅读笔记

核对日期：2026-09-27。返回[指南首页](README.md)。

本页记录编写指南时在源码中发现的问题：没有调用方的代码、注释与实现不一致的地方，以及容易误解的行为边界。这里只做记录，没有修改源码，也没有运行测试来复现。处理前请先重新核对当前源码。

## 1. 未使用或不可达的代码

| 符号 | 位置 | 情况 |
| --- | --- | --- |
| `DestinationPopover` | ContentView.swift | 定义了但没有地方实例化。它的功能已经由工具栏地址栏取代。 |
| `DisconnectedPlaceholder` | ContentView.swift | 定义了但没有地方实例化。 |
| `PanelCoordinator.Panel.destination`、`PanelCoordinator.openDestination` | ResourceModel.swift | 没有调用方会打开这个面板，`panelContent` 也没有对应分支。`StudioCommandAction.openDestination` 现在改为聚焦地址栏。`isDestinationPresented` 仍被读取，但读到的值恒为 false。 |
| `StudioModel.move(tabID:to:)` | ContentView.swift | 函数体为空。唯一的调用方是一个测试，断言资源**不会**被移动；跨空间操作现在由“复制”承担。 |
| `NativeResourceHost`（结构体） | NativeResourceHost.swift | 没有使用。实际使用的是同一文件中的 `NativeResourceContainer`，以及 `WebViewHost`、`TerminalNativeView` 两个功能相同的 representable。 |
| `ResourceStore.shutdownAll()` | ResourceModel.swift | 没有调用方。退出流程走的是 `WorkspaceRegistry.closeAll` → `WorkspaceSession.close()`。 |
| `GhosttyTerminalRuntime.viewBySurface` | GhosttyTerminalSession.swift | 有写入，没有读取。 |
| `AgentController.readGeneration`、`retireRead()` | AgentController.swift | `readGeneration` 只递增不检查；实际的读取校验用的是按问题记录的 `readGenerations`。`retireRead()` 没有调用方。 |
| `TerminalPTYTransport.swift` | — | 默认目标也会编译这个文件，但在默认目标中没有用到它。 |

## 2. 注释与实现不一致

- `StudioCommandAction` 的文档注释说命令面板和菜单栏读取同一份列表，实际并非如此。菜单栏是 `StudioCommands` 中手写的一份，只有命令面板使用 `StudioCommandAction`。两处的文案也有差异，例如“打开目标…”和“打开目的地…”。
- 菜单中的“单面板”和分栏比例这几项在未分屏时仍然可以点击，而工具栏里的布局菜单会把它们禁用。

## 3. 终端行为边界

- **Ghostty 后端拿不到退出码。** `onChildExit` 总是传入 `nil`，所以 `ResourceStore.terminalStateMapping` 里“SSH 退出码 255 → interrupted”的分支在默认目标中永远不会触发。
- **两个后端构造 SSH 参数的方式不同。** VT 版在主机名前加了 `--`，Ghostty 版没有。Ghostty 版只依靠 `validToken` 拒绝以 `-` 开头的主机名。
- **两个后端的读取范围不同。** 默认后端的 `renderedText()` 只返回可见视口；VT 后端先把快照限制在 64 KiB，再应用 12,000 字符的上限。
- **创建终端会话的代码重复了三处**：`registerLocalTerminal`、`registerSSH` 和 `startResource` 各有一份相同的装配逻辑。

## 4. 生命周期与并发边界

- `ResourceStore.runtime(for:)` 在 SwiftUI 的 body 中被调用（`SplitResourceHost`），会在视图更新期间创建 `WKWebView` 并修改 `@Published` 记录。
- 重复的退出请求：`applicationShouldTerminate` 第二次进入时直接返回 `.terminateLater`，但没有对应的 `reply(toApplicationShouldTerminate:)`。
- 只要有任何单空间关闭或归档还在进行，`WorkspaceRegistry.closeAll` 就会直接返回 `false`，用户看不到任何提示。
- `rescanDirectory` 只会新增或覆盖目录条目。磁盘上已删除的配置文件，要到重启后才会从列表中消失。
- 恢复最近空间后，窗口最初创建的那个空临时空间会一直保留，直到窗口关闭。
- `lastActivatedAt` 属于持久化配置，所以每次切换到命名空间都会触发一次写盘。

## 5. 命名遗留

代码里的 “group” 和 “tab” 是旧命名，分别对应现在的工作空间和资源，例如 `StudioGroup`、`StudioTab`、`selectedTabID`、`TabStrip`、`WebRuntimeStore`（`ResourceStore` 的别名）。阅读时请按这个对应关系理解。
