# Web Studio UI 基线结果 — 2026-10-03 系统终端复测

本轮 13 个测试方法：5 通过、8 失败、0 跳过；14 个执行实例：6 通过、8 失败（`testLaunch` 执行两种配置）。失败方法集合与上一轮相同，但 Minimum 和 Independent 的首个失败点已经改变。8 项按已知问题保留，未修改产品代码、测试断言或等待。

用户说明此次从系统终端运行，Codex 不在前台；原始日志仍记录 XCTest 将 `com.openai.codex` 窗口识别为中断对象，因此不能把本轮认定为已经排除前台干扰。中断记录不等于全部失败的唯一根因。

## 本轮版本与执行结果

- 当前代码基线：`97213ee1f44dc05400aa9083af39487a9be8bf02`，分支 `wip/b1-vtperf-20261002`。用户外部执行没有自动保存 Git HEAD/dirty 快照；日志中的两条新增诊断、源文件行号与该提交对应，分析时工作树干净。本报告的版本关联依据这些记录，不补造运行时 Git 回执。
- 实际入口：用户运行 `./scripts/check.sh --ui`。本轮由助手读取既有产物，没有重跑 UI。
- 环境：xcresult 记录 macOS 26.6.2（25G83）、arm64；UI bundle 起止 UTC `2026-10-03T04:29:00.939Z`—`2026-10-03T04:32:45.411Z`。
- 同一脚本的 build 成功、退出 0；Web StudioTests **283/283 通过、0 失败、0 跳过**，退出 0；UI 退出 **65**。结果分别与 build/unit/UI 的 xcresult 及日志相符。
- UI 编译日志有诊断 teardown 捕获变量后修改的警告（`appearancePassed`、`currentApp`、`testPassed`）；不把编译成功描述为零警告，也未在本次记录任务中改动测试实现。

## 前台中断核对

只统计日志 `== Web StudioUITests ==` 之后的实际测试执行段，排除前面的源码编译提示、Codex 后端单元测试名称和常规 `Check for interrupting elements` 探测。共有 **44 次 `Found ... interrupting element(s)` 事件、45 条 Codex 窗口对象记录**；如日志 3784–3786 行明确记录 `com.openai.codex`。多段随后出现 `No monitors handled UI interruption` / `Did not handle the interruption, but will attempt to continue`，窗口名称为 `ChatGPT`。

Address、Composer、三个命令搜索用例的失败快照均把应用标为 `Disabled`。通过的 AgentBlank、Split、StartPage 也有中断记录，所以不能按“出现过中断”直接判定因果。Minimum 段没有这类中断记录；SavedWorkspace 的五次发生在保存前交互，重启后的最终 label 断言段没有记录。

## 八项已知问题

分类用于分诊；“环境”表示观察到环境干扰，“测试”表示测试假设/前置条件候选，“产品候选”表示有源码或行为线索，均不冒充已证实根因。所有源码行号基于 `97213ee`，错误文件为 `Web StudioUITests/Web_StudioUITests.swift`。

