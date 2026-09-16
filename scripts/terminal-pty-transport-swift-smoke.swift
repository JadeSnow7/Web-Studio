import Foundation

@main struct PTYTransportSmoke {
  static func main() async {
    let t = TerminalPTYTransport()
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock(); var output = Data(); var ok = false
    t.onOutput = { lock.lock(); output.append($0); lock.unlock() }
    t.onExit = { _ in done.signal() }
    t.onStart = { started, _ in if started { lock.lock(); ok = t.write(Data("printf 'SWIFT_%s' READY; exit\n".utf8)); lock.unlock() } }
    t.start(executable: "/bin/zsh", argv: ["/bin/zsh", "-df"], environment: ["TERM":"xterm-256color","PATH":"/usr/bin:/bin"], directory: nil, columns: 80, rows: 24)
    precondition(done.wait(timeout: .now() + 3) == .success)
    lock.lock(); let text = String(decoding: output, as: UTF8.self); let accepted = ok; lock.unlock()
    precondition(accepted && text.contains("SWIFT_READY"))
    let stream = TerminalPTYTransport()
    let streamDone = DispatchSemaphore(value: 0)
    let streamLock = NSLock(); var streamOutput = Data()
    stream.onOutput = { chunk in streamLock.lock(); streamOutput.append(chunk); streamLock.unlock() }
    stream.onExit = { _ in streamDone.signal() }
    stream.onStart = { started, _ in
      if started {
        precondition(stream.write(Data("yes X | head -c 1100000; printf 'STREAM_%s' MARK; exit\n".utf8)))
        stream.resize(columns: 0, rows: 0, widthPixels: 0, heightPixels: 0)
      }
    }
    stream.start(executable: "/bin/sh", argv: ["/bin/sh", "-f"], environment: ["PATH":"/usr/bin:/bin"], directory: nil, columns: 80, rows: 24)
    precondition(streamDone.wait(timeout: .now() + 5) == .success)
    streamLock.lock(); let streamedData = streamOutput; let streamed = String(decoding: streamedData, as: UTF8.self); streamLock.unlock()
    precondition(streamedData.count >= 1_100_000 && streamed.contains("STREAM_MARK"))
    let pressure = TerminalPTYTransport()
    pressure.start(executable: "/bin/sleep", argv: ["/bin/sleep", "10"], environment: ["PATH":"/usr/bin:/bin"], directory: nil, columns: 80, rows: 24)
    Thread.sleep(forTimeInterval: 0.1)
    precondition(pressure.write(Data(repeating: 0x41, count: 256 * 1024)))
    precondition(!pressure.write(Data(repeating: 0x42, count: 1)))
    await pressure.closeAndWait()
    let sleeper = TerminalPTYTransport(); let exited = DispatchSemaphore(value: 0)
    sleeper.onExit = { _ in exited.signal() }
    sleeper.start(executable: "/bin/sleep", argv: ["/bin/sleep", "10"], environment: ["PATH":"/usr/bin:/bin"], directory: nil, columns: 80, rows: 24)
    await sleeper.closeAndWait(); precondition(exited.wait(timeout: .now()) == .success); sleeper.close()
    let natural = TerminalPTYTransport(); natural.start(executable: "/bin/sh", argv: ["/bin/sh", "-c", "exit 0"], environment: ["PATH":"/usr/bin:/bin"], directory: nil, columns: 80, rows: 24)
    Thread.sleep(forTimeInterval: 0.2); await natural.closeAndWait(); precondition(!natural.write(Data("x".utf8))); await natural.closeAndWait()
    let before = TerminalPTYTransport(); await before.closeAndWait(); before.close(); before.start(executable: "/bin/sleep", argv: ["/bin/sleep", "10"], environment: ["PATH":"/usr/bin:/bin"], directory: nil, columns: 80, rows: 24); Thread.sleep(forTimeInterval: 0.1); precondition(before.currentPID() == nil)
    guard let fixturePath = ProcessInfo.processInfo.environment["FIXTURE_PATH"] else { fatalError("missing fixture") }
    let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["10"]; try! unrelated.run()
    let resistant = TerminalPTYTransport(); let resistantDone = DispatchSemaphore(value: 0); let resistantLock = NSLock(); var resistantOutput = Data(); var exitCallbacks = 0
    resistant.onOutput = { chunk in resistantLock.lock(); resistantOutput.append(chunk); resistantLock.unlock() }
    resistant.onError = { message in FileHandle.standardError.write(Data("resistant transport error: \(message)\n".utf8)) }
    resistant.onExit = { _ in resistantLock.lock(); exitCallbacks += 1; resistantLock.unlock(); resistantDone.signal() }
    resistant.start(executable: fixturePath, argv: [fixturePath], environment: ["PATH":"/usr/bin:/bin"], directory: nil, columns: 80, rows: 24)
    var childPID: pid_t = -1; var backgroundPID: pid_t = -1
    for _ in 0..<50 { Thread.sleep(forTimeInterval: 0.02); resistantLock.lock(); let text = String(decoding: resistantOutput, as: UTF8.self); resistantLock.unlock(); if let range = text.range(of: "CHILD_PID="), let value = Int32(text[range.upperBound...].prefix(while: { $0.isNumber })) { childPID = pid_t(value) }; if let range = text.range(of: "BACKGROUND_PID="), let value = Int32(text[range.upperBound...].prefix(while: { $0.isNumber })) { backgroundPID = pid_t(value) }; if childPID > 0 && backgroundPID > 0 { break } }
    precondition(childPID > 0 && backgroundPID > 0)
    let resistantCloseDone = DispatchSemaphore(value: 0)
    Task.detached { await resistant.closeAndWait(); resistantCloseDone.signal() }
    precondition(resistantCloseDone.wait(timeout: .now() + 5) == .success)
    precondition(resistantDone.wait(timeout: .now()) == .success)
    let childCheck: Int32 = kill(childPID, 0)
    let childErrno: Int32 = errno
    let groupCheck: Int32 = kill(-childPID, 0)
    let groupErrno: Int32 = errno
    if !(childCheck != 0 && childErrno == ESRCH) {
      FileHandle.standardError.write(Data("resistant child liveness failure child=\(childPID) childKill=\(childCheck) childErrno=\(childErrno) groupKill=\(groupCheck) groupErrno=\(groupErrno) transportPID=\(resistant.currentPID() as Any)\n".utf8))
      preconditionFailure("resistant child survived close")
    }
    precondition(groupCheck != 0 && groupErrno == ESRCH)
    precondition(kill(backgroundPID, 0) != 0 && errno == ESRCH)
    precondition(kill(-backgroundPID, 0) != 0 && errno == ESRCH)
    precondition(unrelated.isRunning); unrelated.terminate(); unrelated.waitUntilExit()
    resistantLock.lock(); precondition(exitCallbacks == 1); resistantLock.unlock()
    let naturalUnrelated = Process(); naturalUnrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); naturalUnrelated.arguments = ["10"]; try! naturalUnrelated.run()
    let naturalResistant = TerminalPTYTransport(); let naturalDone = DispatchSemaphore(value: 0); let naturalLock = NSLock(); var naturalOutput = Data(); var naturalResult: TerminalPTYTransport.Exit?
    naturalResistant.onOutput = { chunk in naturalLock.lock(); naturalOutput.append(chunk); naturalLock.unlock() }
    naturalResistant.onExit = { result in naturalLock.lock(); naturalResult = result; naturalLock.unlock(); naturalDone.signal() }
    naturalResistant.start(executable: fixturePath, argv: [fixturePath, "--natural"], environment: ["PATH":"/usr/bin:/bin"], directory: nil, columns: 80, rows: 24)
    precondition(naturalDone.wait(timeout: .now() + 5) == .success)
    await naturalResistant.closeAndWait()
    naturalLock.lock(); let naturalText = String(decoding: naturalOutput, as: UTF8.self); let observedNatural = naturalResult; naturalLock.unlock()
    precondition(observedNatural?.code == 7 && naturalText.contains("NATURAL_READY"))
    if let range = naturalText.range(of: "CHILD_PID="), let value = Int32(naturalText[range.upperBound...].prefix(while: { $0.isNumber })) { precondition(kill(pid_t(value), 0) != 0 && errno == ESRCH); precondition(kill(-pid_t(value), 0) != 0 && errno == ESRCH) } else { preconditionFailure("missing natural foreground pid") }
    if let range = naturalText.range(of: "BACKGROUND_PID="), let value = Int32(naturalText[range.upperBound...].prefix(while: { $0.isNumber })) { precondition(kill(pid_t(value), 0) != 0 && errno == ESRCH); precondition(kill(-pid_t(value), 0) != 0 && errno == ESRCH) } else { preconditionFailure("missing natural background pid") }
    precondition(naturalUnrelated.isRunning); naturalUnrelated.terminate(); naturalUnrelated.waitUntilExit()
    guard let sigmaskFixture = ProcessInfo.processInfo.environment["SIGMASK_FIXTURE_PATH"] else { fatalError("missing sigmask fixture") }
    let sigmask = TerminalPTYTransport(); let sigmaskDone = DispatchSemaphore(value: 0); let sigmaskReady = DispatchSemaphore(value: 0)
    sigmask.onExit = { _ in sigmaskDone.signal() }
    sigmask.onOutput = { chunk in if String(decoding: chunk, as: UTF8.self).contains("SIGMASK_READY") { sigmaskReady.signal() } }
    sigmask.start(executable: sigmaskFixture, argv: [sigmaskFixture], environment: ["PATH":"/usr/bin:/bin"], directory: nil, columns: 97, rows: 31, widthPixels: 9, heightPixels: 18)
    precondition(sigmaskReady.wait(timeout: .now() + 3) == .success)
    precondition(sigmask.write(Data([0x03])))
    precondition(sigmaskDone.wait(timeout: .now() + 3) == .success)
    await sigmask.closeAndWait()
    print("Swift TerminalPTYTransport smoke passed")
  }
}
