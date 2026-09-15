---
version: alpha
name: Web Studio
description: A native macOS resource workspace with vertical navigation and focused content panes.
typography:
  sans: { fontFamily: SF Pro system font }
  mono: { fontFamily: SF Mono system font }
nativeRadii: { row: 6pt, panel: 10pt }
spacing: { row: 8pt, control: 12pt, panel: 16pt, inset: 20pt }
components:
  toolbar: {}
  resource-navigation: {}
  control-panel: {}
  resource-store: {}
  web-runtime: {}
  terminal-runtime: {}
  layout: {}
  inspector: {}
ownership:
  toolbar: "StudioToolbar; address: StudioToolbar.addressField; workspace-tabs: StudioToolbar.workspaceTabsMenu"
  resource-navigation: "TabStrip and ResourceRow"
  control-panel: "PanelCoordinator"
  resource-store: "ResourceStore"
  web-runtime: "WebTabRuntime"
  terminal-runtime: "TerminalSession"
  layout: "StudioModel.layout and WorkspaceSplitView"
  inspector: "AgentInspectorView and ProviderSettingsView"
omitted:
  - section: colors
    reason: System semantic colors and SwiftUI materials are platform-owned rather than project hex tokens.
  - section: rounded
    reason: Native logical-point radii are recorded in nativeRadii and StudioDesign.Radius; the standard schema accepts only CSS units.
---

# Web Studio Design System

## Overview

### Creative North Star
A quiet native workbench: vertical resource navigation, clear pane focus, and compact controls above the content. The reference HTML supplies visual material; it does not define execution behavior.

### Product context and register
- **Audience and primary job:** Developers organize web and terminal resources and explicitly select content for an Agent question.
- **Market and evidence:** macOS desktop utility; the existing Xcode project owns platform behavior.
- **Language:** Simplified Chinese for the start page and chat surface; existing workspace controls and provider settings retain English copy. Dates use system locale formatting.
- **Usage scene:** Frequent keyboard and pointer use, including a 900×560 minimum content area.
- **Register:** Direct utility copy describing real state and recovery.
- **Signature:** Vertical resource entries, a session-only start page for blank web resources, and a pure Agent chat bar with button-opened advanced context. There is no horizontal tab strip.
- **Restraint:** No fabricated sessions or answers. Content belongs to its resource; the shell does not restyle websites.
- **Anti-references:** Browser-shaped mock content, log lists presented as interactive terminals, and simulated provider success.
- **Token ownership/runtime mapping:** SwiftUI semantic styles, AppKit colors, SF Symbols, system fonts and the canonical owners above. `premium-ui.json` records the native audit mapping.

## Colors
System accent indicates selection and focus. Native window, text and control colors adapt to appearance and contrast. Errors use a semantic error color and explanatory text, never color alone.

## Typography
SF Pro semantic styles for navigation, forms and snapshot text; monospace text for technical entry and terminal content. Long technical values truncate in navigation but remain inspectable in forms and previews.

## Layout
The toolbar occupies a transparent native window band above content, with a bounded, transient snapshot of the active web page softly tinting the top safe-area strip. The snapshot is captured from the existing visible WKWebView at low resolution, invalidated on navigation/failure, and never changes web content geometry or receives input. A semantic veil keeps native traffic lights and capsule controls readable; Reduce Transparency uses the opaque system surface fallback. Sidebar and Agent areas inherit the shared behind-window desktop frost layer and draw only semantic separators. Floating panels and capsules reuse the same native effect through clipped backgrounds; controls use native bordered capsule styles for focus and disabled behavior. The left sidebar remains the group navigation surface; a compact capsule immediately to the right of the editable address field switches resources within the selected group. Resource ownership is independent from a pane's placement. The minimum content area is 900×560; sidebars compact before primary operations become unreachable.

A native NSSplitView displays a single pane or a left-right pair. NativeResourceContainer mounts existing WebKit/Ghostty views. Model validation alone is not evidence of actual simultaneous display; manual acceptance remains separately recorded.

## Elevation & Depth
Use system materials and subtle native dividers. Floating control panels are transient, mutually exclusive surfaces; they appear only when requested. Normal controls do not float over web or terminal content.

## Shapes
Small radii use continuous native shapes for resource selection and panels; capsule geometry defines the shared toolbar control family. Native button focus, disabled and accessibility behavior must remain intact.

## Components

### Shared native language
Views use the shared `StudioDesign` tokens: an 8/12/16 spacing rhythm, 20pt form inset, 6pt resource-row radius and 10pt panel radius. `StudioPanelSurface` supplies decoration only; its content owns the panel geometry (320pt command/resource panels, 300pt group editor, 330pt destination form, and 460pt provider settings). Semantic system colors communicate selection, dividers, warnings and errors. Toolbar controls use one capsule family with stable icon hit targets; icon-only actions retain labels and help text.