| 用例 | 本轮首错与已通过边界 | 分类及当前判断 | 本例中断事件 |
|---|---|---|---:|
| `testAddressValidationKeepsInvalidInputVisible` | `:128` 地址输入无键盘焦点；尚未验证非法地址保留行为 | **测试**：等待存在后直接输入，没有点击或 ⌘L；UX-CONTRACT:32 保证的是 ⌘L 聚焦，不保证启动即聚焦。同时有环境干扰，不能只归一因 | 3 |
| `testAgentComposerDraftSurvivesAdvancedPanelAndNewChat` | `:222` `agents.question` 输入无焦点；调用过 click | **环境**：已记录中断与 Disabled 快照，因果未定。测试 AX 命中或产品编辑焦点仍待分辨，没有源码证据可直接定性产品缺陷 | 4 |
| `testCommandPaletteRowsHaveDistinctBoundedGeometry` | `:117` `command.search` 输入无焦点；此前几何断言通过 | **产品候选**：命令面板创建后缺少初始聚焦机制，见下节；环境干扰并存 | 4 |
| `testCommandPanelsKeyboardSubmitEscapeAndClose` | `:58` 搜索输入无焦点；此前面板关闭/重开已到达 | **产品候选**：同一初始聚焦机制缺口；环境干扰并存 | 4 |
| `testHiddenSidebarFindsResourceThroughCommandSearch` | `:77` 首次命令搜索输入无焦点 | **产品候选**：同一初始聚焦机制缺口；环境干扰并存 | 3 |
| `testIndependentQuestionKeepsDraftAndPickerReturnsToOriginal` | `:329` 等待含 `first draft` 的菜单项超时；两次输入步骤及新问题清空断言已执行通过，回选后的草稿恢复断言未执行 | **环境**：5 次中断，包括打开 picker；是否导致菜单未展开尚未证明。**测试 / 产品候选待分辨**：AX 菜单展开/查询未核实，或草稿更新/菜单呈现异常。不得沿用上一轮“输入无焦点”的首错 | 5 |
| `testMinimumWindowLightAndDarkControls` | `:256` `workspace.showQuestions` 未出现；`:255` 命令按钮可点本轮已通过 | **测试**：实际 1400×859 pt，未进入预期窄窗；该按钮仅在宽度 <1100 的紧凑分支创建。本轮不能用于判定最小窗布局产品缺陷；暗色分支未执行 | 0 |
| `testSavedWorkspaceConfigurationRestoresAfterRelaunch` | `:313` selector.label 不含 `B1 UI Workspace`；“已保存”、重启后资源 IDs 一致、selector 存在均已通过 | **测试**：实际 label 为 `""`；测试假定原生 Menu 把内部 Text 聚合为 label，源码未显式建立该 AX 契约。产品可访问性候选仍待核实；不能定性配置恢复整体失败 | 5 |

## openCommands 线索核实

源码确认用户提供的机制线索：`Web Studio/ContentView.swift:1339–1348` 先同步设置 `.commands`，随后只在弱引用 `commandSearchField` 及 `field.window` 已存在时调用 `makeFirstResponder`。面板由 `:2110–2114` 的条件视图创建；`CommandSearchField.makeNSView`（`:3334–3344`）仅创建字段并登记弱引用，`updateNSView`（`:3346–3360`）没有激活时的聚焦补偿，销毁时又清空弱引用（`:3362`）。新建/重建面板时存在初始聚焦缺口。

地址栏有对应机制：`:1262–1274` 增加 `addressFocusToken` 并异步聚焦，`:2409–2415` 在视图更新后消费 token 再异步聚焦。`UX-CONTRACT.md:36` 明确要求面板 “place initial focus”。因此三个 command.search 用例列为产品候选有源码和契约依据，不能通过新增测试点击将其直接归为测试问题；本轮仍有环境中断，未做修复前后隔离实验，尚未证明该机制是三个失败的唯一根因。

Independent 的菜单标签另有明确契约：`AgentViews.swift:77` 优先首条 user 消息，否则取 `q.draft`、trim 并截取前 24 字符；未发送的 `first draft` 若正确写入，应显示完整文字。`AgentController.swift:20,50–54,118–120` 连接草稿写入、新建前 persist 与切换加载。代码路径预期保留旧草稿，尚未定位确定缺陷；输入步骤无报错也不等于测试已断言第一次输入值准确。

## 新诊断附件

Minimum 的附件名为 **`failure-window-light`**，原始文件 ID 为 `DE080884-6AA2-4F60-AEFD-0D6A8B028807.png`，2800×1718 px；日志和 AX 树记录窗口 frame `{{14,33},{1400,859}}` pt。图中浅色主窗口、顶部命令按钮及右侧问答面板可见，没有遮住主窗口的外部窗口；右下有浮动头像，但无证据将它归因为本例失败。

