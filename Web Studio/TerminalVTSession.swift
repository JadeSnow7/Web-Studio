#if WEB_STUDIO_VT
import AppKit
import Combine
import Foundation
import Security
import StudioVTCoreC

private final class VTFrameMailbox: @unchecked Sendable {
    private let lock = NSLock(); private var latest: VTFrame?; private var scheduled = false
    func offer(_ frame: VTFrame) -> Bool { lock.lock(); defer { lock.unlock() }; latest = frame; if scheduled { return false }; scheduled = true; return true }
    func take() -> VTFrame? { lock.lock(); defer { lock.unlock() }; let value = latest; latest = nil; scheduled = false; return value }
    func hasValue() -> Bool { lock.lock(); defer { lock.unlock() }; return latest != nil }
}

@MainActor
final class TerminalSession: NSObject, ObservableObject {
    enum State: Equatable { case idle, starting, running, exited(Int32?), failed(String), interrupted }
    let resourceID: UUID
    let terminalView: TerminalVTView
    var nativeView: NSView { terminalView }
    @Published private(set) var state: State = .idle
    @Published private(set) var knownDirectory: String?
    private let backend = GhosttyVTBackend(columns: 80, rows: 24)
    private var securityScopedURL: URL?
    private var closeRequested = false
    private var frame: VTFrame?
    private let frameMailbox = VTFrameMailbox()
    var onEncodedKeyForTesting: ((GhosttyKey, GhosttyMods, GhosttyKeyAction, String) -> Void)?

