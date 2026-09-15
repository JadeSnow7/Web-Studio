# SSH 免密登录修复与实机验收

日期：2026-09-13，Asia/Shanghai。

结论：修正后的独立非沙箱验证应用已两次免密登录用户指定的 `ubuntu@106.54.188.236`。远程命令、Ctrl+C、正常退出和重连通过。远程运行期间的窗口尺寸同步观察到异常，未通过该项验收。默认 App Sandbox 的既有 PTY 限制未解决。

## 修改与审查

`Web Studio/TerminalSession.swift` 的 `startSSH` 不再传入 `-F /dev/null`、`IdentityAgent=none`、`IdentityFile=none`。OpenSSH 可以使用已有用户配置和身份文件；仅 SSH 子进程额外接收父进程非空的 `SSH_AUTH_SOCK`。本地 shell 的环境保持原样，没有整体继承父进程环境。

保留独立传递及校验的 host/user/port、`StrictHostKeyChecking=ask` 和应用指定的 known_hosts 文件。未读取或复制私钥内容，未改变服务器认证配置。既有 SSH 配置中的代理等设置也会重新生效。

实现由 coder 完成，主线程对照修改前工具读取和修改后文件审查了两个修改点。该源文件原本未跟踪，coder 未保存独立修改前快照；没有将整个未跟踪文件误认为本次新增实现。README 同步说明认证行为。

## 构建与测试

- 独立标识：`com.huaodong.Web-Studio.SSHValidation`。
- 应用：`/private/tmp/web-studio-ssh-auth-0913/build/Build/Products/Debug/Web Studio.app`。
- 本地验证构建参数使用 `ENABLE_APP_SANDBOX=NO`；项目 Debug/Release 的默认沙箱设置未修改。
- 为避免丢失旧应用未持久化的网页与 Agent 会话，没有退出或覆盖旧应用。最初退出旧应用的 CUA 操作被自动审批拒绝，随后采用独立标识的测试应用。
- `TerminalTests`：6 项全部通过，约 3.584 秒，xcodebuild 退出码 0。包括中文/ANSI/退出码、真实 PTY 尺寸、Ctrl+C、失败路径及进程清理；这些是本地 PTY 测试，不代表远程尺寸同步通过。
- `git diff --check` 通过。

构建使用既有 `/private/tmp/web-studio-final/SourcePackages` 缓存，命令为：

```sh
xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio' \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/web-studio-ssh-auth-0913/build \
  -clonedSourcePackagesDirPath /private/tmp/web-studio-final/SourcePackages \
  -disableAutomaticPackageResolution \
  PRODUCT_BUNDLE_IDENTIFIER=com.huaodong.Web-Studio.SSHValidation \
  ENABLE_APP_SANDBOX=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  test -only-testing:'Web StudioTests/TerminalTests' -parallel-testing-enabled NO \
  -resultBundlePath /private/tmp/web-studio-ssh-auth-0913/terminal.xcresult
```

## 真实连接证据

1. 系统 SSH 基线使用 BatchMode=yes、StrictHostKeyChecking=yes，返回 `__WS_SSH_BASELINE__` 和 `ubuntu`，退出码 0；没有输入密码。
2. 新应用通过地址栏连接 `ssh://ubuntu@106.54.188.236`，直接出现远程 shell。未出现密码提示。
3. 应用内执行 printf 标记、`id -un`、`tty` 和 `stty size`，分别观察到 `__WS_SSH_GUI__`、`ubuntu`、`/dev/pts/1`、`50 100`。
4. `sleep 30` 被 Ctrl+C 中断，随后输出 `__SSH_AFTER_CTRL_C__`。
5. 调整窗口后再次读取远程 `stty size`，仍为 `50 100`，因此运行期尺寸更新未通过；`exit` 后应用显示 `Exited (0)`。
6. 新建第二次 SSH 连接再次直接登录。隐藏 Agent 扩大可用宽度后读取为 `42 80`，输出 `__SSH_RECONNECTED__`。初始尺寸与第一会话不同，但不能据此认定运行期尺寸更新正常；具体原因未定位。
7. 已关闭第一个退出的测试资源，第二个 SSH shell 保持连接供用户使用。

未单独证明本次登录具体使用默认身份文件还是 ssh-agent，也未测试加密私钥解锁、代理跳转或沙箱分发场景。

## 证据位置

- [系统 SSH 基线](/private/tmp/web-studio-ssh-auth-0913/baseline.log)
- [测试日志](/private/tmp/web-studio-ssh-auth-0913/terminal-tests.log)
- [Xcode 测试结果](/private/tmp/web-studio-ssh-auth-0913/terminal.xcresult)
- [签名权限](/private/tmp/web-studio-ssh-auth-0913/entitlements.plist)
- [源文件 SHA-256](/private/tmp/web-studio-ssh-auth-0913/source-sha256.txt)

GUI 截图和辅助功能树保存在本任务的 CUA 工具记录中。
