#if WEB_STUDIO_VT
  import Foundation
  import StudioVTCoreC
  import Synchronization

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
    private var pwdStale = false
    private var lastPwd = ""
    private struct ResizeRequest: Equatable { let columns, rows, cellWidthPixels, cellHeightPixels: Int }
    private static let resizeInterval = DispatchTimeInterval.milliseconds(24)
    private var appliedResize: ResizeRequest?
    private var pendingResize: ResizeRequest?
    private var lastResizeApply: DispatchTime?
    private var resizeTimer: DispatchSourceTimer?
    private let publishDeferred = Atomic<Bool>(false)
    private let mouseTracking = Atomic<Bool>(false)
    private let themeLock = NSLock()
    private var appliedTheme: TerminalTheme?
    public var hasUndrainedFrame: (() -> Bool)?
    public var onStart: ((Bool, String?) -> Void)?
    public var onExit: ((TerminalPTYTransport.Exit) -> Void)?
    public var onError: ((String) -> Void)?
    public var onOutput: ((Data) -> Void)?
    public var onFrame: ((VTFrame) -> Void)?
    public var onDirectory: ((String) -> Void)?
    /// Non-fatal: called (on the PTY queue, or the caller's thread for `sendTyped`) when a small interactive write (key, focus/mouse report, query reply, typed text) exceeded even the interactive allowance and was dropped. Not routed through `onError`, which marks the session failed.
    public var onInputDropped: ((Int) -> Void)?
    private let droppedInteractive = Atomic<Int>(0)
    public var droppedInteractiveBytes: Int { droppedInteractive.load(ordering: .relaxed) }

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
        appliedResize = ResizeRequest(columns: columns, rows: rows, cellWidthPixels: cellWidthPixels, cellHeightPixels: cellHeightPixels)
        refreshModeMirror()
        transport.start(
          executable: executable, argv: argv, environment: environment, directory: directory,
          columns: columns, rows: rows, widthPixels: columns * cellWidthPixels, heightPixels: rows * cellHeightPixels)
      }
    }

    public func encodeKey(
      key: GhosttyKey, modifiers: GhosttyMods, action: GhosttyKeyAction, text: String, unshiftedCodepoint: UInt32 = 0
    ) {
      queue.async { [self] in
        if let data = core.encodeKey(key: key, modifiers: modifiers, action: action, text: text, unshiftedCodepoint: unshiftedCodepoint), !data.isEmpty {
          writeInteractive(data)
          core.scrollToBottom()
          scheduleFrame()
        }
      }
    }
    @discardableResult public func sendRaw(_ data: Data) -> Bool {
      let accepted = transport.write(data)
      if accepted, !data.isEmpty { queue.async { [self] in core.scrollToBottom(); scheduleFrame() } }
      return accepted
    }
    /// Committed keyboard text (IME, multi-character insertText). Same ordering as `sendRaw`, but uses the interactive allowance so it is not lost while a paste holds the bulk admission. Returns whether the bytes were accepted; a refusal is counted and reported like any interactive write. Programmatic sends stay on the bulk `sendRaw`.
    @discardableResult public func sendTyped(_ data: Data) -> Bool {
      let accepted = writeInteractive(data)
      if accepted, !data.isEmpty { queue.async { [self] in core.scrollToBottom(); scheduleFrame() } }
      return accepted
    }
    public func resize(
      columns: Int, rows: Int, cellWidthPixels: Int = 8, cellHeightPixels: Int = 16
    ) {
      queue.async { [self] in
        guard !closed else { return }
        let request = ResizeRequest(columns: columns, rows: rows, cellWidthPixels: cellWidthPixels, cellHeightPixels: cellHeightPixels)
        if resizeTimer != nil { pendingResize = request; return }
        guard request != appliedResize else { return }
        if let last = lastResizeApply, DispatchTime.now() < last + Self.resizeInterval {
          pendingResize = request
          let timer = DispatchSource.makeTimerSource(queue: queue)
          timer.setEventHandler { [weak self] in self?.flushResize() }
          resizeTimer = timer
          timer.schedule(deadline: last + Self.resizeInterval)
          timer.resume()
          return
        }
        applyResize(request)
      }
    }
    /// Trailing edge of a resize burst: applies the latest pending size unless it already equals the applied one.
    private func flushResize() {
      resizeTimer?.cancel()
      resizeTimer = nil
      guard !closed, let request = pendingResize else { return }
      pendingResize = nil
      if request != appliedResize { applyResize(request) }
    }
    /// The core reflow and the TIOCSWINSZ ioctl always go out together, in this order, for the same size.
    private func applyResize(_ request: ResizeRequest) {
      _ = core.resize(
        columns: request.columns, rows: request.rows, cellWidthPixels: request.cellWidthPixels,
        cellHeightPixels: request.cellHeightPixels)
      refreshModeMirror()
      transport.resize(
        columns: request.columns, rows: request.rows, widthPixels: request.columns * request.cellWidthPixels,
        heightPixels: request.rows * request.cellHeightPixels)
      appliedResize = request
      lastResizeApply = DispatchTime.now()
      scheduleFrame()
    }
    public func setTheme(_ theme: TerminalTheme) -> Bool {
      themeLock.lock(); let unchanged = appliedTheme == theme; themeLock.unlock()
      if unchanged { return true }
      return withQueue {
        let result = core.setTheme(theme)
        if result { themeLock.lock(); appliedTheme = theme; themeLock.unlock(); scheduleFrame() }
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
    // Fire-and-forget variants for callers that ignore the result (the Session). The serial queue orders them before any later synchronous read such as selectedText() or snapshot().
    public func selectDragAsync(startColumn: Int, startRow: Int, endColumn: Int, endRow: Int, behavior: Int = 0) { queue.async { [self] in if core.selectDrag(startColumn: startColumn, startRow: startRow, endColumn: endColumn, endRow: endRow, behavior: behavior) { scheduleFrame() } } }
    public func selectionBeginAsync(column: Int, row: Int, clickCount: Int = 1) { queue.async { [self] in if core.selectionBegin(column: column, row: row, clickCount: clickCount) { scheduleFrame() } } }
    public func selectionUpdateAsync(column: Int, row: Int) { queue.async { [self] in if core.selectionUpdate(column: column, row: row) { scheduleFrame() } } }
    public func selectionEndAsync() { queue.async { [self] in if core.selectionEnd() { scheduleFrame() } } }
    public func selectWordAsync(column: Int, row: Int) { queue.async { [self] in if core.selectWord(column: column, row: row) { scheduleFrame() } } }
    public func selectLineAsync(column: Int, row: Int) { queue.async { [self] in if core.selectLine(column: column, row: row) { scheduleFrame() } } }
    public func clearSelectionAsync() { queue.async { [self] in if core.clearSelection() { scheduleFrame() } } }
    public func selectAllAsync() { queue.async { [self] in if core.selectAll() { scheduleFrame() } } }
    public func selectedText() -> String? { withQueue { core.selectedText() } }
    public func paste(_ text: String, allowUnsafe: Bool = false) -> Bool { withQueue { let r = core.paste(text, allowUnsafe: allowUnsafe); let reply = core.takeQueryResponses(); guard r, !reply.isEmpty else { return false }; let accepted = transport.write(reply); if accepted { core.scrollToBottom(); scheduleFrame() }; return accepted } }
    public func focus(_ focused: Bool) { queue.async { [self] in if let data = core.focus(focused) { writeInteractive(data) } } }
    public func mouse(action: Int, button: Int, modifiers: UInt32, xPixels: Double, yPixels: Double, geometry: VTMouseGeometry) { queue.async { [self] in if let data = core.mouse(action: action, button: button, modifiers: modifiers, xPixels: xPixels, yPixels: yPixels, geometry: geometry) { writeInteractive(data) } } }
    /// Lock-free mirror refreshed on the PTY queue after every feed/resize; equals core.mouseReporting() whenever the queue is quiescent.
    public func mouseReporting() -> Bool { mouseTracking.load(ordering: .acquiring) }
    public func pwd() -> String? { withQueue { core.pwd() } }
    public func currentPID() -> pid_t? { transport.currentPID() }
    public var coreForTesting: TerminalVTCore { core }
    public var reservedInputForTesting: Int { transport.reservedInputForTesting }
    public func closeAndWait() async { await transport.closeAndWait() }

    private func withQueue<T>(_ body: () -> T) -> T {
      if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
      return queue.sync(execute: body)
    }

    /// Small control/typed writes use the interactive allowance; a refusal while the transport is still open is counted and reported, never swallowed. Safe from any thread (`onInputDropped` runs on the calling thread). `sendRaw` and `paste` are bulk and report acceptance to their caller.
    @discardableResult private func writeInteractive(_ data: Data) -> Bool {
      if transport.write(data, interactive: true) { return true }
      if transport.isAcceptingInput {
        droppedInteractive.add(data.count, ordering: .relaxed)
        onInputDropped?(data.count)
      }
      return false
    }

    private func consume(_ data: Data) {
      guard !closed else { return }
      guard !inOutput else { return }
      onOutput?(data)
      inOutput = true
      core.feed(data)
      pwdStale = true
      refreshModeMirror()
      let reply = core.takeQueryResponses()
      if !reply.isEmpty { writeInteractive(reply) }
      inOutput = false
      scheduleFrame()
    }
    private func refreshModeMirror() { mouseTracking.store(core.mouseReporting(), ordering: .releasing) }
    private func scheduleFrame() {
      guard visible, !framePending else { return }
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
    /// Frame consumers call this after taking a frame so a publish skipped while it was still undrained is re-armed.
    public func frameDrained() {
      guard publishDeferred.load(ordering: .sequentiallyConsistent) else { return }
      queue.async { [self] in if publishDeferred.exchange(false, ordering: .sequentiallyConsistent) { scheduleFrame() } }
    }
    private func publishFrame(force: Bool = false) {
      framePending = false
      guard visible else { return }
      if !force, let undrained = hasUndrainedFrame {
        publishDeferred.store(true, ordering: .sequentiallyConsistent)
        if undrained() { return }
        publishDeferred.store(false, ordering: .sequentiallyConsistent)
      }
      guard let frame = core.snapshot() else { return }
      onFrame?(frame)
      notifyDirectory()
    }
    /// Reads the cwd only after new input, and reports it only when the raw OSC 7 string actually changed.
    private func notifyDirectory() {
      guard pwdStale, let notify = onDirectory else { return }
      pwdStale = false
      guard let raw = core.pwd(), raw != lastPwd else { return }
      lastPwd = raw
      notify(raw)
    }
    private func finish(_ result: TerminalPTYTransport.Exit) {
      resizeTimer?.cancel()
      resizeTimer = nil
      if let request = pendingResize {
        // The child is gone (no ioctl needed) but the last requested size must still reach the core before the final frame.
        pendingResize = nil
        _ = core.resize(columns: request.columns, rows: request.rows, cellWidthPixels: request.cellWidthPixels, cellHeightPixels: request.cellHeightPixels)
        appliedResize = request
      }
      publishFrame(force: true)
      closed = true
      frameTimer?.cancel()
      frameTimer = nil
      onExit?(result)
    }
  }
#endif
