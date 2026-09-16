#if WEB_STUDIO_VT
  import Foundation
  import CoreText
  import StudioVTCoreC

  public struct VTColor: Sendable, Equatable {
    public let red, green, blue: UInt8
    public init(_ c: GhosttyColorRgb) {
      red = c.r
      green = c.g
      blue = c.b
    }
    public init(_ r: Int, _ g: Int, _ b: Int) {
      red = UInt8(r)
      green = UInt8(g)
      blue = UInt8(b)
    }
    public init(rgb: UInt32) {
      red = UInt8((rgb >> 16) & 255)
      green = UInt8((rgb >> 8) & 255)
      blue = UInt8(rgb & 255)
    }
  }
  public struct VTCell: Sendable {
    public let text: String
    public let wide: GhosttyCellWide
    public let foreground, background, underline: VTColor
    public let selected, inverse, bold, italic, faint, blink, hidden, hasUnderline, strikethrough,
      overline: Bool
    public let underlineStyle: Int
  }
  public struct VTFrameCursor: Sendable {
    public let viewportHasValue: Bool
    public let x, y: Int
    public let visible, wideTail, blinking: Bool
    public let visualStyle: Int
  }
  public struct VTScrollbar: Sendable { public let total, offset, length: UInt64 }
  public struct VTFrame: Sendable {
    public let columns, rows: Int
    public let cells: [VTCell]
    public let visibleData: Data
    public let generation: UInt64
    public let background, foreground: VTColor
    public let cursorColor: VTColor?
    public let cursor: VTFrameCursor
    public let scrollbar: VTScrollbar
    public let snapshotTruncated: Bool
  }
  public struct VTMouseGeometry: Sendable {
    public let screenWidth, screenHeight, cellWidth, cellHeight: Int
    public let paddingTop, paddingBottom, paddingLeft, paddingRight: Int
    public init(screenWidth: Int, screenHeight: Int, cellWidth: Int, cellHeight: Int,
                paddingTop: Int = 0, paddingBottom: Int = 0, paddingLeft: Int = 0, paddingRight: Int = 0) {
      self.screenWidth = screenWidth; self.screenHeight = screenHeight; self.cellWidth = cellWidth; self.cellHeight = cellHeight
      self.paddingTop = paddingTop; self.paddingBottom = paddingBottom; self.paddingLeft = paddingLeft; self.paddingRight = paddingRight
    }
  }
  public final class TerminalVTCore: @unchecked Sendable {
    private final class ReplyBuffer { var data = Data() }
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let replies = ReplyBuffer()
    private var generation: UInt64 = 0
    private static let replyCallback: StudioVTReplyFn = { bytes, len, userdata in
      guard let userdata, let bytes else { return }
      let buffer = Unmanaged<ReplyBuffer>.fromOpaque(userdata).takeUnretainedValue()
      buffer.data.append(bytes, count: len)
    }
    public init(columns: Int, rows: Int) {
      let pointer = Unmanaged.passUnretained(replies).toOpaque()
      handle = studio_vt_create(
        UInt16(clamping: max(1, columns)), UInt16(clamping: max(1, rows)), 8, 16,
        Self.replyCallback, pointer)
    }
    public func close() {
      lock.lock()
      defer { lock.unlock() }
      if let h = handle {
        studio_vt_free(h)
        handle = nil
      }
    }
    deinit { close() }
    public func feed(_ data: Data) {
      lock.lock()
      defer { lock.unlock() }
      guard handle != nil else { return }
      data.withUnsafeBytes { p in
        studio_vt_feed(handle, p.bindMemory(to: UInt8.self).baseAddress, data.count)
      }
      generation &+= 1
    }
    public func takeQueryResponses() -> Data {
      lock.lock()
      defer { lock.unlock() }
      let result = replies.data
      replies.data.removeAll(keepingCapacity: true)
      return result
    }
    public func encodeKey(
      key: GhosttyKey, modifiers: GhosttyMods, action: GhosttyKeyAction, text: String, unshiftedCodepoint: UInt32 = 0
    ) -> Data? {
      lock.lock()
      defer { lock.unlock() }
      guard let handle else { return nil }
      var request = StudioVTKey()
      request.size = MemoryLayout<StudioVTKey>.size
      request.key = key
      request.mods = modifiers
      request.action = action
      request.unshifted_codepoint = unshiftedCodepoint
      var encoded: UnsafeMutablePointer<UInt8>?
      var length = 0
      let result = text.withCString { pointer in
        request.utf8 = pointer
        request.utf8_len = text.utf8.count
        return studio_vt_encode_key(handle, &request, &encoded, &length)
      }
      guard result == GHOSTTY_SUCCESS, let encoded else { return nil }
      defer { studio_vt_bytes_free(encoded) }
      return Data(bytes: encoded, count: length)
    }
    public func setTheme(_ theme: TerminalTheme) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard handle != nil, theme.palette.count == 256 else { return false }
      var t = StudioVTTheme()
      t.size = MemoryLayout<StudioVTTheme>.size
      t.has_foreground = true
      t.has_background = true
      t.has_cursor = true
      t.has_palette = true
      t.foreground = GhosttyColorRgb(
        r: theme.foreground.red, g: theme.foreground.green, b: theme.foreground.blue)
      t.background = GhosttyColorRgb(
        r: theme.background.red, g: theme.background.green, b: theme.background.blue)
      t.cursor = GhosttyColorRgb(r: theme.cursor.red, g: theme.cursor.green, b: theme.cursor.blue)
      let cPalette = theme.palette.map { GhosttyColorRgb(r: $0.red, g: $0.green, b: $0.blue) }
      withUnsafeMutableBytes(of: &t.palette) { dst in
        cPalette.withUnsafeBufferPointer { src in
          dst.copyBytes(from: UnsafeRawBufferPointer(src))
        }
      }
      generation += 1
      return studio_vt_set_theme(handle, &t) == GHOSTTY_SUCCESS
    }
    @discardableResult public func resize(
      columns: Int, rows: Int, cellWidthPixels: Int = 8, cellHeightPixels: Int = 16
    ) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard handle != nil else { return false }
      return studio_vt_resize(
        handle, UInt16(clamping: max(1, columns)), UInt16(clamping: max(1, rows)),
        UInt32(clamping: max(1, cellWidthPixels)), UInt32(clamping: max(1, cellHeightPixels)))
        == GHOSTTY_SUCCESS
    }
    public func snapshot() -> VTFrame? {
      lock.lock()
      defer { lock.unlock() }
      guard handle != nil else { return nil }
      var raw = StudioVTSnapshot()
      raw.size = MemoryLayout<StudioVTSnapshot>.size
      guard studio_vt_snapshot(handle, &raw) == GHOSTTY_SUCCESS else { return nil }
      defer { studio_vt_snapshot_free(&raw) }
      var cells: [VTCell] = []
      if let ptr = raw.cells {
        for i in 0..<raw.cell_count {
          let c = ptr[i]
          let b =
            raw.text.map { Data(bytes: $0.advanced(by: c.text_offset), count: c.text_len) }
            ?? Data()
          cells.append(
            VTCell(
              text: String(decoding: b, as: UTF8.self), wide: c.wide,
              foreground: VTColor(c.foreground), background: VTColor(c.background),
              underline: VTColor(c.underline), selected: c.selected, inverse: c.style.inverse,
              bold: c.style.bold, italic: c.style.italic, faint: c.style.faint,
              blink: c.style.blink, hidden: c.style.invisible, hasUnderline: c.has_underline,
              strikethrough: c.style.strikethrough, overline: c.style.overline,
              underlineStyle: Int(c.style.underline)))
        }
      }
      let v = raw.viewport_text.map { Data(bytes: $0, count: raw.viewport_text_len) } ?? Data()
      let cursor = VTFrameCursor(
        viewportHasValue: raw.cursor.viewport_has_value, x: Int(raw.cursor.viewport_x),
        y: Int(raw.cursor.viewport_y), visible: raw.cursor.visible, wideTail: raw.cursor.wide_tail,
        blinking: raw.cursor.blinking, visualStyle: Int(raw.cursor.visual_style.rawValue))
      let bar = VTScrollbar(
        total: raw.scrollbar.total, offset: raw.scrollbar.offset, length: raw.scrollbar.len)
      return VTFrame(
        columns: Int(raw.cols), rows: Int(raw.rows), cells: cells, visibleData: v,
        generation: generation, background: VTColor(raw.colors.background),
        foreground: VTColor(raw.colors.foreground),
        cursorColor: raw.colors.cursor_has_value ? VTColor(raw.colors.cursor) : nil, cursor: cursor,
        scrollbar: bar, snapshotTruncated: raw.viewport_text_truncated)
    }
    public func scroll(rows: Int) { lock.lock(); defer { lock.unlock() }; guard let handle else { return }; studio_vt_scroll_delta(handle, Int(rows)) }
    public func scroll(toOffset offset: UInt64) { lock.lock(); defer { lock.unlock() }; guard let handle else { return }; studio_vt_scroll_to(handle, Int(offset)) }
    public func scrollToBottom() { lock.lock(); defer { lock.unlock() }; guard let handle else { return }; studio_vt_scroll_bottom(handle) }
    @discardableResult public func selectionBegin(column: Int, row: Int, clickCount: Int = 1) -> Bool {
      lock.lock(); defer { lock.unlock() }; guard let handle else { return false }
      return studio_vt_selection_begin(handle, UInt16(clamping: column), UInt16(clamping: row), Int32(clickCount)) == GHOSTTY_SUCCESS
    }
    @discardableResult public func selectionUpdate(column: Int, row: Int) -> Bool { lock.lock(); defer { lock.unlock() }; guard let handle else { return false }; return studio_vt_selection_update(handle, UInt16(clamping: column), UInt16(clamping: row)) == GHOSTTY_SUCCESS }
    @discardableResult public func selectionEnd() -> Bool { lock.lock(); defer { lock.unlock() }; guard let handle else { return false }; let r = studio_vt_selection_end(handle); return r == GHOSTTY_SUCCESS }
    @discardableResult public func selectDrag(startColumn: Int, startRow: Int, endColumn: Int, endRow: Int, behavior: Int = 0) -> Bool {
      lock.lock(); defer { lock.unlock() }; guard let handle else { return false }
      return studio_vt_select_drag(handle, UInt16(clamping: startColumn), UInt16(clamping: startRow), UInt16(clamping: endColumn), UInt16(clamping: endRow), Int32(behavior)) == GHOSTTY_SUCCESS
    }
    @discardableResult public func selectWord(column: Int, row: Int) -> Bool { lock.lock(); defer { lock.unlock() }; guard let handle else { return false }; return studio_vt_select_word(handle, UInt16(clamping: column), UInt16(clamping: row)) == GHOSTTY_SUCCESS }
    @discardableResult public func selectLine(column: Int, row: Int) -> Bool { lock.lock(); defer { lock.unlock() }; guard let handle else { return false }; return studio_vt_select_line(handle, UInt16(clamping: column), UInt16(clamping: row)) == GHOSTTY_SUCCESS }
    @discardableResult public func clearSelection() -> Bool { lock.lock(); defer { lock.unlock() }; guard let handle else { return false }; return studio_vt_clear_selection(handle) == GHOSTTY_SUCCESS }
    @discardableResult public func selectAll() -> Bool { lock.lock(); defer { lock.unlock() }; guard let handle else { return false }; return studio_vt_select_all(handle) == GHOSTTY_SUCCESS }
    public func selectedText() -> String? { lock.lock(); defer { lock.unlock() }; guard let handle else { return nil }; var p: UnsafeMutablePointer<UInt8>?; var n = 0; guard studio_vt_selected_text(handle, &p, &n) == GHOSTTY_SUCCESS, let p else { return nil }; defer { studio_vt_bytes_free(p) }; return String(decoding: Data(bytes: p, count: n), as: UTF8.self) }
    @discardableResult public func paste(_ text: String, allowUnsafe: Bool = false) -> Bool { lock.lock(); defer { lock.unlock() }; guard let handle else { return false }; var written = false; let result = text.data(using: .utf8)!.withUnsafeBytes { b in studio_vt_paste(handle, b.bindMemory(to: UInt8.self).baseAddress, text.utf8.count, allowUnsafe, &written) }; return result == GHOSTTY_SUCCESS && written }
    public func focus(_ focused: Bool) -> Data? { lock.lock(); defer { lock.unlock() }; guard let handle else { return nil }; var p: UnsafeMutablePointer<UInt8>?; var n = 0; guard studio_vt_focus(handle, focused, &p, &n) == GHOSTTY_SUCCESS, let p else { return nil }; defer { studio_vt_bytes_free(p) }; return Data(bytes: p, count: n) }
    public func mouse(action: Int, button: Int, modifiers: UInt32, xPixels: Double, yPixels: Double, geometry: VTMouseGeometry) -> Data? { lock.lock(); defer { lock.unlock() }; guard let handle else { return nil }; var p: UnsafeMutablePointer<UInt8>?; var n = 0; let result = studio_vt_mouse(handle, Int32(action), Int32(button), modifiers, xPixels, yPixels, UInt32(clamping: geometry.screenWidth), UInt32(clamping: geometry.screenHeight), UInt32(clamping: geometry.cellWidth), UInt32(clamping: geometry.cellHeight), UInt32(clamping: geometry.paddingTop), UInt32(clamping: geometry.paddingBottom), UInt32(clamping: geometry.paddingLeft), UInt32(clamping: geometry.paddingRight), &p, &n); guard result == GHOSTTY_SUCCESS, let p else { return nil }; defer { studio_vt_bytes_free(p) }; return Data(bytes: p, count: n) }
    public func mouseReporting() -> Bool { lock.lock(); defer { lock.unlock() }; guard let handle else { return false }; return studio_vt_mouse_reporting(handle) }
    public func pwd() -> String? { lock.lock(); defer { lock.unlock() }; guard let handle else { return nil }; var p: UnsafeMutablePointer<UInt8>?; var n = 0; guard studio_vt_pwd(handle, &p, &n) == GHOSTTY_SUCCESS, let p else { return nil }; defer { studio_vt_bytes_free(p) }; return String(decoding: Data(bytes: p, count: n), as: UTF8.self) }
  }
#endif
