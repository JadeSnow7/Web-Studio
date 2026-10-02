#if WEB_STUDIO_VT
import Foundation
import StudioVTCoreC

private final class Recorder {
  let condition = NSCondition()
  var output = Data(); var frames = [VTFrame](); var callbacks = [String](); var exitCode: Int32?
  func appendOutput(_ data: Data) { condition.lock(); output.append(data); condition.broadcast(); condition.unlock() }
  func appendFrame(_ frame: VTFrame) { condition.lock(); frames.append(frame); condition.broadcast(); condition.unlock() }
  func appendCallback(_ value: String) { condition.lock(); callbacks.append(value); condition.broadcast(); condition.unlock() }
  func recordExit(_ code: Int32?) { condition.lock(); exitCode = code; if code == 7 { precondition(frames.last?.visibleData.range(of: Data("EXIT_FINAL".utf8)) != nil) }; callbacks.append("exit\(code ?? -1)"); condition.broadcast(); condition.unlock() }
  func wait(_ predicate: @escaping (Recorder) -> Bool, timeout: TimeInterval = 3) -> Bool { condition.lock(); defer { condition.unlock() }; let deadline = Date(timeIntervalSinceNow: timeout); while !predicate(self) { if !condition.wait(until: deadline) { return predicate(self) } }; return true }
}

@main struct TerminalVTBackendSmoke {
  static func main() async {
    let backend = GhosttyVTBackend(columns: 80, rows: 24); let done = DispatchSemaphore(value: 0)
    backend.onExit = { _ in done.signal() }
    backend.start(executable: "/bin/sh", argv: ["/bin/sh", "-c", "printf '\u{1b}[31m中文\u{1b}[0m'; exit 7"], environment: ["PATH":"/usr/bin:/bin"], directory: nil, columns: 80, rows: 24)
    precondition(done.wait(timeout: .now() + 3) == .success); let frame = backend.snapshot(); precondition(frame != nil); precondition(frame!.visibleData.contains(Data("中文".utf8))); precondition(!frame!.visibleData.contains(0x1b)); await backend.closeAndWait(); print("TerminalVTBackend smoke passed")
    guard let fixture = ProcessInfo.processInfo.environment["FIXTURE_PATH"] else { fatalError("fixture") }
    let interactive = GhosttyVTBackend(columns: 80, rows: 24); let recorder = Recorder(); let started = DispatchSemaphore(value: 0)
    interactive.onStart = { ok, _ in recorder.appendCallback("start"); precondition(ok); started.signal() }; interactive.onFrame = { recorder.appendFrame($0) }; interactive.onOutput = { recorder.appendOutput($0) }
    interactive.onExit = { result in recorder.recordExit(result.code) }
    interactive.start(executable: fixture, argv: [fixture], environment: ["PATH":"/usr/bin:/bin"], directory: nil, columns: 80, rows: 24); precondition(started.wait(timeout: .now() + 3) == .success)
    precondition(recorder.wait({ $0.output.range(of: Data("QUERY_OK".utf8)) != nil })); let pid = interactive.currentPID(); precondition(pid != nil)
    interactive.resize(columns: 97, rows: 31, cellWidthPixels: 8, cellHeightPixels: 16); precondition(recorder.wait({ $0.frames.contains { $0.columns == 97 && $0.rows == 31 } })); interactive.sendRaw(Data("SIZE?\n".utf8)); precondition(recorder.wait({ $0.output.range(of: Data("SIZE=31,97,776,496".utf8)) != nil }))
    interactive.setVisible(false); _ = interactive.snapshot(); recorder.condition.lock(); let hiddenCount = recorder.frames.count; recorder.condition.unlock(); interactive.sendRaw(Data("HIDDEN\n".utf8)); precondition(recorder.wait({ $0.output.range(of: Data("HIDDEN_MARK".utf8)) != nil })); recorder.condition.lock(); let hiddenFrames = recorder.frames.count; recorder.condition.unlock(); precondition(hiddenFrames == hiddenCount)
    precondition(interactive.snapshot()?.visibleData.range(of: Data("HIDDEN_MARK".utf8)) != nil); interactive.setVisible(true); _ = interactive.snapshot(); precondition(recorder.wait({ $0.frames.contains { $0.visibleData.range(of: Data("HIDDEN_MARK".utf8)) != nil } }))
    precondition(interactive.setTheme(.light)); precondition(interactive.currentPID() == pid); interactive.sendRaw(Data("FINAL\n".utf8)); precondition(recorder.wait({ $0.frames.contains { $0.visibleData.range(of: Data("FINAL_MARK".utf8)) != nil } })); precondition(interactive.setTheme(.dark)); precondition(interactive.currentPID() == pid)
    precondition(interactive.sendRaw(Data("EXIT7\n".utf8))); precondition(recorder.wait({ $0.exitCode == 7 })); recorder.condition.lock(); let callbacks = recorder.callbacks; recorder.condition.unlock(); precondition(callbacks.first == "start" && callbacks.last == "exit7"); precondition(interactive.snapshot()?.visibleData.range(of: Data("EXIT_FINAL".utf8)) != nil); await interactive.closeAndWait(); print("TerminalVTBackend interactive smoke passed")
    await LaneBSmoke.run()
    await InputOrderSmoke.run()
  }
}

