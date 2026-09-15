# Web Studio implementation and acceptance

Final verification date: 2026-09-12. Source implementation and documentation are delivered in the existing dirty worktree. The six-feature product is not fully accepted: interactive terminals are blocked by retained App Sandbox, final UI execution is blocked by macOS authentication, and real SSH/API connections lack configuration. Build, model tests and actual runtime evidence are separate claims.

## Baseline and scope

The existing dirty worktree was inspected and preserved as the implementation baseline. README, DESIGN, UX contract, source and reference HTML were read first. The HTML supplied design material only. Its browser preview was blocked by URL policy; no workaround was attempted.

Native stack: Xcode 26.6, macOS 26.6.2, SwiftUI/AppKit/WebKit, deployment macOS 26.5 and Swift language version 5. SwiftTerm exact 1.14.0 (`849e8a4f3d6f79ddee07152400137f1370c32621`) is pinned through SPM with its MIT notice retained. No Rust, independent daemon, commit, push, release or system-setting change was introduced.

## Feature status

| Feature | Implementation | Verification boundary |
| --- | --- | --- |
| Unified resources | ResourceStore owns stable IDs, ordered records, groups, web/terminal runtimes and read capabilities. Views hold resource IDs. | Identity, web instance reuse, movement, resource/pane closure and model shutdown tests pass. |
| Vertical navigation and capsules | Horizontal strip removed; groups, names, moves and hidden-sidebar access retained. Native bordered capsule controls and compact pane headers are implemented. | Earlier signed controls build passed manual keyboard/pointer checks. Final visual/keyboard regression is unverified because the UI runner could not initialize. |
| Address and command panels | Distinct Command-L / Command-K surfaces with captured resource/pane, validation and keyboard selection. | Earlier manual checks passed; final captured-pane, closed-target and original-window/fallback tests pass. Final native keyboard regression is blocked. |
| Local and SSH terminal | SwiftTerm native emulator plus app-owned real PTY adapter, launch handshake, I/O, resize and owned cleanup. SSH uses separate argv, explicit host checking and container known_hosts. | **Interactive runtime blocked by retained App Sandbox.** Component/build presence is not accepted as a working terminal. |
| Dual panes | NSSplitView, stable pane IDs, focus, resource picker, divider ratio, swap and separate pane closure. Safe native containers transfer existing views. | Model and native reparenting tests pass. Final simultaneous-display, divider drag and pointer/focus acceptance is blocked. |
| Agent | Explicit selection, bounded previews, immutable requests, Responses client, cancellation/retry, retained source disclosure and native provider configuration. | Transport/controller/settings tests cover selected snapshots, cancellation, late results, errors, retries, read failures and unconfigured state. Real Keychain CRUD passed. Real API and final native interaction are separately unverified. |

## Architecture and data boundaries

