> 2026-09-26 当前导航：M2 仍未完整验收，M3 未执行，默认目标仍为 GhosttyKit。后续 W0/W1 离屏实验和本机测试包已记录在 [性能路线](../../records/PERF-20260917/task-summary.md)，候选未合入生产。本文以下为各自版本的历史检查点，PID、锁屏和等待用户状态不代表当前现场；统一状态见 [STATUS](../../STATUS.md)。

## 2026-09-17 本轮性能调查交付

已完成八个基础场景各六组配对（96个正式App窗口）、四类VT离屏Unicode负载各六轮、独立调用栈和存活分配快照。一个帧内字体复用实验在隔离构建验证，未采用到生产。

[完整报告及证据索引](evidence/performance-investigation-20260916/RESULTS-20260917.md) · [Unicode诊断](evidence/performance-investigation-20260916/UNICODE-DIAGNOSTIC-RESULTS.md) · [预算建议v5](evidence/performance-investigation-20260916/budget-proposal-v5.json)。本轮调查结果已交付，GPU/实际帧时间/输入显示延迟、分配生命周期及精确阻塞时长仍未可靠测得。预算proposed、MET-004 undetermined、M2整体仍in_progress；不代表发布就绪。

原GUI存活，七个二进制hash匹配，主仓库renderer不变，自有App和限时辅助进程已清理；未提交推送/M3/移除依赖/合并部署。以下为保留的历史进度。

## 2026-09-17 并发六组完成，归因继续

要求的八个基础场景（可见/隐藏空闲、ASCII、中文、mixed、滚动、resize、并发）现均有六组新旧配对。并发12个正式窗口及36个含预热负载的实际hash、序列、身份和完成边界均核验通过；App CPU中位VT5.538143秒/旧1.657350秒（约23秒包络，含逐次AX）。独立5秒调用栈再次支持VT重复字体获取为主要候选成本，但不解释全部差值。

[并发结果与限制](evidence/performance-investigation-20260916/CONCURRENT-RESULTS-20260917.md) · [全部重复值](evidence/performance-investigation-20260916/concurrent-results-20260917.json) · [预算v4](evidence/performance-investigation-20260916/budget-proposal-v4.json)。正在补充有界内存快照与VT离屏Unicode诊断；预算保持proposed，整体M2和发布条件未满足。以下为保留的历史进度。

## 2026-09-17 解锁后续跑进度

历史容量对齐后的滚动与 resize 已各完成六组配对。主线程独立核对24个测量窗，滚动 CPU 中位数 VT/旧为0.264733/0.253190秒，resize为0.828831/0.649825秒；均为约20秒App包络，含AX/截图/查询，不代表帧时间。按事先记录的续跑选择保留 matrix-02 第一组并完成第2–6组，原整体中断失败不改写。

[完整交互结果](evidence/performance-investigation-20260916/HISTORY-INTERACTION-RESULTS-20260917.md) · [逐轮证据](evidence/performance-investigation-20260916/history-interaction-results-20260917.json) · [预算建议 v3](evidence/performance-investigation-20260916/budget-proposal-v3.json)。并发试采第一轮预热20输入/200输出及DSR成功，第二轮因输入方就绪竞态失败，工具修正中，正式并发仍0组。预算proposed、M2未完整验收；生产默认旧后端、无提交推送/M3/合并部署。以下检查点为历史记录。

## 2026-09-17 最新性能检查点

已完成无 coverage 输出 36 轮、可见/隐藏空闲 24 轮，以及隔离帧内字体复用 12 轮对照和九幅离屏像素一致检查；两个 5 秒调用栈有效。默认历史保留量不一致被实测发现，已建立可回到第 0 行的独立历史对齐副本。滚动/resize 四轮试采有效，正式六对批次再次因 Mac 锁屏中断；并发真实 App 数据仍未采集。原始失败及部分样本保留，不合并凑足六对。

[完整调查检查点](evidence/performance-investigation-20260916/CHECKPOINT-20260917.md) · [全部重复和配对数据](evidence/performance-investigation-20260916/checkpoint-20260917-data.json) · [修订预算建议](evidence/performance-investigation-20260916/budget-proposal-v2.json)。字体实验未合入生产；默认旧后端、无提交推送/M3/依赖移除/合并部署。预算 proposed，M2完整验收未判定。当前下一依赖是手动解锁及未完成场景/归因，不重复询问已有 IME/VoiceOver 普通朗读回执。以下保留历史内容。

# Terminal VT migration

## 2026-09-16 性能调查最新检查点

