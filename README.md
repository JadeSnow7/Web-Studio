# Web Studio

A native macOS workspace built with SwiftUI, AppKit, WebKit, SwiftTerm and the pinned GhosttyKit core. Resources, their visible panes, layout and Agent requests have separate ownership. [DESIGN.md](DESIGN.md) and [UX-CONTRACT.md](UX-CONTRACT.md) describe the product contract; [the acceptance report](output/six-features-acceptance.md) distinguishes implementation from actual verification.

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
Third-party dependencies and vendored code remain under their respective
licenses; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and
[`Vendor/ghostty/LICENSE`](Vendor/ghostty/LICENSE).

## Current implementation

- **Resources:** `ResourceStore` owns stable IDs, ordered records, groups, web runtimes and terminal sessions. Views reference IDs. Groups organize resources and do not isolate logins or permissions. Existing WebKit shared website data storage is retained.
- **Vertical navigation:** The horizontal tab strip is removed. The sidebar retains groups, new resources, selection, custom names and cross-group movement. ⌘T, ⌘1–⌘9, Control-Tab and ⌘K remain available when the sidebar is hidden.
- **Control panels:** ⌘L opens Web/SSH destination entry. ⌘K opens defined app commands and resource lookup; it does not execute Shell text. Panels capture their resource/pane target, show validation, and support Return and Escape. An address entered against a terminal creates a related web resource; SSH always creates a separate terminal resource.
- **Web runtime:** Persistent `WKWebView` instances preserve state and history. Navigation, load progress, failures, reload, page titles, source-bound popups and native origin-labelled dialogs are supported. Custom resource titles survive page changes.
- **Terminal integration:** The direct-download desktop target uses GhosttyKit v1.3.1 (commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`) as the single production terminal backend. Ghostty owns the PTY, parser and GPU surface; `TerminalSession` owns resource lifetime and Agent snapshots. SwiftTerm 1.14.0 remains available for deterministic adapter tests and comparison. The desktop target is intentionally unsandboxed; the future browser/App Store product is a separate target boundary and is not part of this build.
- **Layout:** The single/left-right dual-pane model now preserves resource references, pane IDs and focus, prevents duplicate mounting, and separates pane closure from resource closure. `NSSplitView` supplies the draggable divider; native hosts transfer existing runtime views.
- **Start page:** Blank resources show Web, local terminal and SSH entry actions, session-pinned destinations and actual recently used resources. Fixed destinations can be added from the start page and remain available after their source resource closes.
- **Agent chat:** The default sidebar shows a transcript and bottom composer. Resources, exact previews and provider settings open through buttons; each question retains its request details. New Chat clears the session conversation and selection. Explicit resource selection, bounded text previews, immutable requests and the existing Responses API adapter remain in place. Provider settings use endpoint-bound Keychain credentials. Real API acceptance requires user configuration.

The minimum content size remains 900×560. Resource and layout state are kept for the current app session. There is no running-process restoration after quit or default background keepalive.

The Layout menu exposes Split (⌘⌥\), Focus Other Pane (⌘⌥O), Close Focused Pane (⌘⌥W), Single Pane (⌘⌥1), Swap Panes (⌘⌥⇧S), and divider ratio controls (⌘⌥[, ⌘⌥], ⌘⌥0). ⌘⌥S toggles the sidebar. Closing a pane only changes the layout.

## Terminal and shutdown boundary

Local terminals start `/bin/zsh` as a login-capable interactive shell in the direct-download desktop process. New Terminal in Folder uses the native folder picker. Ghostty owns process startup and rendering; GUI acceptance must verify the selected directory and executable in the built app.

SSH uses `/usr/bin/ssh`, separately quoted arguments, `StrictHostKeyChecking=ask`, and an app-owned known_hosts file. It forwards a nonempty inherited `SSH_AUTH_SOCK` so an existing agent can authenticate. The app does not read or copy private-key contents or automatically accept unknown hosts. Existing SSH configuration can affect connection behavior, including proxies and authentication. Process startup does not mean authenticated connection success.

⌘W closes an open primary panel first, otherwise the focused resource. A live terminal close offers Cancel before termination. Normal app quit warns about live terminals, then awaits owned session cleanup, including resource-close tasks already in progress. It does not kill unrelated processes by name.

The direct-download desktop target runs without App Sandbox so Ghostty can create a controlling TTY. Outbound network access and user-selected files continue to follow the desktop product policy. Web downloads, find-in-page and per-site permission UI are outside this iteration. No signing or notarization result is implied by this configuration.

Closing a window also waits for that window's resource store to shut down, including web-only windows. Ghostty surface close and child exit are tracked separately from UI state so resource shutdown can await backend completion.

## Ask an Agent about selected resources

For local validation, Provider settings can use the installed Codex CLI (`/opt/homebrew/bin/codex`, or set another executable path). Run `codex login` in Terminal, choose Codex CLI, optionally enter a model override, use Check CLI login, then Save. The app starts one ephemeral read-only `codex exec --json` process in a unique temporary directory, passes only the question and selected bounded snapshots on stdin, and disables tool, browser, MCP, hook and history surfaces. The app does not read or copy CLI tokens. A successful CLI command proves the adapter and CLI path; it is not evidence that GUI acceptance or interactive browser/terminal control is implemented.

1. Open the Agent sidebar and click 资源 to select resources. Resource listing does not send their contents.
2. Click 预览, then 读取预览. Inspect each snapshot, collection time, source, range, truncation and errors. Reads are limited to 12,000 characters per resource and 48,000 per preview. Remove failed items or read again before sending.
3. Open the gear button (设置). Enter a complete HTTPS Responses endpoint and model ID. The default endpoint is `https://api.openai.com/v1/responses`; no model or key is assumed. Enter a key in the secure field to save or replace it. Delete Key removes only the current endpoint's credential. Endpoint/model are ordinary preferences; keys are only in Keychain.
4. Enter a question and Send. Each request freezes its question, snapshots and provider configuration. Cancel ends the request; Retry keeps the original request context. Switching tabs or closing a resource does not change retained request sources.

The client uses nonstreaming [Responses API](https://developers.openai.com/api/reference/cli/resources/responses/methods/create) requests with `store:false`, no tools and no hidden prior history. Resource text is untrusted evidence. Screenshots, automatic Shell execution, file editing and page-control tools are not provided. The visible chat transcript is kept in session memory. Each API call contains only its current question and explicitly selected snapshots; earlier chat messages are not silently included.

Configuration presence is not a successful connection test. Missing credentials, network/service errors and cancellation are shown explicitly. Fake providers exist only in tests.

## Build and test

Open `Web Studio.xcodeproj` in Xcode and select the `Web Studio` scheme and My Mac. Build GhosttyKit v1.3.1 with Zig 0.15.2 using [scripts/build-ghostty.sh](scripts/build-ghostty.sh), or set `GHOSTTY_KIT_PATH` to a compatible `GhosttyKit.xcframework` directory. SwiftTerm is pinned through SPM; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

### Rebuilding the pinned Ghostty core

The checked-in Ghostty headers, module map, and runtime resources identify the integration contract. The generated `Vendor/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a` is intentionally excluded from ordinary Git commits because it is a 132 MB native archive. A clean clone must therefore rebuild it locally or obtain a matching artifact through a trusted distribution channel before the Xcode target can link.

The supported local recipe currently requires:

- official Ghostty v1.3.1 at commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`, checked after cloning the official repository;
- Zig 0.15.2 for Apple arm64, with the official archive SHA-256 `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b`;
- full Xcode, the Xcode Command Line Tools, and Homebrew `gettext`;
- a local clone of that fixed Ghostty source, then `GHOSTTY_SOURCE_DIR` and `ZIG_BIN` pointing to it and to the Zig executable when running `./scripts/build-ghostty.sh` from the repository root.

The build script validates the pinned source and produces the native arm64 framework and resources; it is not a downloader and does not claim universal, Intel, signed, notarized, or App Store output. Do not substitute an archive built from another Ghostty revision or architecture.

Local ad-hoc signed build:

```sh
xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio' \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/web-studio-local-signed \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
open '/private/tmp/web-studio-local-signed/Build/Products/Debug/Web Studio.app'
```

The direct-download Debug and Release targets set `ENABLE_APP_SANDBOX=NO`. The future browser/App Store target is intentionally separate and is not represented by this Xcode target.

```sh
xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio' \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/web-studio-codex-local \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ENABLE_APP_SANDBOX=NO build
open '/private/tmp/web-studio-codex-local/Build/Products/Debug/Web Studio.app'
```

The CLI backend ignores Codex user configuration to prevent MCP, hooks, skills and other automatic capabilities from entering the request. A blank model field uses the CLI's own default model; an entered model is passed as an explicit override. Authentication reuses the CLI login already established in Terminal, while the app never reads or copies CLI tokens.

For application-only appearance checks, launch with `--appearance-light` or `--appearance-dark`. `--minimum-window` selects 900×560 content at launch. These flags do not change system appearance settings.

Focused model checks, with the signed test host:

```sh
xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio' \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/web-studio-tests \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  test -only-testing:'Web StudioTests/Web_StudioTests' -parallel-testing-enabled NO
```

Model and Agent offline tests explicitly disable terminal process launch or inject test providers. The current Ghostty regression run passed 107 tests with 0 failures and 0 skips; its result and log paths are recorded in the [Ghostty acceptance report](output/ghostty-integration-acceptance.md). Full IME composition, remote SSH, TUI-specific behavior, developer signing/notarization, Intel, and App Store targets remain outside that acceptance. See [start-page and chat acceptance](output/start-chat/acceptance.md) for the separate UI scope.

No distribution signing, release publication, or system-setting change is implied by this build. Bundle identifier: `com.huaodong.Web-Studio`.

## Pinned GhosttyVT migration boundary

The opt-in standalone VT path is pinned to Ghostty commit
`d4c88d8069912b653d707191388ca98e24751f12`, Zig `0.16.0`, target
`aarch64-macos`, and the checksums in `Vendor/GhosttyVT/DEPENDENCY.lock`.
Rebuild and test it with `./scripts/build-ghostty-vt.sh` and
`./scripts/test-ghostty-vt.sh`. The opt-in `Web Studio VT` arm64/macOS target
uses the canonical core/backend/Metal/host scripts below; final arm64 Debug/Release,
core, backend, host and offscreen checks passed. The existing app regression suite
also passed 128 tests in 11 suites under Xcode 27 / Swift 6.4. The Xcode 27 license block is resolved.
The rebuilt MTKView app has passed the bounded GUI cases documented in the
[GUI checkpoint](output/terminal-vt-migration/GUI-20260916.md). M2 implementation
and complete acceptance remain in progress; the existing default backend is unchanged.

```sh
./scripts/test-terminal-vt-core.sh
./scripts/test-terminal-vt-backend.sh
./scripts/test-terminal-metal.sh
./scripts/test-terminal-vt-host.sh
./scripts/test-terminal-vt-core-asan.sh
```

See [the migration acceptance record](output/terminal-vt-migration/ACCEPTANCE.md)
for evidence boundaries.

Opt-in target build:

```sh
xcodebuild -project 'Web Studio.xcodeproj' -scheme 'Web Studio VT' \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/web-studio-vt \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```