- ResourceStore owns runtime lifetime. PaneState and WorkspaceLayout describe mounting, arrangement, ratio and focus. Groups remain organizational; the existing shared WebKit default data store is retained.
- PanelCoordinator allows one primary panel and captures resource, pane, window and focus. Address/SSH input and defined application commands are distinct. Terminal URL entry creates a related web resource; SSH creates a separate terminal resource.
- Reads are explicit, bounded to 12,000 characters per resource and 48,000 per preview. Web reads use an isolated WebKit content world and navigation/URL checks. Terminal reads expose rendered output, known directory and real state; no process-tree inference or raw input capture is claimed.
- AgentRun retains value snapshots and provider configuration. Send does not reread. Retry uses the original request. Source closure does not erase submitted evidence. Resource text is untrusted context, separate from system instructions.
- The Responses request is nonstreaming, sets `store:false`, and registers no tools or implicit history. Endpoint/model preferences are separate from endpoint-bound Keychain secrets. Fake providers and credentials exist only in tests. [Official Responses schema](https://developers.openai.com/api/reference/cli/resources/responses/methods/create).

## Final automated evidence

The primary agent ran and independently inspected the final results. No production source changed after these runs; the final UI test edits only strengthened UI assertions.

| Suite/check | Actual result | Evidence |
| --- | --- | --- |
| Resource/layout/lifecycle/focus and native host | 48 passed | `/private/tmp/web-studio-final-unit.xcresult` |
| Agent Responses transport | 10 passed | Same final unit result |
| Resource reading | 8 passed, including actual WKWebView HTML, navigation and cancellation | Same final unit result |
| Agent controller | 10 passed | Same final unit result |
| Provider settings | 5 passed | Same final unit result |
| Production macOS Keychain CRUD | 1 passed, unique synthetic endpoint-bound test item, deleted afterward | Same final unit result |
| Combined preceding suites | **82 passed, 0 failed, 6 suites** | `/private/tmp/web-studio-final-unit.log`; root xcresult metrics independently read |
| Strict terminal | **6 tests: 3 passed, 3 failed** | `/private/tmp/web-studio-final-terminal.xcresult` |
| Final UI suite | **Runner initialization failed; no UI cases executed** | `/private/tmp/web-studio-final-ui.xcresult` |
| Normal signed application build | Passed | `/private/tmp/web-studio-final-app-build.log` |
| Final UI test compilation | Passed | `/private/tmp/web-studio-final-ui-build.log` |
| Normal application signature/entitlements | `codesign --verify --deep --strict` passed; sandbox retained | `/private/tmp/web-studio-final-signature.log`, `/private/tmp/web-studio-final-entitlements.plist` |
| Strict native ownership audit / whitespace check | 0 findings / `git diff --check` passed | `/private/tmp/web-studio-premium-audit.json` |

The model suite covers resource identity, web instance reuse, group movement, all pane combinations, duplicate mounting, pane/resource closure, shutdown scope, captured command pane, invalid/closed targets, native view reparenting and original-window/fallback focus. The programmatic window-close test no longer crashes.

The transport tests use a URLProtocol-backed HTTP fixture and inspect actual request JSON/authentication headers. They exercise HTTP errors, malformed/refused/empty/incomplete replies, credential validation, redirect rejection and cancellation of delayed transport. Controller tests cover immutable in-flight snapshots, source closure, retry with original context, read failure, aggregate limits, late completion and independent read cancellation. These tests do not call a real model service.

The real Keychain test calls the production implementation with a unique `.invalid` endpoint and a synthetic nonfunctional token. It saves, reads, replaces and deletes only that test item. No unrelated credentials are enumerated or read. Configuration UI and real provider connectivity remain separate unverified items.

Xcode adds temporary test-runner file-read and Mach-service entitlements to its XCTest host. Therefore the final ordinary application was built separately with the normal `build` action. That artifact has only App Sandbox, network client, read-only user-selected files and Debug `get-task-allow`; no temporary test exceptions. This distinction matters when reproducing acceptance.

## Actual native interaction already observed

A signed controls-stage application was launched and inspected through native UI automation before the Mac locked. The following were observed on that build:

- No horizontal tab strip; vertical resource navigation was present.
- Command-L focused address input; typing and Return loaded Example Domain.
- Command-K focused command search; Return on Open Destination kept the replacement address panel visible. Escape returned focus to the webpage.
- Example Domain link navigation to IANA and toolbar Back returned to Example Domain.
- Command-T and Command-1 switched resources while preserving loaded content.
- Custom resource name survived page navigation.
- Closing a captured resource while its address panel remained open caused Return to retain a closed-target error; it did not navigate the surviving resource.
- Command-W closed the primary panel first. With sidebar hidden, Command-T created a resource and Command-K selected an existing resource.
- Minimum native window measured 900×600 including a 40-point toolbar, leaving 900×560 content. Address controls remained reachable.

These observations are **not** final split/Agent/appearance acceptance. Final dark/light, minimum-size split/Agent, terminal input, clipboard/Chinese input, divider drag and post-integration focus behavior remain unverified. The Mac is locked; the user has been asked to unlock it. No lock bypass or system appearance change was attempted.

An earlier XCUITest runner timed out enabling automation. The final runner failed before any test case with `com.apple.LocalAuthentication Code=-4: System authentication is running.` The replacement suite contains six tests and no skips, targeting vertical resource entries, visible and keyboard panel entry, SSH validation, pane closure/hidden-sidebar lookup, Agent preview/settings, and app-only light/dark minimum-window checks. No final screenshots or passing GUI results were produced.

## Confirmed terminal restriction

The signed sandbox host reports `forkpty: login_tty could't make controlling tty`; an actual earlier `stty size` probe reported `stty: TIOCGETD: Operation not permitted`. Startup now validates controlling-TTY acquisition and surfaces failure before presenting a running shell.

Read-only inspection of the current macOS application sandbox profile supports this restriction. App Sandbox, outbound networking and read-only user-selected-file entitlements remain enabled. No private entitlement, expanded file grant or sandbox disablement was used.

A separate C-adapter diagnostic outside App Sandbox executed `/bin/sh`, emitted `PTY_OK`, reported geometry `27 91`, and returned exit code 7. Missing directory/executable returned setup errors. That diagnostic is **not** signed interactive-terminal acceptance. Earlier weak green terminal assertions were rejected and replaced with no-echo/actual-output checks.

The final terminal failures are `shellEmitsUnicodeANSIAndExitCode`, `resizeIsAppliedToRealPTY`, and `interactiveShellRespondsToCtrlCAndContinues`. Failure reporting, immediate close/reap and leaving an unrelated test process running passed. Under the controlling-TTY refusal, invalid-directory/executable tests observe failure but do not isolate later chdir/exec stages. Successful cleanup checks under refused startup do not prove cleanup of a running interactive process group. Real continuous output, Ctrl-C, interactive programs, geometry and running-session cleanup remain blocked/unverified under the required sandbox boundary.

## External and environment blockers

- **Local/SSH interactive terminal:** controlling-terminal operations denied by retained App Sandbox.
- **Remote SSH login and interruption:** no authorized test host/authentication configuration, in addition to the PTY restriction.
- **Real model request:** no user-supplied endpoint/model/key. No unrelated credentials were searched.
- **Configuration UI and final native interaction:** Mac remains locked. Production Keychain CRUD was separately exercised with a unique synthetic test item, in addition to injected settings tests; that does not verify the configuration UI or an API connection.
- **Final appearance and minimum-size interaction:** pending an unlocked native session. No system settings are modified for these checks.

## Final application and delivery

The ordinary signed application is `/private/tmp/web-studio-final-app/Build/Products/Debug/Web Studio.app`. It was launched with `--appearance-light --minimum-window`; the running executable was independently confirmed as PID 53095. This is process-launch evidence, not successful visible interaction through the locked/authenticating macOS session. The application remains available for review.

README, DESIGN, UX-CONTRACT, native UI audit configuration and third-party notice now describe the final implementation and its restrictions. Old horizontal navigation, mixed Shell command input and fake runtime/Agent claims are removed. Existing dirty source and reference images were preserved; no commit, push, release, system-setting change or security bypass was performed. Redundant task-generated temporary build caches were removed after disk exhaustion; source, original changes, logs and result bundles were retained.

Remaining acceptance requires an unlocked macOS session for final native interaction, an approved solution for controlling-TTY operations that retains the chosen security boundary, an authorized SSH test environment, and user-configured model endpoint/model/key. No extra helper, independent service or disabled sandbox was introduced to hide the terminal blocker.
