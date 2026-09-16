#if WEB_STUDIO_VT
import AppKit
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
    print("Terminal VT host smoke passed")
  }
}
#endif
