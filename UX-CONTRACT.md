# Web Studio UX contract

## Scope and ownership

Resources, views, layouts and Agent requests have separate lifetimes. Named workspace configuration is saved automatically; runtimes, questions and snapshots remain session-only. WebKit retains its existing shared default website data store; workspaces do not isolate accounts, networking or permissions.

## Canonical UI Map

| Capability | Canonical owner | Source of truth | Allowed variants | Verification |
| --- | --- | --- | --- | --- |
| Resource identity and lifecycle | `ResourceStore` | Ordered resource records and owned runtimes | web / local terminal / SSH | model and runtime tests |
| Workspaces and navigation | `StudioModel`, `TabStrip`, `ResourceRow` | Workspace IDs and resource IDs | expanded / compact / hidden sidebar | model and native interaction |
| Layout and focus | `WorkspaceSession.layout` via `StudioModel` | `WorkspaceLayout`, stable `PaneState` IDs | single / left-right pair | model tests; native NSSplitView; manual verification pending |
| Form | `StudioToolbar.addressField`, `PanelCoordinator`, and name editors | Captured target and validated input | address / SSH / terminal path / names | routing tests and native keyboard checks |
| Select/Listbox | Native SwiftUI pickers and resource entries | Selected IDs | modes / resources | keyboard and pointer checks |
| Scrollbar | Native SwiftUI/AppKit scrolling | Platform geometry | navigation / command list / terminal | native interaction |
| Application commands | `StudioCommands`, `CommandPalette` | Typed `StudioCommandAction` with explicit targets | menu / palette / shortcuts | model and native interaction |
| Web runtime | `WebTabRuntime` | Persistent `WKWebView` and its navigation state | loading / loaded / failed | model and live page checks |
| Terminal runtime | `TerminalSession`, `GhosttyTerminalRuntime`, GhosttyKit v1.3.1 | One Ghostty surface and its owned PTY per resource | starting / running / exited / failed / interrupted | focused build and live GUI acceptance; SwiftTerm remains test-only |
| Resource reading | `ResourceStore.read` | Explicit resource ID and bounded snapshot | isolated web text / latest rendered terminal output | focused reads and runtime tests |
| Agent surface | `AgentInspectorView`, `AgentController` | Chat composer, explicit selection, preview and immutable AgentRun | requesting / completed / failed / cancelled | offline controller and transport tests |
| Provider configuration | `ProviderSettingsView`, `ProviderSettings`, `KeychainCredentialStore` | Endpoint/model preferences; endpoint-bound Keychain credential | missing / configured but unverified / error | settings tests and external API acceptance |

## Navigation and controls

The sidebar, forms and Agent inspector use `StudioDesign` for shared spacing, radii, semantic feedback and decorative panel surfaces. Form content owns a 20pt inset and its existing geometry. Resource rows are full-width native buttons with a persistent `.isSelected` cue and accent edge; close, add and status icon actions have stable hit areas, labels and help. The toolbar address field remains the persistent native editor, while the workspace selector and navigation controls share capsule sizing.

The sidebar now lists workspaces with independent resource stores, layouts and Agent drafts. The toolbar workspace menu remains reachable with the sidebar hidden. Workspace switching retains loaded runtimes. Live resources cannot move across workspaces. New Web Page and New Terminal controls use the web and terminal symbols consistently in the toolbar, sidebar, start page and application menu; resource switching uses the active workspace sidebar and ⌘K. The workspace fold button only changes sidebar expansion; selecting a workspace name changes the active workspace. ⌘T, ⌘1–⌘9 and Control-Tab cycling remain available when the sidebar is hidden. ⌘K searches configuration descriptors across workspaces without starting terminal/SSH processes or reading content. Resource results show workspace, type and destination, share keyboard selection with actions, and focus an existing owning window when appropriate. This path has model coverage; final native verification remains in progress.

Blank web resources render a start page derived from their workspace. The start page routes web, local terminal and SSH actions through the existing model, stores user-added destination snapshots so pins reopen after their original resource closes, shows up to five actual recent resources, and hides the recent section when empty. Named workspace pins are included in configuration. Resource recency is independent per workspace and remains in memory; temporary workspace configuration is not saved until named.

⌘L focuses and selects the persistent native address field. HTTP(S) input on a web resource navigates that resource. HTTP(S) input on a terminal creates a same-workspace web resource. SSH and local terminal paths always create separate same-workspace terminal resources, preserving existing processes and their working directories. Invalid or unsupported input remains in the field with an inline error; Escape restores the captured value. Switching resources cancels the current edit and displays the newly selected resource's address. AppKit owns text editing and first-responder focus through `NativeAddressField`.

⌘K contains defined application actions and resource lookup, not Shell execution. Enter executes the selected action. Switching resources after opening a panel must not change its execution target. Closed targets retain an error rather than redirecting work.

Panels are mutually exclusive, place initial focus, support keyboard selection and Return, close with Escape, and restore a still-valid original responder. When that responder is unavailable, focus belongs to workspace navigation. Top navigation state belongs to the focused resource. Pane content has no resource picker/header; only split mode exposes a subtle focused-pane edge cue.