已完成无 coverage 的新旧 Release 36 轮输出测量（ASCII/中文/mixed 各六对），CPU 中位数比分别为 1.240/1.374/1.286，write+DSR 回执更早；仅作整体后端比较，不等同呈现或 Unicode 根因。旧冻结 legacy 带 coverage 插桩，原三轮不再作为同配置定量比较依据，历史证据保留。

放大 mixed 负载调用栈支持重复字体获取为候选热点；一个帧内字体复用 patch 只在隔离 worktree，主线程独立版本绑定的 Release 构建和 Metal smoke 通过。未完成 A/B 性能和四 traits/GUI 回归，未采用到生产源码。

Mac 锁屏且自动解锁失败，现场后续采集受阻；空闲只有一个 VT 有效样本，隐藏空闲/匹配距离滚动/连续 resize/并发输入输出六对均未完成。原 GUI 和既有 Apps 保留，已停止自有等待 runner。下一依赖：用户解锁、修正并发测量协议、补齐场景和实验验证。预算 proposed，M2 全部验收未判定。

详情与证据：[性能调查报告](evidence/performance-investigation-20260916/REPORT.md)、[六对完整结果](evidence/performance-investigation-20260916/CLEAN-OUTPUT-RESULTS.md)、[新版候选预算](evidence/performance-investigation-20260916/budget-proposal.json)。主仓库生产默认旧后端，无提交推送/M3/依赖移除/合并部署。

## 2026-09-16 新增人工回执与现场复验

扩展 IME 已由用户确认完成；VoiceOver 终端普通文本朗读已由用户确认正常，字幕文字据用户报告为 `ASCII abc XYZ 0123`。这两项不再重复询问。当前证据目录没有找到对应 VoiceOver 原始字幕截图，本轮消息未附图片；回执明确区分用户确认、用户报告的截图内容、AX 可访问文本与自动接口测试。语音输入另列未判定，疑似网络问题尚无根因证据。

当前 GUI 是旧 Debug PID 21524，哈希与此前记录一致；冻结 Debug / 新旧 Release 五个二进制文件均匹配旧记录，没有把新构建通过迁移为其 GUI 通过。HEAD 和 origin/main 现场核对均为 `ced7edc25bd6ab6434712ce4da0b4bd16afad499`，本轮不提交推送。

精确 900×560 工具栏下方内容区已补亮色双栏、亮色单栏、深色单栏选区/光标 PNG。独立 AX/CG 实测外框900×600、toolbar40、内容split group高560；横向674点终端布局加左侧226点。截图是工具传输尺寸，不当作原生2×像素采集。实际显示2×；其他实际缩放未判定。外观已恢复原“自动”，见 AX 回执。

资源隐藏/恢复后 PID22208 与历史保持；⌘L、⌘K、Escape、点击返回后收到 `VO_INPUT=[FOCUS_RETURN_0123]`，这是普通键盘/焦点实测，不替代 VoiceOver 导航。专属关闭资源 PID4959、5418、5419、5420 在取消后存活，确认后只读检查均不存在；无关终端 PID22208、81191 存活。此为关闭后轮询结果，不声称测量即时回收延迟。

原始证据：`evidence/m2-followup-*`；逐项结果见 [恢复实测结果](evidence/m2-resume-results.md)。剩余 VoiceOver 导航、返回输入与选区朗读已准备持续读取程序等待用户回执，输入不会作为命令执行。隔离性能字体/格距已实测对齐，新旧Release现场同为45×134网格、深色、2×；逐场景数据、trace限制与候选预算统一见 `evidence/performance-normalized-20260916/RESULTS.md`。预算需用户确认，整体 M2 未判定。

以下保留先前检查点的原始范围；与本节冲突的“扩展IME待回执”等描述已被本节结果取代。


## Objective

Implement the approved libghostty-vt + CoreText + Metal terminal with matched dark/light themes. Preserve resource-owned sessions, native interaction and explicit bounded Agent snapshots.

## Current state

- M0 complete: fixed source SHA `d4c88d8069912b653d707191388ca98e24751f12`, Zig 0.16.0, 35 headers and reproducible static archive verified.
- M1 integrated: final arm64 Debug and Release builds pass. The independent `Web Studio VT` target uses CoreText and on-demand MTKView; final symbol/framework checks find the VT core and no GhosttyKit/SwiftTerm renderer linkage.
- M2 partial: real Shell, Ctrl-C, copy/paste confirmation, vim/less/top, scrollback, resource hiding, theme switching, splits and isolated shell-based localhost SSH passed the versioned cases in `GUI-20260916.md`. Final-window native scrollbar dragging, selection across appearance, increase contrast, explicit Agent preview and exit code/final-screen retention also passed.
- M2 source includes enhanced keyboard encoding, IME/AX interfaces, original-session foreground/background cleanup, increase contrast, reduced motion and the public nonblinking insertion-indicator preference. Native host, Metal, backend, PTY and sanitizer checks passed at their recorded checkpoints. Synthetic IME checks do not establish real system composition.
- Main independently reran the application suite after a Swift 6.4 protocol-isolation repair: **128 tests in 11 suites passed in 6.777 seconds**. These are the existing `Web StudioTests`, separate from the standalone VT tests.
- M3 not executed: default production target remains GhosttyKit because the acceptance gates below are incomplete. The stage snapshot was committed and pushed as `2631e149787c6cfd8d9b0903c89995e8cde96083` on `main`; distribution signing and notarization remain unverified.

