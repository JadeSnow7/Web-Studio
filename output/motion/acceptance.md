# Quiet motion acceptance

Date: 2026-09-13.

Scope: the approved restrained motion treatment, including the left task and resource labels. Existing working-tree changes are preserved. The before-change snapshots for the six owned source/design files are in `/private/tmp/web-studio-motion-before`.

## Implemented

- Left task and resource buttons have 120 ms hover and press feedback. Resource selection uses a 160 ms animated accent marker; task selection uses a quiet neutral fill.
- Shared motion tokens cover hover, press, selection, panel presentation, and message insertion. Reduce Motion suppresses spatial motion while retaining state feedback.
- Command and form panels use a local 180 ms entrance/exit treatment. Command search now keeps one native `NSTextField` mounted, with synchronous focus transfer and explicit query/selection reset. Other forms retain their captured presentation identity and generation guards. The exercised native command-input paths passed after the Mac was unlocked.
- Start-page actions have subtle hover lift. The title has a static, low-opacity radial glow whose bounds do not affect layout.
- Agent message insertion has an opacity/4 pt reveal, and the shared send/stop control retains a fixed footprint.
- The separate interactive concept now includes left-label hover and press feedback in addition to its selection motion.

## Verification

Current status: implementation, source review, build, unit/model regression checks, and the scoped manual native GUI checks below are complete. The user unlocked the Mac, and native acceptance resumed. The final App is open at `/private/tmp/web-studio-adaptive/Build/Products/Debug/Web Studio.app`, with two empty tabs available to try the selection feedback.

The user-requested coder subagent implemented the native changes. The primary agent reviewed the implementation, and a separate read-only agent checked native target integration and the command input lifecycle. The final six-file source/design fingerprints match `source-sha256.json`; `changes.patch` records the complete scoped diff and `app-followup.patch` records this follow-up against the previous reviewed snapshot. Existing working-tree changes were preserved.

This follow-up also connects the left-side new-task, new-tab, and new-terminal buttons to the shared hover/press style. Their labels use the full 24×24 feedback area. Source review corrected hidden command-input focus handling, inactive command execution, selection reset after clearing search, and top alignment of other forms beside the retained command panel.

Native acceptance exposed two further issues that were fixed and rechecked: command rows used positional scroll identities and displayed stale titles after filtering; they now use stable command IDs for rendering, scrolling, and click resolution. Returning from command search to a native address field retained the shared field editor rather than its owner; the captured responder now resolves to the owning `NSTextField`.

| Check | Result | Evidence |
| --- | --- | --- |
| Final macOS Debug build-for-testing | Passed | `build-app.log`: TEST BUILD SUCCEEDED |
| Final unit/model tests | 94 tests in 5 suites passed | `unit-app.log`: 2.385 seconds, TEST EXECUTE SUCCEEDED |
| Strict design audit | Zero findings | `design-app-audit.json` |
| Design lint | Zero errors; one inherited `nativeRadii` export-schema warning | `design-app-lint.json` |
| Whitespace check | Passed | `git diff --check` |
| Selected native XCTest UI cases from the preceding implementation | Did not execute | `ui.log`: runner initialization timed out while enabling automation mode |
| Scoped native GUI checks | Passed manually after unlock | Native CUA observations detailed below |

The selected unit suites were Web_StudioTests, AgentServiceTests, ResourceReadTests, AgentControllerTests, and ProviderSettingsTests. The XCTest compatibility wrapper reports zero tests; the Swift Testing result correctly reports the 94 executed tests. Terminal and credential integration suites were not part of this check.

## Native GUI acceptance after unlock

- First-open Cmd-K followed immediately by typing preserved the complete query. Repeated Escape→Cmd-K→typing with distinct queries (`New`, `New Tab`, `Toggle Agents`, `Toggle Tab Strip`) preserved input; repeated Cmd-K while open retained the query.
- Filtering `New` displayed New Tab, New Terminal, and New Task Group. Filtering `Toggle Agents` displayed that command alone. This was verified after the stable-row-identity correction.
- After moving the selected result down twice, Clear reset the query and selection; Return created a new tab rather than running the formerly selected command.
- Switching directly from commands to Agent Preview removed the hidden search field from accessibility and returned focus to the window. Clicking the Agent editor then accepted a Chinese test draft. Closing commands restored that editor and a subsequent `A` appended to the draft.
- Closing commands while editing an address restored focus to the native address field, and a following character was received there. The native field selected its text on refocus; exact caret/selection restoration is not claimed. The test address was never submitted and was cleared afterward.
- Left resource selection followed clicks; closing the selected resource selected its neighbor. New task group opened its editor; Cancel and switching back to Workspace restored the group's resources. The short group editor remained aligned at the top, with its surface and focused field intact.
- The final rebuilt App was rechecked for address focus, filtered command titles, quick-reopen input, Return creating a new tab, and resource selection. Its start-page glow and two-tab selection state were inspected visually. Test drafts were cleared.

No terminal/SSH process or provider request was needed for these UI checks. Native screenshots were inspected in CUA, not stored as files. Timing and hover/press curves are established by the implementation; screenshots and interaction checks are not frame-time measurements.

## Earlier supporting native checks

Earlier native CUA checks supplemented the unavailable UI test runner:

- Resource selection followed clicks across three empty tabs. Closing the selected middle resource removed that resource and selected its neighbor; the close target remained separate.
- Earlier quick-reopen checks sometimes retained `New Tab` input, but repeated checks later exposed dropped characters. Those results are superseded by the retained native input and post-unlock checks above.
- An Agent test draft survived opening resources and preview, selecting the blank resource, and reading the preview's real `Page is unavailable.` error.
- Opening provider settings replaced preview and focused the endpoint field. Canceling settings preserved the draft; New Chat cleared the test draft and returned to the empty state.
- The inspected start-page screenshot showed a diffuse title glow without the earlier rectangular edge and retained the existing layout.
- In this follow-up, the new-tab and new-task buttons executed their own actions, the task editor opened and canceled, switching back restored the owning group's tabs, and closing a selected tab selected its neighbor.

These checks establish the exercised behavior, not exhaustive UI automation or measured animation performance. Screenshots were inspected in the native CUA tool; no screenshot files are attached to this report.

## Remaining verification limits

- Actual IME composition and measured motion smoothness remain unverified. Chinese paste was exercised, but that does not establish composition/candidate-selection behavior. Source review confirms the marked-text guards and native editing delegation.
- The seven selected XCTest UI cases never started, so they are not reported as passes. The runner failure was environmental initialization, not an assertion failure.
- A real incoming Agent reply was not exercised because no provider was configured. Message insertion motion was reviewed in source; controller behavior was covered by the offline tests.
- System Reduce Motion, increased contrast, dark appearance, minimum-window layout, and all keyboard focus visuals were not comprehensively exercised on the final build. Reduce Motion branches were checked in source.
- Frame timing and performance were not profiled.

## Boundaries

- Native WebKit and terminal view identity, mounting, split geometry, and resource lifetime remain outside the motion implementation.
- No provider request, credential change, commit, push, or system appearance preference change is part of this work.
- Existing transcript scrolling behavior is retained; this iteration does not add a policy for following messages only when the reader is near the bottom.
- The separate interactive concept illustrates the visual treatment; it is not a screenshot or runtime acceptance of the macOS app.
