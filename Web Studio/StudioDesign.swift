import SwiftUI
import AppKit
import WebKit

/// Shared visual language for the native workbench. Keep these values semantic so
/// macOS appearance, contrast, and accessibility settings remain authoritative.
enum StudioDesign {
    enum Motion {
        static let hover: TimeInterval = 0.12
        static let press: TimeInterval = 0.12
        static let selection: TimeInterval = 0.16
        static let panel: TimeInterval = 0.18
        static let message: TimeInterval = 0.18
        static func animation(_ duration: TimeInterval, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: duration)
        }
        static func messageTransition(reduceMotion: Bool) -> AnyTransition {
            reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4))
        }
    }
    enum Spacing {
        static let row: CGFloat = 8
        static let control: CGFloat = 12
        static let panel: CGFloat = 16
        static let inset: CGFloat = 20
    }

    enum Radius {
        static let row: CGFloat = 6
        static let panel: CGFloat = 10
    }

    enum Color {
        static let opaqueSurface = SwiftUI.Color(nsColor: .windowBackgroundColor)
        static let fieldFill = SwiftUI.Color(nsColor: .controlBackgroundColor).opacity(0.35)
        static let selectedFill = SwiftUI.Color.accentColor.opacity(0.14)
        static let groupSelectedFill = SwiftUI.Color.secondary.opacity(0.08)
        static let hoverFill = SwiftUI.Color.primary.opacity(0.06)
        static let divider = SwiftUI.Color.secondary.opacity(0.22)
        static let error = SwiftUI.Color.red
        static let warning = SwiftUI.Color.orange
    }
}

struct StudioPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isEnabled && configuration.isPressed ? StudioDesign.Color.selectedFill : (isEnabled && isHovered ? StudioDesign.Color.hoverFill : .clear), in: RoundedRectangle(cornerRadius: StudioDesign.Radius.row, style: .continuous))
            .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(StudioDesign.Motion.animation(StudioDesign.Motion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(StudioDesign.Motion.animation(StudioDesign.Motion.hover, reduceMotion: reduceMotion), value: isHovered)
            .onHover { if isEnabled { isHovered = $0 } else { isHovered = false } }
    }
}

extension View {
    func studioGlassSurface(cornerRadius: CGFloat = StudioDesign.Radius.panel) -> some View {
        modifier(StudioGlassSurfaceModifier(cornerRadius: cornerRadius))
    }

    func studioGlassCapsule() -> some View { modifier(StudioGlassCapsuleModifier()) }

    func studioGlassButton(prominent: Bool = false) -> some View {
        modifier(StudioGlassButtonModifier(prominent: prominent))
    }

    func studioFieldSurface() -> some View { modifier(StudioFieldSurfaceModifier()) }
    func studioShellScrim() -> some View { modifier(StudioShellScrimModifier()) }
    func studioHoverLift() -> some View { modifier(StudioHoverLiftModifier()) }
}

private struct StudioHoverLiftModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.offset(y: hovering && !reduceMotion ? -1 : 0)
            .animation(StudioDesign.Motion.animation(StudioDesign.Motion.hover, reduceMotion: reduceMotion), value: hovering)
            .onHover { hovering = $0 }
    }
}

private struct StudioGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let outline = contrast == .increased ? SwiftUI.Color.secondary.opacity(0.5) : StudioDesign.Color.divider
        content
            .background {
                Group {
                    if reduceTransparency { StudioDesign.Color.opaqueSurface }
                    else { StudioBackdrop(reduceTransparency: false).allowsHitTesting(false) }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(outline).allowsHitTesting(false) }
    }
}

private struct StudioGlassCapsuleModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let outline = contrast == .increased ? SwiftUI.Color.secondary.opacity(0.5) : StudioDesign.Color.divider
        content
            .background {
                Group {
                    if reduceTransparency { StudioDesign.Color.opaqueSurface }
                    else { StudioBackdrop(reduceTransparency: false).allowsHitTesting(false) }
                }
                .clipShape(Capsule())
            }
            .overlay { Capsule().stroke(outline).allowsHitTesting(false) }
    }
}

