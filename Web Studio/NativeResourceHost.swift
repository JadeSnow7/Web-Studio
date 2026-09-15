import AppKit
import SwiftUI

/// Owns exactly one native runtime view at a time. SwiftUI may reuse the
/// representable while resource identity changes, so removal is scoped to our
/// container and never detaches a view owned by another host.
struct NativeResourceHost: NSViewRepresentable {
    let nativeView: NSView

    func makeNSView(context: Context) -> NativeResourceContainer {
        let container = NativeResourceContainer()
        container.mount(nativeView)
        return container
    }

    func updateNSView(_ nsView: NativeResourceContainer, context: Context) {
        nsView.mount(nativeView)
    }

    static func dismantleNSView(_ nsView: NativeResourceContainer, coordinator: ()) {
        nsView.unmount()
    }
}

final class NativeResourceContainer: NSView {
    private weak var mountedView: NSView?
    private var mountConstraints: [NSLayoutConstraint] = []

    func mount(_ view: NSView) {
        if mountedView === view, view.superview === self {
            return
        }
        if let old = mountedView, old.superview === self { old.removeFromSuperview() }
        NSLayoutConstraint.deactivate(mountConstraints)
        mountConstraints.removeAll()
        mountedView = view
        if view.superview !== self {
            view.removeFromSuperview()
            addSubview(view)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        mountConstraints = [
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(mountConstraints)
    }

    func unmount() {
        if let view = mountedView, view.superview === self { view.removeFromSuperview() }
        NSLayoutConstraint.deactivate(mountConstraints)
        mountConstraints.removeAll()
        mountedView = nil
    }
}