// Lane B (backend/session/core performance) assertions. Every child is a `sh -c` script driven line by line through the PTY so output happens exactly when a test asks for it.
private final class LaneFlag: @unchecked Sendable {
  private let lock = NSLock(); private var stored = false
  var value: Bool { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}
private final class LaneRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var output = Data(), frames = [VTFrame](), exitCode: Int32?, exited = false, finalFrameHadMarkerBeforeExit: String?
  func attach(to backend: GhosttyVTBackend) {
    backend.onOutput = { [self] data in lock.lock(); output.append(data); lock.unlock() }
    backend.onFrame = { [self] frame in lock.lock(); frames.append(frame); lock.unlock() }
    backend.onExit = { [self] result in lock.lock(); exitCode = result.code; exited = true; finalFrameHadMarkerBeforeExit = frames.last.map { String(decoding: $0.visibleData, as: UTF8.self) }; lock.unlock() }
  }
  func hasOutput(_ text: String) -> Bool { lock.lock(); defer { lock.unlock() }; return output.range(of: Data(text.utf8)) != nil }
  func hasFrame(_ text: String) -> Bool { lock.lock(); defer { lock.unlock() }; return frames.contains { $0.visibleData.range(of: Data(text.utf8)) != nil } }
  var outputText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: output, as: UTF8.self) }
  func count(of text: String) -> Int { lock.lock(); defer { lock.unlock() }; return String(decoding: output, as: UTF8.self).components(separatedBy: text).count - 1 }
  var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
  var lastFrame: VTFrame? { lock.lock(); defer { lock.unlock() }; return frames.last }
  var hasExited: Bool { lock.lock(); defer { lock.unlock() }; return exited }
  var exitStatus: Int32? { lock.lock(); defer { lock.unlock() }; return exitCode }
  var lastFrameTextAtExit: String? { lock.lock(); defer { lock.unlock() }; return finalFrameHadMarkerBeforeExit }
}
private final class LaneFlagCounter: @unchecked Sendable {
  private let lock = NSLock(); private var sum = 0
  func add(_ n: Int) { lock.lock(); sum += n; lock.unlock() }
  var total: Int { lock.lock(); defer { lock.unlock() }; return sum }
}
private final class LaneDirectories: @unchecked Sendable {
  private let lock = NSLock(); private var list = [String]()
  func attach(to backend: GhosttyVTBackend) { backend.onDirectory = { [self] raw in lock.lock(); list.append(raw); lock.unlock() } }
  var values: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
private enum LaneBSmoke {
  static func eventually(_ timeout: TimeInterval = 4, _ predicate: () -> Bool) -> Bool { let deadline = Date(timeIntervalSinceNow: timeout); while Date() < deadline { if predicate() { return true }; usleep(5_000) }; return predicate() }
  static func settle(_ milliseconds: Int = 120) { usleep(UInt32(milliseconds * 1_000)) }
  static func barrier(_ backend: GhosttyVTBackend) { backend.queue.sync {} }
  static func launch(_ script: String, columns: Int = 80, rows: Int = 24, configure: (GhosttyVTBackend) -> Void = { _ in }) -> (GhosttyVTBackend, LaneRecorder) {
    let backend = GhosttyVTBackend(columns: columns, rows: rows); let recorder = LaneRecorder(); recorder.attach(to: backend); configure(backend)
    backend.start(executable: "/bin/sh", argv: ["/bin/sh", "-c", script], environment: ["PATH": "/usr/bin:/bin"], directory: nil, columns: columns, rows: rows)
    return (backend, recorder)
  }
  static func run() async {
    await hiddenOutputTakesNoSnapshots()
    await undrainedFrameDefersSnapshots()
    await directoryNotifiedOncePerChange()
    await mouseMirrorMatchesCore()
    await selectionAsyncThenSyncRead()
    await unchangedThemeIsNoOp()
    await emptyKeyOutputDoesNotScrollOrSchedule()
    await resizeDedupesAndCoalesces()
    await pendingResizeSurvivesExitWithoutDangling()
    print("TerminalVTBackend lane B smoke passed")
  }

  // B4: identical resizes are no-ops, a burst is applied as the first request plus one trailing apply, and core and child (TIOCSWINSZ) always end on the same final size.
  static func resizeDedupesAndCoalesces() async {
    let (backend, recorder) = launch("stty -echo; printf READY_R; while IFS= read -r l; do printf 'SZ=%s;' \"$(stty size)\"; done"); let core = backend.coreForTesting
    func childSees(_ expected: String) -> Bool { let seen = recorder.count(of: "SZ=\(expected);"); _ = backend.sendRaw(Data("?\n".utf8)); return eventually { recorder.count(of: "SZ=\(expected);") > seen } }
    precondition(eventually { recorder.hasFrame("READY_R") }); settle(); barrier(backend)
    let base = core.resizeCountForTesting(), frames = recorder.frameCount
    for _ in 0..<20 { backend.resize(columns: 80, rows: 24, cellWidthPixels: 8, cellHeightPixels: 16) }; backend.resize(columns: 80, rows: 24); settle(); barrier(backend)
    precondition(core.resizeCountForTesting() == base && recorder.frameCount == frames, "B4: a resize identical to the applied size must be a no-op"); precondition(childSees("24 80"))
    backend.resize(columns: 100, rows: 30, cellWidthPixels: 8, cellHeightPixels: 16); precondition(eventually { recorder.lastFrame?.columns == 100 && recorder.lastFrame?.rows == 30 }, "B4: a changed size must produce a frame")
    for _ in 0..<20 { backend.resize(columns: 100, rows: 30, cellWidthPixels: 8, cellHeightPixels: 16) }; settle(); barrier(backend)
    precondition(core.resizeCountForTesting() == base + 1, "B4: repeated identical resizes were applied again"); precondition(childSees("30 100"))
    backend.resize(columns: 100, rows: 30, cellWidthPixels: 9, cellHeightPixels: 16); settle(); barrier(backend); precondition(core.resizeCountForTesting() == base + 2, "B4: a changed cell pixel size is a different request")
    settle(60); let burstBase = core.resizeCountForTesting()
    for i in 0..<100 { backend.resize(columns: 60 + i, rows: 20 + i % 11, cellWidthPixels: 8, cellHeightPixels: 16) }
    precondition(eventually { recorder.lastFrame?.columns == 159 && recorder.lastFrame?.rows == 20 }, "B4: the final requested size was never applied"); settle(); barrier(backend)
    let applied = core.resizeCountForTesting() - burstBase; print("B4 burst: 100 resize requests -> \(applied) core.resize applications")
    precondition(applied >= 1 && applied <= 10, "B4: burst was not coalesced (\(applied) applications)"); precondition(backend.snapshot()!.columns == 159 && backend.snapshot()!.rows == 20); precondition(childSees("20 159"), "B4: child window size differs from the final requested size")
    settle(60); let tailBase = core.resizeCountForTesting()
    backend.resize(columns: 120, rows: 33, cellWidthPixels: 8, cellHeightPixels: 16); backend.resize(columns: 121, rows: 33, cellWidthPixels: 8, cellHeightPixels: 16); backend.resize(columns: 120, rows: 33, cellWidthPixels: 8, cellHeightPixels: 16); settle(150); barrier(backend)
    let tailApplied = core.resizeCountForTesting() - tailBase; precondition(tailApplied >= 1 && tailApplied <= 3, "B4: expected the first request and at most a trailing apply, got \(tailApplied)"); precondition(backend.snapshot()!.columns == 120 && backend.snapshot()!.rows == 33); precondition(childSees("33 120"))
    await backend.closeAndWait()
  }

