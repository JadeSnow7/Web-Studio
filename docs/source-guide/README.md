# Web Studio 源码架构指南

核对日期：2026-09-27。本指南依据当前工作区源码静态阅读编写，包括未提交的 B1 改动。编写时没有运行构建、XCTest 或 GUI。实现与验收状态以 [STATUS.md](../../STATUS.md) 为准；产品契约见 [DESIGN.md](../../DESIGN.md) 和 [UX-CONTRACT.md](../../UX-CONTRACT.md)。本指南只回答“代码在哪里、谁持有谁、调用怎样流动、改动后跑什么测试”。

源码引用采用“文件 + 符号名”，不写行号。行号会随重构失效，请用符号搜索定位。

## 阅读顺序

| 章节 | 内容 |
| --- | --- |
| [01 应用、窗口与工作空间](01-app-window-workspace.md) | 启动流程、启动参数、工作空间生命周期、窗口关闭与应用退出 |
| [02 配置持久化](02-persistence.md) | schema、磁盘布局、`WorkspaceRepository`、`WorkspaceSaveController` |
| [03 资源、网页与界面](03-resources-ui.md) | `ResourceStore`、`WebTabRuntime`、分栏布局、`StudioModel`、命令与快捷键、`ContentView.swift` 类型地图 |
| [04 终端](04-terminal.md) | 两个 App 目标、Ghostty 后端、VT 管线、PTY、SSH、Vendor |
| [05 Agent 问答](05-agent.md) | 问题模型、预览预算、请求槽、Responses 与 Codex CLI 后端、凭据 |
| [06 构建、测试与脚本](06-build-test-scripts.md) | Xcode 目标、测试文件映射、测试缝、`scripts/` 分类 |
| [07 源码阅读笔记](07-code-reading-notes.md) | 未使用代码、注释与实现不符处、行为边界 |

B1 的设计取舍与原实施分期见 [B1 架构记录](../../records/WORKSPACE-B1-20260917/ARCHITECTURE.md)（历史记录，本指南不替代它）。

## 技术栈与目标

