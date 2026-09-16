#if !WEB_STUDIO_VT
import AppKit
import Foundation
import GhosttyKit
import Darwin

/// The direct-download terminal backend. Ghostty owns the PTY, parser and
/// renderer; Web Studio owns the resource/session lifetime and the AppKit view.
///
/// This is deliberately a small adapter around the pinned GhosttyKit C API.
/// It keeps the product boundary independent from Ghostty's private Swift app
/// layer, which lets the future sandboxed/browser target choose another host.
@MainActor
final class GhosttyTerminalRuntime {
    static let shared = GhosttyTerminalRuntime()

    private var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var viewBySurface: [UInt: WeakSurfaceView] = [:]

    private final class WeakSurfaceView {
        weak var value: GhosttyTerminalView?
        init(_ value: GhosttyTerminalView) { self.value = value }
    }

    private init() {
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty/ghostty", isDirectory: true),
           FileManager.default.fileExists(atPath: resources.path) {
            setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
        }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else { return }
        let config = ghostty_config_new()
        // Keep the first integration deterministic. User Ghostty config files
        // are a future explicit preference, not an implicit source of keybinds
        // or commands for Web Studio resources.
        if let configPath = Bundle.main.resourceURL?.appendingPathComponent("ghostty/web-studio.conf").path {
            ghostty_config_load_file(config, configPath)
        }
        ghostty_config_finalize(config)
        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in GhosttyTerminalRuntime.wakeup(userdata) },
            action_cb: { app, target, action in GhosttyTerminalRuntime.action(app!, target: target, action: action) },
            read_clipboard_cb: { userdata, location, state in GhosttyTerminalRuntime.readClipboard(userdata, location: location, state: state) },
            confirm_read_clipboard_cb: { userdata, string, state, request in GhosttyTerminalRuntime.confirmReadClipboard(userdata, string: string, state: state, request: request) },
            write_clipboard_cb: { userdata, location, content, count, confirm in GhosttyTerminalRuntime.writeClipboard(userdata, location: location, content: content, count: count, confirm: confirm) },
            close_surface_cb: { userdata, processAlive in GhosttyTerminalRuntime.closeSurface(userdata, processAlive: processAlive) }
        )
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            return
        }
        self.config = config
        self.app = app

    }

    func makeView(directory: String, environment: [String: String], command: String, waitAfterCommand: Bool = false) -> GhosttyTerminalView? {
        guard let app else { return nil }
        let view = GhosttyTerminalView(frame: .zero)
        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        surfaceConfig.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_TAB
        surfaceConfig.wait_after_command = waitAfterCommand
        let create: ghostty_surface_t? = directory.withCString { cwd in
            surfaceConfig.working_directory = cwd
            return command.withCString { commandPointer in
                surfaceConfig.command = commandPointer
            return environment.withCStringPairs { pairs in
                surfaceConfig.env_vars = pairs.pointer
                surfaceConfig.env_var_count = pairs.count
                return ghostty_surface_new(app, &surfaceConfig)
            }
            }
        }
        guard let surface = create else { return nil }
        view.attach(surface: surface)
        viewBySurface[UInt(bitPattern: view.surfacePointer)] = WeakSurfaceView(view)
        return view
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    private static func runtime(_ userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalRuntime? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyTerminalRuntime>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            guard let runtime = runtime(userdata), let app = runtime.app else { return }
            ghostty_app_tick(app)
        }
    }

    private static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if action.tag == GHOSTTY_ACTION_PWD {
            guard let surface = target.target.surface,
                  let pointer = ghostty_surface_userdata(surface),
                  let pwd = action.action.pwd.pwd else { return true }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(pointer).takeUnretainedValue()
            let path = String(cString: pwd)
            DispatchQueue.main.async { view.onDirectoryChange?(path) }
            return true
        }
        guard action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED else { return false }
        guard let surface = target.target.surface else { return false }
        let viewPointer = ghostty_surface_userdata(surface)
        guard let viewPointer else { return false }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(viewPointer).takeUnretainedValue()
        // Ghostty's macOS login wrapper cannot reliably expose the child's
        // exit status. Preserve the stable-core fact as unknown instead of
        // turning its default value into a false success code.
        DispatchQueue.main.async { view.onChildExit?(nil) }
        return true
    }

    private static func readClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        guard let userdata,
              let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue() as GhosttyTerminalView?,
              let surface = view.surfacePointer else { return false }
        let value = NSPasteboard.general.string(forType: .string) ?? ""
        value.withCString { pointer in
            // `false` deliberately routes an ordinary paste through the
            // pinned confirmation callback; the string pointer is non-null.
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
        return true
    }

    private static func confirmReadClipboard(_ userdata: UnsafeMutableRawPointer?, string: UnsafePointer<CChar>?, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let userdata,
              let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue() as GhosttyTerminalView?,
              let surface = view.surfacePointer else { return }
        // Explicit paste is a user gesture and may be completed. OSC 52 reads
        // remain denied until a future user-facing permission sheet exists.
        let approved: Bool
        if request == GHOSTTY_CLIPBOARD_REQUEST_PASTE {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Paste into terminal?"
            alert.informativeText = "The terminal will receive the current clipboard text."
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            approved = alert.runModal() == .alertFirstButtonReturn
        } else {
            approved = false
        }
        let value = approved ? (string.map { String(cString: $0) } ?? "") : ""
        value.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, true)
        }
    }

    private static func writeClipboard(_ userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int, confirm: Bool) {
        guard !confirm, let content, count > 0 else { return }
        let pasteboard = NSPasteboard.general
        for index in 0..<count {
            let item = content[index]
            guard let data = item.data, let mime = item.mime, String(cString: mime) == "text/plain" else { continue }
            pasteboard.clearContents()
            pasteboard.setString(String(cString: data), forType: .string)
            break
        }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard !processAlive else { return }
        guard let userdata else { return }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async { view.onChildExit?(nil) }
    }
}
private extension Dictionary where Key == String, Value == String {
    func withCStringPairs<T>(_ body: (CStringPairs) throws -> T) rethrows -> T {
        let values = map { (key: strdup($0.key), value: strdup($0.value)) }
        defer { values.forEach { free($0.key); free($0.value) } }
        var pairs = values.map { ghostty_env_var_s(key: $0.key, value: $0.value) }
        return try pairs.withUnsafeMutableBufferPointer { buffer in
            try body(CStringPairs(pointer: buffer.baseAddress, count: buffer.count))
        }
    }
}

