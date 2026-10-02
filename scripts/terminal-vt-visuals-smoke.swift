import AppKit
import Darwin
import Foundation
import StudioVTCoreC

// Headless check of the pure accessibility-fingerprint helpers in TerminalVisuals.swift, driven by real
// TerminalVTCore frames. Also prints (never asserts) how much the old per-frame AX model cost by comparison.
// Compiled with -DVISUALS_VIEW (host-style, includes TerminalVTView) it additionally checks the view: lazy AX model
// equivalence/freshness against a copy of the old per-frame algorithm, and layout behaviour.

// Allocation counter (best effort): libmalloc's malloc_logger hook, resolved at run time.
nonisolated(unsafe) let allocCounter: UnsafeMutablePointer<Int> = { let p = UnsafeMutablePointer<Int>.allocate(capacity: 1); p.pointee = 0; return p }()
let mallocLoggerCallback: @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void = { type, _, _, _, _, _ in if type & 2 != 0 { allocCounter.pointee += 1 } }
func countAllocations(_ body: () -> Void) -> Int? {
  guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
  let slot = symbol.assumingMemoryBound(to: (@convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void)?.self)
  allocCounter.pointee = 0
  slot.pointee = mallocLoggerCallback
  body()
  slot.pointee = nil
  return allocCounter.pointee
}

