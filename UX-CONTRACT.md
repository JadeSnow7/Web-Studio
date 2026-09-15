# Web Studio UX contract

## Scope and ownership

Resources, views, layouts and Agent requests have separate lifetimes. Resource and layout state is session-only. WebKit retains its existing shared default website data store; task groups do not isolate accounts, networking or permissions.

## Canonical UI Map

| Capability | Canonical owner | Source of truth | Allowed variants | Verification |
| --- | --- | --- | --- | --- |
| Resource identity and lifecycle | `ResourceStore` | Ordered resource records and owned runtimes | web / local terminal / SSH | model and runtime tests |
| Groups and navigation | `StudioModel`, `TabStrip`, `ResourceRow` | Group IDs and resource IDs | expanded / compact / hidden sidebar | model and native interaction |
| Layout and focus | `StudioModel.layout` | `WorkspaceLayout`, stable `PaneState` IDs | single / left-right pair | model tests; native NSSplitView; manual verification pending |
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

The sidebar, forms and Agent inspector use `StudioDesign` for shared spacing, radii, semantic feedback and decorative panel surfaces. Form content owns a 20pt inset and its existing geometry. Resource rows are full-width native buttons with a persistent `.isSelected` cue and accent edge; close, add and status icon actions have stable hit areas, labels and help. The toolbar address field remains the persistent native editor, while its neighboring resource menu and navigation controls share capsule sizing.

The left sidebar retains task groups, creation, switching, renaming and cross-group movement. New Web Page and New Terminal controls use the web and terminal symbols consistently in the toolbar, sidebar, start page and application menu; the compact toolbar capsule immediately right of the address field switches resources within the selected group. ⌘T, ⌘1–⌘9 and Control-Tab cycling remain available when the sidebar is hidden. ⌘K can find resources across groups.

Blank web resources render a session-only start page. The start page routes web, local terminal and SSH actions through the existing model, stores user-added destination snapshots so pins reopen after their original resource closes, shows up to five actual recent resources, and hides the recent section when empty. Pins and recency are not persisted.

⌘L focuses and selects the persistent native address field. HTTP(S) input on a web resource navigates that resource. HTTP(S) input on a terminal creates a same-group web resource. SSH and local terminal paths always create separate same-group terminal resources, preserving existing processes and their working directories. Invalid or unsupported input remains in the field with an inline error; Escape restores the captured value. Switching tabs cancels the current edit and displays the newly selected resource's address. AppKit owns text editing and first-responder focus through `NativeAddressField`.

⌘K contains defined application actions and resource lookup, not Shell execution. Enter executes the selected action. Switching resources after opening a panel must not change its execution target. Closed targets retain an error rather than redirecting work.

Panels are mutually exclusive, place initial focus, support keyboard selection and Return, close with Escape, and restore a still-valid original responder. When that responder is unavailable, focus belongs to workspace navigation. Top navigation state belongs to the focused resource. Pane content has no resource picker/header; only split mode exposes a subtle focused-pane edge cue.

## Layout and closing

The top toolbar band is transparent through native window styling (`titlebarAppearsTransparent`, no separator, clear non-opaque window background, and hidden SwiftUI window-toolbar background). When an active web runtime is loaded, a low-resolution snapshot of its visible top strip is softened and veiled behind the actual safe-area band; it is noninteractive, bounded, cleared during navigation/failure, and never changes web content geometry. The root backdrop remains the fallback continuous full-window frost, while foreground workspace layout remains below the toolbar. Existing native toolbar placement, traffic lights, drag region, shortcuts and capsule controls remain intact. One noninteractive behind-window visual effect supplies desktop frost; sidebar and Agent surfaces use only semantic separators, while floating panels and capsules reuse that effect through clipped backgrounds. Buttons remain native bordered capsule controls with native focus and disabled semantics. Reduce Transparency selects opaque semantic fills.

One resource may be mounted in one pane at a time. Selecting an already displayed resource focuses its existing pane. Changing placement or split ratio must not create a new runtime or reload a page.

The Layout menu provides keyboard-accessible split creation, focus switching, pane closure, single-pane return, swapping and ratio adjustment/reset. Pane content remains headerless; split focus uses a subtle edge cue and pane closure remains available from the Layout menu.

- Switching a resource changes display only.
- Closing a pane removes a layout reference and preserves its resource.
- Closing a resource releases its web runtime or terminates its owned terminal.
- Closing the final resource creates a fresh blank web resource ID.
- ⌘W closes the top control panel first; otherwise it uses the same focused-resource close path as the resource close button.
- A live terminal close warns that its session will end and offers Cancel first.
- Normal application quit offers the same consequence/cancel choice for live terminals, then waits for owned cleanup. Pending resource-close tasks are included.
- Normal window closure waits for that window's resource store, even when it contains only web resources. Other windows' stores are not closed by this path.

