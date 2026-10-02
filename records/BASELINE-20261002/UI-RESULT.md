# Web Studio UI 基线结果 — 2026-10-03

最终被测提交：`6febfff9378c455decc288e89509f8d40e04537f`，分支 `wip/b1-vtperf-20261002`。运行前后工作树为空。
完整复测 xcodebuild 退出 65。13 个测试方法：5 通过、8 失败、0 跳过、0 未运行；testLaunch 在两种 UI 配置下分别执行，因此日志实际记录 14 个实例，6 通过、8 失败。

## 环境与执行边界

- 本机 macOS 26.6.2、arm64，Xcode 27.0（27A266a）；启动前 IOConsoleLocked=false。
- 用户在首次初始化超时后完成 XCTest 授权，并明确要求重试。进程使用基础环境变量白名单，不继承模型/API 凭据。
- 使用原 B3 project、scheme、Debug/macOS arm64、串行测试与 ad-hoc 签名参数；额外参数只使用已有 SwiftPM 缓存、禁止自动依赖更新，并保存独立 xcresult。标准输出/错误直接写日志，退出码取 xcodebuild，不取 tee。
- 未创建 GitHub Actions；未执行真实模型或要求外部 API 的检查。

## 三次实际运行

| 运行 | 被测提交 | 退出码 | 用例结果 |
|---|---|---:|---|
| 首次 | aa32a10 | 65 | runner 初始化超时，13 方法均未运行 |
| 用户授权后重试 | aa32a10 | 65 | 13 方法 3/10；14 实例 4/10 |
| 测试启动与定位修正后 | 6febfff | 65 | 13 方法 5/8；14 实例 6/8 |

首次现代 xcresult summary 把一个 System Failure 计为 1 个失败，但 legacy metrics 显示 testsCount=0；本报告不把系统错误冒充业务用例执行。两轮正常运行的现代 summary 对 testLaunch 两配置去重，故与文本日志的实例数不同。

最终实际命令：

```sh
xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio' -configuration Debug -destination platform=macOS,arch=arm64 -derivedDataPath /private/tmp/ws-phase2 -clonedSourcePackagesDirPath /private/tmp/ws-phase2-source-packages -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -resultBundlePath /Users/huaodong/Documents/Codex/2026-10-02/files-pasted-by-the-user-main/work/web-phase2/ui-6febfff/ui.xcresult CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test '-only-testing:Web StudioUITests' -parallel-testing-enabled NO
```

## 逐用例结果

首错误位置均为 Web StudioUITests/Web_StudioUITests.swift；testLaunch 属于 Web_StudioUITestsLaunchTests。下列“失败”可能是 XCTest 操作失败或业务断言失败。首轮初始化阶段所有行均未运行。

| 测试方法 | 授权后首次 | 最终 | 首错误与位置 |
|---|---|---|---|
| `testAddressValidationKeepsInvalidInputVisible` | 失败 | 失败 | `:128` 输入时 neither element nor any descendant has keyboard focus |
| `testAgentBlankReadAndProviderSettingsFlow` | 失败 | 通过 | — |
| `testAgentComposerDraftSurvivesAdvancedPanelAndNewChat` | 失败 | 失败 | `:222` 输入时 neither element nor any descendant has keyboard focus |
| `testBlankLaunchVerticalResourcesAndNewTab` | 通过 | 通过 | — |
| `testCommandPaletteRowsHaveDistinctBoundedGeometry` | 失败 | 失败 | `:117` 输入时 neither element nor any descendant has keyboard focus |
| `testCommandPanelsKeyboardSubmitEscapeAndClose` | 失败 | 失败 | `:58` 输入时 neither element nor any descendant has keyboard focus |
| `testHiddenSidebarFindsResourceThroughCommandSearch` | 失败 | 失败 | `:77` 输入时 neither element nor any descendant has keyboard focus |
| `testIndependentQuestionKeepsDraftAndPickerReturnsToOriginal` | 失败 | 失败 | `:293` 输入时 neither element nor any descendant has keyboard focus |
| `testMinimumWindowLightAndDarkControls` | 失败 | 失败 | `:241` commands.button.isHittable 为 false |
| `testSavedWorkspaceConfigurationRestoresAfterRelaunch` | 失败 | 失败 | `:284` workspace.selector.label 未满足包含 B1 UI Workspace |
| `testSplitPickersAndClosePanePreserveResources` | 失败 | 通过 | — |
| `testStartPageAddsSessionPinnedDestination` | 通过 | 通过 | — |
| `testLaunch` | 通过 | 通过 | —（两种 UI 配置都通过） |