## Layout and closing

The top toolbar band is transparent through native window styling (`titlebarAppearsTransparent`, no separator, clear non-opaque window background, and hidden SwiftUI window-toolbar background). When an active web runtime is loaded, a low-resolution snapshot of its visible top strip is softened and veiled behind the actual safe-area band; it is noninteractive, bounded, cleared during navigation/failure, and never changes web content geometry. The root backdrop remains the fallback continuous full-window frost, while foreground workspace layout remains below the toolbar. Existing native toolbar placement, traffic lights, drag region, shortcuts and capsule controls remain intact. One noninteractive behind-window visual effect supplies desktop frost; sidebar and Agent surfaces use only semantic separators, while floating panels and capsules reuse that effect through clipped backgrounds. Buttons remain native bordered capsule controls with native focus and disabled semantics. Reduce Transparency selects opaque semantic fills.

One resource may be mounted in one pane at a time. Selecting an already displayed resource focuses its existing pane. Changing placement or split ratio must not create a new runtime or reload a page.

The Layout menu provides keyboard-accessible split creation, focus switching, pane closure, single-pane return, swapping and ratio adjustment/reset. Pane content remains headerless; split focus uses a subtle edge cue and pane closure remains available from the Layout menu.

- Switching a resource changes display only.
- Closing a pane removes a layout reference and preserves its resource.
- Closing a resource releases its web runtime or terminates its owned terminal.
- Closing the final resource leaves an empty workspace; creating a resource is explicit.
- ⌘W closes the top control panel first; otherwise it uses the same focused-resource close path as the resource close button.
- A live terminal close warns that its session will end and offers Cancel first.
- Normal application quit offers the same consequence/cancel choice for live terminals, then waits for owned cleanup. Pending resource-close tasks are included.
- Normal window closure summarizes and waits for every loaded workspace in that window, including hidden workspaces and pending resource-close tasks. Other windows remain open.

There is no arbitrary nesting, default background keepalive, or restoration of running processes after quit. The dual-pane model and native NSSplitView display are implemented. Current native checks are bounded to the builds and actions recorded in the B1 evidence; older UI-runner failures are historical and do not describe a new run.

## Web behavior

Page state and history belong to the existing `WKWebView`. Back, Forward, Reload and Stop use that runtime. Committed navigation and title changes update resource metadata, preserving a custom user title. Popups belong to the initiating resource's workspace.

Loading uses WebKit progress; failure names the error and offers reload. Cancelled navigation is not reported as a failure. Native JavaScript dialogs identify origin. Only explicit user link activation may hand off supported mail/telephony schemes. Downloads and find-in-page are outside this iteration.

## Terminal and security boundary

GhosttyKit v1.3.1 supplies the production terminal parser, GPU renderer, native text input and PTY. `TerminalSession` owns the resource-to-surface mapping and forwards focus, geometry, text and close events. Local sessions start `/bin/zsh` in the direct-download desktop process. The separate sandboxed browser/App Store target is intentionally deferred and must not share this entitlement boundary.

Ghostty owns terminal input buffering and process I/O. `TerminalSession` forwards text, raw control bytes, focus and geometry, retains the final text snapshot, and waits for surface shutdown before completing resource close. This contract is implementation evidence; successful interactive acceptance still requires the focused native GUI run.

SSH uses system `ssh`, arguments passed separately, explicit host checking and app-owned known_hosts. It does not scan user private keys or automatically accept unknown hosts. A running SSH process is not proof of authenticated connectivity.

The direct-download desktop target disables App Sandbox. Historical signed-sandbox denial of controlling-TTY/line-discipline ioctls remains documented in the earlier runtime report and is not evidence for this target. The future browser/App Store target will define a separate sandbox boundary.

## Agent context and provider contract

The provider panel explicitly selects Responses API or Codex CLI. CLI status distinguishes configured, checked, and unavailable states and provides terminal login guidance. CLI requests use a frozen path/model, an ephemeral read-only process, bounded JSONL output, and explicit failure/cancellation handling; a local CLI response does not constitute GUI or live interactive-runtime acceptance.

The question inspector presents independent questions. A scrollable answer area and bottom composer keep the selected question visible; Resources and Preview are opened by mutually exclusive buttons, while Settings uses `PanelCoordinator`. Resource selection and exact snapshot disclosures remain explicit. Empty guidance says “新问题”, and a compact disabled-send hint identifies the missing resource/preview gate. Provider settings retain persistent labels and disable endpoint, model and secret inputs while saving or deleting credentials. “Configured; connection not verified” describes configuration presence without claiming a successful connection.

Selected-source labels beside the composer show pending collection, collection time, truncation and read failure; closed selected sources remain removable. No automatic expiry is claimed. Resource selection is explicit. Read/Preview freezes source IDs, runtime instances and bounded contents; the user confirms these exact materials before Send; selection changes require a matching new preview. Each resource permits at most 12,000 characters and a preview at most 48,000. Budget exhaustion and read failure remain visible and block submission until removed or reread. Runtime failure metadata is distinct from inability to read a resource.

