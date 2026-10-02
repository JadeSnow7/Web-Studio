# 06 构建、测试与脚本

核对日期：2026-09-27，依据当前工作区源码与 `project.pbxproj` 静态阅读，未运行构建或测试。返回[指南首页](README.md)。具体构建命令见 [README](../../README.md#build-and-test)；历史测试结果与适用范围见 [STATUS.md](../../STATUS.md)。

## 1. Xcode 目标

| 目标 | 类型 | Bundle ID | 源码 | 链接 | 关键设置 |
| --- | --- | --- | --- | --- | --- |
| `Web Studio` | App | `com.huaodong.Web-Studio` | 整个 `Web Studio/` | SwiftTerm、`GhosttyKit.xcframework`；`Vendor/ghostty` 作为资源 | 关闭 App Sandbox；默认 MainActor 隔离；approachable concurrency；bridging header；`GHOSTTY_KIT_PATH` |
| `Web Studio VT` | App | `com.huaodong.Web-Studio-VT` | 同一目录 | 仅 `Vendor/GhosttyVT/lib/libghostty-vt.a` 与系统框架 | `WEB_STUDIO_VT` 编译条件（Swift 与 C）；关闭沙盒；仅 arm64；ad-hoc 签名 |
| `Web StudioTests` | 单元测试 | `com.huaodong.Web-StudioTests` | `Web StudioTests/` | 宿主 `Web Studio.app` | VT 代码不在此测试 |
| `Web StudioUITests` | UI 测试 | `com.huaodong.Web-StudioUITests` | `Web StudioUITests/` | 目标 `Web Studio` | — |

项目级：macOS 部署目标 26.5；`GHOSTTY_KIT_PATH = $(PROJECT_DIR)/Vendor`；SwiftTerm 通过 SPM 锁定 exact 1.14.0。

## 2. 测试文件映射

`Web StudioTests/` 全部使用 Swift Testing（`@Test`、`#expect`），约 270 个测试；`Web StudioUITests/` 使用 XCTest，13 个测试方法。下表数字为源码中 `@Test` / `func test` 的出现次数。

| 文件 | 数量 | 覆盖 | 主要测试替身 |
| --- | --- | --- | --- |
| `Web_StudioTests.swift` | 60 | 地址解析、SSH 校验、资源与空间、`ResourceStore` 所有权与关闭、网页运行时、导航策略、命令面板、面板、分栏、原生视图重挂载、常用与最近 | `TestFirstResponderView` |
| `AgentControllerTests.swift` | 14 | `AgentController`：关闭等待、newChat、迟到响应、预览预算、重试、取消、12k 上限 | 多个假 Provider、可控 reader |
| `WorkspaceQuestionTests.swift` | 9 | 多问题：草稿独立、显式确认、单请求槽、取消占槽、读取回到原问题、重试复用冻结请求 | `QuestionReaderGate` |
| `AgentServiceTests.swift` | 10 | `ProviderConfiguration` 校验、Responses 解析、HTTP 错误、重定向拒绝、取消 | `URLProtocol` 桩 |
| `CodexBackendTests.swift` | 7 | `parseJSONL`、后端路由 | 触碰即报错的凭据桩 |
| `CodexProcessRunnerTests.swift` | 11 | 进程双流、超时、忽略 SIGTERM 的子进程、取消、输出上限 | 真实 `/bin/sh` 脚本 |
| `CredentialIntegrationTests.swift` | 1 | 真实 Keychain 读写删除 | `.invalid` 域名 endpoint |
| `ProviderSettingsTests.swift` | 8 | endpoint 隔离、草稿重置、CLI 检查取消 | 独立 UserDefaults suite |
| `ResourceReadTests.swift` | 8 | 有界 Unicode 读取、真实 `WKWebView`、导航中读取、终端与 SSH 元数据 | — |
| `TerminalTests.swift` | 6 | PTY：Unicode/ANSI、退出码、resize、Ctrl-C、回收 | `startForTesting` |
| `GhosttyIntegrationTests.swift` | 4 | Ghostty 会话：argv、resize、重挂载不杀子进程、关闭范围 | `startGhosttyForTesting` |
| `PageChromeTests.swift` | 2 | 顶部取色运行时查找与无窗口截图 | — |
| `WorkspacePersistenceTests.swift` | 14 | `WorkspaceRepository`：往返、schema、备份恢复、revision、文件锁 | 临时根目录、故障注入 |
| `WorkspaceSaveControllerTests.swift` | 10 | 防抖、generation、丢弃、revision | 可控 writer |
| `WorkspaceRestorationTests.swift` | 14 | 打开、关闭、重开、归档、恢复最近空间、并发加载、诊断 | 加载/目录 gate |
| `WorkspaceClosePreparationTests.swift` | 12 | 关闭准备、归档、丢弃 | `WriterProbe` |
| `WorkspaceCopyTests.swift` | 11 | 跨空间复制、revision 冲突 | `CopyGate` |
| `WorkspaceReviewFixTests.swift` | 12 | 跨窗口归档、延迟/被取代的空间操作、重扫合并 | gate |
| `WorkspaceResourceLifecycleTests.swift` | 10 | 只恢复描述、启动/结束幂等、关闭等待、符号链接目录、快照实例 | `closeAndWaitHook` |
| `WorkspaceIntegrationTests.swift` | 10 | 新建/重命名/归档流程、目录默认值 | 临时根目录 |
| `WorkspaceTerminalActionsTests.swift` | 9 | 结束与修复终端、过期捕获、分屏选择 | `closeAndWaitHook` |
| `WorkspaceModelTests.swift` | 8 | 切换空间、运行时归属、分屏选择 | — |
| `WorkspaceOwnershipTests.swift` | 6 | Registry/Coordinator 所有权、关闭幂等、配置推送到所有会话 | — |
| `WorkspaceNavigationTests.swift` | 6 | 搜索、命令面板、选择未载入空间的资源 | `terminalFactoryCreationCount` |
| `WorkspaceLaunchOptionsTests.swift` | 6 | `StudioLaunchOptions`、隔离 suite 与 Keychain service | — |
| `WorkspaceCompactTests.swift` | 4 | 紧凑布局与问答面板偏好 | — |
| `Web_StudioUITests.swift` | 12 | 端到端 UI：命令面板、地址校验、分屏、Agent 读取与设置、起始页、外观、重启后恢复空间 | 始终传入 `--workspace-config-root /tmp/web-studio-ui-<UUID>` |
| `Web_StudioUITestsLaunchTests.swift` | 1 | 启动截图 | — |

没有共享测试辅助文件，各文件自带 `private` 替身。

### 生产代码中的测试缝

| 测试缝 | 位置 | 用途 |
| --- | --- | --- |
| `launchTerminalProcesses: false` | `ResourceStore`、`WorkspaceSession`、`StudioModel` | 登记终端但不启动进程 |
| `terminalFactoryCreationCount` | `ResourceStore` | 断言没有创建终端会话 |
| `closeAndWaitHook` | `ResourceStore` | 在终端关闭中途挂起 |
| `startForTesting` / `startGhosttyForTesting` | `TerminalSession` | SwiftTerm PTY 路径 / Ghostty 生产路径 |
| `saveWriter`、`configurationLoader`、`directoryLoader` | `WorkspaceRegistry` 构造参数 | 替换磁盘读写 |
| `WorkspaceRepositoryFault` | `WorkspaceRepository` | 写入流程故障注入 |
| `reader`、`service` | `AgentController` 构造参数 | 替换资源读取与 Provider |
| `credentials`、`defaults`、`cliChecker` | `ProviderSettings` 构造参数 | 替换 Keychain、UserDefaults、CLI 检查 |

### 改哪里、跑哪些测试

| 改动范围 | 优先运行 |
| --- | --- |
| 工作空间、窗口、关闭 | `Workspace*Tests`（尤其 Ownership、ClosePreparation、Restoration、ReviewFix） |
| 配置 schema 或仓库 | `WorkspacePersistenceTests`、`WorkspaceSaveControllerTests`、`WorkspaceRestorationTests` |
| `ResourceStore`、网页运行时、布局、命令 | `Web_StudioTests`、`ResourceReadTests`、`PageChromeTests`、`WorkspaceModelTests` |
| 默认终端 | `TerminalTests`、`GhosttyIntegrationTests`、`WorkspaceTerminalActionsTests` |
| VT 终端 | `scripts/test-terminal-*.sh`（见下节） |
| Agent 与 Provider | `AgentControllerTests`、`WorkspaceQuestionTests`、`AgentServiceTests`、`CodexBackendTests`、`CodexProcessRunnerTests`、`ProviderSettingsTests` |
| 可见界面与快捷键 | `Web StudioUITests`（需解锁的 GUI 会话） |

只跑单元测试：`xcodebuild … test -only-testing:'Web StudioTests' -parallel-testing-enabled NO`（完整命令见 README）。

## 3. `scripts/` 分类

### Ghostty 构建

| 脚本 | 作用 | 输入 |
| --- | --- | --- |
| `build-ghostty.sh` | 校验 Ghostty v1.3.1 源码与 Zig 0.15.2，构建 xcframework，拷贝到 `Vendor/` 并写入 `web-studio.conf` | `GHOSTTY_SOURCE_DIR`、`ZIG_BIN`、`GHOSTTY_OUTPUT_DIR` 等 |
| `ghostty-build-tools/libtool`、`xcrun` | 构建期 PATH 垫片 | `ZIG_BIN` |

### GhosttyVT

| 脚本 | 作用 |
| --- | --- |
| `build-ghostty-vt.sh` | 按 `DEPENDENCY.lock` 下载校验 Zig 0.16.0、检出锁定 commit、构建 `libghostty-vt`、确定性重打包并校验所有 SHA256 |
| `test-ghostty-vt.sh` + `ghostty-vt-smoke.c` | 检查导出符号并运行 C 烟测 |
| `module.modulemap` | `StudioVTCoreC` 模块定义 |

### 终端烟测（VT 与 PTY）

| 脚本 | 覆盖 |
| --- | --- |
| `test-terminal-vt-core.sh`、`test-terminal-vt-core-asan.sh` | `StudioVTCore.c` 与 `TerminalVTCore`（含 AddressSanitizer 版本） |
| `test-terminal-vt-backend.sh` | PTY + VT 核心 + `GhosttyVTBackend`，配合 `terminal-vt-backend-fixture.c` |
| `test-terminal-metal.sh` | `TerminalMetalRenderer` 像素与图集压力 |
| `test-terminal-vt-host.sh` | 完整 VT 栈（`TerminalVTView`、`TerminalVTSession`） |
| `test-terminal-pty-transport.sh`、`test-terminal-pty-transport-swift.sh` | `StudioPTY.c` 与 `TerminalPTYTransport`，含抗信号与信号掩码 fixture |
| `test-terminal-font-frame-equivalence.sh` | 字体帧内复用候选的像素等价检查 |
| `test-terminal-window-probe.sh` | 只读 AX/窗口几何探针 |
| `test-terminal-unicode-diagnostic.sh` | Unicode 渲染诊断（Release 构建） |

### 性能测量

| 脚本 | 作用 |
| --- | --- |
| `terminal-m2-investigate.py`、`terminal-m2-concurrent.py`、`terminal-m2-matrix.py`、`terminal-m2-memory.py`、`terminal-m2-profile.py` | VT 与旧后端的 M2 配对测量：负载 fixture、进程采样、场景矩阵、内存摘要、`xctrace` 包装；各有 `*-test.py` |
| `terminal-performance-probe*.sh`、`terminal-performance-probe.swift`、`terminal-benchmark.py` | GhosttyKit 离屏探针、场景负载与采样 |
| `app-performance-baseline.py` | 全应用非 UI 采样基线（复用 M2 采样器，校验 PID 与二进制哈希） |

性能计划与结果见 [PERFORMANCE-PLAN.md](../../PERFORMANCE-PLAN.md) 和 [执行进度](../../records/PERF-20260917/task-summary.md)。