  // B4: a resize still pending when the child exits is applied to the core (never dropped, never applied after close) and nothing dangles afterwards.
  // The transport runs a ~350 ms kill escalation between the leader's exit and onExit, so requests are issued at offsets straddling that deadline: early ones are accepted and must reach the core, late ones arrive after close and must be ignored.
  static func pendingResizeSurvivesExitWithoutDangling() async {
    for round in 0..<8 {
      let (backend, recorder) = launch("stty -echo; printf READY_X; IFS= read -r l; exit 5"); let core = backend.coreForTesting
      precondition(eventually { recorder.hasFrame("READY_X") }); settle(60)
      precondition(backend.sendRaw(Data("go\n".utf8))); precondition(eventually { backend.currentPID() == nil }, "B4: leader exit not observed"); usleep(UInt32((300 + round * 8) * 1_000))
      backend.resize(columns: 90, rows: 28); backend.resize(columns: 91, rows: 29); backend.resize(columns: 92, rows: 30); barrier(backend); let acceptedBeforeClose = !recorder.hasExited
      precondition(eventually { recorder.hasExited }, "B4: exit not delivered"); precondition(recorder.exitStatus == 5); settle(150); barrier(backend)
      let applied = core.resizeCountForTesting(), size = backend.snapshot()!
      precondition(acceptedBeforeClose ? (size.columns == 92 && size.rows == 30) : (size.columns == 80 && size.rows == 24), "B4: round \(round) accepted=\(acceptedBeforeClose) ended at \(size.columns)x\(size.rows)")
      backend.resize(columns: 70, rows: 20); settle(80); barrier(backend); precondition(core.resizeCountForTesting() == applied && backend.snapshot()!.columns == size.columns, "B4: a resize was applied after the child exited")
      await backend.closeAndWait()
    }
  }

  // B3(a): the lock-free mouseReporting() mirror equals core.mouseReporting() at every quiescent point while tracking modes are toggled by the child.
  static func mouseMirrorMatchesCore() async {
    let (backend, recorder) = launch("stty -echo; printf READY_M; while IFS= read -r l; do case \"$l\" in on) printf '\u{1b}[?1000h';; off) printf '\u{1b}[?1000l';; any) printf '\u{1b}[?1003h';; anyoff) printf '\u{1b}[?1003l';; esac; printf 'ACK_%s;' \"$l\"; done"); let core = backend.coreForTesting
    precondition(eventually { recorder.hasFrame("READY_M") }); barrier(backend); precondition(!backend.mouseReporting() && !core.mouseReporting(), "B3: tracking must start disabled")
    for (line, expected) in [("on", true), ("off", false), ("any", true), ("anyoff", false), ("on", true)] {
      precondition(backend.sendRaw(Data("\(line)\n".utf8))); let acks = recorder.count(of: "ACK_\(line);"); precondition(eventually { recorder.count(of: "ACK_\(line);") > acks }, "B3: no ack for \(line)"); barrier(backend)
      precondition(core.mouseReporting() == expected, "B3: fixture did not toggle mouse tracking for \(line)"); precondition(backend.mouseReporting() == expected, "B3: mouseReporting mirror differs from the core after \(line)")
    }
    precondition(backend.sendRaw(Data("done\n".utf8))); await backend.closeAndWait()
  }

  // B3(b): asynchronous selection requests are ordered before a later synchronous selectedText(), without any barrier in between.
  static func selectionAsyncThenSyncRead() async {
    let (backend, recorder) = launch("stty -echo; printf SELECT_ME_TEXT; IFS= read -r l; exit 0")
    precondition(eventually { recorder.hasFrame("SELECT_ME_TEXT") })
    backend.selectionBeginAsync(column: 0, row: 0, clickCount: 1); backend.selectionUpdateAsync(column: 14, row: 0); backend.selectionEndAsync(); let dragged = backend.selectedText(); precondition(dragged == "SELECT_ME_TEXT", "B3: begin/update/end async selection, got \(String(describing: dragged))")
    precondition(backend.selectionBegin(column: 0, row: 0, clickCount: 1) && backend.selectionUpdate(column: 14, row: 0) && backend.selectionEnd() && backend.selectedText() == dragged, "B3: async begin/update/end differs from the synchronous gesture")
    backend.selectDragAsync(startColumn: 0, startRow: 0, endColumn: 5, endRow: 0, behavior: 0); precondition(backend.selectedText() == "SELECT", "B3: async drag selection")
    backend.selectLineAsync(column: 2, row: 0); precondition(backend.selectedText() == "SELECT_ME_TEXT", "B3: async line selection")
    backend.selectWordAsync(column: 2, row: 0); let word = backend.selectedText(); precondition(word != nil && !word!.isEmpty); precondition(backend.selectWord(column: 2, row: 0)); precondition(backend.selectedText() == word, "B3: async word selection differs from the synchronous one")
    backend.selectAllAsync(); precondition(backend.selectedText()?.contains("SELECT_ME_TEXT") == true, "B3: async select all")
    backend.clearSelectionAsync(); let cleared = backend.selectedText(); precondition(cleared == nil || cleared == "", "B3: async clear selection")
    let frames = recorder.frameCount; backend.selectionBeginAsync(column: 0, row: 0, clickCount: 1); backend.selectionUpdateAsync(column: 5, row: 0); precondition(eventually { recorder.frameCount > frames && recorder.lastFrame?.cells.prefix(4).allSatisfy { $0.selected } == true }, "B3: async selection did not schedule a frame with selected cells")
    precondition(backend.sendRaw(Data("\n".utf8))); precondition(eventually { recorder.hasExited }); await backend.closeAndWait()
  }