本例实际失败是找不到紧凑布局的问答切换按钮。`ContentView.swift:288–292` 以宽度 <1100 切换 compact，`:2582–2594` 仅在 compact 创建 `workspace.showQuestions`；1400 pt 下不创建它符合当前代码。`Web_StudioApp.swift:113,124` 的 `--minimum-window` 只设置 `.defaultSize(900,560)`，`ContentView.swift:2076` 仅限制最小尺寸；测试 launch helper 只验单窗、不验宽度。为何得到 1400 pt 尚未确定，不能写成已证实系统恢复了旧窗。

SavedWorkspace 的日志第 3739 行与文本附件 **`workspace-selector-label-on-failure`** 一致：

```text
workspace.selector actual label on failure:
```

冒号后的 label 是长度 0 的空字符串 `""`，不是 unavailable 标记；查询的 MenuButton 存在。`ContentView.swift:2453–2463` 的 Menu 标签内部有名称和状态两个 Text，没有显式 `.accessibilityLabel`。这份 label 证据不足以确定名称是否持久化/显示正确；资源 ID 恢复通过仅支持该独立断言。

## 证据位置与校验

- 用户原始 UI bundle：`/var/folders/87/gyhx13hs45351j7vwkdrr4sr0000gn/T/web-studio-check-results.yG4QD9/ui.xcresult`；同目录包含 build.xcresult、unit.xcresult。
- 原始日志：`/private/tmp/ws-ui-clean.log`；UI 日志段第 1370–4158 行。
- 保留的日志、summary、逐例详情、导出附件和统计：`/Users/huaodong/Documents/Codex/2026-10-02/files-pasted-by-the-user-main/work/web-phase2/ui-user-97213ee/`。
- 可直接查看的诊断副本：`/Users/huaodong/Documents/Codex/2026-10-02/files-pasted-by-the-user-main/outputs/Web-Studio-UI-20261003/`，含 failure-window-light.png、workspace-selector-label-on-failure.txt、summary.json、log-analysis.json。

| 产物 | SHA-256 |
|---|---|
| ws-ui-clean.log | `410a6ba00dec1220dc494bc91644568927ddf92dafa2110ae5389353553b4f61` |
| UI summary.json（xcresulttool --compact 原始输出） | `22553628c4512864f3bf98a2e8736df128ceebc1b760bb0283d17426cb086733` |
| failure-window-light PNG | `140eb2f547d40cbb540374a2263d06845cc2c252fb444213a62b79d9f363a5f0` |
| workspace-selector-label-on-failure TXT | `56e3dfd84a0f80c85e1f3ea1ea7e7f0aeae42b5f45cda433722114b3fdd18a15` |

用户已授权在本报告提交后，将 main 快进到 `wip/b1-vtperf-20261002` 并推送。这是保留已知失败的基线交付授权，不代表 8 项 UI 问题已修复或完整产品验收通过；本轮仅修改本报告。

---

## 历史记录：此前三次运行（保留当时结论）

以下为上一版记录。其中“最终”“待用户确认”“B5 尚未执行”仅描述当时状态；当前结果和授权以上文为准。

### Web Studio UI 基线结果 — 2026-10-03

最终被测提交：`6febfff9378c455decc288e89509f8d40e04537f`，分支 `wip/b1-vtperf-20261002`。运行前后工作树为空。
完整复测 xcodebuild 退出 65。13 个测试方法：5 通过、8 失败、0 跳过、0 未运行；testLaunch 在两种 UI 配置下分别执行，因此日志实际记录 14 个实例，6 通过、8 失败。

### 环境与执行边界

- 本机 macOS 26.6.2、arm64，Xcode 27.0（27A266a）；启动前 IOConsoleLocked=false。
- 用户在首次初始化超时后完成 XCTest 授权，并明确要求重试。进程使用基础环境变量白名单，不继承模型/API 凭据。
- 使用原 B3 project、scheme、Debug/macOS arm64、串行测试与 ad-hoc 签名参数；额外参数只使用已有 SwiftPM 缓存、禁止自动依赖更新，并保存独立 xcresult。标准输出/错误直接写日志，退出码取 xcodebuild，不取 tee。
- 未创建 GitHub Actions；未执行真实模型或要求外部 API 的检查。

