# 终端自动化测试记录

日期：2026-09-13，Asia/Shanghai。

结论：现有非沙箱本地验证应用通过本次原生界面交互检查；当前源码的默认沙箱构建完成，但 TerminalTests 为 3 通过、3 失败，共 10 个断言失败。两种构建的证据不能混用。

## 默认沙箱构建：当前源码

执行命令：

```sh
xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio' \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/web-studio-terminal-0913/build \
  -clonedSourcePackagesDirPath /private/tmp/web-studio-final/SourcePackages \
  -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  test -only-testing:'Web StudioTests/TerminalTests' \
  -parallel-testing-enabled NO \
  -resultBundlePath /private/tmp/web-studio-terminal-0913/sandbox-cached.xcresult
```

构建签名中的 `com.apple.security.app-sandbox` 为 true。测试执行约 53.475 秒，xcodebuild 退出码 65。

| 测试 | 结果 |
| --- | --- |
| shellEmitsUnicodeANSIAndExitCode | 失败，2 个断言 |
| resizeIsAppliedToRealPTY | 失败，4 个断言 |
| interactiveShellRespondsToCtrlCAndContinues | 失败，4 个断言 |
| invalidDirectoryAndExecutableBecomeFailures | 通过，但启动提前失败，未隔离验证 chdir/exec 阶段 |
| immediateCloseAndWaitReapsChild | 通过，限于启动被拒绝的路径 |
| closingOwnedSessionLeavesUnrelatedProcessRunning | 通过，限于启动被拒绝的路径 |

实测错误：`forkpty: login_tty could't make controlling tty`。沙箱内的正常运行、Ctrl+C 和尺寸同步仍未通过。

## 原生界面自动化：现有非沙箱应用

应用：`/private/tmp/web-studio-codex-local/Build/Products/Debug/Web Studio.app`。签名中没有 App Sandbox entitlement；本次没有重建此应用，也没有把这些结果视为当前源码的完整回归结果。

通过 CUA 操作原生 UI，并从实际截图和辅助功能树观察：

| 场景 | 实测结果 |
| --- | --- |
| 新建本地终端 | 显示 Terminal running，出现 shell 提示符 |
| ASCII 命令输入 | printf 标记和 pwd 正常输出 |
| 中文及 ANSI 颜色 | 粘贴 printf 命令后，显示绿色“你好 Web Studio” |
| Ctrl+C | sleep 30 运行约 6 秒后被中断，随后 echo 输出 __AFTER_CTRL_C__ |
| 窗口缩放 | stty size 从 45 89 变为 38 68 |
| 活动会话关闭提示 | Cmd+W 出现 Terminate terminal? 和 Cancel/Terminate |
| 取消关闭 | 会话保留，echo 输出 __CANCEL_PRESERVED__ |
| 显式退出 | exit 7 后状态显示 Exited (7) |
| 关闭运行中的会话 | 专用 shell PID 71020、sleep PID 71434 在关闭前存在；Terminate 后两个 PID 均不存在 |

输入工具限制：CUA typeText 对中文的直接注入未保留中文；paste 报等待剪贴板读取超时，但随后截图确认命令已经进入终端，按 Return 后中文正确显示。因此中文粘贴/输出通过，中文输入法组合输入未验证。

测试创建的两个终端资源已关闭，原有网页和 Agent 会话保留。窗口缩小后已拉回接近原来的大小；未断言像素级恢复。

## 权限与未测范围

- CUA 的界面读取、截图、点击和键盘操作实际可用，本次没有要求用户新增辅助功能或屏幕录制权限。
- 初次受限执行无法下载依赖；使用已有包缓存，并通过执行权限审批运行 Xcode 测试成功进入测试阶段。
- `ps` 在受限执行中被拒绝；通过执行权限审批，仅查询本次创建的两个 PID，完成清理检查。
- 未修改系统隐私权限、项目 App Sandbox 设置或应用源码。无需为这些已完成检查授予完全磁盘访问。
- Web Studio 的 controlling-TTY 拒绝来自应用自身沙箱，增加 Codex 的 UI 权限不能修复此问题；需要另行决定终端运行架构/分发方式。
- 未进行 SSH 登录、真实远程主机认证、中文输入法组合输入、交互式编辑器或完整应用退出清理测试。

## 证据文件

- [沙箱测试日志](/private/tmp/web-studio-terminal-0913/sandbox-cached.log)
- [Xcode 测试结果](/private/tmp/web-studio-terminal-0913/sandbox-cached.xcresult)
- [沙箱构建权限](/private/tmp/web-studio-terminal-0913/sandbox-entitlements.plist)
- [现有 UI 应用权限](/private/tmp/web-studio-terminal-0913/ui-entitlements.plist)
- [关闭前进程](/private/tmp/web-studio-terminal-0913/ui-process-before.txt)
- [关闭后进程](/private/tmp/web-studio-terminal-0913/ui-process-after.json)

原生界面截图和辅助功能树位于本任务的 CUA 工具记录中。

## SSH 后续验证

用户指定 `ubuntu@106.54.188.236` 后，使用同一非沙箱应用连接。首次 ED25519 指纹与本机 `/Users/huaodong/.ssh/known_hosts` 中该主机的已存记录一致，核对后继续认证。实际进入 password 提示，尚未证明登录成功。

第一次会话随后显示 `Connection closed by 106.54.188.236 port 22`、`Exited (255)`；资源切换正常，未观察到整个 UI 卡死，服务端关闭的具体原因未确定。

第二次连接由用户自行输入密码，界面显示两次 `Permission denied, please try again.`，随后显示 `ubuntu@106.54.188.236: Permission denied (publickey,password).`、`Exited (255)`。已确认认证失败，不能仅据客户端提示断定密码错误、账户策略或输入传递的具体原因。未自动重试密码。

当前源码 `TerminalSession.startSSH` 显式使用 `-F /dev/null`、`IdentityAgent=none`、`IdentityFile=none`，因此不复用用户 SSH 配置、agent 或默认身份文件。需要与系统 Terminal 的登录方式对照；普通系统 SSH 使用密钥成功不等于此应用的密码认证应当成功。远程命令、远程 Ctrl+C、远程尺寸和正常退出仍未验收。
