# 04 终端

核对日期：2026-09-27，依据当前工作区源码静态阅读，未运行构建或测试。返回[指南首页](README.md)。VT 迁移进度见 [迁移状态](../../output/terminal-vt-migration/STATUS.md)，本章只描述代码结构。

## 1. 两个 App 目标与条件编译

两个 App 目标编译同一个 `Web Studio/` 目录（Xcode 同步文件夹，无按文件排除）。由文件内的 `#if WEB_STUDIO_VT` 决定各自编入什么。

| 仅默认目标 `Web Studio`（`!WEB_STUDIO_VT`） | 仅 `Web Studio VT`（`WEB_STUDIO_VT`） | 两者都编译 |
| --- | --- | --- |
| `TerminalSession.swift`、`GhosttyTerminalSession.swift` | `TerminalVTSession.swift`、`TerminalVTBackend.swift`、`TerminalVTCore.swift`、`TerminalVTView.swift`、`TerminalMetalRenderer.swift`、`TerminalVisuals.swift`、`StudioVTCore.c` 的函数体 | `TerminalPTYTransport.swift`（默认目标中未使用）、`StudioPTY.c`、其余所有 App 与界面文件 |

两个 `TerminalSession` 同名、接口一致，`ResourceStore` 只依赖这组公共接口：

- 状态 `State`：`idle`、`starting`、`running`、`exited(Int32?)`、`failed(String)`、`interrupted`
- 属性：`nativeView`、`@Published state`、`knownDirectory`、`snapshotWasTruncated`
- 方法：`startLocal`、`startSSH`、`setKnownDirectory`、`retainSecurityScope`、`send(data:)`、`resize(cols:rows:)`、`renderedText()`、`close(interrupted:)`、`closeAndWait()`

C 代码进入 Swift 的方式：

| 模块 | 方式 |
| --- | --- |
| `StudioPTY` | `Web Studio-Bridging-Header.h` 导入 `StudioPTY.h` |
| `StudioVTCoreC` | [`scripts/module.modulemap`](../../scripts/module.modulemap) 包装 `StudioVTCore.h`，VT 目标把 `scripts` 加入 Swift include 路径 |
| `GhosttyKit` | `Vendor/GhosttyKit.xcframework/macos-arm64/Headers/module.modulemap` |

## 2. 默认目标：Ghostty 后端

| 类型 | 职责 |
| --- | --- |
| `GhosttyTerminalRuntime`（单例 `.shared`） | 持有 `ghostty_app_t` 与配置；注册唤醒、action、剪贴板、surface 关闭等 C 回调；设置 `GHOSTTY_RESOURCES_DIR` 并加载 `ghostty/web-studio.conf` |
| `GhosttyTerminalView` | `NSView` + `NSTextInputClient`，持有 `ghostty_surface_t`，转发键盘、IME、鼠标、滚动、尺寸 |
| `TerminalSession` | 资源侧生命周期；生产路径只使用 Ghostty 视图 |

启动（`TerminalSession.start`）：

- 环境变量：`HOME`、`ZDOTDIR`（等于 HOME）、`PATH=/usr/bin:/bin:/usr/sbin:/sbin`、`LANG=en_US.UTF-8`、`TERM=xterm-256color`；仅当可执行文件为 `/usr/bin/ssh` 且继承了 `SSH_AUTH_SOCK` 时转发它。
- 本地终端：`/bin/zsh`，argv `zsh -il`，工作目录为指定目录或 HOME。
- SSH：`ssh -o StrictHostKeyChecking=ask -o UserKnownHostsFile=~/.web-studio-known_hosts -p <port> [-l user] host`，主机与用户名先经 `validToken` 校验（不以 `-` 开头、无空白、控制字符和斜杠）。
- 命令被 shell 引号拼接后交给 `GhosttyTerminalRuntime.makeView(directory:environment:command:waitAfterCommand:)`；无法创建 surface 时状态为 `failed`。

其他行为：

- 输入：`send(data:)` 通过 `ghostty_surface_binding_action("text:…")` 传递，控制字节保持语义。
- 剪贴板：`web-studio.conf` 设为 `clipboard-read = deny`、`clipboard-write = deny`；只有显式粘贴会弹窗确认；写入仅限纯文本。
- `renderedText()` 只读当前可见视口，不含回滚历史。
- 退出：Ghostty 的登录包装无法给出子进程退出码，`onChildExit` 总传 `nil`，因此 `exited(255)` 相关映射在默认目标中不会触发。
- 关闭：`close()` 请求关闭 surface 并 `forceFree()`，同步触发退出回调并唤醒 `closeAndWait()` 的等待者。

