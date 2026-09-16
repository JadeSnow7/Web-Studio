#if WEB_STUDIO_VT
import Foundation

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
  }
}
#endif