  // B3(c): re-applying the current theme is a no-op (no frame, no generation bump) while a changed theme still reschedules a frame.
  static func unchangedThemeIsNoOp() async {
    let (backend, recorder) = launch("stty -echo; printf READY_T; IFS= read -r l; exit 0"); let core = backend.coreForTesting
    precondition(eventually { recorder.hasFrame("READY_T") }); settle()
    precondition(backend.setTheme(.light)); precondition(eventually { recorder.lastFrame?.background == VTColor(rgb: 0xF7F8FA) }, "B3: a changed theme must reschedule a frame"); settle()
    let generation = backend.snapshot()!.generation, frames = recorder.frameCount, snapshots = core.snapshotCountForTesting()
    for _ in 0..<5 { precondition(backend.setTheme(.light), "B3: unchanged theme must still report success") }; settle(); barrier(backend)
    precondition(recorder.frameCount == frames && core.snapshotCountForTesting() == snapshots, "B3: unchanged theme scheduled a frame"); precondition(backend.snapshot()!.generation == generation, "B3: unchanged theme bumped the generation")
    precondition(backend.setTheme(.dark)); precondition(eventually { recorder.lastFrame?.background == VTColor(rgb: 0x252A2E) }, "B3: switching back must reschedule a frame"); precondition(backend.snapshot()!.generation == generation + 1)
    precondition(backend.sendRaw(Data("\n".utf8))); precondition(eventually { recorder.hasExited }); await backend.closeAndWait()
  }

  // B3(d): key events whose encoded bytes are empty (modifier-only, release) neither scroll to bottom nor schedule a frame; non-empty output still does.
  static func emptyKeyOutputDoesNotScrollOrSchedule() async {
    let (backend, recorder) = launch("stty -echo; i=0; while [ $i -lt 100 ]; do echo LINE_$i; i=$((i+1)); done; printf READY_K; while IFS= read -r l; do :; done"); let core = backend.coreForTesting
    let shift = GhosttyMods(GHOSTTY_MODS_SHIFT)
    precondition(core.encodeKey(key: GHOSTTY_KEY_SHIFT_LEFT, modifiers: shift, action: GHOSTTY_KEY_ACTION_PRESS, text: "") == Data() && core.encodeKey(key: GHOSTTY_KEY_SHIFT_LEFT, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_RELEASE, text: "") == Data() && core.encodeKey(key: GHOSTTY_KEY_A, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_RELEASE, text: "") == Data(), "B3: fixture keys no longer encode to empty output")
    precondition(eventually { recorder.hasFrame("READY_K") }); settle(); backend.scroll(rows: -10); settle(); barrier(backend)
    let before = backend.snapshot()!.scrollbar; precondition(before.offset + before.length < before.total, "B3: fixture did not scroll back")
    let frames = recorder.frameCount, snapshots = core.snapshotCountForTesting()
    backend.encodeKey(key: GHOSTTY_KEY_SHIFT_LEFT, modifiers: shift, action: GHOSTTY_KEY_ACTION_PRESS, text: ""); backend.encodeKey(key: GHOSTTY_KEY_SHIFT_LEFT, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_RELEASE, text: ""); backend.encodeKey(key: GHOSTTY_KEY_A, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_RELEASE, text: ""); precondition(backend.sendRaw(Data()))
    settle(); barrier(backend)
    precondition(recorder.frameCount == frames && core.snapshotCountForTesting() == snapshots, "B3: empty key output scheduled a frame"); precondition(backend.snapshot()!.scrollbar.offset == before.offset, "B3: empty key output scrolled to bottom")
    backend.encodeKey(key: GHOSTTY_KEY_A, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_PRESS, text: "a"); precondition(eventually { recorder.frameCount > frames }, "B3: non-empty key output must still schedule a frame")
    let bottom = backend.snapshot()!.scrollbar; precondition(bottom.offset + bottom.length == bottom.total, "B3: non-empty key output must still scroll to bottom")
    await backend.closeAndWait()
  }

  // B2: the cwd is read only after new input and reported once per distinct raw OSC 7 value (never for repeats); nothing here touches the main thread.
  static func directoryNotifiedOncePerChange() async {
    func osc7(_ path: String) -> String { "printf '\u{1b}]7;file://host\(path)\u{07}'" }
    let directories = LaneDirectories()
    let script = [osc7("/tmp/x"), osc7("/tmp/x"), osc7("/tmp/y"), osc7("/tmp/y"), osc7("/tmp/x")].joined(separator: "; sleep 0.12; ") + "; sleep 0.12; printf PWD_DONE; IFS= read -r l; exit 0"
    let (backend, recorder) = launch(script, configure: { directories.attach(to: $0) }); let core = backend.coreForTesting
    precondition(eventually { recorder.hasFrame("PWD_DONE") }, "B2: script did not finish"); settle(150); barrier(backend)
    precondition(directories.values == ["file://host/tmp/x", "file://host/tmp/y", "file://host/tmp/x"], "B2: expected exactly one notification per directory change, got \(directories.values)")
    let reads = core.pwdReadCountForTesting(); precondition(reads >= 3 && reads <= recorder.frameCount, "B2: pwd read \(reads) times for \(recorder.frameCount) frames")
    let frames = recorder.frameCount; for _ in 0..<3 { backend.scrollToBottom(); settle(60) }; barrier(backend)
    precondition(recorder.frameCount > frames, "B2: scroll frames were not published"); precondition(core.pwdReadCountForTesting() == reads, "B2: pwd was re-read without new input"); precondition(directories.values.count == 3, "B2: unchanged directory was notified again")
    precondition(backend.sendRaw(Data("\n".utf8))); precondition(eventually { recorder.hasExited }, "B2: exit not delivered"); await backend.closeAndWait()
  }