Panels share the same material surface, header treatment, inset and action order: Cancel on the left and the primary action on the right. Forms keep persistent field labels above controls, initial focus, and inline feedback with text as well as status color.

Start-page actions and bookmark tiles use native rounded rectangles; toolbar controls retain their capsule family. The blank web resource shows `StartPageView`: three real actions, user-managed session destination snapshots, and up to five actual recently used resources. It never fabricates destinations. The Agent inspector is a chat-first surface with a scrollable transcript, a bottom composer, and compact buttons for Resources, Preview and provider settings. Advanced context remains explicit and uses the canonical panel coordinator.

### Foundational visual states
Every resource exposes its actual type and lifecycle. Focus and selection have a visible shape and accessible label. Do not present process creation as successful SSH authentication.

### Buttons and actions
Address entry and application commands remain separate actions: ⌘L focuses the persistent Web/SSH/terminal address field; ⌘K opens defined commands and resource search. The command palette never executes arbitrary Shell text.

### Navigation and data display
`TabStrip`, `ResourceRow`, and `StudioToolbar.workspaceTabsMenu` expose groups and ordered resources. Grouping is organizational, not a login or permission boundary. User titles take precedence over page-reported titles. Hidden-sidebar access remains available through the toolbar capsule, ⌘T, tab shortcuts and ⌘K search.

### Forms and overlays
`PanelCoordinator` owns one primary panel. Capture resource, pane, window and focus when opening; closing or moving resources must not silently redirect an action. Forms retain invalid input, identify their target, explain errors and support Escape. A closed target remains an explicit error.

### Iconography
globe identifies web pages, terminal identifies local terminals, and server.rack identifies SSH resources. Task groups use square.stack.3d.up; creating a group uses rectangle.stack.badge.plus. Icon actions require labels and help. Status needs text in addition to symbols.

### Motion
Motion is local and state-scoped. Shared `StudioDesign.Motion` tokens use 120ms for
hover/press, 160ms for resource selection, 180ms for panels and messages. Task and
resource buttons keep native semantics while adding quiet hover/press feedback;
resource selection moves only its accent marker. Floating panels use a stable
captured identity and a short opacity/6pt/0.98-scale entrance; the retiring surface
is disabled while it fades and focus is handed back immediately. The command panel
keeps its native input mounted while its single host uses the same opacity/6pt/0.98
entrance motion; focus transfers independently. Address focus styling is local.
`accessibilityReduceMotion` removes displacement and scale and
skips animation; `accessibilityReduceTransparency` retains the existing opaque
fallback and increased contrast retains strong focus. Runtime identity, geometry,
WebKit, SwiftTerm and split dragging are not animated. The start page uses a
low-saturation static accent radial gradient near its title, with native button and
recent-resource touch feedback. Agent rows use a short local fade/upward reveal;
message following remains scoped to existing transcript behavior.

### Resource surfaces
`ResourceStore` owns runtime lifetime. WebKit retains page state across view changes. In the direct-download target, `TerminalSession` owns one Ghostty surface per terminal resource while Ghostty owns that surface's PTY, parser and renderer. The SwiftTerm PTY seam remains test-only for deterministic adapter coverage. A terminal surface must report setup errors before presenting a running session; closing a resource requests Ghostty surface shutdown and releases the owned surface exactly once.

The current direct-download target disables App Sandbox so Ghostty can own a controlling TTY. Build and GUI acceptance remain separate evidence; the historical signed-sandbox result is retained only in the earlier acceptance report and does not describe this target.

### Content and data visualization
AgentInspectorView exposes explicit resource selection, exact text snapshot previews and fixed request sources. ProviderSettingsView configures endpoint/model and write-only Keychain credential input. Missing configuration and connection-unverified states are explicit. Requests, cancellation, failure and retry show real controller state; no production fake Provider is available.

## Do's and Don'ts
- Use native semantic controls, materials, focus and accessibility.
- Preserve resource and pane identity during layout operations.
- State failures and unavailable services accurately.
- Do not infer complete process semantics from terminal text.
- Do not add horizontal tabs, CSS chrome, arbitrary Shell commands in the palette, or hidden automatic resource collection. Pane content has no per-pane header; split focus uses a subtle content edge cue only.

## Verification
Actual results and limits are recorded in [the acceptance report](output/six-features-acceptance.md). Compilation, model checks, native interaction and external-service acceptance are separate evidence categories.