| 项 | 说明 |
| --- | --- |
| 平台 | macOS 26.5+，arm64；SwiftUI 为主，AppKit 负责窗口、地址栏、分栏、终端视图 |
| 网页 | WebKit `WKWebView`，每个网页资源一个持久实例 |
| 终端（默认目标 `Web Studio`） | GhosttyKit v1.3.1（`Vendor/GhosttyKit.xcframework`），Ghostty 自己管理 PTY、解析和 GPU 渲染 |
| 终端（可选目标 `Web Studio VT`） | libghostty-vt（`Vendor/GhosttyVT`）+ 应用自有 PTY、CoreText 字形、Metal 渲染 |
| SwiftTerm 1.14.0 | 仅通过 `TerminalSession.startForTesting` 在测试中使用，不参与生产渲染 |
| Agent | OpenAI Responses API（`URLSession`）或本机 Codex CLI 子进程 |
| 并发 | App 目标设置 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`：未标注的类型默认在主 actor。`WorkspaceRepository` 与 `KeychainCredentialStore` 是 `actor`；配置类型、`CodexProcessRunner` 等显式 `nonisolated` |
| 沙盒 | 两个 App 目标都关闭 App Sandbox（Ghostty 需要控制终端，Codex CLI 需要子进程） |

## 源码文件速查

所有文件位于 [`Web Studio/`](../../Web%20Studio)。

| 模块 | 文件 | 主要类型 |
| --- | --- | --- |
| 应用装配 | [Web_StudioApp.swift](../../Web%20Studio/Web_StudioApp.swift) | `StudioLaunchOptions`、`StudioApplicationDelegate`、`Web_StudioApp`、`StudioCommands`（菜单） |
| 窗口 | [WindowCoordinator.swift](../../Web%20Studio/WindowCoordinator.swift) | `WindowCoordinator`、`WorkspaceCloseSummary` |
| | [WindowLifecycle.swift](../../Web%20Studio/WindowLifecycle.swift) | `WindowLifecycle`、`LifecycleView`、`WindowDelegateProxy`、关闭确认弹窗函数 |
| 工作空间 | [WorkspaceSession.swift](../../Web%20Studio/WorkspaceSession.swift) | `WorkspaceSession` |
| | [WorkspaceRegistry.swift](../../Web%20Studio/WorkspaceRegistry.swift) | `WorkspaceRegistry`、`WorkspaceDirectoryEntry`、`WorkspaceDiagnostic`、`WorkspaceOpenResult` |
| 持久化 | [WorkspaceConfiguration.swift](../../Web%20Studio/WorkspaceConfiguration.swift) | `WorkspaceConfiguration` 及其子类型、`WorkspaceConfigurationEnvelope` |
| | [WorkspaceRepository.swift](../../Web%20Studio/WorkspaceRepository.swift) | `WorkspaceRepository`（actor）、`WorkspaceRepositoryError` |
| | [WorkspaceSaveController.swift](../../Web%20Studio/WorkspaceSaveController.swift) | `WorkspaceSaveController`、`WorkspaceSaveState` |
| 资源与布局模型 | [ResourceModel.swift](../../Web%20Studio/ResourceModel.swift) | `ResourceStore`、`ResourceRecord`、`ResourceSnapshot`、`WorkspaceLayout`、`PaneState`、`PanelCoordinator` |
| 网页 | [WebRuntime.swift](../../Web%20Studio/WebRuntime.swift) | `WebTabRuntime`、`WebNavigationState`、`WebTabView` |
| 视图挂载与分栏 | [NativeResourceHost.swift](../../Web%20Studio/NativeResourceHost.swift)、[WorkspaceSplitView.swift](../../Web%20Studio/WorkspaceSplitView.swift) | `NativeResourceContainer`、`WorkspaceSplitView` |
| 主界面 | [ContentView.swift](../../Web%20Studio/ContentView.swift)（约 3600 行） | `StudioModel`、`ContentView`、`StudioWindowRoot`、`StudioToolbar`、`TabStrip`、`CommandPalette` 等，见 [03](03-resources-ui.md#7-contentviewswift-类型地图) |
| | [StartPageView.swift](../../Web%20Studio/StartPageView.swift) | `StartPageView`、`StartEntryView` |
| | [StudioDesign.swift](../../Web%20Studio/StudioDesign.swift) | `StudioDesign` token、玻璃材质修饰符、`PageChromeBackdrop` |
| 终端（默认） | [TerminalSession.swift](../../Web%20Studio/TerminalSession.swift)、[GhosttyTerminalSession.swift](../../Web%20Studio/GhosttyTerminalSession.swift) | `TerminalSession`、`GhosttyTerminalRuntime`、`GhosttyTerminalView` |
| 终端（VT） | [TerminalVTSession.swift](../../Web%20Studio/TerminalVTSession.swift)、[TerminalVTBackend.swift](../../Web%20Studio/TerminalVTBackend.swift)、[TerminalVTCore.swift](../../Web%20Studio/TerminalVTCore.swift)、[TerminalVTView.swift](../../Web%20Studio/TerminalVTView.swift)、[TerminalMetalRenderer.swift](../../Web%20Studio/TerminalMetalRenderer.swift)、[TerminalVisuals.swift](../../Web%20Studio/TerminalVisuals.swift) | `TerminalSession`（VT 版）、`GhosttyVTBackend`、`TerminalVTCore`、`TerminalVTView`、`TerminalMetalRenderer` |
| PTY 与 C 代码 | [TerminalPTYTransport.swift](../../Web%20Studio/TerminalPTYTransport.swift)、[StudioPTY.c](../../Web%20Studio/StudioPTY.c)、[StudioVTCore.c](../../Web%20Studio/StudioVTCore.c) | `TerminalPTYTransport`、`studio_pty_*`、`studio_vt_*` |
| Agent | [AgentController.swift](../../Web%20Studio/AgentController.swift)、[AgentService.swift](../../Web%20Studio/AgentService.swift)、[AgentViews.swift](../../Web%20Studio/AgentViews.swift)、[ProviderSettings.swift](../../Web%20Studio/ProviderSettings.swift)、[CodexProcessRunner.swift](../../Web%20Studio/CodexProcessRunner.swift) | `AgentController`、`ConfiguredAgentService`、`URLSessionResponsesProvider`、`CodexCLIProvider`、`ProviderSettings`、`KeychainCredentialStore` |

## 所有权总图

实线为强引用，`weak` 为弱引用。

```text
Web_StudioApp ──@NSApplicationDelegateAdaptor──▶ StudioApplicationDelegate
                                                  └─▶ WorkspaceRegistry（进程内唯一）
                                                       ├─▶ saveControllers[id] ─▶ WorkspaceSaveController ─▶ WorkspaceRepository(actor)
                                                       │                           └─weak─▶ WorkspaceSession
                                                       ├─weak─▶ sessionsByID[id]
                                                       ├─▶ locations[id] ─weak─▶ NSWindow / WindowCoordinator
                                                       └─▶ ProviderSettings（全局共享）

每个窗口：
StudioWindowRoot ─@StateObject─▶ StudioModel
   ├─▶ WindowCoordinator
   │     ├─▶ PanelCoordinator
   │     └─▶ loadedSessions[id] ─▶ WorkspaceSession   ← 会话唯一的长期强持有者
   └─▶ session（当前活动空间）

WorkspaceSession
   ├─▶ ResourceStore ─▶ WebTabRuntime(WKWebView) / TerminalSession(原生视图 + 后端)
   ├─▶ AgentController
   ├─▶ layout: WorkspaceLayout、pinnedDestinations、recentResourceIDs
   └─▶ ProviderSettings（共享实例）

LifecycleView ─▶ WindowDelegateProxy（NSWindow.delegate 为弱引用，由该视图保活）
```

要点：

- Registry 只弱引用会话。会话存活取决于某个 `WindowCoordinator.loadedSessions` 仍持有它。
- 一个会话最多归属一个窗口；一个窗口可载入多个会话，其中一个为活动空间。
- 视图只保存资源 ID。原生视图（`WKWebView`、终端视图）归运行时所有，界面通过 `NativeResourceContainer` 移入移出，不会重建。

## 主要调用方向

```text
SwiftUI View / StudioCommands / WindowKeyRouter
   → StudioModel（窗口级门面：命令、面板、地址栏、布局操作）
      → WindowCoordinator（窗口内会话、关闭）→ WorkspaceRegistry（目录、加载、归档、复制、全局关闭）
      → WorkspaceSession → ResourceStore（资源与运行时）/ AgentController（问答）
配置保存：WorkspaceSession.exportConfiguration → WorkspaceSaveController → WorkspaceRepository（磁盘）
配置加载：WorkspaceRepository.load → WorkspaceSession(configuration:) → ResourceStore.restoreDescriptors（只恢复描述，不启动进程）
运行时回调：WebTabRuntime / TerminalSession → ResourceStore 回调（onCommit、onStateChange 等）→ StudioModel
```