private struct CStringPairs {
    let pointer: UnsafeMutablePointer<ghostty_env_var_s>?
    let count: Int
}

/// Native Ghostty surface with AppKit text input and geometry forwarding.
@MainActor
final class GhosttyTerminalView: NSView, NSTextInputClient {
    private(set) var surfacePointer: ghostty_surface_t!
    var onChildExit: ((Int32?) -> Void)?
    var onDirectoryChange: ((String) -> Void)?
    private var markedTextValue = ""
    private var closeScheduled = false
    private var retainedText = ""
    private var keyTextAccumulator: String?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surfacePointer { ghostty_surface_set_focus(surfacePointer, true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        if let surfacePointer { ghostty_surface_set_focus(surfacePointer, false) }
        return super.resignFirstResponder()
    }

    func attach(surface: ghostty_surface_t) {
        surfacePointer = surface
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        registerForDraggedTypes([.string, .fileURL])
        updateTrackingAreas()
        needsLayout = true
    }

    func send(data: Data) {
        guard let surfacePointer, !data.isEmpty else { return }
        // `ghostty_surface_text` is the C API's paste operation and is not a
        // raw PTY write: control bytes such as Ctrl+C must go through a binding
        // action so Ghostty's key encoder preserves their meaning.
        let escaped = data.map { String(format: "\\x%02x", $0) }.joined()
        let action = "text:" + escaped
        action.withCString { ghostty_surface_binding_action(surfacePointer, $0, UInt(action.utf8.count)) }
    }

    func resize(cols: Int, rows: Int) {
        guard let surfacePointer else { return }
        let metrics = ghostty_surface_size(surfacePointer)
        guard metrics.cell_width_px > 0, metrics.cell_height_px > 0 else {
            needsLayout = true
            layoutSubtreeIfNeeded()
            return
        }
        let usedWidth = UInt32(metrics.columns) * metrics.cell_width_px
        let usedHeight = UInt32(metrics.rows) * metrics.cell_height_px
        let paddingWidth = metrics.width_px >= usedWidth ? metrics.width_px - usedWidth : 0
        let paddingHeight = metrics.height_px >= usedHeight ? metrics.height_px - usedHeight : 0
        ghostty_surface_set_size(surfacePointer,
                                  UInt32(max(1, cols)) * metrics.cell_width_px + paddingWidth,
                                  UInt32(max(1, rows)) * metrics.cell_height_px + paddingHeight)
    }

    func renderedText() -> String {
        guard let surfacePointer else { return retainedText }
        let size = ghostty_surface_size(surfacePointer)
        var selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: UInt32(size.columns), y: UInt32(size.rows)),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surfacePointer, selection, &text), let pointer = text.text else { return "" }
        defer { ghostty_surface_free_text(surfacePointer, &text) }
        return String(cString: pointer)
    }

    func close() {
        guard let surfacePointer, !closeScheduled else { return }
        closeScheduled = true
        ghostty_surface_request_close(surfacePointer)
        forceFree()
    }

    private func forceFree() {
        guard let surface = surfacePointer else { return }
        retainedText = renderedText()
        surfacePointer = nil
        ghostty_surface_free(surface)
        onChildExit?(nil)
    }

    override func layout() {
        super.layout()
        guard let surfacePointer else { return }
        let size = convertToBacking(bounds.size)
        guard size.width > 1, size.height > 1 else { return }
        ghostty_surface_set_size(surfacePointer, UInt32(max(1, size.width)), UInt32(max(1, size.height)))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surfacePointer else { return }
        let scale = window?.backingScaleFactor ?? 2
        ghostty_surface_set_content_scale(surfacePointer, scale, scale)
        layout()
    }

    override func keyDown(with event: NSEvent) {
        guard let surfacePointer else { return super.keyDown(with: event) }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = ""
        interpretKeyEvents([event])
        let text = keyTextAccumulator
        keyTextAccumulator = nil
        sendKey(surfacePointer, action: action, event: event,
                text: text?.isEmpty == true ? nil : text,
                composing: !markedTextValue.isEmpty)
    }

    override func keyUp(with event: NSEvent) {
        guard let surfacePointer else { return }
        sendKey(surfacePointer, action: GHOSTTY_ACTION_RELEASE, event: event, text: nil, composing: false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let surfacePointer else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surfacePointer, Double(point.x), Double(bounds.height - point.y), event.ghosttyMods(event.modifierFlags))
        ghostty_surface_mouse_button(surfacePointer, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event.ghosttyMods(event.modifierFlags))
    }
    override func mouseUp(with event: NSEvent) {
        guard let surfacePointer else { return }
        ghostty_surface_mouse_button(surfacePointer, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event.ghosttyMods(event.modifierFlags))
    }
    override func mouseMoved(with event: NSEvent) {
        updateMousePosition(event)
    }
    override func mouseDragged(with event: NSEvent) {
        // Selection is driven by the pressed left button; forwarding only
        // mouseMoved leaves the Ghostty surface at the initial cell.
        updateMousePosition(event)
    }
    override func scrollWheel(with event: NSEvent) {
        guard let surfacePointer else { return }
        ghostty_surface_mouse_scroll(surfacePointer, event.scrollingDeltaX, event.scrollingDeltaY, 0)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    private func updateMousePosition(_ event: NSEvent) {
        guard let surfacePointer else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surfacePointer, Double(point.x), Double(bounds.height - point.y), event.ghosttyMods(event.modifierFlags))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let value = string as? String { text = value }
        else if let value = string as? NSAttributedString { text = value.string }
        else { return }
        unmarkText()
        if var accumulator = keyTextAccumulator {
            accumulator.append(text)
            keyTextAccumulator = accumulator
        } else if let surfacePointer {
            text.withCString { ghostty_surface_text(surfacePointer, $0, UInt(text.utf8.count)) }
        }
        markedTextValue = ""
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedTextValue = attributed.string
        } else {
            markedTextValue = (string as? String) ?? ""
        }
        guard let surfacePointer else { return }
        markedTextValue.withCString { ghostty_surface_preedit(surfacePointer, $0, UInt(markedTextValue.utf8.count)) }
    }
    func unmarkText() {
        markedTextValue = ""
        if let surfacePointer { ghostty_surface_preedit(surfacePointer, nil, 0) }
    }
    func hasMarkedText() -> Bool { !markedTextValue.isEmpty }
    func markedRange() -> NSRange { markedTextValue.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedTextValue.utf16.count) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let caret = convert(NSRect(x: 0, y: max(0, bounds.height - 22), width: 1, height: 22), to: nil)
        return window?.convertToScreen(caret) ?? caret
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    private func sendKey(_ surface: ghostty_surface_t, action: ghostty_input_action_e,
                         event: NSEvent, text: String?, composing: Bool) {
        var key = event.ghosttyKeyEvent(action)
        key.composing = composing
        guard let text, !text.isEmpty, text.utf8.first ?? 0 >= 0x20 else {
            _ = ghostty_surface_key(surface, key)
            return
        }
        text.withCString { pointer in
            key.text = pointer
            _ = ghostty_surface_key(surface, key)
        }
    }

    deinit {
        if let surfacePointer { ghostty_surface_free(surfacePointer) }
    }
}
private extension NSEvent {
    func ghosttyKeyEvent(_ action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = ghosttyMods(modifierFlags)
        key.keycode = UInt32(keyCode)
        key.unshifted_codepoint = characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        return key
    }
    func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }
}
#endif
