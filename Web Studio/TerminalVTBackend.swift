#if WEB_STUDIO_VT
  import Foundation
  import StudioVTCoreC

  public protocol TerminalBackend: AnyObject {
    func start(
      executable: String, argv: [String], environment: [String: String], directory: String?,
      columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int)
    @discardableResult func sendRaw(_ data: Data) -> Bool
    func resize(columns: Int, rows: Int, cellWidthPixels: Int, cellHeightPixels: Int)
    func setTheme(_ theme: TerminalTheme) -> Bool
    func snapshot() -> VTFrame?
    func scroll(rows: Int)
    func scroll(toOffset: UInt64)
    func scrollToBottom()
    func selectDrag(startColumn: Int, startRow: Int, endColumn: Int, endRow: Int, behavior: Int) -> Bool
    func selectionBegin(column: Int, row: Int, clickCount: Int) -> Bool
    func selectionUpdate(column: Int, row: Int) -> Bool
    func selectionEnd() -> Bool
    func selectWord(column: Int, row: Int) -> Bool
    func selectLine(column: Int, row: Int) -> Bool
    func clearSelection() -> Bool
    func selectAll() -> Bool
    func selectedText() -> String?
    func paste(_ text: String, allowUnsafe: Bool) -> Bool
    func focus(_ focused: Bool)
    func mouse(action: Int, button: Int, modifiers: UInt32, xPixels: Double, yPixels: Double, geometry: VTMouseGeometry)
    func mouseReporting() -> Bool
    func pwd() -> String?
    func closeAndWait() async
    func currentPID() -> pid_t?
  }

  public final class GhosttyVTBackend: @unchecked Sendable, TerminalBackend {
    public let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let transport: TerminalPTYTransport
    private let core: TerminalVTCore
    private var frameTimer: DispatchSourceTimer?
    private var framePending = false
    private var visible = true
    private var started = false
    private var closed = false
    private var inOutput = false
    private var lastFrame: VTFrame?
    public var onStart: ((Bool, String?) -> Void)?
    public var onExit: ((TerminalPTYTransport.Exit) -> Void)?
    public var onError: ((String) -> Void)?
    public var onOutput: ((Data) -> Void)?
    public var onFrame: ((VTFrame) -> Void)?

    public init(columns: Int, rows: Int) {
      core = TerminalVTCore(columns: columns, rows: rows)
      transport = TerminalPTYTransport()
      queue = transport.queue
      queue.setSpecific(key: queueKey, value: 1)
      transport.onOutput = { [weak self] data in self?.consume(data) }
      transport.onStart = { [weak self] ok, error in self?.onStart?(ok, error) }
      transport.onError = { [weak self] error in self?.onError?(error) }
      transport.onExit = { [weak self] result in self?.finish(result) }
    }

    public func start(
      executable: String, argv: [String], environment: [String: String], directory: String?,
      columns: Int, rows: Int, cellWidthPixels: Int = 8, cellHeightPixels: Int = 16
    ) {
      queue.async { [self] in
        guard !started, !closed else { return }
        started = true
        guard core.snapshot() != nil else {
          onError?("VT core initialization failed")
          finish(.init(code: nil, signal: nil))
          return
        }
        _ = core.resize(columns: columns, rows: rows, cellWidthPixels: cellWidthPixels, cellHeightPixels: cellHeightPixels)
        transport.start(
          executable: executable, argv: argv, environment: environment, directory: directory,
          columns: columns, rows: rows, widthPixels: columns * cellWidthPixels, heightPixels: rows * cellHeightPixels)
      }
    }

    public func encodeKey(
      key: GhosttyKey, modifiers: GhosttyMods, action: GhosttyKeyAction, text: String, unshiftedCodepoint: UInt32 = 0
    ) {
      queue.async { [self] in
        if let data = core.encodeKey(key: key, modifiers: modifiers, action: action, text: text, unshiftedCodepoint: unshiftedCodepoint) {
          _ = transport.write(data)
          core.scrollToBottom()
          scheduleFrame()
        }
      }
    }
    @discardableResult public func sendRaw(_ data: Data) -> Bool {
      let accepted = transport.write(data)
      if accepted { queue.async { [self] in core.scrollToBottom(); scheduleFrame() } }
      return accepted
    }
    public func resize(
      columns: Int, rows: Int, cellWidthPixels: Int = 8, cellHeightPixels: Int = 16
    ) {
      queue.async { [self] in
        guard !closed else { return }
        _ = core.resize(
          columns: columns, rows: rows, cellWidthPixels: cellWidthPixels,
          cellHeightPixels: cellHeightPixels)
        transport.resize(
          columns: columns, rows: rows, widthPixels: columns * cellWidthPixels,
          heightPixels: rows * cellHeightPixels)
        scheduleFrame()
      }
    }
    public func setTheme(_ theme: TerminalTheme) -> Bool {
      withQueue {
        let result = core.setTheme(theme)
        if result { scheduleFrame() }
        return result
      }
    }
    public func setVisible(_ value: Bool) {
      queue.async { [self] in
        visible = value
        if value { scheduleFrame() }
      }
    }
    public func snapshot() -> VTFrame? { withQueue { core.snapshot() } }
    public func scroll(rows: Int) { queue.async { [self] in core.scroll(rows: rows); scheduleFrame() } }
    public func scroll(toOffset offset: UInt64) { queue.async { [self] in core.scroll(toOffset: offset); scheduleFrame() } }
    public func scrollToBottom() { queue.async { [self] in core.scrollToBottom(); scheduleFrame() } }
    public func selectDrag(startColumn: Int, startRow: Int, endColumn: Int, endRow: Int, behavior: Int = 0) -> Bool { withQueue { let r = core.selectDrag(startColumn: startColumn, startRow: startRow, endColumn: endColumn, endRow: endRow, behavior: behavior); if r { scheduleFrame() }; return r } }
    public func selectionBegin(column: Int, row: Int, clickCount: Int = 1) -> Bool { withQueue { let r = core.selectionBegin(column: column, row: row, clickCount: clickCount); if r { scheduleFrame() }; return r } }
    public func selectionUpdate(column: Int, row: Int) -> Bool { withQueue { let r = core.selectionUpdate(column: column, row: row); if r { scheduleFrame() }; return r } }
    public func selectionEnd() -> Bool { withQueue { let r = core.selectionEnd(); if r { scheduleFrame() }; return r } }
    public func selectWord(column: Int, row: Int) -> Bool { withQueue { let r = core.selectWord(column: column, row: row); if r { scheduleFrame() }; return r } }
    public func selectLine(column: Int, row: Int) -> Bool { withQueue { let r = core.selectLine(column: column, row: row); if r { scheduleFrame() }; return r } }
    public func clearSelection() -> Bool { withQueue { let r = core.clearSelection(); if r { scheduleFrame() }; return r } }
    public func selectAll() -> Bool { withQueue { let r = core.selectAll(); if r { scheduleFrame() }; return r } }
    public func selectedText() -> String? { withQueue { core.selectedText() } }
    public func paste(_ text: String, allowUnsafe: Bool = false) -> Bool { withQueue { let r = core.paste(text, allowUnsafe: allowUnsafe); let reply = core.takeQueryResponses(); guard r, !reply.isEmpty else { return false }; let accepted = transport.write(reply); if accepted { core.scrollToBottom(); scheduleFrame() }; return accepted } }
    public func focus(_ focused: Bool) { queue.async { [self] in if let data = core.focus(focused) { _ = transport.write(data) } } }
    public func mouse(action: Int, button: Int, modifiers: UInt32, xPixels: Double, yPixels: Double, geometry: VTMouseGeometry) { queue.async { [self] in if let data = core.mouse(action: action, button: button, modifiers: modifiers, xPixels: xPixels, yPixels: yPixels, geometry: geometry) { _ = transport.write(data) } } }
    public func mouseReporting() -> Bool { withQueue { core.mouseReporting() } }
    public func pwd() -> String? { withQueue { core.pwd() } }
    public func currentPID() -> pid_t? { transport.currentPID() }
    public func closeAndWait() async { await transport.closeAndWait() }

    private func withQueue<T>(_ body: () -> T) -> T {
      if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
      return queue.sync(execute: body)
    }

    private func consume(_ data: Data) {
      guard !closed else { return }
      guard !inOutput else { return }
      onOutput?(data)
      inOutput = true
      core.feed(data)
      let reply = core.takeQueryResponses()
      if !reply.isEmpty { _ = transport.write(reply) }
      inOutput = false
      scheduleFrame()
    }
    private func scheduleFrame() {
      guard !framePending else { return }
      framePending = true
      if frameTimer == nil {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.publishFrame() }
        frameTimer = timer
        timer.schedule(deadline: .now() + .milliseconds(16))
        timer.resume()
      } else {
        frameTimer?.schedule(deadline: .now() + .milliseconds(16))
      }
    }
    private func publishFrame() {
      framePending = false
      guard let frame = core.snapshot() else { return }
      lastFrame = frame
      if visible { onFrame?(frame) }
    }
    private func finish(_ result: TerminalPTYTransport.Exit) {
      publishFrame()
      closed = true
      frameTimer?.cancel()
      frameTimer = nil
      onExit?(result)
    }
  }
#endif