private struct StudioGlassButtonModifier: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule) }
        else { content.buttonStyle(.bordered).buttonBorderShape(.capsule) }
    }
}

private struct StudioFieldSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(StudioDesign.Color.opaqueSurface, in: RoundedRectangle(cornerRadius: StudioDesign.Radius.row, style: .continuous))
            } else {
                content.background(StudioDesign.Color.fieldFill, in: RoundedRectangle(cornerRadius: StudioDesign.Radius.row, style: .continuous))
            }
        }
    }
}

private struct StudioShellScrimModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.overlay(alignment: .trailing) { Rectangle().fill(contrast == .increased ? SwiftUI.Color.secondary.opacity(0.5) : StudioDesign.Color.divider).frame(width: 1).allowsHitTesting(false) }
    }
}

struct StudioBackdrop: NSViewRepresentable {
    let reduceTransparency: Bool
    func makeNSView(context: Context) -> StudioBackdropView {
        let view = StudioBackdropView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = reduceTransparency ? .windowBackground : .underWindowBackground
        view.isEmphasized = false
        return view
    }
    func updateNSView(_ view: StudioBackdropView, context: Context) {
        view.material = reduceTransparency ? .windowBackground : .underWindowBackground
        view.isEmphasized = false
    }
}

final class StudioBackdropView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A runtime-scoped page tint for the native toolbar band. The image is clipped to
/// the safe-area strip, softened, and veiled so native controls retain their contrast.
struct PageChromeBackdrop: View {
    @ObservedObject var runtime: WebTabRuntime
    let topInset: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var captureID: String {
        "\(runtime.resourceID.uuidString)|\(runtime.state.url?.absoluteString ?? "blank")|\(runtime.state.isLoading)|\(reduceTransparency)"
    }

    var body: some View {
        GeometryReader { _ in
            Group {
                if !reduceTransparency, let snapshot = runtime.chromeSnapshot {
                    Image(nsImage: snapshot)
                        .resizable(resizingMode: .stretch)
                        .scaledToFill()
                        .blur(radius: 18)
                        .overlay { SwiftUI.Color(nsColor: .windowBackgroundColor).opacity(0.42) }
                } else {
                    SwiftUI.Color(nsColor: .windowBackgroundColor)
                }
            }
            // The overlay ends at the content boundary; it never paints over the page.
            .frame(height: max(0, topInset))
            .clipped()
            .allowsHitTesting(false)
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: captureID) {
            guard !reduceTransparency else {
                runtime.clearChromeSnapshot()
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                await runtime.capturePageChromeSnapshot()
            }
        }
        .offset(y: -topInset)
        .onDisappear { runtime.clearChromeSnapshot() }
    }
}

struct StudioPanelSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .studioGlassSurface(cornerRadius: StudioDesign.Radius.panel)
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

struct StudioFieldLabel: View {
    let title: String
    var body: some View { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
}

struct StudioInlineFeedback: View {
    let message: String
    var isError = false
    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.circle" : "info.circle")
            .font(.caption)
            .foregroundStyle(isError ? StudioDesign.Color.error : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension ProviderSettings.Status {
    var studioLabel: String {
        switch self {
        case .notConfigured: return "Not configured"
        case .configuredUnverified: return "Configured; connection not verified"
        case .missingKey: return "Endpoint configured; API key missing"
        case .cliConfiguredUnverified: return "Codex CLI configured; login not checked"
        case .cliChecked: return "Codex CLI login checked"
        case .cliUnavailable: return "Codex CLI unavailable or not logged in"
        case .error: return "Provider status unavailable"
        }
    }
    var studioIsError: Bool { self == .error || self == .cliUnavailable }
}

func studioResourceSymbol(_ kind: ResourceKind) -> String {
    switch kind {
    case .web: return "globe"
    case .sshTerminal: return "server.rack"
    case .localTerminal: return "terminal"
    }
}

func studioResourceSymbol(_ destination: StudioDestination) -> String {
    switch destination {
    case .blank, .web: return studioResourceSymbol(.web)
    case .terminal: return studioResourceSymbol(.localTerminal)
    case .ssh: return studioResourceSymbol(.sshTerminal)
    }
}
