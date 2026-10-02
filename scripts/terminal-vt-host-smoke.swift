#if WEB_STUDIO_VT
import AppKit
import Combine
import Foundation
import StudioVTCoreC

@main
@MainActor
struct TerminalVTHostSmoke {
  static func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 4) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
  }

  static func main() async {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)

    let enhanced = TerminalVTCore(columns: 80, rows: 24)
    enhanced.feed(Data("\u{1b}[>11u".utf8))
    let leftShift = GhosttyMods(GHOSTTY_MODS_SHIFT | GHOSTTY_MODS_SHIFT_SIDE)
    let rightShift = GhosttyMods(GHOSTTY_MODS_SHIFT)
    let press = enhanced.encodeKey(key: GHOSTTY_KEY_A, modifiers: leftShift, action: GHOSTTY_KEY_ACTION_PRESS, text: "a", unshiftedCodepoint: 97)
    let repeatBytes = enhanced.encodeKey(key: GHOSTTY_KEY_A, modifiers: rightShift, action: GHOSTTY_KEY_ACTION_REPEAT, text: "a", unshiftedCodepoint: 97)
    let release = enhanced.encodeKey(key: GHOSTTY_KEY_A, modifiers: rightShift, action: GHOSTTY_KEY_ACTION_RELEASE, text: "a", unshiftedCodepoint: 97)
    print("enhanced-bytes press=\(Array(press ?? Data())) repeat=\(Array(repeatBytes ?? Data())) release=\(Array(release ?? Data()))")
    fputs("enhanced-actual press=\(Array(press ?? Data())) repeat=\(Array(repeatBytes ?? Data())) release=\(Array(release ?? Data()))\n", stderr)
    precondition(press == Data("\u{1b}[97;2u".utf8), "unexpected enhanced press bytes")
    precondition(repeatBytes == Data("\u{1b}[97;2:2u".utf8), "unexpected enhanced repeat bytes")
    precondition(release == Data("\u{1b}[97;2:3u".utf8), "unexpected enhanced release bytes")
    let inputSession = TerminalSession(resourceID: UUID())
    var inputEvents: [(GhosttyKey, GhosttyMods, GhosttyKeyAction, String)] = []
    inputSession.onEncodedKeyForTesting = { key, mods, action, text in inputEvents.append((key, mods, action, text)) }
    let inputView = inputSession.terminalView
    func key(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], chars: String = "a", code: UInt16 = 0, repeatFlag isRepeat: Bool = false) -> NSEvent { NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: isRepeat, keyCode: code)! }
    inputView.keyDown(with: key(.keyDown)); inputView.keyDown(with: key(.keyDown, repeatFlag: true)); inputView.keyUp(with: key(.keyUp))
    precondition(inputEvents.map { $0.2 } == [GHOSTTY_KEY_ACTION_PRESS, GHOSTTY_KEY_ACTION_REPEAT, GHOSTTY_KEY_ACTION_RELEASE], "plain key press/repeat/release sequence changed")
    inputEvents.removeAll()
    inputView.flagsChanged(with: key(.flagsChanged, flags: [.shift], chars: "", code: 56))
    inputView.flagsChanged(with: key(.flagsChanged, flags: [.shift], chars: "", code: 60))
    inputView.flagsChanged(with: key(.flagsChanged, flags: [.shift], chars: "", code: 60))
    inputView.flagsChanged(with: key(.flagsChanged, flags: [], chars: "", code: 56))
    precondition(inputEvents.count == 4 && inputEvents[0].0 == GHOSTTY_KEY_SHIFT_LEFT && inputEvents[0].2 == GHOSTTY_KEY_ACTION_PRESS && inputEvents[1].0 == GHOSTTY_KEY_SHIFT_RIGHT && inputEvents[1].2 == GHOSTTY_KEY_ACTION_PRESS && inputEvents[2].0 == GHOSTTY_KEY_SHIFT_RIGHT && inputEvents[2].2 == GHOSTTY_KEY_ACTION_RELEASE && inputEvents[3].0 == GHOSTTY_KEY_SHIFT_LEFT && inputEvents[3].2 == GHOSTTY_KEY_ACTION_RELEASE, "left/right modifier transitions changed")
    inputEvents.removeAll()
    inputView.flagsChanged(with: key(.flagsChanged, flags: [.shift], chars: "", code: 56))
    _ = inputView.resignFirstResponder()
    precondition(inputEvents.map { $0.2 } == [GHOSTTY_KEY_ACTION_PRESS, GHOSTTY_KEY_ACTION_RELEASE], "focus-loss did not release the held modifier")
    inputEvents.removeAll()
    inputView.keyUp(with: key(.keyUp, code: 0)); precondition(inputEvents.isEmpty, "missing key press generated a release")

    let failed = TerminalSession(resourceID: UUID())
    failed.startForTesting(executable: "/definitely/missing/web-studio-shell", argv: ["missing"], directory: "/tmp")
    let failedOK = await wait({ if case .failed = failed.state { return true }; return false }); precondition(failedOK, "failed start did not remain failed")

    let exited = TerminalSession(resourceID: UUID())
    exited.startForTesting(executable: "/bin/sh", argv: ["sh", "-c", "printf 'FINAL_7 中文'; exit 7"], directory: "/tmp")
    let exitedOK = await wait({ if case .exited(7) = exited.state { return true }; return false }); precondition(exitedOK, "exit 7 not delivered")
    precondition(exited.renderedText().contains("FINAL_7"), "final frame was lost before exit")
    let bounded = exited.renderedSnapshot(maxBytes: 10)
    precondition(bounded.count <= 10 && String(data: bounded, encoding: .utf8) != nil && String(decoding: bounded, as: UTF8.self).hasPrefix("FINAL_7"), "snapshot is not bounded UTF-8")
    let exitedPID = await exited.actualPID(); precondition(exitedPID == nil, "natural exit retained PID")

    let closed = TerminalSession(resourceID: UUID())
    closed.startLocal(directory: "/tmp")
    await closed.closeAndWait()
    let closedDoneImmediately = await wait({ if case .interrupted = closed.state { return true }; if case .exited = closed.state { return true }; if case .failed = closed.state { return true }; return false }); precondition(closedDoneImmediately, "immediate close did not finish")
    let closedPID = await closed.actualPID(); precondition(closedPID == nil, "close retained PID")

    let hidden = TerminalSession(resourceID: UUID()); hidden.startLocal(directory: "/tmp")
    let hiddenStarted = await wait({ if case .running = hidden.state { return true }; return false }); precondition(hiddenStarted, "hidden shell did not start")
    hidden.setVisible(false); hidden.sendRaw(Data("stty -echo; printf 'HIDDEN_%s_MARK\\n' AGENT\n".utf8))
    let hiddenOK = await wait({ hidden.renderedText().contains("HIDDEN_AGENT_MARK") }); precondition(hiddenOK, "hidden session did not provide a fresh snapshot")
    hidden.setVisible(true); await hidden.closeAndWait()

    let interactive = TerminalSession(resourceID: UUID())
    interactive.startForTesting(executable: "/bin/sh", argv: ["sh", "-i"], directory: "/tmp")
    let interactiveStarted = await wait({ if case .running = interactive.state { return true }; return false }); precondition(interactiveStarted, "interactive shell did not start")
    interactive.sendRaw(Data("stty -echo; printf '__READY_%s__\\n' HOST\n".utf8))
    let ready = await wait({ interactive.renderedText().contains("__READY_HOST__") }); precondition(ready, "interactive shell did not become ready")
    interactive.sendRaw(Data("yes SCROLL | head -n 45\n".utf8))
    let scrollReady = await wait({ interactive.renderedText().contains("SCROLL") }); precondition(scrollReady, "scrollback output did not arrive")
    interactive.sendRaw(Data("printf 'AX_WIDE_中文_🙂\\n'\n".utf8))
    let ax = interactive.terminalView
    let axWindow = NSWindow(contentRect: NSRect(x: 137, y: 211, width: 640, height: 400), styleMask: [], backing: .buffered, defer: true)
    let axContainer = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    axWindow.contentView = axContainer
    axContainer.addSubview(ax)
    ax.frame = NSRect(x: 17, y: 23, width: axContainer.bounds.width - 34, height: axContainer.bounds.height - 46)
    axWindow.orderOut(nil)
    interactive.setVisible(true)
    ax.layoutSubtreeIfNeeded()
    if let frame = interactive.currentFrameForTesting() { ax.update(frame: frame) }
    let axReady = await wait({ (ax.accessibilityValue() as? String)?.contains("AX_WIDE_中文_🙂") == true }); precondition(axReady, "AX wide text did not reach the displayed frame")
    precondition(ax.isScrollbackEnabled, "scrollback fixture did not expose enabled scroller")
    let displayed = await wait({ ax.accessibilityNumberOfCharacters() > 0 && ax.isScrollbackEnabled })
    precondition(displayed && ax.isScrollbackEnabled, "scrollback fixture did not expose enabled scroller")
    let axText = (ax.accessibilityValue() as? String) ?? ""
    let axCount = ax.accessibilityNumberOfCharacters()
    precondition(axCount == axText.utf16.count && ax.accessibilityString(for: NSRange(location: 0, length: axCount)) == axText, "AX UTF-16 count/string mismatch")
    precondition(ax.accessibilityString(for: NSRange(location: -1, length: 1)) == nil && ax.accessibilityRange(for: -1).location == NSNotFound, "AX negative range was accepted")
    precondition(ax.accessibilityString(for: NSRange(location: Int.max, length: Int.max)) == nil && ax.accessibilityFrame(for: NSRange(location: Int.max, length: Int.max)) == .zero && ax.accessibilityRange(for: Int.max).location == NSNotFound, "AX overflow range was accepted")
    let wideStart = (axText as NSString).range(of: "中文").location
    precondition(wideStart != NSNotFound && ax.accessibilityRange(for: wideStart).length > 0, "AX wide CJK cell mapping missing")
    let emojiStart = (axText as NSString).range(of: "🙂").location
    precondition(emojiStart != NSNotFound && ax.accessibilityRange(for: emojiStart).length == 2, "AX emoji UTF-16 mapping missing")
    precondition(abs(ax.accessibilityFrame(for: NSRange(location: wideStart, length: 2)).size.width - ax.geometry.cellSize.width * 4) < 0.5, "AX wide frame width is not four cells")
    let wideScreenFrame = ax.accessibilityFrame(for: NSRange(location: wideStart, length: 2))
    precondition(ax.accessibilityRange(for: wideScreenFrame.origin).location == wideStart, "AX screen point mapping missing")
    let firstWideScreenFrame = ax.accessibilityFrame(for: NSRange(location: wideStart, length: 1))
    precondition(ax.accessibilityRange(for: NSPoint(x: firstWideScreenFrame.maxX - 1, y: firstWideScreenFrame.midY)).location == wideStart, "AX wide tail screen hit mapping missing")
    precondition(ax.accessibilityRange(for: emojiStart + 1).length == 2, "AX surrogate interior did not map to grapheme")
    let caret = ax.accessibilityFrame(for: NSRange(location: wideStart, length: 0)); precondition(caret.width <= 1.5, "AX insertion frame is a full cell")
    interactive.sendRaw(Data("printf '__BUSY_%s__\\n' tick; sleep 5\n".utf8))
    let busy = await wait({ interactive.renderedText().contains("__BUSY_tick__") }); precondition(busy, "interactive loop did not run")
    let controlC = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)
    precondition(controlC != nil && interactive.terminalView.acceptsFirstResponder)
    interactive.terminalView.keyDown(with: controlC!)
    try? await Task.sleep(nanoseconds: 300_000_000)
    interactive.sendRaw(Data("printf 'FOLLOWUP_%s\\n' OK\n".utf8))
    let followupOK = await wait({ interactive.renderedText().contains("FOLLOWUP_OK") }); precondition(followupOK, "Ctrl-C/follow-up PTY path failed")
    let themePID = await interactive.actualPID(); precondition(interactive.setTheme(.light)); let themePIDAfter = await interactive.actualPID(); precondition(themePIDAfter == themePID)

    let ime = interactive.terminalView
    var actual = NSRange(location: NSNotFound, length: 0)
    ime.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
    precondition(ime.hasMarkedText() && ime.markedRange().length == 1 && ime.selectedRange().location == 1)
    let markedAttributes = ime.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: &actual)?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    precondition(markedAttributes?.pointSize == 13 && markedAttributes?.fontName == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName, "marked text font was not normalized")
    precondition(ime.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: &actual)?.string == "中" && actual.length == 1)
    precondition(ime.attributedSubstring(forProposedRange: NSRange(location: Int.max, length: Int.max), actualRange: &actual) == nil && actual.location == NSNotFound, "IME overflow range was accepted")
    _ = ime.firstRect(forCharacterRange: NSRange(location: Int.max, length: Int.max), actualRange: &actual); precondition(actual.location == NSNotFound, "IME overflow rect range was accepted")
    let markedRect = ime.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: &actual)
    ime.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 1))
    let shiftedMarkedRect = ime.firstRect(forCharacterRange: NSRange(location: 1, length: 1), actualRange: &actual)
    precondition(shiftedMarkedRect.origin.x > markedRect.origin.x, "marked prefix did not offset IME rect")
    ime.insertText("文", replacementRange: NSRange(location: 0, length: 1)); precondition(!ime.hasMarkedText())
    ime.unmarkText(); precondition(ime.selectedRange().location == NSNotFound)
    await interactive.closeAndWait()
    // Lane B (B2): OSC 7 reaches knownDirectory once per distinct directory; repeats and the unchanged start directory publish nothing, and setKnownDirectory only works while idle.
    let osc = TerminalSession(resourceID: UUID()); var oscDirectories: [String?] = []; let oscSink = osc.$knownDirectory.sink { oscDirectories.append($0) }
    osc.setKnownDirectory("/var"); precondition(osc.knownDirectory == "/var", "idle setKnownDirectory did not apply")
    func osc7(_ path: String) -> String { "printf '\u{1b}]7;file://host\(path)\u{07}'" }
    osc.startForTesting(executable: "/bin/sh", argv: ["sh", "-c", [osc7("/tmp"), osc7("/usr/local"), osc7("/usr/local"), osc7("/usr/share"), osc7("/usr/local")].joined(separator: "; sleep 0.12; ") + "; sleep 0.12; printf 'PWD_DONE'; IFS= read -r l; exit 0"], directory: "/tmp")
    let oscRunning = await wait({ if case .running = osc.state { return true }; return false }); precondition(oscRunning, "OSC 7 fixture did not start")
    osc.setKnownDirectory("/nope"); precondition(osc.knownDirectory != "/nope", "setKnownDirectory applied outside idle")
    let oscDone = await wait({ osc.renderedText().contains("PWD_DONE") }); precondition(oscDone, "OSC 7 fixture did not finish")
    try? await Task.sleep(nanoseconds: 250_000_000)
    precondition(oscDirectories == [nil, "/var", "/tmp", "/usr/local", "/usr/share", "/usr/local"], "OSC 7 must publish exactly once per distinct directory: \(oscDirectories)")
    osc.sendRaw(Data("\n".utf8)); let oscExited = await wait({ if case .exited(0) = osc.state { return true }; return false }); precondition(oscExited, "OSC 7 fixture exit not delivered"); oscSink.cancel()
    // Lane B (B3): the Session's selection wrappers no longer block on the PTY queue yet stay ordered before selectedText(); mouseReporting() is a mirror of the core; an unchanged theme is a no-op.
    let sel = TerminalSession(resourceID: UUID())
    sel.startForTesting(executable: "/bin/sh", argv: ["sh", "-c", "printf 'SELECT_ME_TEXT'; printf '\u{1b}[?1000h'; printf MOUSE_ON; IFS= read -r l; printf '\u{1b}[?1000l'; printf MOUSE_OFF; IFS= read -r l; exit 0"], directory: "/tmp")
    let selReady = await wait({ sel.renderedText().contains("MOUSE_ON") }); precondition(selReady, "selection fixture did not start"); precondition(sel.mouseReporting(), "mouseReporting mirror did not follow ?1000h")
    sel.selectionBegin(column: 0, row: 0, clickCount: 1); sel.selectionUpdate(column: 14, row: 0); sel.selectionEnd(); precondition(sel.selectedText() == "SELECT_ME_TEXT", "async begin/update/end selection was not ordered before selectedText()")
    sel.selectDrag(startColumn: 0, startRow: 0, endColumn: 5, endRow: 0); precondition(sel.selectedText() == "SELECT", "async drag selection")
    sel.selectLine(column: 3, row: 0); precondition(sel.selectedText()?.contains("SELECT_ME_TEXT") == true, "async line selection")
    sel.selectWord(column: 1, row: 0); precondition(sel.selectedText()?.isEmpty == false, "async word selection")
    sel.selectAll(); precondition(sel.selectedText()?.contains("SELECT_ME_TEXT") == true, "async select all"); sel.clearSelection(); let selCleared = sel.selectedText(); precondition(selCleared == nil || selCleared == "", "async clear selection")
    precondition(sel.setTheme(.light) && sel.setTheme(.light) && sel.setTheme(.dark) && sel.setTheme(.dark), "setTheme must report success for repeated and changed themes")
    sel.sendRaw(Data("\n".utf8)); let selOff = await wait({ sel.renderedText().contains("MOUSE_OFF") }); precondition(selOff, "mouse-off marker missing"); precondition(!sel.mouseReporting(), "mouseReporting mirror did not follow ?1000l")
    sel.sendRaw(Data("\n".utf8)); let selExited = await wait({ if case .exited(0) = sel.state { return true }; return false }); precondition(selExited, "selection fixture exit not delivered")
    // Lane B (B4): a burst of Session.resize calls coalesces, repeating the final size is a no-op, and the child's TIOCGWINSZ reports the final size.
    let rz = TerminalSession(resourceID: UUID())
    rz.startForTesting(executable: "/bin/sh", argv: ["sh", "-c", "stty -echo; printf READY_RZ; while IFS= read -r l; do printf 'SZ=%s;' \"$(stty size)\"; done"], directory: "/tmp")
    let rzReady = await wait({ rz.renderedText().contains("READY_RZ") }); precondition(rzReady, "resize fixture did not start")
    let rzGeometry = rz.terminalView.geometry
    for i in 0..<100 { rz.resize(columns: 60 + i, rows: 20 + i % 11, geometry: rzGeometry) }
    for _ in 0..<20 { rz.resize(columns: 159, rows: 20, geometry: rzGeometry) }
    let rzApplied = await wait({ rz.currentFrameForTesting().map { $0.columns == 159 && $0.rows == 20 } == true }); precondition(rzApplied, "final coalesced resize was not applied to the core")
    rz.sendRaw(Data("?\n".utf8)); let rzSize = await wait({ rz.renderedText().contains("SZ=20 159;") }); precondition(rzSize, "child window size differs from the final requested size")
    await rz.closeAndWait()
    print("Terminal VT host smoke passed")
  }
}
#endif
