import Foundation
import AppKit
import Testing
@testable import Web_Studio

@MainActor
struct TerminalTests {
    private func waitFor(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }

    private func session() -> TerminalSession {
        TerminalSession(resourceID: UUID(), frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
    }

    @Test func shellEmitsUnicodeANSIAndExitCode() async {
        let terminal = session()
        terminal.startForTesting(executable: "/bin/sh", argv: ["sh", "-c", "printf '\\033[32m你好\\033[0m\\n'; sleep .3; exit 7"], directory: "/tmp")
        _ = await waitFor { if case .exited = terminal.state { return true }; return false }
        _ = await waitFor { (String(data: terminal.renderedSnapshot(), encoding: .utf8) ?? "").contains("你好") }
        let output = (String(data: terminal.renderedSnapshot(), encoding: .utf8) ?? "").replacingOccurrences(of: "\0", with: "")
        #expect(output.contains("你好"))
        if case .exited(let code) = terminal.state { #expect(code == 7) } else { #expect(false) }
    }

    @Test func resizeIsAppliedToRealPTY() async {
        let terminal = session()
        terminal.startForTesting(executable: "/bin/sh", argv: ["sh", "-i"], directory: "/tmp")
        #expect(await waitFor({ terminal.state == .running }))
        terminal.send(data: Data("stty -echo\nprintf '__READY_%s__\\n' 'PTY'\n".utf8))
        #expect(await waitFor { String(data: terminal.renderedSnapshot(), encoding: .utf8)?.contains("__READY_PTY__") == true })
        terminal.resize(cols: 97, rows: 31)
        terminal.send(data: Data("stty size\n".utf8))
        let resizedReady = await waitFor { String(data: terminal.renderedSnapshot(), encoding: .utf8)?.contains("31 97") == true }
        #expect(resizedReady)
        terminal.send(data: Data("exit\n".utf8))
        #expect(await waitFor { if case .exited = terminal.state { return true }; return false })
    }

    @Test func interactiveShellRespondsToCtrlCAndContinues() async {
        let terminal = session()
        terminal.startLocal(directory: "/tmp")
        #expect(await waitFor({ terminal.state == .running }))
        terminal.send(data: Data("stty -echo\nprintf '__READY_%s__\\n' 'PTY'\n".utf8))
        #expect(await waitFor { String(data: terminal.renderedSnapshot(), encoding: .utf8)?.contains("__READY_PTY__") == true })
        terminal.send(data: Data("i=0; while true; do i=$((i+1)); printf '__TICK_%s__\\n' \"$i\"; sleep 0.05; done\n".utf8))
        #expect(await waitFor { String(data: terminal.renderedSnapshot(), encoding: .utf8)?.contains("__TICK_3__") == true })
        try? await Task.sleep(for: .milliseconds(150))
        terminal.send(data: Data([3]))
        try? await Task.sleep(for: .milliseconds(150))
        terminal.send(data: Data("printf '__AFTER_%s__\\n' 'INT'\n".utf8))
        #expect(await waitFor { String(data: terminal.renderedSnapshot(), encoding: .utf8)?.contains("__AFTER_INT__") == true })
        terminal.send(data: Data("exit\n".utf8))
        await terminal.closeAndWait()
    }

    @Test func invalidDirectoryAndExecutableBecomeFailures() async {
        let badDirectory = session()
        badDirectory.startForTesting(executable: "/bin/sh", argv: ["sh"], directory: "/definitely/missing/web-studio-dir")
        #expect(await waitFor { if case .failed = badDirectory.state { return true }; return false })

        let badExecutable = session()
        badExecutable.startForTesting(executable: "/definitely/missing/web-studio-executable", argv: ["missing"], directory: "/tmp")
        #expect(await waitFor { if case .failed = badExecutable.state { return true }; return false })
    }

    @Test func immediateCloseAndWaitReapsChild() async {
        let terminal = session()
        terminal.startForTesting(executable: "/bin/sh", argv: ["sh", "-c", "sleep 10"], directory: "/tmp")
        let closeTask = Task { await terminal.closeAndWait() }
        await closeTask.value
        #expect(await terminal.actualPID() == nil)
        if case .interrupted = terminal.state { } else if case .failed = terminal.state { } else { #expect(false) }
    }

    @Test func closingOwnedSessionLeavesUnrelatedProcessRunning() async {
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["2"]
        try? unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }

        let terminal = session()
        terminal.startForTesting(executable: "/bin/sh", argv: ["sh", "-c", "sleep 10"], directory: "/tmp")
        await terminal.closeAndWait()
        #expect(unrelated.isRunning)
    }
}