// Verbatim copy of the old TerminalVTView.accessibilityModel() text/selection computation (cells array included),
// used only as a behavioural reference and cost comparison.
struct OldAXCell { let range: NSRange; let row: Int; let frame: NSRect }
func oldAccessibilityModel(_ frame: VTFrame, geometry: TerminalGeometry, boundsHeight: CGFloat) -> (text: String, cells: [OldAXCell], selection: NSRange) {
  var text = "", cells: [OldAXCell] = [], selectedStart: Int?, selectedEnd: Int?, utf16Offset = 0
  text.reserveCapacity(frame.rows * (frame.columns + 1))
  for row in 0..<frame.rows {
    for column in 0..<frame.columns {
      let cell = frame.cells[row * frame.columns + column]
      if cell.wide.rawValue == 2 || cell.wide.rawValue == 3 { continue }
      let value = cell.text.isEmpty ? " " : cell.text; let start = utf16Offset; let length = value.utf16.count; text += value; utf16Offset += length
      let width = cell.wide.rawValue == 1 ? geometry.cellSize.width * 2 : geometry.cellSize.width
      let origin = geometry.origin(for: column, row: row)
      let localFrame = NSRect(x: origin.x, y: boundsHeight - origin.y - geometry.cellSize.height, width: width, height: geometry.cellSize.height)
      cells.append(OldAXCell(range: NSRange(location: start, length: length), row: row, frame: localFrame))
      if cell.selected { selectedStart = min(selectedStart ?? start, start); selectedEnd = utf16Offset }
    }
    if row + 1 < frame.rows { text += "\n"; utf16Offset += 1 }
  }
  let selection = selectedStart.flatMap { s in selectedEnd.map { NSRange(location: s, length: max(0, $0 - s)) } } ?? NSRange(location: NSNotFound, length: 0)
  return (text, cells, selection)
}
func oldFingerprint(_ frame: VTFrame, geometry: TerminalGeometry, boundsHeight: CGFloat) -> String {
  let m = oldAccessibilityModel(frame, geometry: geometry, boundsHeight: boundsHeight)
  let bar = frame.scrollbar
  return "\(frame.generation)|\(frame.columns)x\(frame.rows)|\(bar.offset):\(bar.length):\(bar.total)|\(m.text.utf16.count)|\(m.selection.location):\(m.selection.length)"
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func snap(_ core: TerminalVTCore) -> VTFrame { guard let f = core.snapshot() else { fputs("FAIL: snapshot returned nil\n", stderr); exit(1) }; return f }
func fp(_ f: VTFrame) -> TerminalAccessibilityFingerprint { TerminalAccessibilityFingerprint(frame: f) }
func manualSelection(_ f: VTFrame) -> (first: Int, last: Int, count: Int) {
  var first = -1, last = -1, count = 0
  for (i, c) in f.cells.enumerated() where c.selected { if first < 0 { first = i }; last = i; count += 1 }
  return (first, last, count)
}
func lines(_ n: Int, prefix: String = "line") -> Data { Data((1...n).map { "\(prefix) \($0)\r\n" }.joined().utf8) }

@main @MainActor struct Smoke {
  static func main() {
    // 1. Identical frames -> equal fingerprints; empty selection is the documented "none" value.
    let core = TerminalVTCore(columns: 20, rows: 4)
    core.feed(lines(12))
    let a = snap(core), b = snap(core)
    check(fp(a) == fp(b), "identical frames must have equal fingerprints")
    check(fp(a).selection == .none && fp(a).selection == TerminalSelectionSignature(first: -1, last: -1, count: 0), "no selection must give TerminalSelectionSignature.none")
    check(fp(a).generation == a.generation && fp(a).columns == 20 && fp(a).rows == 4, "fingerprint must carry generation and grid")
    check(fp(a).scrollTotal == a.scrollbar.total && fp(a).scrollOffset == a.scrollbar.offset && fp(a).scrollLength == a.scrollbar.length, "fingerprint must carry the scrollbar")
    check(a.scrollbar.total > a.scrollbar.length, "fixture must have scrollback (total \(a.scrollbar.total) length \(a.scrollbar.length))")

    // 2. Feed changes the fingerprint (generation), the grid stays the same.
    core.feed(Data("more".utf8))
    let afterFeed = snap(core)
    check(fp(afterFeed) != fp(a) && fp(afterFeed).generation != fp(a).generation, "feed must change the fingerprint")
    check(fp(afterFeed).selection == fp(a).selection, "feed alone must not change the selection signature")

    // 3. Scroll changes the fingerprint through the scrollbar offset only (generation is not bumped by scrolling).
    core.scroll(rows: -3)
    let scrolled = snap(core)
    check(scrolled.generation == afterFeed.generation && scrolled.scrollbar.offset != afterFeed.scrollbar.offset, "scroll must move the scrollbar offset without changing the core generation")
    check(fp(scrolled) != fp(afterFeed) && fp(scrolled).scrollOffset != fp(afterFeed).scrollOffset, "scroll must change the fingerprint")
    core.scrollToBottom()
    check(fp(snap(core)) == fp(afterFeed), "scrolling back to the bottom must restore the fingerprint")

    // 4. Resize changes the fingerprint through columns/rows (generation is not bumped by resize).
    let before = snap(core)
    core.resize(columns: 30, rows: 6)
    let resized = snap(core)
    check(resized.generation == before.generation && (resized.columns, resized.rows) == (30, 6), "resize must change the grid without changing the core generation")
    check(fp(resized) != fp(before) && fp(resized).columns == 30 && fp(resized).rows == 6, "resize must change the fingerprint")
    core.resize(columns: 20, rows: 4)
    check(fp(snap(core)).columns == 20, "resize back")
    core.resize(columns: 20, rows: 5)
    check(fp(snap(core)) != fp(before), "a rows-only resize must change the fingerprint")
    core.resize(columns: 20, rows: 4)

    // 5. Theme changes bump the generation, so they change the fingerprint.
    let themeBefore = snap(core)
    check(core.setTheme(.light), "setTheme(light)")
    check(fp(snap(core)) != fp(themeBefore), "theme change must change the fingerprint")

    // 6. Selection: signature follows selectAll / clear / drag; stable when nothing changes; does not touch the generation.
    let plain = snap(core)
    check(core.selectAll(), "selectAll")
    let all1 = snap(core), all2 = snap(core)
    let allSig = fp(all1).selection
    check(allSig != .none && allSig.count > 0 && allSig.first >= 0 && allSig.last >= allSig.first, "selectAll must produce a non-empty signature: \(allSig)")
    check(fp(all1) == fp(all2), "selection must be stable across identical frames")
    check((allSig.first, allSig.last, allSig.count) == manualSelection(all1) as (Int, Int, Int), "signature must equal a manual scan: \(allSig) vs \(manualSelection(all1))")
    check(all1.generation == plain.generation && fp(all1) != fp(plain), "selection changes the fingerprint (selection is part of it) without touching the generation")
    check(core.clearSelection(), "clearSelection")
    check(fp(snap(core)) == fp(plain) && fp(snap(core)).selection == .none, "clearing the selection must restore the fingerprint")
    check(core.selectDrag(startColumn: 1, startRow: 0, endColumn: 4, endRow: 0), "selectDrag")
    let drag = snap(core); let dragSig = fp(drag).selection
    check(dragSig != .none && dragSig != allSig && dragSig.count == 4 && dragSig.last - dragSig.first == 3, "drag 1..4 on row 0 must select 4 contiguous cells: \(dragSig)")
    check(core.selectDrag(startColumn: 1, startRow: 0, endColumn: 6, endRow: 0), "selectDrag wider")
    check(fp(snap(core)).selection != dragSig && fp(snap(core)).selection.count == 6, "extending the drag must change the signature")
    check(core.selectDrag(startColumn: 1, startRow: 0, endColumn: 4, endRow: 1), "selectDrag two rows")
    let twoRow = fp(snap(core)).selection
    check(twoRow.first == 1 && twoRow.last == 20 + 4 && twoRow.count == 24, "linear two-row selection (row 0 col 1 .. row 1 col 4) must cover cells 1...24: \(twoRow)")
    // the begin/update/end path used by the mouse handlers
    check(core.clearSelection(), "clear")
    check(core.selectionBegin(column: 2, row: 2, clickCount: 1), "selectionBegin")
    check(core.selectionUpdate(column: 7, row: 2), "selectionUpdate")
    let mid = fp(snap(core)).selection
    check(core.selectionEnd(), "selectionEnd")
    let ended = fp(snap(core)).selection
    check(mid != .none && ended == mid, "selectionEnd must not change the selected cells")
    check(core.clearSelection(), "clear again")

    // 7. Wide / CJK cells: head, spacer tail, emoji; signature scans every cell, old AX selection semantics agree on "changed".
    let cjk = TerminalVTCore(columns: 24, rows: 3)
    cjk.feed(Data("中文AB🙂C\r\nplain row".utf8))
    let cjkPlain = snap(cjk)
    check(cjkPlain.cells.contains { $0.wide.rawValue == 1 } && cjkPlain.cells.contains { $0.wide.rawValue == 2 }, "fixture must contain wide head and spacer tail cells")
    let geometry = TerminalGeometry(backingScale: 2)
    var previous: (frame: VTFrame, model: (text: String, cells: [OldAXCell], selection: NSRange))? = nil
    var oldChangedSigSame = 0, compared = 0
    for (sc, ec) in [(0, 0), (0, 1), (0, 3), (1, 3), (2, 5), (2, 8), (0, 9), (4, 9), (5, 9)] {
      check(cjk.selectDrag(startColumn: sc, startRow: 0, endColumn: ec, endRow: 0), "cjk selectDrag \(sc)-\(ec)")
      let f = snap(cjk); let m = oldAccessibilityModel(f, geometry: geometry, boundsHeight: 400); let s = fp(f).selection
      let manual = manualSelection(f)
      check((s.first, s.last, s.count) == manual as (Int, Int, Int), "cjk signature vs manual scan for \(sc)-\(ec)")
      check(s != .none && s.first <= s.last && s.count <= s.last - s.first + 1, "cjk signature sanity \(sc)-\(ec): \(s)")
      if let p = previous {
        compared += 1
        // the new signature must be at least as sensitive as the old AX selection range
        if p.model.selection != m.selection && fp(p.frame).selection == s { oldChangedSigSame += 1 }
      }
      previous = (f, m)
    }
    check(oldChangedSigSame == 0, "signature missed \(oldChangedSigSame) of \(compared) selection changes that the old AX selection range detected")
    check(cjk.clearSelection() && fp(snap(cjk)).selection == .none, "cjk clear")
    check(fp(snap(cjk)) == fp(cjkPlain), "cjk fingerprint restored after clear")

    // 8. Old fingerprint parity for the cases the old one covered: whenever the old fingerprint changes between two
    //    frames of the same session, the new one changes too (never a missed valueChanged), across feed/scroll/resize/theme/selection.
    let parity = TerminalVTCore(columns: 30, rows: 5)
    parity.feed(lines(20, prefix: "parity 中文"))
    var frames: [VTFrame] = [snap(parity)]
    parity.feed(Data("x".utf8)); frames.append(snap(parity))
    parity.scroll(rows: -4); frames.append(snap(parity))
    parity.scrollToBottom(); frames.append(snap(parity))
    parity.resize(columns: 40, rows: 6); frames.append(snap(parity))
    _ = parity.setTheme(.light); frames.append(snap(parity))
    _ = parity.selectAll(); frames.append(snap(parity))
    _ = parity.clearSelection(); frames.append(snap(parity))
    var missed = 0
    for i in 0..<frames.count { for j in (i + 1)..<frames.count where j < frames.count {
      let oldChanged = oldFingerprint(frames[i], geometry: geometry, boundsHeight: 400) != oldFingerprint(frames[j], geometry: geometry, boundsHeight: 400)
      let newChanged = fp(frames[i]) != fp(frames[j])
      if oldChanged && !newChanged { missed += 1 }
    } }
    check(missed == 0, "new fingerprint missed \(missed) frame pairs that the old fingerprint told apart")

    // 9. Cost comparison (printed only). 134x45 screen full of mixed ASCII/CJK text with a multi-row selection.
    let big = TerminalVTCore(columns: 134, rows: 45)
    big.feed(Data((1...60).map { "row \($0): the quick brown fox jumps over the lazy dog 中文测试 ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789\r\n" }.joined().utf8))
    _ = big.selectDrag(startColumn: 3, startRow: 5, endColumn: 90, endRow: 20)
    let bigFrame = snap(big)
    let iterations = 200
    var sink = 0
    let newTime: Double = { let t = DispatchTime.now().uptimeNanoseconds; for _ in 0..<iterations { let f = fp(bigFrame); sink &+= f.selection.count &+ Int(truncatingIfNeeded: f.generation) }; return Double(DispatchTime.now().uptimeNanoseconds - t) / Double(iterations) / 1000 }()
    let oldTime: Double = { let t = DispatchTime.now().uptimeNanoseconds; for _ in 0..<iterations { sink &+= oldFingerprint(bigFrame, geometry: geometry, boundsHeight: 900).utf8.count }; return Double(DispatchTime.now().uptimeNanoseconds - t) / Double(iterations) / 1000 }()
    let newAllocs = countAllocations { for _ in 0..<iterations { let f = fp(bigFrame); sink &+= f.selection.count } }
    let oldAllocs = countAllocations { for _ in 0..<iterations { sink &+= oldFingerprint(bigFrame, geometry: geometry, boundsHeight: 900).utf8.count } }
    let sanity = countAllocations { var xs = [Int](repeating: 1, count: 1024); xs[0] = sink; sink &+= xs.count }
    func perIter(_ v: Int?) -> String { v.map { String(format: "%.2f", Double($0) / Double(iterations)) } ?? "unavailable" }
    print("MEASURE 134x45 fingerprint (\(bigFrame.cells.count) cells, \(iterations) iterations, swiftc -O, one process, not a benchmark):")
    print("MEASURE   new TerminalAccessibilityFingerprint: \(String(format: "%.2f", newTime)) us/frame, mallocs/frame \(perIter(newAllocs))")
    print("MEASURE   old accessibilityModel()+string fingerprint: \(String(format: "%.2f", oldTime)) us/frame, mallocs/frame \(perIter(oldAllocs))")
    print("MEASURE   malloc counter sanity (one 8 KiB array alloc): \(sanity.map(String.init) ?? "unavailable") (expect >= 1); sink=\(sink & 1)")
#if VISUALS_VIEW
    viewChecks()
#endif
    print("Terminal VT visuals smoke passed")
  }
}

#if VISUALS_VIEW
final class ResizeLog { var sends: [(cols: Int, rows: Int, cellPixels: CGSize)] = [] }
struct ViewFixture {
  let session: TerminalSession, view: TerminalVTView, window: NSWindow, container: NSView, log = ResizeLog()
  init(width: CGFloat = 640, height: CGFloat = 400) {
    _ = NSApplication.shared; NSApplication.shared.setActivationPolicy(.prohibited)
    session = TerminalSession(resourceID: UUID()); view = session.terminalView
    let log = self.log
    view.onResizeSentForTesting = { log.sends.append(($0, $1, $2)) }
    window = NSWindow(contentRect: NSRect(x: 137, y: 211, width: 640, height: 400), styleMask: [], backing: .buffered, defer: true)
    container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400)); window.contentView = container; container.addSubview(view)
    view.frame = NSRect(x: 17, y: 23, width: width, height: height)
    window.orderOut(nil); view.layoutSubtreeIfNeeded()
  }
  var grid: (cols: Int, rows: Int) { view.geometry.gridSize(for: view.bounds.size) }
  func screen(_ r: NSRect) -> NSRect { window.convertToScreen(view.convert(r, to: nil)) }
}
// Compares every AX getter the view exposes against the old algorithm run on the same frame, geometry and bounds.
func checkAXGetters(_ fx: ViewFixture, _ frame: VTFrame, _ label: String) {
  let view = fx.view
  let ref = oldAccessibilityModel(frame, geometry: view.geometry, boundsHeight: view.bounds.height)
  let count = ref.text.utf16.count
  check((view.accessibilityValue() as? String) == ref.text, "\(label): accessibilityValue differs from the reference model")
  check(view.accessibilityNumberOfCharacters() == count, "\(label): accessibilityNumberOfCharacters")
  check(view.accessibilitySelectedTextRange() == ref.selection, "\(label): accessibilitySelectedTextRange \(view.accessibilitySelectedTextRange()) vs \(ref.selection)")
  check(view.accessibilityVisibleCharacterRange() == NSRange(location: 0, length: count), "\(label): accessibilityVisibleCharacterRange")
  let expectedSelected = ref.selection.location == NSNotFound ? "" : (ref.text as NSString).substring(with: ref.selection)
  check(view.accessibilitySelectedText() == expectedSelected, "\(label): accessibilitySelectedText")
  check(view.accessibilitySelectedTextRanges() == (ref.selection.location == NSNotFound ? [] : [NSValue(range: ref.selection)]), "\(label): accessibilitySelectedTextRanges")
  check(view.accessibilityString(for: NSRange(location: 0, length: count)) == ref.text && view.accessibilityString(for: NSRange(location: count + 1, length: 0)) == nil, "\(label): accessibilityString(for:)")
  for line in [0, frame.rows / 2, frame.rows - 1, frame.rows] {
    let first = ref.cells.first(where: { $0.row == line }); let end = ref.cells.last(where: { $0.row == line })?.range
    var expected = NSRange(location: NSNotFound, length: 0)
    if let first { expected = NSRange(location: first.range.location, length: end.map { NSMaxRange($0) - first.range.location } ?? 0) }
    check(view.accessibilityRange(forLine: line) == expected, "\(label): accessibilityRange(forLine: \(line))")
  }
  for index in stride(from: 0, to: count, by: max(1, count / 23)) {
    check(view.accessibilityLine(for: index) == (ref.cells.last(where: { $0.range.location <= index })?.row ?? NSNotFound), "\(label): accessibilityLine(for: \(index))")
    let expectedRange = (ref.text as NSString).character(at: index) == 10 ? NSRange(location: index, length: 1) : (ref.cells.first(where: { NSLocationInRange(index, $0.range) })?.range ?? NSRange(location: NSNotFound, length: 0))
    check(view.accessibilityRange(for: index) == expectedRange, "\(label): accessibilityRange(for: \(index))")
    let hits = ref.cells.filter { NSIntersectionRange($0.range, NSRange(location: index, length: 3)).length > 0 }
    if let first = hits.first, index + 3 <= count {
      let union = hits.dropFirst().reduce(first.frame) { $0.union($1.frame) }
      check(view.accessibilityFrame(for: NSRange(location: index, length: 3)) == fx.screen(union), "\(label): accessibilityFrame(for: \(index)+3) (cell frames embed geometry/bounds)")
      check(view.accessibilityRange(for: NSPoint(x: fx.screen(first.frame).midX, y: fx.screen(first.frame).midY)) == first.range, "\(label): accessibilityRange(for: point) at index \(index)")
    }
  }
}
func viewChecks() {
  // AX model: getters equal the old per-frame algorithm; the lazily built model is never stale.
  let fx = ViewFixture()
  let view = fx.view
  check(view.accessibilityValue() as? String == fx.session.renderedText(), "no frame yet: AX value must fall back to the session's live text")
  let grid = fx.grid
  let core = TerminalVTCore(columns: grid.cols, rows: grid.rows)
  core.feed(Data("AX 中文 🙂 first\r\nsecond row\r\n".utf8) + lines(6, prefix: "row"))
  let f1 = snap(core)
  view.update(frame: f1)
  checkAXGetters(fx, f1, "frame 1")
  checkAXGetters(fx, f1, "frame 1 (cache warm)")
  core.feed(Data("MORE OUTPUT 界\r\n".utf8))
  let f2 = snap(core)
  view.update(frame: f2)
  check((view.accessibilityValue() as? String) != oldAccessibilityModel(f1, geometry: view.geometry, boundsHeight: view.bounds.height).text, "a new frame must invalidate the cached AX model")
  checkAXGetters(fx, f2, "frame 2 (after feed)")
  check(core.selectDrag(startColumn: 3, startRow: 0, endColumn: 12, endRow: 1), "selectDrag")
  let f3 = snap(core)
  check(f3.generation == f2.generation, "selection keeps the generation")
  view.update(frame: f3)
  check(view.accessibilitySelectedTextRange().location != NSNotFound, "selection must reach the AX model")
  checkAXGetters(fx, f3, "frame 3 (selection only)")
  core.scroll(rows: -2)
  let f4 = snap(core)
  view.update(frame: f4)
  checkAXGetters(fx, f4, "frame 4 (scrolled)")
  // Bounds change without a new frame: cell frames embed bounds.height, so the cached model must be rebuilt.
  let framesBefore = view.accessibilityFrame(for: NSRange(location: 0, length: 3))
  fx.view.frame = NSRect(x: 17, y: 23, width: 640, height: 300); fx.view.layoutSubtreeIfNeeded()
  checkAXGetters(fx, f4, "frame 4 (bounds height changed)")
  check(view.accessibilityFrame(for: NSRange(location: 0, length: 3)) != framesBefore, "cell frames must follow the new bounds")
  fx.view.frame = NSRect(x: 17, y: 23, width: 500, height: 300); fx.view.layoutSubtreeIfNeeded()
  checkAXGetters(fx, f4, "frame 4 (bounds width changed)")
  print("VIEW AX model: getters equal the reference algorithm across feed/selection/scroll/bounds changes")
  layoutChecks()
}
// The backend applies the first resize of a burst at once but coalesces later ones into a ~24 ms trailing edge, so the core is polled
// rather than read straight after layout.
func coreFollowsGrid(_ fx: ViewFixture) -> Bool {
  for _ in 0..<200 {
    if let f = fx.session.currentFrameForTesting(), (f.columns, f.rows) == (fx.grid.cols, fx.grid.rows) { return true }
    Thread.sleep(forTimeInterval: 0.01)
  }
  return false
}
func layoutChecks() {
  // layout(): session.resize only when (cols, rows, cell pixel size) changed since the last request; drawableSize always follows bounds.
  let fx = ViewFixture(width: 606, height: 354)
  let view = fx.view, log = fx.log
  func relayout(_ label: String) { view.needsDisplay = false; view.needsLayout = true; view.layoutSubtreeIfNeeded(); check(view.needsDisplay, "\(label): layout must leave the view needing display (sanity only: AppKit marks it too, mutation of layout()'s own needsDisplay is not detected)") }
  func expectedDrawable() -> CGSize { CGSize(width: view.bounds.width * view.geometry.backingScale, height: view.bounds.height * view.geometry.backingScale) }
  check(log.sends.count == 1, "first layout must send exactly one resize (got \(log.sends.count))")
  check(log.sends[0].cols == fx.grid.cols && log.sends[0].rows == fx.grid.rows && log.sends[0].cellPixels == view.geometry.cellPixelSize, "first resize carries the laid out grid and cell pixel size")
  check(view.drawableSize == expectedDrawable() && view.drawableSize.width > 0, "drawableSize must follow bounds * scale after the first layout")
  check(coreFollowsGrid(fx), "the backend core must have received the first grid")
  for i in 1...3 { relayout("repeat \(i)") }
  check(log.sends.count == 1, "identical layouts must not re-send the resize (sends: \(log.sends.count))")
  view.frame = NSRect(x: 17, y: 23, width: 500, height: 300); view.layoutSubtreeIfNeeded()
  check(log.sends.count == 2 && log.sends[1].cols == fx.grid.cols && log.sends[1].rows == fx.grid.rows && (log.sends[1].cols, log.sends[1].rows) != (log.sends[0].cols, log.sends[0].rows), "a changed grid must send exactly one new resize")
  check(view.drawableSize == expectedDrawable(), "drawableSize must follow a resized view")
  check(coreFollowsGrid(fx), "the backend core must follow the new grid")
  // bounds change that keeps the same grid: no resize, but the drawable and repaint still follow.
  let sameGridWidth = view.bounds.width + 0.5
  check(view.geometry.gridSize(for: CGSize(width: sameGridWidth, height: view.bounds.height)) == fx.grid, "fixture: +0.5pt must keep the grid")
  view.frame = NSRect(x: 17, y: 23, width: sameGridWidth, height: 300); relayout("same grid, wider bounds")
  check(log.sends.count == 2, "same grid must not send again (sends: \(log.sends.count))")
  check(view.drawableSize == expectedDrawable(), "drawableSize must follow bounds even when the grid is unchanged")
  // a different session (or none -> some) must always be told the size again
  view.session = nil; relayout("no session")
  check(log.sends.count == 2, "no session: nothing to send to")
  view.session = fx.session; relayout("session re-attached")
  check(log.sends.count == 3 && log.sends[2].cols == fx.grid.cols, "re-attaching a session must re-send the current size")
  view.frame = NSRect(x: 17, y: 23, width: 500, height: 200); view.layoutSubtreeIfNeeded()
  check(log.sends.count == 4 && log.sends[3].rows == fx.grid.rows && log.sends[3].rows != log.sends[2].rows, "a rows-only change must send")
  print("VIEW layout: \(log.sends.count) resizes sent for initial + 3 identical + grid change + same-grid change + session detach/attach + rows change; drawableSize and repaint follow bounds")
}
#endif