    init(resourceID: UUID, frame: CGRect = .zero) {
        self.resourceID = resourceID
        terminalView = TerminalVTView(session: nil)
        super.init()
        terminalView.session = self
        terminalView.frame = frame
        backend.onStart = { [weak self] ok, message in Task { @MainActor in self?.started(ok, message) } }
        backend.onFrame = { [weak self] frame in guard let self, self.frameMailbox.offer(frame) else { return }; Task { @MainActor in self.drainFrames() } }
        backend.onError = { [weak self] message in Task { @MainActor in self?.failed(message) } }
        backend.onExit = { [weak self] exit in Task { @MainActor in self?.exited(exit.code) } }
    }
    func setKnownDirectory(_ directory: String) { if state == .idle { knownDirectory = directory } }
    func retainSecurityScope(_ url: URL) { if url.startAccessingSecurityScopedResource() { securityScopedURL = url } }
    func startLocal(directory: String? = nil) {
        let cwd = directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        knownDirectory = cwd
        start(executable: "/bin/zsh", argv: ["zsh", "-il"], directory: cwd)
    }
    func startForTesting(executable: String, argv: [String], directory: String) { knownDirectory = directory; start(executable: executable, argv: argv, directory: directory) }
    func startSSH(host: String, user: String, port: Int, knownHosts: String) {
        guard valid(host), !host.hasPrefix("-"), user.isEmpty || valid(user), (1...65535).contains(port) else { failed("Invalid SSH connection details"); return }
        let args = ["ssh", "-o", "StrictHostKeyChecking=ask", "-o", "UserKnownHostsFile=\(knownHosts)", "-p", "\(port)"] + (user.isEmpty ? [] : ["-l", user]) + ["--", host]
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path
        knownDirectory = cwd
        start(executable: "/usr/bin/ssh", argv: args, directory: cwd)
    }
    private func start(executable: String, argv: [String], directory: String) {
        guard state == .idle else { return }
        if let rendererError = terminalView.rendererError { state = .failed(rendererError); return }
        state = .starting
        var env = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "ZDOTDIR": FileManager.default.homeDirectoryForCurrentUser.path,
                   "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color"]
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !socket.isEmpty { env["SSH_AUTH_SOCK"] = socket }
        let grid = terminalView.bounds.width > 0 ? terminalView.geometry.gridSize(for: terminalView.bounds.size) : (cols: 80, rows: 24)
        backend.start(executable: executable, argv: argv, environment: env, directory: directory, columns: grid.cols, rows: grid.rows, cellWidthPixels: Int(terminalView.geometry.cellPixelSize.width), cellHeightPixels: Int(terminalView.geometry.cellPixelSize.height))
    }
    private func started(_ ok: Bool, _ message: String?) { guard state == .starting else { return }; if ok { state = closeRequested ? .interrupted : .running } else { failed(message ?? "Unable to start terminal") } }
    private func failed(_ message: String) { state = .failed(message) }
    private func exited(_ code: Int32?) { drainFrames(); securityScopedURL?.stopAccessingSecurityScopedResource(); securityScopedURL = nil; if case .failed = state {} else { state = closeRequested ? .interrupted : .exited(code) } }
    private func normalizedDirectory(_ value: String) -> String? {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
        if !value.lowercased().hasPrefix("file://") && !value.hasPrefix("/") { return nil }
        guard let url = value.lowercased().hasPrefix("file://") ? URL(string: value) : URL(fileURLWithPath: value) else { return nil }
        guard url.isFileURL, url.path.hasPrefix("/"), url.path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return nil }
        return url.standardizedFileURL.path
    }
    private func drainFrames() { if let latest = frameMailbox.take() { frame = latest; if let pwd = backend.pwd(), let directory = normalizedDirectory(pwd) { knownDirectory = directory }; terminalView.update(frame: latest) }; if frameMailbox.hasValue() { Task { @MainActor in self.drainFrames() } } }
    func reportRenderError(_ message: String) { if state == .running { state = .failed(message) } }
    func sendRaw(_ data: Data) { _ = backend.sendRaw(data) }
    func send(data: Data) { sendRaw(data) }
    func resize(columns: Int, rows: Int, geometry: TerminalGeometry) { backend.resize(columns: columns, rows: rows, cellWidthPixels: Int(geometry.cellPixelSize.width), cellHeightPixels: Int(geometry.cellPixelSize.height)) }
    func resize(cols: Int, rows: Int) { backend.resize(columns: cols, rows: rows, cellWidthPixels: Int(geometryForCurrentView.cellPixelSize.width), cellHeightPixels: Int(geometryForCurrentView.cellPixelSize.height)) }
    private var geometryForCurrentView: TerminalGeometry { terminalView.geometry }
    func setTheme(_ theme: TerminalTheme) -> Bool { backend.setTheme(theme) }
    func setVisible(_ visible: Bool) { backend.setVisible(visible) }
    private func liveFrame() -> VTFrame? { backend.snapshot() ?? frame }
    private func boundedUTF8(_ data: Data, maxBytes: Int) -> Data {
        let limit = min(max(0, maxBytes), 64 * 1024)
        var result = Data(data.prefix(limit))
        while !result.isEmpty && String(data: result, encoding: .utf8) == nil { result.removeLast() }
        return result
    }
    func renderedText() -> String { String(decoding: boundedUTF8(liveFrame()?.visibleData ?? Data(), maxBytes: 64 * 1024), as: UTF8.self) }
    func currentFrameForTesting() -> VTFrame? { backend.snapshot() }
    var snapshotWasTruncated: Bool { liveFrame()?.snapshotTruncated ?? false }
    func renderedSnapshot(maxBytes: Int = 64 * 1024) -> Data { boundedUTF8(liveFrame()?.visibleData ?? Data(), maxBytes: maxBytes) }
    func scroll(toOffset offset: UInt64) { backend.scroll(toOffset: offset) }
    func scroll(rows: Int) { backend.scroll(rows: rows) }
    func scrollToBottom() { backend.scrollToBottom() }
    func selectDrag(startColumn: Int, startRow: Int, endColumn: Int, endRow: Int, behavior: Int = 0) { _ = backend.selectDrag(startColumn: startColumn, startRow: startRow, endColumn: endColumn, endRow: endRow, behavior: behavior) }
    func selectWord(column: Int, row: Int) { _ = backend.selectWord(column: column, row: row) }
    func selectLine(column: Int, row: Int) { _ = backend.selectLine(column: column, row: row) }
    func selectAll() { _ = backend.selectAll() }
    func clearSelection() { _ = backend.clearSelection() }
    func selectedText() -> String? { backend.selectedText() }
    @discardableResult func paste(_ text: String, allowUnsafe: Bool = false) -> Bool { backend.paste(text, allowUnsafe: allowUnsafe) }
    @discardableResult func selectionBegin(column: Int, row: Int, clickCount: Int) -> Bool { backend.selectionBegin(column: column, row: row, clickCount: clickCount) }
    @discardableResult func selectionUpdate(column: Int, row: Int) -> Bool { backend.selectionUpdate(column: column, row: row) }
    @discardableResult func selectionEnd() -> Bool { backend.selectionEnd() }
    func focus(_ focused: Bool) { backend.focus(focused) }
    func mouseReporting() -> Bool { backend.mouseReporting() }
    func sendMouse(action: Int, button: Int, modifiers: UInt32, point: CGPoint, geometry: VTMouseGeometry) { backend.mouse(action: action, button: button, modifiers: modifiers, xPixels: point.x, yPixels: point.y, geometry: geometry) }
    func actualPID() async -> pid_t? { backend.currentPID() }
    func encode(event: NSEvent, action: GhosttyKeyAction = GHOSTTY_KEY_ACTION_PRESS, textOverride: String? = nil, forceText: Bool = false) -> Bool {
        // Printable text belongs to NSTextInputClient so the input manager can compose it.
        // Keep control/navigation keys in the VT key path even when AppKit supplies a character.
        let nonTextKey = [36, 48, 51, 53, 99, 96, 97, 98, 100, 101, 103, 109, 111, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126].contains(event.keyCode)
        if !forceText && action != GHOSTTY_KEY_ACTION_RELEASE && event.characters != nil && !nonTextKey && !event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command) { return false }
        let key: GhosttyKey = keyFor(event.keyCode)
        guard key != GHOSTTY_KEY_UNIDENTIFIED else { return false }
        var mods = GhosttyMods(0); if event.modifierFlags.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }; if event.modifierFlags.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }; if event.modifierFlags.contains(.option) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if event.modifierFlags.contains(.command) { mods |= GhosttyMods(GHOSTTY_MODS_SUPER) }; if event.modifierFlags.contains(.capsLock) { mods |= GhosttyMods(GHOSTTY_MODS_CAPS_LOCK) }
        let text = textOverride ?? (forceText ? "" : (event.characters ?? ""))
        let encodedText = (event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command)) ? "" : text
        let unshiftedCodepoint: UInt32 = event.type == .flagsChanged ? 0 : (event.characters(byApplyingModifiers: [])?.unicodeScalars.first.map { $0.value } ?? 0)
        onEncodedKeyForTesting?(key, mods, action, encodedText)
        backend.encodeKey(key: key, modifiers: mods, action: action, text: encodedText, unshiftedCodepoint: unshiftedCodepoint)
        return true
    }
    func encodeKeyUp(event: NSEvent) { _ = encode(event: event, action: GHOSTTY_KEY_ACTION_RELEASE, forceText: true) }
    private func keyFor(_ code: UInt16) -> GhosttyKey { switch code {
      case 36: GHOSTTY_KEY_ENTER; case 48: GHOSTTY_KEY_TAB; case 49: GHOSTTY_KEY_SPACE; case 51: GHOSTTY_KEY_BACKSPACE; case 53: GHOSTTY_KEY_ESCAPE; case 117: GHOSTTY_KEY_DELETE
      case 115: GHOSTTY_KEY_HOME; case 119: GHOSTTY_KEY_END; case 116: GHOSTTY_KEY_PAGE_UP; case 121: GHOSTTY_KEY_PAGE_DOWN; case 123: GHOSTTY_KEY_ARROW_LEFT; case 124: GHOSTTY_KEY_ARROW_RIGHT; case 125: GHOSTTY_KEY_ARROW_DOWN; case 126: GHOSTTY_KEY_ARROW_UP
      case 122: GHOSTTY_KEY_F1; case 120: GHOSTTY_KEY_F2; case 99: GHOSTTY_KEY_F3; case 118: GHOSTTY_KEY_F4; case 96: GHOSTTY_KEY_F5; case 97: GHOSTTY_KEY_F6; case 98: GHOSTTY_KEY_F7; case 100: GHOSTTY_KEY_F8; case 101: GHOSTTY_KEY_F9; case 109: GHOSTTY_KEY_F10; case 103: GHOSTTY_KEY_F11; case 111: GHOSTTY_KEY_F12
      case 18: GHOSTTY_KEY_DIGIT_1; case 19: GHOSTTY_KEY_DIGIT_2; case 20: GHOSTTY_KEY_DIGIT_3; case 21: GHOSTTY_KEY_DIGIT_4; case 23: GHOSTTY_KEY_DIGIT_5; case 22: GHOSTTY_KEY_DIGIT_6; case 26: GHOSTTY_KEY_DIGIT_7; case 28: GHOSTTY_KEY_DIGIT_8; case 25: GHOSTTY_KEY_DIGIT_9; case 29: GHOSTTY_KEY_DIGIT_0
      case 27: GHOSTTY_KEY_MINUS; case 24: GHOSTTY_KEY_EQUAL; case 33: GHOSTTY_KEY_BRACKET_LEFT; case 30: GHOSTTY_KEY_BRACKET_RIGHT; case 42: GHOSTTY_KEY_BACKSLASH; case 41: GHOSTTY_KEY_SEMICOLON; case 39: GHOSTTY_KEY_QUOTE; case 43: GHOSTTY_KEY_COMMA; case 47: GHOSTTY_KEY_PERIOD; case 44: GHOSTTY_KEY_SLASH; case 50: GHOSTTY_KEY_BACKQUOTE
      case 56: GHOSTTY_KEY_SHIFT_LEFT; case 60: GHOSTTY_KEY_SHIFT_RIGHT; case 58: GHOSTTY_KEY_ALT_LEFT; case 61: GHOSTTY_KEY_ALT_RIGHT; case 59: GHOSTTY_KEY_CONTROL_LEFT; case 62: GHOSTTY_KEY_CONTROL_RIGHT; case 54: GHOSTTY_KEY_META_RIGHT; case 55: GHOSTTY_KEY_META_LEFT; case 57: GHOSTTY_KEY_CAPS_LOCK
      case 8: GHOSTTY_KEY_C; case 0: GHOSTTY_KEY_A; case 1: GHOSTTY_KEY_S; case 2: GHOSTTY_KEY_D; case 3: GHOSTTY_KEY_F; case 4: GHOSTTY_KEY_H; case 5: GHOSTTY_KEY_G; case 6: GHOSTTY_KEY_Z; case 7: GHOSTTY_KEY_X; case 9: GHOSTTY_KEY_V; case 11: GHOSTTY_KEY_B; case 12: GHOSTTY_KEY_Q; case 13: GHOSTTY_KEY_W; case 14: GHOSTTY_KEY_E; case 15: GHOSTTY_KEY_R; case 16: GHOSTTY_KEY_Y; case 17: GHOSTTY_KEY_T; case 31: GHOSTTY_KEY_O; case 32: GHOSTTY_KEY_U; case 34: GHOSTTY_KEY_I; case 35: GHOSTTY_KEY_P; case 37: GHOSTTY_KEY_L; case 38: GHOSTTY_KEY_J; case 40: GHOSTTY_KEY_K; case 45: GHOSTTY_KEY_N; case 46: GHOSTTY_KEY_M
      default: GHOSTTY_KEY_UNIDENTIFIED } }
    func close(interrupted: Bool = false) { closeRequested = true; if interrupted { state = .interrupted }; Task { await backend.closeAndWait() } }
    func closeAndWait() async { closeRequested = true; await backend.closeAndWait() }
    private func valid(_ value: String) -> Bool { !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value < 127 && $0 != " '".unicodeScalars.first! && $0 != "\"".unicodeScalars.first! } }
}
#endif