  // B1: a hidden terminal never snapshots and never calls onFrame, the synchronous snapshot stays live, and unhiding always yields a fresh frame.
  static func hiddenOutputTakesNoSnapshots() async {
    let (backend, recorder) = launch("stty -echo; printf READY_H; IFS= read -r l; printf HID_A; IFS= read -r l; printf HID_B; IFS= read -r l; exit 0"); let core = backend.coreForTesting
    precondition(eventually { recorder.hasFrame("READY_H") }, "B1: ready frame missing")
    backend.setVisible(false); settle(); barrier(backend)
    let snapshots = core.snapshotCountForTesting(), frames = recorder.frameCount
    precondition(backend.sendRaw(Data("1\n".utf8))); precondition(eventually { recorder.hasOutput("HID_A") }); precondition(backend.sendRaw(Data("2\n".utf8))); precondition(eventually { recorder.hasOutput("HID_B") }); settle(); barrier(backend)
    precondition(core.snapshotCountForTesting() == snapshots, "B1: hidden output produced a snapshot"); precondition(recorder.frameCount == frames, "B1: hidden output delivered a frame")
    precondition(backend.snapshot()?.visibleData.range(of: Data("HID_AHID_B".utf8)) != nil, "B1: synchronous snapshot is not live while hidden"); precondition(core.snapshotCountForTesting() == snapshots + 1, "B1: only the synchronous snapshot may run while hidden")
    backend.setVisible(true); precondition(eventually { recorder.hasFrame("HID_AHID_B") }, "B1: no fresh frame after unhide"); precondition(recorder.frameCount > frames)
    backend.setVisible(false); settle(); barrier(backend); let hiddenExitFrames = recorder.frameCount
    precondition(backend.sendRaw(Data("3\n".utf8))); precondition(eventually { recorder.hasExited }, "B1: hidden child exit not delivered"); settle(); precondition(recorder.frameCount == hiddenExitFrames, "B1: hidden exit delivered a frame"); precondition(backend.snapshot()?.visibleData.range(of: Data("HID_AHID_B".utf8)) != nil)
    await backend.closeAndWait()
  }