There is no arbitrary nesting, default background keepalive, or restoration of running processes after quit. The dual-pane model and native NSSplitView display are implemented. Final native interaction is unverified: the UI runner failed to initialize with “System authentication is running”.

## Web behavior

Page state and history belong to the existing `WKWebView`. Back, Forward, Reload and Stop use that runtime. Committed navigation and title changes update resource metadata, preserving a custom user title. Popups belong to the initiating resource's group.

Loading uses WebKit progress; failure names the error and offers reload. Cancelled navigation is not reported as a failure. Native JavaScript dialogs identify origin. Only explicit user link activation may hand off supported mail/telephony schemes. Downloads and find-in-page are outside this iteration.

## Terminal and security boundary

GhosttyKit v1.3.1 supplies the production terminal parser, GPU renderer, native text input and PTY. `TerminalSession` owns the resource-to-surface mapping and forwards focus, geometry, text and close events. Local sessions start `/bin/zsh` in the direct-download desktop process. The separate sandboxed browser/App Store target is intentionally deferred and must not share this entitlement boundary.

Ghostty owns terminal input buffering and process I/O. `TerminalSession` forwards text, raw control bytes, focus and geometry, retains the final text snapshot, and waits for surface shutdown before completing resource close. This contract is implementation evidence; successful interactive acceptance still requires the focused native GUI run.

SSH uses system `ssh`, arguments passed separately, explicit host checking and container-owned known_hosts. It does not scan user private keys or automatically accept unknown hosts. A running SSH process is not proof of authenticated connectivity.

The direct-download desktop target disables App Sandbox. Historical signed-sandbox denial of controlling-TTY/line-discipline ioctls remains documented in the earlier runtime report and is not evidence for this target. The future browser/App Store target will define a separate sandbox boundary.

## Agent context and provider contract

The provider panel explicitly selects Responses API or Codex CLI. CLI status distinguishes configured, checked, and unavailable states and provides terminal login guidance. CLI requests use a frozen path/model, an ephemeral read-only process, bounded JSONL output, and explicit failure/cancellation handling; a local CLI response does not constitute GUI or live interactive-runtime acceptance.

The Agent inspector presents a chat-first surface. A scrollable dialogue and bottom composer keep the question visible; Resources and Preview are opened by mutually exclusive buttons, while Settings uses `PanelCoordinator`. Resource selection and exact snapshot disclosures remain explicit. Empty guidance says “开始对话”, and a compact disabled-send hint identifies the missing resource/preview gate. Provider settings retain persistent labels and disable endpoint, model and secret inputs while saving or deleting credentials. “Configured; connection not verified” describes configuration presence without claiming a successful connection.

Resource selection is explicit. Read/Preview freezes source IDs and bounded contents before Send; selection changes require a matching new preview. Each resource permits at most 12,000 characters and a preview at most 48,000. Budget exhaustion and read failure remain visible and block submission until removed or reread. Runtime failure metadata is distinct from inability to read a resource.

Preview disclosures expose exact text, source ID/title/URL, time, range, truncation, known directory, lifecycle and errors. Run sources belong to the submitted request and remain available after resource closure. The chat displays the actual user/assistant messages from this window; each question links to its immutable request details. This transcript is display-only: each API request still contains its current question and explicit snapshots. Sending captures the question before clearing the composer. New chat cancels active reads/requests and clears the transcript, run details, draft, selected resources and previews; late results cannot repopulate the new chat. Retry preserves the original question, snapshots, endpoint and model; a fresh preview is a separate action. Cancellation invalidates late results and cancels the request task.

Only configured HTTPS Responses endpoints are supported. Endpoint and model may be stored in ordinary preferences. Secrets are write-only UI input to an endpoint-bound Keychain item; no secret is persisted in preferences or logs. Configuration presence does not claim a successful API response. Resource evidence is untrusted context, separate from system instructions; requests have no tools, hidden history or automatic action permissions.

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
page title owns a restrained static accent gradient and its native buttons/recency
rows expose hover and press feedback. Agent message reveal is local to rows; it does
not change Agent business logic or evidence gates. These are implementation rules;
they do not constitute runtime or GUI acceptance evidence.

Icon actions need meaningful labels, stable IDs and keyboard equivalents. Focus must remain in web/terminal input during ordinary toolbar and layout updates. Native semantics own appearance, contrast and reduced motion. Theme acceptance must use an app-level override, not a system-setting change.

No skipped destination-form test counts as a pass. The native UI suite targets current resource IDs and controls; compilation is separate from successful UI execution. Record model tests, actual native checks, runner initialization failures, sandbox restrictions and missing external configuration separately in [the earlier runtime acceptance report](output/six-features-acceptance.md) and [the current start-page/chat acceptance report](output/start-chat/acceptance.md).
