# Terminal VT migration

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
