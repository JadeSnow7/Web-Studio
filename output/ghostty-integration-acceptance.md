# Ghostty integration acceptance

## Fixed inputs

- Ghostty: v1.3.1, commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- Zig: 0.15.2, official arm64 macOS archive SHA256
  `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b`
- Host target: direct-download macOS desktop, native arm64 during the first
  integration pass
- Current arm64 archive: `Vendor/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a`,
  SHA256 `29181cb34ed7f5a4144085493fda635472d41f953ffb1e5e1d42b1933eb5d35d`
- App sandbox: disabled for this target so Ghostty can create a controlling
  TTY; no App Store or notarization claim is made
- App-owned Ghostty config denies OSC clipboard read/write and sets
  `window-vsync = false` for headless/no-active-display test hosts; this avoids
  initializing a display link when the host exposes zero active displays.

## Ownership contract

`ResourceStore` owns `TerminalSession` and pane placement. One production
session creates one Ghostty surface, and Ghostty creates the only PTY for that
surface. `GhosttyTerminalRuntime` owns the process-wide Ghostty app/tick loop.
The SwiftTerm PTY remains test-only and is selected by `startForTesting`.

Ghostty's surface view receives AppKit key events, text insertion and IME
preedit, focus changes and backing-size changes. `ResourceStore.read` obtains a
bounded viewport snapshot through Ghostty's text API, preserving the existing
Agent evidence boundary.

## Verification state

This file records the acceptance contract and fixed inputs. Build output and
GUI results are appended only after the corresponding command or live check is
run. A successful framework build does not prove local shell, SSH, IME,
clipboard, resize, or process cleanup acceptance.

## Current evidence

- `xcodebuild -project "Web Studio.xcodeproj" -scheme "Web Studio" -configuration Debug -destination "platform=macOS,arch=arm64" ... build`: passed on 2026-09-16; latest incremental log `/private/tmp/web-studio-ghostty-app-build11.log`.
- `nm -gU` finds `ghostty_init`, `ghostty_app_new`, and `ghostty_surface_new` in the pinned arm64 archive.
- Repository build-script check passed with `GHOSTTY_OUTPUT_DIR=/private/tmp/web-studio-ghostty-script-check ./scripts/build-ghostty.sh`; the output archive, config, runtime resources and LICENSE matched the pinned inputs.
- Regression suites passed: 107 passed, 0 failed, 0 skipped. Result: `/private/tmp/web-studio-ghostty-tests/Logs/Test/Test-Web Studio-2026.09.16_03-16-25-+0800.xcresult`; log: `/private/tmp/web-studio-ghostty-regression.log`.
- GUI validation passed for keyboard input, Chinese paste, native Ctrl-C, ⌘L/⌘K, split layout, same-session PID retention, resize `46x108 → 46x53`, retained output after exit, and `Exited (status unavailable)`. The focused validation bundle used identifier `com.huaodong.Web-Studio.GhosttyValidation`.
- After the regression run, the mouse-drag selection patch was incrementally
  rebuilt and GUI-verified: `GHOSTTY_SELECTION_OK` and a CUA drag selected the
  complete terminal string with visible highlight. Build log:
  `/private/tmp/web-studio-ghostty-gui-mouse-build.log`.
- Ghostty's macOS login wrapper does not reliably report the child exit code in
  this pinned core, so the production adapter reports `.exited(nil)` for that
  callback rather than treating the observed default as a successful zero.
- Full IME composition, remote SSH, TUI-specific behavior, developer signing/
  notarization, Intel, and App Store targets remain outside this acceptance.
