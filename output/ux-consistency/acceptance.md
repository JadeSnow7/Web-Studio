# UX consistency acceptance — 2026-09-12

## Scope

Changed `StudioDesign.swift`, the view layer of `ContentView.swift`, `AgentViews.swift`, `DESIGN.md`, and `UX-CONTRACT.md`. Existing dirty and untracked project work was preserved. The pre-view model definitions in ContentView are byte-for-byte unchanged from the task-start snapshot; resource, provider and terminal runtime source files were not modified.

Shared native tokens now cover 8/12/16pt spacing, 20pt form inset, 6pt resource-row and 10pt panel radii, selection, feedback and panel decoration. Resource rows use full button-label hit regions and selected traits plus an accent edge. Forms share persistent labels, Cancel-left/commit-right order and deferred initial focus. The Agent inspector separates Resources, Preview, Question and Response, uses accurate shared provider status copy and a shorter read label at narrow widths.

## Verified

- Final source compiled and passed 86 core tests in five suites. Command: `xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio' -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/web-studio-final CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test -parallel-testing-enabled NO -only-testing:'Web StudioTests/Web_StudioTests' -only-testing:'Web StudioTests/AgentServiceTests' -only-testing:'Web StudioTests/ResourceReadTests' -only-testing:'Web StudioTests/AgentControllerTests' -only-testing:'Web StudioTests/ProviderSettingsTests'`.
- Final test log: `/private/tmp/web-studio-ux-verified.log`; result: `/private/tmp/web-studio-final/Logs/Test/Test-Web Studio-2026.09.12_22-18-12-+0800.xcresult`.
- `build-for-testing` passed before the final focus/read-label adjustment; the final `test` command rebuilt that adjustment successfully. Changed view files produced no compiler diagnostics. Existing actor-isolation warnings in untouched runtime/default-argument code remain; no Swift language-mode or isolation migration was performed.
- Strict native ownership audit: zero findings (`static-audit.json`). Official designmd lint: zero errors and warnings (`design-lint.json`). Native logical-point radii use an explicit metadata extension because the standard rounded schema only supports CSS dimensions.
- `git diff --check` passed.
- Native CUA checks used an independently signed copy of the final binary with temporary bundle identifier `local.webstudio.ux-final`, preserving sandbox entitlements. No provider credential was entered or external Agent request sent.
- Final GUI: sidebar selected traits and accent cue; Agent section hierarchy and disabled Send; 900×560 minimum content region and 220pt inspector; readable narrow read button and scrolling; Agent shortcut from the minimum window; provider endpoint automatically selected on opening; resource rename initial selection and Return submission updating sidebar, toolbar and Agent list.
- Additional checks on the preceding UX build: command palette initial focus and Escape; blank-resource read failure with Send disabled; editing a provider endpoint draft, cancelling with Escape, and reopening restored the committed value. The final changes only deferred provider focus and adjusted read-button geometry/text on these paths.

## Limits

- XCUITest did not run: the runner failed to initialize with `Timed out while enabling automation mode`. Log: `/private/tmp/web-studio-ux-final-tests.log`. This is not a passed UI suite.
- An earlier full non-UI run completed 93 tests: 90 passed, three terminal tests failed (10 assertions) reproducing the existing sandbox controlling-TTY denial. The isolated test-endpoint Keychain test passed. Log: `/private/tmp/web-studio-ux-tests.log`. No terminal or security settings were changed.
- Manual screenshots cover the current dark appearance, not light/high-contrast/reduced-motion, full VoiceOver or IME matrices. At minimum width macOS moves a trailing toolbar action into its native overflow menu; the Agent keyboard shortcut was verified.
- Live provider responses and interactive terminal/SSH acceptance remain outside this UX change.

## Screenshots

- `workspace.png`: final shared layout at regular width.
- `narrow.png`: minimum window with 220pt Agent inspector.
- `provider-focus.png`: final provider form with endpoint selected on opening.

`source-sha256.json` records the reviewed source and design-document versions.