### 三次实际运行

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

### 逐用例结果

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

### 原因分组与已做修正

1. 首轮环境：testmanagerd 请求启用 Automation Mode，系统要求身份认证（Enable UI Automation），60 秒后超时。用户完成授权后，后两轮全部用例能够执行；没有修改权限策略或绕过系统认证。

2. 测试启动/查询问题：授权后首轮七项出现两个窗口同 identifier 的 Multiple matching elements；分屏菜单同时匹配 MenuBar 与窗口工具栏。提交 6febfff 只改两份 UI 测试，增加临时恢复隔离参数、显式 activate、单窗口等待与断言，菜单查询限定到主窗口。最终单窗口断言均通过，重复匹配未再出现，Split 完整通过。观察支持修正有效，但不能单凭一次对照断言两窗口的唯一根因就是系统恢复。

3. 六项键盘焦点失败：Address、Composer、Geometry、CommandPanels、HiddenSidebar、IndependentQuestion 的对应日志段均记录 Codex Window/Dialog 中断，输入对象缺少键盘焦点，部分快照将应用标为 Disabled。环境干扰已经观察到；仍无法证明它解释全部焦点失败，不能认定六项产品功能已通过，也不通过新增 search.click 或删除断言规避。代码中的首次命令搜索聚焦问题只作为待隔离核验的候选，不记作已证实产品缺陷。

4. 窄窗可点击性：Minimum 在浅色分支 commands.button.isHittable 失败，地址栏存在且可命中的先行断言已通过；该用例段没有 Codex 中断记录。环境、布局或测试原因未定；后续暗色分支因本例失败未执行。没有修改产品布局或放宽断言。

5. 工作空间标签：SavedWorkspace 的“已保存”和重启后 resource IDs 恢复断言通过，最终 selector.label 包含名称的断言失败。保存前有 Codex 中断，重启后断言段未记录；实际 label 未被输出，不能据此认定保存/恢复整体失败，也不能认定产品或测试哪一方有误。

现有产品源码未修改，未使用 XCTSkip，未删除或放宽业务断言。B3 停在上述 8 个失败方法的处置决定；后续修复、接受为已知问题或延期由用户确认。B5 合入 main 尚未执行。

### 日志与校验

| 目录 | UTC 开始/结束 | 日志 SHA-256 |
|---|---|---|
| `/Users/huaodong/Documents/Codex/2026-10-02/files-pasted-by-the-user-main/work/web-phase2/ui-aa32a10` | 2026-10-02T16:46:39.547761+00:00 — 2026-10-02T16:48:21.299175+00:00 | `6adc891b1ff5472c07fd463a4ea77e0f9c8553c15e3f511986776c612cca6e07` |
| `/Users/huaodong/Documents/Codex/2026-10-02/files-pasted-by-the-user-main/work/web-phase2/ui-aa32a10-retry` | 2026-10-02T16:54:01.860496+00:00 — 2026-10-02T16:58:08.840821+00:00 | `d8762568a599a70a1ac24c70e746e3a6ebf15e6251fd4c9f652e2f576698c6ea` |
| `/Users/huaodong/Documents/Codex/2026-10-02/files-pasted-by-the-user-main/work/web-phase2/ui-6febfff` | 2026-10-02T17:04:42.710979+00:00 — 2026-10-02T17:16:12.463852+00:00 | `5b4ba8a03ed5c350ca877dfb2c2ffdae13a8c9351fee8a4206fb7b1757184148` |

各目录保存 plan.json、result.json、run.log、ui.xcresult 和 summary.json；首次授权诊断另有 diagnostic.txt。完整日志保存失败和受干扰的历史，不用本轮结果覆盖之前证据。