## 原因分组与已做修正

1. 首轮环境：testmanagerd 请求启用 Automation Mode，系统要求身份认证（Enable UI Automation），60 秒后超时。用户完成授权后，后两轮全部用例能够执行；没有修改权限策略或绕过系统认证。

2. 测试启动/查询问题：授权后首轮七项出现两个窗口同 identifier 的 Multiple matching elements；分屏菜单同时匹配 MenuBar 与窗口工具栏。提交 6febfff 只改两份 UI 测试，增加临时恢复隔离参数、显式 activate、单窗口等待与断言，菜单查询限定到主窗口。最终单窗口断言均通过，重复匹配未再出现，Split 完整通过。观察支持修正有效，但不能单凭一次对照断言两窗口的唯一根因就是系统恢复。

3. 六项键盘焦点失败：Address、Composer、Geometry、CommandPanels、HiddenSidebar、IndependentQuestion 的对应日志段均记录 Codex Window/Dialog 中断，输入对象缺少键盘焦点，部分快照将应用标为 Disabled。环境干扰已经观察到；仍无法证明它解释全部焦点失败，不能认定六项产品功能已通过，也不通过新增 search.click 或删除断言规避。代码中的首次命令搜索聚焦问题只作为待隔离核验的候选，不记作已证实产品缺陷。

4. 窄窗可点击性：Minimum 在浅色分支 commands.button.isHittable 失败，地址栏存在且可命中的先行断言已通过；该用例段没有 Codex 中断记录。环境、布局或测试原因未定；后续暗色分支因本例失败未执行。没有修改产品布局或放宽断言。

5. 工作空间标签：SavedWorkspace 的“已保存”和重启后 resource IDs 恢复断言通过，最终 selector.label 包含名称的断言失败。保存前有 Codex 中断，重启后断言段未记录；实际 label 未被输出，不能据此认定保存/恢复整体失败，也不能认定产品或测试哪一方有误。

现有产品源码未修改，未使用 XCTSkip，未删除或放宽业务断言。B3 停在上述 8 个失败方法的处置决定；后续修复、接受为已知问题或延期由用户确认。B5 合入 main 尚未执行。

## 日志与校验

| 目录 | UTC 开始/结束 | 日志 SHA-256 |
|---|---|---|
| `/Users/huaodong/Documents/Codex/2026-10-02/files-pasted-by-the-user-main/work/web-phase2/ui-aa32a10` | 2026-10-02T16:46:39.547761+00:00 — 2026-10-02T16:48:21.299175+00:00 | `6adc891b1ff5472c07fd463a4ea77e0f9c8553c15e3f511986776c612cca6e07` |
| `/Users/huaodong/Documents/Codex/2026-10-02/files-pasted-by-the-user-main/work/web-phase2/ui-aa32a10-retry` | 2026-10-02T16:54:01.860496+00:00 — 2026-10-02T16:58:08.840821+00:00 | `d8762568a599a70a1ac24c70e746e3a6ebf15e6251fd4c9f652e2f576698c6ea` |
| `/Users/huaodong/Documents/Codex/2026-10-02/files-pasted-by-the-user-main/work/web-phase2/ui-6febfff` | 2026-10-02T17:04:42.710979+00:00 — 2026-10-02T17:16:12.463852+00:00 | `5b4ba8a03ed5c350ca877dfb2c2ffdae13a8c9351fee8a4206fb7b1757184148` |

各目录保存 plan.json、result.json、run.log、ui.xcresult 和 summary.json；首次授权诊断另有 diagnostic.txt。完整日志保存失败和受干扰的历史，不用本轮结果覆盖之前证据。