SwiftTerm 与旧的 `PTYProcess`（`forkpty` + 串行队列 + SIGHUP/SIGTERM/350ms 后 SIGKILL）只经由 `startForTesting` 使用；`startGhosttyForTesting` 走生产路径。

## 3. VT 目标：自有前端管线

```text
TerminalVTView（MTKView，主线程）── 键盘/IME/鼠标/粘贴 ──▶ TerminalSession(VT)
      ▲ update(frame)                                            │
      │ VTFrameMailbox（只保留最新帧）                            ▼
TerminalSession.drainFrames ◀── onFrame ── GhosttyVTBackend（transport 串行队列，16ms 合帧）
                                             │ feed / 查询回复 / 按键、焦点、鼠标编码
                              TerminalVTCore（NSLock）──C──▶ StudioVTCore.c ──▶ libghostty-vt.a
                              TerminalPTYTransport ────C──▶ StudioPTY.c（forkpty、进程组信号）
```

| 组件 | 要点 |
| --- | --- |
| `TerminalSession`（VT 版） | 与默认版同接口；SSH 参数在主机前加 `--`，校验更严格（可打印 ASCII，不含引号和空格）；Metal 初始化失败时直接失败；初始网格取视图几何，回退 80×24 |
| `GhosttyVTBackend` | 实现 `TerminalBackend` 协议；在传输队列上把 PTY 输出喂给核心、写回查询回复、16ms 合并帧；不可见时不发布帧 |
| `TerminalVTCore` | 用锁包装 C 句柄；`VTFrame` 含单元格、可见文本、光标、滚动条、颜色、`snapshotTruncated` |
| `StudioVTCore.c` | 创建 Ghostty 终端（开启字素簇模式）、渲染状态、键盘和鼠标编码器；`studio_vt_snapshot` 复制单元格并生成视口文本，上限 65,536 字节 |
| `TerminalPTYTransport` | 串行队列；`studio_pty_spawn_pixels` 启动；输入保留上限 256 KiB；32 KiB 分块读取；50ms 回收计时；关闭时对会话进程组发 SIGHUP/SIGTERM，并以 350ms 间隔升级 SIGKILL；领头进程退出后同样清理整个会话，后台作业不会遗留 |
| `StudioPTY.c` | `forkpty` + close-on-exec 错误管道，错误阶段编码（其中 7 表示无法获得控制终端，通常因沙盒）；`signal_group` 只在进程组全部成员属于预期会话时才发信号 |
| `TerminalVTView` | `MTKView` 按需绘制；Cmd+V 确认后粘贴、Cmd+C 复制、Cmd+A 全选；按住 Shift 绕过鼠标上报以本地选择；可见网格暴露为辅助功能文本区；主题随外观和增强对比度切换 |
| `TerminalMetalRenderer` | 2048 像素字形图集页 + 光栅缓存；内联 shader 源码；最多 3 帧在途 |
| `TerminalVisuals` | `TerminalTheme`（亮/暗、256 色、增强对比度）、`TerminalCursorBlinkPolicy`、`TerminalGeometry`（13pt 等宽单元、内边距） |

VT 代码不在 Xcode 单元测试宿主中（测试宿主是默认目标），由 `scripts/test-terminal-*.sh` 独立编译测试，见 [06](06-build-test-scripts.md)。

## 4. `Vendor/`

| 路径 | 说明 |
| --- | --- |
| `GhosttyKit.xcframework/` | 完整 Ghostty 静态库与头文件（Ghostty v1.3.1，commit `332b2aef…`）。`libghostty-fat.a` 约 132 MB，不随普通提交入库，需用 [`scripts/build-ghostty.sh`](../../scripts/build-ghostty.sh) 本地构建 |
| `ghostty/` | 运行时资源（shell integration、主题、terminfo、`web-studio.conf`），作为文件夹资源拷入 App |
| `GhosttyVT/` | libghostty-vt 静态库与头文件，锁定在 commit `d4c88d80…`、Zig 0.16.0，校验值见 `DEPENDENCY.lock`；说明见 [Vendor/GhosttyVT/README.md](../../Vendor/GhosttyVT/README.md) |

构建设置 `GHOSTTY_KIT_PATH` 默认为 `$(PROJECT_DIR)/Vendor`，应指向**包含** `GhosttyKit.xcframework` 的目录。
