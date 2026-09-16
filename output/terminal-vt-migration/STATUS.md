# Terminal VT migration

## Objective

Implement the approved libghostty-vt + CoreText + Metal terminal with matched dark/light themes. Preserve resource-owned sessions, native interaction and explicit bounded Agent snapshots.

## Current state

- M0 complete: fixed source SHA `d4c88d8069912b653d707191388ca98e24751f12`, Zig 0.16.0, 35 headers and reproducible static archive verified.
- M1 integrated: final arm64 Debug and Release builds pass. The independent `Web Studio VT` target uses CoreText and on-demand MTKView; final symbol/framework checks find the VT core and no GhosttyKit/SwiftTerm renderer linkage.
- M2 partial: real Shell, Ctrl-C, copy/paste confirmation, vim/less/top, scrollback, resource hiding, theme switching, splits and isolated shell-based localhost SSH passed the versioned cases in `GUI-20260916.md`. Final-window native scrollbar dragging, selection across appearance, increase contrast, explicit Agent preview and exit code/final-screen retention also passed.
- M2 source includes enhanced keyboard encoding, IME/AX interfaces, original-session foreground/background cleanup, increase contrast, reduced motion and the public nonblinking insertion-indicator preference. Native host, Metal, backend, PTY and sanitizer checks passed at their recorded checkpoints. Synthetic IME checks do not establish real system composition.
- Main independently reran the application suite after a Swift 6.4 protocol-isolation repair: **128 tests in 11 suites passed in 6.777 seconds**. These are the existing `Web StudioTests`, separate from the standalone VT tests.
- M3 not executed: default production target remains GhosttyKit because the acceptance gates below are incomplete. No commit, push, distribution signing or notarization is claimed.

## Environment and evidence boundaries

- The user accepted the Xcode license. Xcode 27 / Swift 6.4 and GUI access work. The official Metal Toolchain was installed to build the legacy comparison target.
- Sandbox cache denial was retried with host build permissions; host GPU permission was required for Metal tests. These failures are recorded separately from code failures.
- Final build: `/private/tmp/web-studio-vt-final/Build/Products/Debug/Web Studio VT.app`; Release is in the sibling Release directory. Bundle: `com.huaodong.Web-Studio.VTFinal20260916`.
- Latest GUI launch included all terminal preference/input/PTY changes. The subsequent shared Agent protocol edit was compiled and unit-tested in refreshed artifacts but that refreshed process was not relaunched for GUI acceptance.
- Strict PTY tests keep an uncooperative leader unreaped until owned foreground/background groups in the original session disappear, then reap it. Immediate child/group ESRCH, one exit callback, natural exit code 7/final output and unrelated-process survival passed. This is not proof of arbitrary descendants that detach into a new session.
- GUI observations and version boundaries are in `GUI-20260916.md`. Real screenshots were inspected in the tool record; standalone GUI PNG archival remains pending. Offscreen renderer PNGs do not replace those screenshots.

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

Dependency builds, unit tests, GUI interaction, SSH fixture checks, appearance screenshots and performance measurements are separate evidence. No commit, push, signing/notarization or external SSH host acceptance is implied.

## Remaining validation and production gate

- Real Chinese system IME preedit, candidates, commit and cancel: automation could not activate the candidate UI; a manual check is pending. The source-level NSTextInputClient contract passes.
- Full VoiceOver, physical keyboard/mouse corner cases, dedicated SSH resource/first-use host-key confirmation and remaining final focus/close scenarios.
- Exact 900×560 layout and actual GUI PNG archival. The only connected display is 2×; 1× is currently an offscreen renderer check.
- Controlled identical-load old/new performance comparison with frame time, input latency, CPU/GPU, memory and visible-idle behavior. Existing exploratory recordings are not a performance acceptance result.
- M3 remains gated by the above. No production default switch or old dependency removal has been made.
- The temporary localhost SSH server is stopped; keys remain outside the repository. No user remote was contacted.

## Integration review requirements

- A separate VT app target must link only the pinned VT archive. Legacy GhosttyKit/SwiftTerm source paths and framework build phases cannot be present in that target. Keep the current app target as the comparison build until acceptance gates pass.
- PTY output feeds the VT state on the transport/session serial domain. Query replies must be drained in that domain; delivery to the main thread uses a coalesced latest owned frame so rapid output cannot enqueue unbounded frame copies.
- The app host remains MainActor-owned. A resource retains its backend and native view across mounting, splitting and appearance changes. A hidden host stops rendering while the backend continues parsing.
- Natural exit publishes a final frame before the exit state. Resource close completes only after owned process cleanup and dispatch-source cancellation; an initialized backend failure must surface an error rather than spawn a second session.
- Standalone adapter and renderer smoke tests must execute the actual Swift/C implementations. A shell input echo is not evidence that a command ran; readiness and completion markers must be generated by the child.
