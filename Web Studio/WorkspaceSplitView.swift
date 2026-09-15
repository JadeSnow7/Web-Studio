import AppKit
import SwiftUI

struct WorkspaceSplitView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        NativeWorkspaceSplit(model: model)
    }
}

private struct NativeWorkspaceSplit: NSViewRepresentable {
    @ObservedObject var model: StudioModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSSplitView { context.coordinator.splitView }
    func updateNSView(_ split: NSSplitView, context: Context) { context.coordinator.update() }
    final class Coordinator: NSObject, NSSplitViewDelegate {
        let model: StudioModel
        let splitView = ManagedSplitView()
        var hosts: [UUID: NSHostingView<AnyView>] = [:]
        private var applying = false
        private var suppressResizeCallback = false
        private var pointerMonitor: Any?
        init(model: StudioModel) {
            self.model = model; super.init(); splitView.isVertical = true; splitView.dividerStyle = .thin; splitView.delegate = self
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, self.model.panels.panel == nil, let window = self.splitView.window, event.window === window else { return event }
                let point = self.splitView.convert(event.locationInWindow, from: nil)
                guard let hit = self.splitView.subviews.first(where: { $0.frame.contains(point) }), let paneID = UUID(uuidString: hit.identifier?.rawValue.replacingOccurrences(of: "pane.", with: "") ?? "") else { return event }
                self.model.focusPane(paneID)
                return event
            }
        }
        deinit { if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) } }
        func update() {
            guard !applying else { return }
            suppressResizeCallback = true
            let panes = [model.layout.primary] + (model.layout.secondary.map { [$0] } ?? [])
            let ids = Set(panes.map(\.id))
            for (id, host) in hosts where !ids.contains(id) { if host.superview === splitView { host.removeFromSuperview() }; hosts.removeValue(forKey: id) }
            var ordered: [NSView] = []
            for pane in panes {
                let host: NSHostingView<AnyView>
                if let existing = hosts[pane.id] { host = existing } else { host = NSHostingView(rootView: AnyView(SplitPaneView(model: model, pane: pane))); hosts[pane.id] = host }
                host.rootView = AnyView(SplitPaneView(model: model, pane: pane)); host.identifier = NSUserInterfaceItemIdentifier("pane.\(pane.id.uuidString)")
                ordered.append(host)
            }
            if splitView.subviews != ordered {
                applying = true
                splitView.subviews.forEach { $0.removeFromSuperview() }
                ordered.forEach { splitView.addSubview($0) }
                applying = false
            }
            if panes.count == 2, splitView.bounds.width > 0 {
                let desired = min(max(splitView.bounds.width * CGFloat(model.layout.splitRatio), 180), max(180, splitView.bounds.width - 180))
                if abs(splitView.subviews[0].frame.width - desired) > 1 { splitView.setPosition(desired, ofDividerAt: 0) }
            }
            splitView.adjustSubviews()
            if panes.count == 1, let host = splitView.subviews.first, host.frame != splitView.bounds {
                host.frame = splitView.bounds
            }
            splitView.needsLayout = true
            DispatchQueue.main.async { [weak self] in self?.suppressResizeCallback = false }
        }
        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !applying, !suppressResizeCallback, splitView.bounds.width > 0, splitView.subviews.count == 2 else { return }
            let ratio = Double(splitView.subviews[0].frame.width / splitView.bounds.width)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.applying else { return }
                if abs(self.model.layout.splitRatio - ratio) > 0.001 { self.model.setSplitRatio(ratio) }
            }
        }
        func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { min(max(proposedPosition, 180), max(180, splitView.bounds.width - 180)) }
    }

    final class ManagedSplitView: NSSplitView {
        override func layout() {
            super.layout()
            guard bounds.width > 0, bounds.height > 0 else { return }
            adjustSubviews()
            if subviews.count == 1 {
                subviews[0].frame = bounds
            } else if subviews.count == 2,
                      subviews.allSatisfy({ $0.frame.width <= 0 || $0.frame.height <= 0 }) {
                let divider = dividerThickness
                let left = floor((bounds.width - divider) * 0.5)
                subviews[0].frame = NSRect(x: 0, y: 0, width: left, height: bounds.height)
                subviews[1].frame = NSRect(x: left + divider, y: 0,
                                            width: bounds.width - left - divider, height: bounds.height)
            }
        }
    }
}

private struct SplitPaneView: View {
    @ObservedObject var model: StudioModel
    let pane: PaneState
    var body: some View {
        Group {
            if let id = pane.resourceID { SplitResourceHost(model: model, resourceID: id).id(pane.id) }
        }
        // The content itself is the pane. A single pane has no chrome; in a split,
        // the focused pane gets only a quiet edge cue so content remains primary.
        .overlay {
            if model.layout.isSplit && pane.isFocused {
                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if model.layout.isSplit { model.focusPane(pane.id) } }
    }
}

private struct SplitResourceHost: View {
    @ObservedObject var model: StudioModel
    let resourceID: UUID
    var body: some View {
        Group {
            if let record = model.webRuntimes.records[resourceID] {
                switch record.location {
                case let .web(url):
                    if let url, let runtime = model.webRuntimes.runtime(for: resourceID) { WebTabView(runtime: runtime, url: url) }
                    else { StartPageView(model: model, resourceID: resourceID) }
                case .localTerminal, .ssh: if let session = model.webRuntimes.terminalSession(for: resourceID) { TerminalSessionView(session: session) } else { Text("Terminal unavailable") }
                }
            } else { Text("Resource unavailable") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