## Environment and evidence boundaries

- The user accepted the Xcode license. Xcode 27 / Swift 6.4 and GUI access work. The official Metal Toolchain was installed to build the legacy comparison target.
- Sandbox cache denial was retried with host build permissions; host GPU permission was required for Metal tests. These failures are recorded separately from code failures.
- Final build: `/private/tmp/web-studio-vt-final/Build/Products/Debug/Web Studio VT.app`; Release is in the sibling Release directory. Bundle: `com.huaodong.Web-Studio.VTFinal20260916`.
- Latest GUI launch included all terminal preference/input/PTY changes. The subsequent shared Agent protocol edit was compiled and unit-tested in refreshed artifacts but that refreshed process was not relaunched for GUI acceptance.
- Strict PTY tests keep an uncooperative leader unreaped until owned foreground/background groups in the original session disappear, then reap it. Immediate child/group ESRCH, one exit callback, natural exit code 7/final output and unrelated-process survival passed. This is not proof of arbitrary descendants that detach into a new session.
- GUI observations and version boundaries are in `GUI-20260916.md`. Real screenshots were inspected in the tool record; later default-window and SSH PNGs are archived. Exact-size/split appearance PNG archival remains pending. Offscreen renderer PNGs do not replace those screenshots.

## Ownership

- Main agent: architecture, reviews, independent acceptance and this status file.
- Coder: bounded stage implementation, dependency/build scripts, tests and implementation documentation.

## Evidence index

- `evidence/final-checkpoint.json`: source/script/header hashes, final binary hashes and milestone boundary.
- `evidence/final-debug-build.log`, `evidence/final-release-build.log`: refreshed final builds.
- `evidence/final-app-tests.log`: main independent 128-test run.
- `evidence/final-pref-host.log`, `evidence/final-pref-metal.log`: main independent preference/input/AX and rendering tests.

- `evidence/pty-background-main-review.log`: independent host execution of foreground/background immediate PID/group disappearance checks, natural-exit output/code preservation and unrelated-process survival.

- `evidence/input-host-main-review.log`: exact Kitty report-all press/repeat/release bytes, view/session event transitions, IME range/font checks, offset-view AX bounds and wide-cell hit tests. This is a native offscreen host test, not system IME acceptance.

- [GUI checkpoint](GUI-20260916.md): actual unique VT app interactions, version boundaries, restored system preferences and isolated SSH coverage.
- [Acceptance matrix](ACCEPTANCE.md): passed cases and remaining gates.
- [Historical checkpoints](HISTORY.md): earlier builds, failures and superseded environment blocks.
- `evidence/pty-uncooperative-close-final.log`: independently checked strict foreground process cleanup.
- `evidence/pty-startup-signal-pixels-final.log`: startup, inherited signal mask and pixel resize checks.
- `evidence/backend-after-close-final.log`: backend regression after that PTY repair.
- `evidence/corrected-metal-stress.log`: 1,200 distinct visible glyphs in each of two in-flight frames, sampled pixel checks and opacity.
- `evidence/gui-idle-metal-checkpoint.json`: no-input ten-second recording, zero target Metal submissions; window visibility not independently established. Not a controlled load comparison.
- Earlier `before-final-fixes` and `blocked-handoff` evidence names explicitly refer to older versions.

## Acceptance distinctions

Dependency builds, unit tests, GUI interaction, SSH fixture checks, appearance screenshots and performance measurements are separate evidence. Commit/push of the stage snapshot are confirmed separately above; signing/notarization and external SSH host acceptance remain unverified.

## Remaining validation and production gate

- WeChat Input Method: user confirmed normal input in the current default Debug window; submitted screenshot verifies IME_RESULT=[中文] and visible preedit text. This manual case passed. Composition across focus changes, exact minimum content size and splits remain pending; the screenshot does not independently show the candidate/cancel sequence.
- Full VoiceOver, physical keyboard/mouse corner cases and remaining final focus/close scenarios. Dedicated localhost SSH resource/first-use host-key confirmation passed; see current results.
- Exact 900×560 layout and actual GUI PNG archival. The only connected display is 2×; 1× is currently an offscreen renderer check.
- Controlled identical-load old/new performance comparison with frame time, input latency, CPU/GPU, memory and visible-idle behavior. Existing exploratory recordings are not a performance acceptance result.
- M3 remains gated by the above. No production default switch or old dependency removal has been made.
- Both localhost SSH fixtures are stopped. The current dedicated-resource first-use/input/resize/exit cases passed; no user remote was contacted.

