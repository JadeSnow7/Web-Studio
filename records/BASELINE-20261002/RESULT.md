# Web Studio 基线验证记录 — 2026-10-02

被测提交：`c76ccd2adf8c34f67e952c0dbd013685fc1dc841`（A5 五组基线提交完成点）。
分支：`wip/b1-vtperf-20261002`。本报告提交不属于被测源码提交。
执行时间（Asia/Shanghai）：`2026-10-02T22:28:10.452412+08:00` 至 `2026-10-02T22:29:11.496787+08:00`。

编译与链接完成，已运行指定单元测试；测试命令失败。单次运行共 283 项：282 通过、1 失败、0 跳过。未修复、未重跑；未运行 UI 测试。

## 环境

- 平台：`Darwin 25.6.0 arm64`。
- Xcode：Xcode 27.0；Build version 27A266a。
- Swift：swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)；Target: arm64-apple-macosx26.0。
- 本次使用现有 Ghostty 库及锁定依赖；未安装、升级依赖或重建 Ghostty。

## 实际命令及范围

```sh
/usr/bin/xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio' -configuration Debug -destination platform=macOS,arch=arm64 -derivedDataPath /private/tmp/ws-phase1 -clonedSourcePackagesDirPath /private/tmp/ws-phase1-source-packages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -resultBundlePath /private/tmp/ws-phase1-unit.xcresult CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test '-only-testing:Web StudioTests' -parallel-testing-enabled NO
```

工作目录为仓库根目录。标准输出与标准错误完整写入 `/private/tmp/ws-phase1-unit.log`；退出码直接取自 xcodebuild 进程，不取日志转存命令的退出码。
相对原命令新增三个锁包参数，禁止解析到锁文件以外版本并跳过远端更新；`-clonedSourcePackagesDirPath` 使用既有缓存的独立副本，`-resultBundlePath` 固定测试结果位置。未宣称完全断网。
既有缓存来自 `~/Library/Developer/Xcode/DerivedData/Web_Studio-bxwowkmqklofdzgstaupxspltknl/SourcePackages`，复制到 `/private/tmp/ws-phase1-source-packages`。
复制前缓存含 681 个普通文件、23214632 字节及 2 个符号链接；副本逐项摘要校验一致。
- SwiftTerm：1.14.0，`849e8a4f3d6f79ddee07152400137f1370c32621`。
- swift-argument-parser：1.8.2，`6a52f3251125d74daf04fcbd5e6f08a75d074382`。
测试范围仅 `Web StudioTests`；`Web StudioUITests` 未运行。测试进程未继承真实模型/API 凭据变量；测试中的临时文件、PTY、隔离 preferences 及随机测试 endpoint 的 Keychain CRUD 属于现有测试行为。

## 结果

| xcodebuild 退出码 | 总数 | 通过 | 失败 | 跳过 | 预期失败 |
|---:|---:|---:|---:|---:|---:|
| 65 | 283 | 282 | 1 | 0 | 0 |

计数来源：`xcrun xcresulttool get test-results summary --path /private/tmp/ws-phase1-unit.xcresult --compact`。未获得的计数不记为通过；日志中的 XCTest 计数不替代 Swift Testing 总数。

失败用例：
- `interactiveShellRespondsToCtrlCAndContinues()`：Expectation failed: await waitFor { String(data: terminal.renderedSnapshot(), encoding: .utf8)?.contains("__AFTER_INT__") == true }
- 实际日志第 3000 行报告 `TerminalTests.swift:56:9`（仓库路径 `Web StudioTests/TerminalTests.swift:56`）。此处只记录失败断言，未诊断或推断根因。

构建/启动诊断：
- 日志第 3457 行：`** TEST FAILED **`

## 文件完整性与日志

运行前后全部已跟踪文件摘要一致、237 个批准候选文件摘要一致，工作树及暂存区为空；未改源码、格式、锁文件或失败测试。
- 完整日志：`/private/tmp/ws-phase1-unit.log`，405330 字节。
- 日志 SHA-256：`8177db5b34102978b0217693cc86114b6dfbd4c257302f857502fa449bed4650`。
- 仓库外日志副本、实际执行计划、版本、结果 JSON、源文件摘要、敏感扫描及 xcresult 摘要：`~/Backups/phase1-20261002/Web Studio/commit-review-20261002/tests/`。
- 日志敏感扫描未发现未处理命中；完整暂存报告在提交前另行扫描。


## 指定用例复跑计数 — 2026-10-02

`interactiveShellRespondsToCtrlCAndContinues()`，串行 10 次：通过 10 次，失败 0 次，未运行或未能确认执行 0 次。