  // B1: while the consumer still holds an undrained frame no new snapshot is produced; after it drains the latest state is published once; finish() bypasses the gate.
  static func undrainedFrameDefersSnapshots() async {
    let held = LaneFlag()
    let (backend, recorder) = launch("stty -echo; printf READY_G; IFS= read -r l; printf GATE_A; IFS= read -r l; printf GATE_B; IFS= read -r l; printf GATE_C; IFS= read -r l; printf GATE_FIN; exit 4", configure: { $0.hasUndrainedFrame = { held.value } }); let core = backend.coreForTesting
    precondition(eventually { recorder.hasFrame("READY_G") }, "B1: gate ready frame missing"); settle(); barrier(backend)
    held.value = true; let snapshots = core.snapshotCountForTesting(), frames = recorder.frameCount
    precondition(backend.sendRaw(Data("1\n".utf8))); precondition(eventually { recorder.hasOutput("GATE_A") }); precondition(backend.sendRaw(Data("2\n".utf8))); precondition(eventually { recorder.hasOutput("GATE_B") }); settle(); barrier(backend)
    precondition(core.snapshotCountForTesting() == snapshots && recorder.frameCount == frames, "B1: snapshot produced while a frame was undrained")
    held.value = false; backend.frameDrained(); precondition(eventually { recorder.hasFrame("GATE_AGATE_B") }, "B1: latest state not published after the frame was drained"); settle(); barrier(backend)
    precondition(core.snapshotCountForTesting() == snapshots + 1 && recorder.frameCount == frames + 1, "B1: expected exactly one snapshot after the drain")
    for _ in 0..<5 { backend.frameDrained() }; settle(60); barrier(backend); precondition(core.snapshotCountForTesting() == snapshots + 1, "B1: frameDrained without a deferred publish must be a no-op")
    held.value = true; precondition(backend.sendRaw(Data("3\n".utf8))); precondition(eventually { recorder.hasOutput("GATE_C") }); settle(); barrier(backend); precondition(!recorder.hasFrame("GATE_C"), "B1: deferred publish leaked a frame")
    precondition(backend.sendRaw(Data("4\n".utf8))); precondition(eventually { recorder.hasExited }, "B1: exit not delivered"); precondition(recorder.exitStatus == 4)
    precondition(recorder.lastFrameTextAtExit?.contains("GATE_FIN") == true, "B1: finish() did not publish the final frame before onExit while a frame was undrained")
    await backend.closeAndWait()
  }
}
// Input-ordering / input-drop assertions (correctness, not performance). Failures are collected instead of trapping so one run reports every broken guarantee.
private final class InputChecks: @unchecked Sendable {
  static let shared = InputChecks(); private let lock = NSLock(); private var list = [String]()
  func fail(_ message: String) { lock.lock(); list.append(message); lock.unlock(); FileHandle.standardError.write(Data("INPUT-CHECK FAILED: \(message)\n".utf8)) }
  var failures: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
private func check(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { InputChecks.shared.fail(message()) } }
private enum InputOrderSmoke {
  static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  static func run() async {
    await keyAndRawKeepProgramOrderUnderBacklog()
    await keyAndRawKeepProgramOrderWithoutBacklog()
    await interactiveWritesSurviveFullPasteBudget()
    await interactiveOverflowIsReportedAndBounded()
    await admissionIsReleasedOnCloseAndExit()
    await typedTextKeepsOrderAndSurvivesFullPasteBudget()
    let failures = InputChecks.shared.failures
    if failures.isEmpty { print("TerminalVTBackend input ordering/drop smoke passed") } else { print("TerminalVTBackend input ordering/drop smoke FAILED (\(failures.count) checks)"); exit(1) }
  }
  static func firstMismatch(_ actual: String, _ expected: String) -> String {
    let a = Array(actual.utf8), e = Array(expected.utf8); var i = 0
    while i < min(a.count, e.count), a[i] == e[i] { i += 1 }
    let lo = max(0, i - 4)
    return "first mismatch at byte \(i) (actual \(a.count) bytes, expected \(e.count)): actual ...\(String(decoding: a[lo..<min(a.count, i + 8)], as: UTF8.self)) expected ...\(String(decoding: e[lo..<min(e.count, i + 8)], as: UTF8.self))"
  }
  /// Sends `count` tokens from the calling (non-queue) thread in program order, mixing encodeKey, sendRaw and paste, and returns the byte string the child must receive.
  static func sendMixed(_ backend: GhosttyVTBackend, count: Int, stallEvery: Int) -> String {
    var expected = ""
    for i in 0..<count {
      let ch = String(alphabet[i % alphabet.count])
      if stallEvery > 0, i % stallEvery == 0 { backend.queue.async { usleep(3_000) } }
      switch i % 6 {
      case 0, 2, 3: backend.encodeKey(key: GHOSTTY_KEY_A, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_PRESS, text: ch, unshiftedCodepoint: 0)
      case 1, 4: check(backend.sendRaw(Data(ch.utf8)), "sendRaw of one byte was rejected")
      default: check(backend.paste(ch, allowUnsafe: true), "paste of one byte was rejected")
      }
      expected += ch
    }
    return expected
  }
  static func readback(_ recorder: LaneRecorder, marker: String, expected: String) -> String {
    _ = LaneBSmoke.eventually(6) { let t = recorder.outputText; guard let r = t.range(of: marker) else { return false }; return t[r.upperBound...].utf8.count >= expected.utf8.count }
    LaneBSmoke.settle(150)
    let text = recorder.outputText; guard let r = text.range(of: marker) else { return "" }
    return String(text[r.upperBound...])
  }
  // O1: a key encoded on the queue must reach the child before raw bytes the caller sent after it, even when the queue is backed up.
  static func keyAndRawKeepProgramOrderUnderBacklog() async {
    let (backend, recorder) = LaneBSmoke.launch("stty raw -echo; printf READY_O1; exec cat")
    check(LaneBSmoke.eventually { recorder.hasOutput("READY_O1") }, "O1: child never became ready")
    // Deterministic minimal case: the serial queue is busy, then key 'a' followed by raw 'b'.
    backend.queue.async { usleep(200_000) }
    backend.encodeKey(key: GHOSTTY_KEY_A, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_PRESS, text: "a", unshiftedCodepoint: 0); check(backend.sendRaw(Data("b".utf8)), "O1: sendRaw rejected")
    let first = readback(recorder, marker: "READY_O1", expected: "ab")
    check(first == "ab", "O1: encodeKey('a') then sendRaw('b') on a busy queue reached the child as \"\(first)\" instead of \"ab\"")
    // Backlog case: queue stalled up front and periodically while 600 mixed tokens are issued.
    backend.queue.async { usleep(300_000) }
    let expected = "ab" + sendMixed(backend, count: 600, stallEvery: 25)
    let actual = readback(recorder, marker: "READY_O1", expected: expected)
    check(actual == expected, "O1: mixed key/raw/paste stream reordered under backlog: \(firstMismatch(actual, expected))")
    await backend.closeAndWait()
  }
  // O2: same property with no artificial stall (natural races between the caller and the PTY queue).
  static func keyAndRawKeepProgramOrderWithoutBacklog() async {
    let (backend, recorder) = LaneBSmoke.launch("stty raw -echo; printf READY_O2; exec cat")
    check(LaneBSmoke.eventually { recorder.hasOutput("READY_O2") }, "O2: child never became ready")
    var expected = ""
    for _ in 0..<20 { expected += sendMixed(backend, count: 300, stallEvery: 0) }
    let actual = readback(recorder, marker: "READY_O2", expected: expected)
    check(actual == expected, "O2: mixed key/raw/paste stream reordered without stall: \(firstMismatch(actual, expected))")
    await backend.closeAndWait()
  }
  // D1: while a full-size paste holds the 256 KiB admission, small interactive writes (key, focus report, mouse report, query reply) must not be silently lost.
  static func interactiveWritesSurviveFullPasteBudget() async {
    let dir = NSTemporaryDirectory() + "ws-vt-input-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(atPath: dir) }
    let g1 = dir + "/g1", g2 = dir + "/g2"
    func touch(_ path: String) { FileManager.default.createFile(atPath: path, contents: Data()) }
    let script = "stty raw -echo; printf 'READY_D1\u{1b}[?1004h\u{1b}[?1000h\u{1b}[?1006h'; while [ ! -e \(g1) ]; do sleep 0.02; done; printf '\u{1b}[6n'; while [ ! -e \(g2) ]; do sleep 0.02; done; exec cat"
    let (backend, recorder) = LaneBSmoke.launch(script)
    check(LaneBSmoke.eventually { recorder.hasOutput("READY_D1") }, "D1: child never became ready"); LaneBSmoke.barrier(backend)
    // The child is not reading, so the kernel PTY buffer fills and the rest stays pending in the transport. Top the admission up one byte at a time until it refuses, so it is exactly full when the interactive writes below are attempted.
    var bulk = 256 * 1024
    check(backend.sendRaw(Data(repeating: 0x78, count: bulk)), "D1: a paste exactly the size of the admission budget must be accepted")
    LaneBSmoke.barrier(backend); LaneBSmoke.settle(150); LaneBSmoke.barrier(backend)
    while backend.sendRaw(Data([0x78])) { bulk += 1; if bulk > 300 * 1024 { break } }
    check(bulk <= 300 * 1024, "D1: admission never filled (bulk=\(bulk))"); print("D1: admission filled with \(bulk) pending bulk bytes")
    backend.encodeKey(key: GHOSTTY_KEY_A, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_PRESS, text: "a", unshiftedCodepoint: 0)
    backend.focus(true)
    backend.mouse(action: 0, button: 1, modifiers: 0, xPixels: 4, yPixels: 4, geometry: VTMouseGeometry(screenWidth: 640, screenHeight: 384, cellWidth: 8, cellHeight: 16))
    LaneBSmoke.barrier(backend)
    touch(g1); check(LaneBSmoke.eventually { recorder.hasOutput("\u{1b}[6n") }, "D1: child never issued the cursor-position query"); LaneBSmoke.settle(150); LaneBSmoke.barrier(backend)
    touch(g2)
    _ = LaneBSmoke.eventually(8) { let t = recorder.outputText; guard let r = t.range(of: "\u{1b}[6n") else { return false }; return t[r.upperBound...].utf8.count >= bulk }
    _ = LaneBSmoke.eventually(3) { let t = recorder.outputText; guard let r = t.range(of: "\u{1b}[6n") else { return false }; return t[r.upperBound...].contains("\u{1b}[1;") }
    LaneBSmoke.settle(150)
    let text = recorder.outputText; let rest = text.range(of: "\u{1b}[6n").map { String(text[$0.upperBound...]) } ?? ""
    let tail = String(rest.dropFirst(bulk))
    check(rest.hasPrefix(String(repeating: "x", count: bulk)), "D1: the paste itself was not delivered intact (\(rest.utf8.count) bytes echoed)")
    check(tail.contains("a"), "D1: key 'a' encoded while the paste budget was full was silently dropped (tail=\(tail.debugDescription))")
    check(tail.contains("\u{1b}[I"), "D1: focus report was silently dropped (tail=\(tail.debugDescription))")
    check(tail.contains("\u{1b}[<0;"), "D1: mouse report was silently dropped (tail=\(tail.debugDescription))")
    check(tail.contains("\u{1b}[1;"), "D1: cursor-position query reply was silently dropped (tail=\(tail.debugDescription))")
    touch(g2); await backend.closeAndWait()
  }
  static func makeGate() -> (path: String, open: () -> Void, cleanup: () -> Void) {
    let dir = NSTemporaryDirectory() + "ws-vt-gate-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/g"; return (path, { FileManager.default.createFile(atPath: path, contents: Data()) }, { try? FileManager.default.removeItem(atPath: dir) })
  }
  /// Fills the bulk admission exactly (child not reading) and returns the number of pending bulk bytes.
  static func fillBulkAdmission(_ backend: GhosttyVTBackend, label: String) -> Int {
    var bulk = 256 * 1024
    check(backend.sendRaw(Data(repeating: 0x78, count: bulk)), "\(label): a paste exactly the size of the admission budget must be accepted")
    LaneBSmoke.barrier(backend); LaneBSmoke.settle(150); LaneBSmoke.barrier(backend)
    while backend.sendRaw(Data([0x78])) { bulk += 1; if bulk > 300 * 1024 { break } }
    return bulk
  }
  // D2: interactive writes are bounded: beyond the allowance they are counted and reported through onInputDropped (not onError), everything admitted is delivered in order, and the admission counter returns to zero.
  static func interactiveOverflowIsReportedAndBounded() async {
    let gate = makeGate(); defer { gate.cleanup() }
    let (backend, recorder) = LaneBSmoke.launch("stty raw -echo; printf READY_D2; while [ ! -e \(gate.path) ]; do sleep 0.02; done; exec cat")
    let reports = LaneFlagCounter(); backend.onInputDropped = { reports.add($0) }
    var errors = [String](); let errorLock = NSLock(); backend.onError = { errorLock.lock(); errors.append($0); errorLock.unlock() }
    check(LaneBSmoke.eventually { recorder.hasOutput("READY_D2") }, "D2: child never became ready")
    let bulk = fillBulkAdmission(backend, label: "D2")
    let allowance = 64 * 1024, keys = allowance + 4000
    for _ in 0..<keys { backend.encodeKey(key: GHOSTTY_KEY_A, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_PRESS, text: "k", unshiftedCodepoint: 0) }
    LaneBSmoke.barrier(backend)
    check(backend.droppedInteractiveBytes == 4000 && reports.total == 4000, "D2: expected exactly 4000 dropped interactive bytes reported, got counter=\(backend.droppedInteractiveBytes) callbacks=\(reports.total)")
    check(backend.reservedInputForTesting == 256 * 1024 + allowance, "D2: admission is not bounded at limit+allowance (reserved=\(backend.reservedInputForTesting))")
    check(!backend.sendRaw(Data([0x78])), "D2: bulk writes must still be refused while the budget is full")
    gate.open()
    let total = bulk + allowance
    _ = LaneBSmoke.eventually(10) { let t = recorder.outputText; guard let r = t.range(of: "READY_D2") else { return false }; return t[r.upperBound...].utf8.count >= total }
    LaneBSmoke.settle(150)
    let text = recorder.outputText; let rest = text.range(of: "READY_D2").map { String(text[$0.upperBound...]) } ?? ""
    check(rest == String(repeating: "x", count: bulk) + String(repeating: "k", count: allowance), "D2: delivered stream differs from admitted bytes (\(rest.utf8.count) bytes vs \(total))")
    check(LaneBSmoke.eventually { backend.reservedInputForTesting == 0 }, "D2: reservedInput did not return to 0 after delivery (\(backend.reservedInputForTesting))")
    errorLock.lock(); check(errors.isEmpty, "D2: an overflow must not be reported through onError: \(errors)"); errorLock.unlock()
    await backend.closeAndWait()
  }
  // D3: reservedInput is released on close and on child exit even with a pending backlog.
  static func admissionIsReleasedOnCloseAndExit() async {
    do {
      let gate = makeGate(); defer { gate.cleanup() }
      let (backend, recorder) = LaneBSmoke.launch("stty raw -echo; printf READY_D3; while [ ! -e \(gate.path) ]; do sleep 0.02; done; exec cat")
      check(LaneBSmoke.eventually { recorder.hasOutput("READY_D3") }, "D3: child never became ready")
      let bulk = fillBulkAdmission(backend, label: "D3"); check(backend.reservedInputForTesting > 0 && bulk > 0, "D3: nothing pending")
      backend.encodeKey(key: GHOSTTY_KEY_A, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_PRESS, text: "a", unshiftedCodepoint: 0); LaneBSmoke.barrier(backend)
      await backend.closeAndWait()
      check(backend.reservedInputForTesting == 0, "D3: reservedInput not released on close (\(backend.reservedInputForTesting))")
      check(!backend.sendRaw(Data([0x78])), "D3: writes must be refused after close")
    }
    do {
      let gate = makeGate(); defer { gate.cleanup() }
      let (backend, recorder) = LaneBSmoke.launch("stty raw -echo; printf READY_D3B; while [ ! -e \(gate.path) ]; do sleep 0.02; done; exit 3")
      check(LaneBSmoke.eventually { recorder.hasOutput("READY_D3B") }, "D3: exit child never became ready")
      _ = fillBulkAdmission(backend, label: "D3b")
      backend.encodeKey(key: GHOSTTY_KEY_A, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_PRESS, text: "a", unshiftedCodepoint: 0); LaneBSmoke.barrier(backend)
      gate.open()
      check(LaneBSmoke.eventually(8) { recorder.hasExited }, "D3: child exit not delivered with pending input")
      check(LaneBSmoke.eventually { backend.reservedInputForTesting == 0 }, "D3: reservedInput not released on child exit (\(backend.reservedInputForTesting))")
      await backend.closeAndWait()
      check(backend.reservedInputForTesting == 0, "D3: reservedInput nonzero after exit+close (\(backend.reservedInputForTesting))")
    }
  }
  /// The entry point TerminalVTView.insertText uses for committed IME / multi-character text.
  @discardableResult static func typed(_ backend: GhosttyVTBackend, _ data: Data) -> Bool { backend.sendTyped(data) }
  static func key(_ backend: GhosttyVTBackend, _ text: String) { backend.encodeKey(key: GHOSTTY_KEY_A, modifiers: GhosttyMods(0), action: GHOSTTY_KEY_ACTION_PRESS, text: text, unshiftedCodepoint: 0) }
  // T1/T2/T3: committed typed text is keyboard input. It stays ordered relative to encoded keys, is not lost while a paste holds the bulk admission, and beyond the allowance is counted and reported.
  static func typedTextKeepsOrderAndSurvivesFullPasteBudget() async {
    do {
      let (backend, recorder) = LaneBSmoke.launch("stty raw -echo; printf READY_T1; exec cat")
      check(LaneBSmoke.eventually { recorder.hasOutput("READY_T1") }, "T1: child never became ready")
      backend.queue.async { usleep(200_000) }
      key(backend, "a"); check(typed(backend, Data("bc".utf8)), "T1: typed text rejected"); key(backend, "d"); typed(backend, Data("e".utf8))
      backend.queue.async { usleep(200_000) }
      for i in 0..<300 { let ch = String(alphabet[i % alphabet.count]); if i % 3 == 0 { key(backend, ch) } else { typed(backend, Data((ch + ch).utf8)) } }
      var exact = "abcde"; for i in 0..<300 { let ch = String(alphabet[i % alphabet.count]); exact += i % 3 == 0 ? ch : ch + ch }
      let actual = readback(recorder, marker: "READY_T1", expected: exact)
      check(actual == exact, "T1: typed text reordered relative to encoded keys: \(firstMismatch(actual, exact))")
      await backend.closeAndWait()
    }
    let gate = makeGate(); defer { gate.cleanup() }
    let (backend, recorder) = LaneBSmoke.launch("stty raw -echo; printf READY_T2; while [ ! -e \(gate.path) ]; do sleep 0.02; done; exec cat")
    let reports = LaneFlagCounter(); backend.onInputDropped = { reports.add($0) }
    check(LaneBSmoke.eventually { recorder.hasOutput("READY_T2") }, "T2: child never became ready")
    let bulk = fillBulkAdmission(backend, label: "T2")
    let ime = "中文输入é"
    check(typed(backend, Data(ime.utf8)), "T2: committed text was refused while a paste held the bulk admission")
    let allowance = 64 * 1024, used = ime.utf8.count
    check(typed(backend, Data(repeating: 0x6b, count: allowance - used)), "T2: typed text within the allowance was refused")
    check(!typed(backend, Data(repeating: 0x7a, count: 100)), "T2: typed text beyond the allowance must report refusal")
    check(backend.droppedInteractiveBytes == 100 && reports.total == 100, "T2: refusal not counted/reported (counter=\(backend.droppedInteractiveBytes) callbacks=\(reports.total))")
    check(backend.reservedInputForTesting == 256 * 1024 + allowance, "T2: typed writes are not bounded at limit+allowance (reserved=\(backend.reservedInputForTesting))")
    gate.open()
    let total = bulk + allowance
    _ = LaneBSmoke.eventually(10) { let t = recorder.outputText; guard let r = t.range(of: "READY_T2") else { return false }; return t[r.upperBound...].utf8.count >= total }
    LaneBSmoke.settle(150)
    let text = recorder.outputText; let rest = text.range(of: "READY_T2").map { String(text[$0.upperBound...]) } ?? ""
    check(rest == String(repeating: "x", count: bulk) + ime + String(repeating: "k", count: allowance - used), "T2: delivered stream differs from admitted bytes (\(rest.utf8.count) vs \(total))")
    check(LaneBSmoke.eventually { backend.reservedInputForTesting == 0 }, "T2: reservedInput did not return to 0 (\(backend.reservedInputForTesting))")
    await backend.closeAndWait()
  }
}
#endif