Preview disclosures expose exact text, source ID/title/URL, time, range, truncation, known directory, lifecycle and errors. Run sources belong to the submitted request and remain available after resource closure. The question view displays actual user/assistant messages from the selected workspace and question; each question links to its immutable request details. This transcript is display-only: each API request still contains its current question and explicit snapshots. Sending captures the question before clearing the composer. New Question retains previous independent questions and unsent drafts until workspace close or app exit. Selection and preview confirmation belong to each question. A background answer returns to its original question; each workspace allows one physical provider request, including cancellation cleanup, at a time. The UI identifies a request running in another question and provides navigation and cancellation. Retry preserves the original question, snapshots, endpoint and model; a fresh preview is a separate action. Cancellation invalidates late results and cancels the request task.

Only configured HTTPS Responses endpoints are supported. Endpoint and model may be stored in ordinary preferences. Secrets are write-only UI input to an endpoint-bound Keychain item; no secret is persisted in preferences or logs. Configuration presence does not claim a successful API response. Resource evidence is untrusted context, separate from system instructions; requests have no tools, hidden history or automatic action permissions.

## Standalone VT acceptance boundary

M1/M2 GhosttyVT APIs are opt-in source contracts for snapshots, scrolling,
selection, paste, focus, mouse, PWD and backend forwarding. They are pinned to
commit `d4c88d8069912b653d707191388ca98e24751f12`, Zig `0.16.0`, and
`aarch64-macos` as recorded in `Vendor/GhosttyVT/DEPENDENCY.lock`. Local
compile/smoke results remain separate from live app and GUI acceptance. The
existing terminal backend remains the default until an explicit migration gate.

## Accessibility and verification

### Motion contract

`StudioDesign.Motion` is the shared source for local hover/press (120ms), selection
(160ms), panel (180ms) and message (180ms) timing. Native task/resource buttons keep
their existing click, keyboard, context-menu, close-hit-area and accessibility
semantics. Group selection is neutral; resource selection uses the accent marker and
only that marker may move between rows. Panel presentation captures a stable panel
identity, disables the retiring host during its fade, and restores focus immediately;
panel content and runtime identities do not animate. The command panel keeps its
native input mounted while its single host uses opacity/6pt/0.98 entrance motion;
focus transfer is independent. Other panels retain the captured host presentation.
Reduced motion removes offset
and scale, and Reduce Transparency keeps the existing opaque fallback. The start
page uses a compact heading and its native buttons/recency rows expose hover and press feedback. Agent message reveal is local to rows; it does
not change Agent business logic or evidence gates. These are implementation rules;
they do not constitute runtime or GUI acceptance evidence.

Icon actions need meaningful labels, stable IDs and keyboard equivalents. Focus must remain in web/terminal input during ordinary toolbar and layout updates. Native semantics own appearance, contrast and reduced motion. Theme acceptance must use an app-level override, not a system-setting change.

No skipped destination-form test counts as a pass. The native UI suite targets current resource IDs and controls; compilation is separate from successful UI execution. Record model tests, actual native checks, runner initialization failures, sandbox restrictions and missing external configuration separately in [the earlier runtime acceptance report](output/six-features-acceptance.md) and [the historical start-page/chat acceptance report](output/start-chat/acceptance.md). Current evidence is consolidated in [STATUS.md](STATUS.md), including the later full XCTest UI failures and targeted B1 repairs.

## B1 implementation boundary

WorkspaceSession owns resources, layout, recency, pins and AgentController in memory. WindowCoordinator owns loaded sessions; the application registry maintains weak ownership and shared provider preferences. Forms must be completed or explicitly cancelled before switching; a blocked switch preserves their input. Closing a workspace clears its questions and runtime. B1 implements persistence, save-before-close, archive, explicit split selection, configuration search, compact content/question switching and explicit terminal session controls. Ending a terminal keeps its descriptor and pane; restarting creates a new runtime instance. Failed directory repair retains the original path. Model, automated UI and native checks are reported separately. The [B1 task record](records/WORKSPACE-B1-20260917/task-summary.md) separates checkpoints from final product and GUI acceptance.


## B1 workspace review fixes

Single-workspace archiving reconciles the owning window after cleanup: remaining loaded spaces stay usable, and an emptied window receives a temporary workspace. Whole-window closure and application exit do not create replacement spaces. Save failure preserves the original live workspace.

Creating a web or terminal resource in an unloaded saved workspace waits for that workspace to open. A failed, blocked or superseded open never redirects creation to another workspace. A target already owned by another window keeps the existing locate-only behavior.

Directory-scan failures remain visible as configuration diagnostics, including corrupt and unsupported-version files. Diagnostics identify the workspace and configuration file, allow locating the file and explicitly rescanning, and remain reachable when the sidebar is hidden. Rescans preserve live workspace state and do not overwrite failed configuration files. Resolved errors clear after a successful rescan.

These behavior requirements are verified separately by model tests and native UI checks in [the review-fix record](records/WORKSPACE-B1-20260917/review-fixes/task-summary.md); they do not extend the original B1 product-acceptance claim.
