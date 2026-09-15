import AppKit
import SwiftUI

struct WindowLifecycle: NSViewRepresentable {
    @ObservedObject var model: StudioModel
    func makeNSView(context: Context) -> LifecycleView { LifecycleView(model: model) }
    func updateNSView(_ nsView: LifecycleView, context: Context) { nsView.model = model }
}

final class LifecycleView: NSView {
    var model: StudioModel
    private var proxy: WindowDelegateProxy?
    init(model: StudioModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        if proxy == nil || window.delegate !== proxy {
            proxy = WindowDelegateProxy(original: window.delegate, model: model)
            window.delegate = proxy
        }
    }
    override func removeFromSuperview() {
        if let window, window.delegate === proxy { window.delegate = proxy?.original }
        proxy = nil
        super.removeFromSuperview()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.delegate === proxy { window.delegate = proxy?.original }
        super.viewWillMove(toWindow: newWindow)
    }
}

final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    let model: StudioModel
    private var closing = false
    init(original: NSWindowDelegate?, model: StudioModel) { self.original = original; self.model = model }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))), original.windowShouldClose?(sender) == false { return false }
        guard !closing else { return false }
        if model.webRuntimes.liveTerminalCount > 0 {
            let alert = NSAlert(); alert.messageText = "Terminal sessions are still running"; alert.informativeText = "Closing will terminate the terminal subprocesses."; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Terminate")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        closing = true
        Task { @MainActor [model, weak sender] in
            model.agentController.shutdown()
            await model.webRuntimes.shutdown()
            sender?.close()
        }
        return false
    }
    override func responds(to selector: Selector) -> Bool { super.responds(to: selector) || (original?.responds(to: selector) ?? false) }
    override func forwardingTarget(for selector: Selector) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
}