## Integration review requirements

- A separate VT app target must link only the pinned VT archive. Legacy GhosttyKit/SwiftTerm source paths and framework build phases cannot be present in that target. Keep the current app target as the comparison build until acceptance gates pass.
- PTY output feeds the VT state on the transport/session serial domain. Query replies must be drained in that domain; delivery to the main thread uses a coalesced latest owned frame so rapid output cannot enqueue unbounded frame copies.
- The app host remains MainActor-owned. A resource retains its backend and native view across mounting, splitting and appearance changes. A hidden host stops rendering while the backend continues parsing.
- Natural exit publishes a final frame before the exit state. Resource close completes only after owned process cleanup and dispatch-source cancellation; an initialized backend failure must surface an error rather than spawn a second session.
- Standalone adapter and renderer smoke tests must execute the actual Swift/C implementations. A shell input echo is not evidence that a command ran; readiness and completion markers must be generated by the child.

## 2026-09-16 acceptance execution contract

The next stage follows the user-approved Veriflow L2 workflow after the Veriflow CI repair. Main owns this summary, [structured state](task-state.json), [append-only log](work-log.md), contracts and final review. Coder owns bounded implementation tasks; skill improvements are recorded, not applied.

The `2631e14` source snapshot is the new starting point. Existing GUI results retain their recorded binary boundaries; they do not automatically validate this source. The minimum 900×560 measurement means content area, consistent with README and DESIGN. Use `--minimum-window` and independently measure actual content size.

Priority: real Chinese IME and window PNGs; full interaction/VoiceOver and lifecycle; dedicated isolated SSH resource and first-use key confirmation; controlled legacy/VT performance baseline. The user will assist with manual IME, VoiceOver or display checks when automation cannot establish them. Unavailable cases remain undetermined. Performance budgets will be proposed only after baseline measurement and require user confirmation before performance acceptance. M3/default backend migration is outside this execution.

## Current execution checkpoint (2026-09-16)

Veriflow PR #3 repair `a4e841f` passed all six remote matrix jobs (push and pull_request, Python 3.11/3.12/3.13). The prerequisite CI task is complete. Skill improvement observations are recorded in its task record; skill source was not changed.

For Web Studio source `2631e14`, main independently rebuilt the isolated VT Debug and both arm64 Release comparison targets, reran the native host smoke and PTY/Swift transport/backend/C adapter ASan checks successfully. Evidence: `evidence/m2-current-*.json`. The first sandbox build failure is retained separately; the host retry succeeded. Swift smoke compilation emitted asynchronous NSLock warnings, so these runs do not establish strict Swift 6 language-mode compliance of the smoke harnesses.

The user has completed the current Debug window manual check with WeChat Input Method and reported normal input. The submitted screenshot and report are archived in `evidence/m2-wechat-ime-user.png` and `.json`; Chinese submission is visibly confirmed. Current Release GUI checks establish Command-K palette, Command-L address selection and explicit click back to terminal with unchanged shell PID; this is not complete focus acceptance. True window captures are archived as `evidence/m2-ime-ready.png` and release-ready JPEGs. Capture transport resizes images; their pixel dimensions do not establish the native 900×560 content size or physical display scaling.

The performance sampling scripts passed nine main-thread tests after review corrections. Data are limited to single-process CPU time and discrete RSS. Default VT grid is 45×98, legacy grid is 47×108 in the current windows: the initial default-configuration observations are exploratory, not a normalized renderer comparison. Frame time, input latency, GPU, other display scale, complete VoiceOver and dedicated SSH GUI acceptance are tracked below. Production default remains unchanged.

The current dedicated SSH resource passed verified first-use fingerprint, input, remote resize (45×98 → 45×134), unchanged PID and Exited (7)/final-output retention. Test services and exact temporary host entry were cleaned up. Current CPU/RSS exploratory values and outstanding conditions are in [M2 current results](M2-CURRENT-RESULTS.md); no performance acceptance is declared.

## 恢复执行记录入口

2026-09-16 后续窗口、人工回执、生命周期、性能可比性和冻结版本回归统一记录于 [恢复实测结果](evidence/m2-resume-results.md)。下文或上述旧结果保留各自版本边界；本轮最新判定以该记录和 task-state.json 为准。
