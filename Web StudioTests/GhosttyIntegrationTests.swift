import AppKit
import Darwin
import Foundation
import Testing
@testable import Web_Studio

/// Black-box checks for the default, direct-download Ghostty backend.
/// These launch `/bin/sh` through TerminalSession, never the SwiftTerm seam.
@Suite(.serialized)
@MainActor
struct GhosttyIntegrationTests {
    private struct Fixture {
        let directory: URL
        let session: TerminalSession
        let window: NSWindow

        func close() async {
            await session.closeAndWait()
            window.orderOut(nil)
        }
    }

    private func fixture(width: CGFloat = 900, height: CGFloat = 560) -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-studio-ghostty-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = TerminalSession(resourceID: UUID(), frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        return Fixture(directory: directory, session: session, window: window)
    }

    private func mount(_ f: Fixture) throws {
        try #require(f.session.ghosttyView != nil, "Ghostty surface unavailable; state=\(f.session.state)")
        guard let content = f.window.contentView else { return }
        content.addSubview(f.session.nativeView)
        f.session.nativeView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            f.session.nativeView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            f.session.nativeView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            f.session.nativeView.topAnchor.constraint(equalTo: content.topAnchor),
            f.session.nativeView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        f.window.layoutIfNeeded()
    }

    private func waitFor(timeout: Duration = .seconds(5), _ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func pid(from url: URL) -> pid_t? {
        guard let value = Int32(read(url).trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return pid_t(value)
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test func launchesExactShellAndCapturesUnicodeAnsiAndUnknownExitStatus() async throws {
        let f = fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        defer { Task { await f.close() } }
        let marker = f.directory.appendingPathComponent("launch.txt").path
        let script = "printf 'cwd=%s\\nargv0=%s\\narg1=%s\\n' \"$PWD\" \"$0\" \"$1\" > \(Self.shellQuote(marker)); printf '\\033[32mGHOSTTY_UNICODE_你好\\033[0m\\n'; exit 7"
        let literalArgument = "literal space 'quote'; $HOME"
        f.session.startGhosttyForTesting(executable: "/bin/sh", argv: ["sh", "-c", script, "ghostty-test-zero", literalArgument], directory: f.directory.path)
        try mount(f)
        #expect(await waitFor { f.session.state.isExited })
        let markerText = read(URL(fileURLWithPath: marker))
        let cwd = markerText.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("cwd=") })
            .map { String($0.dropFirst(4)) }
        #expect(cwd.map(canonicalPath) == canonicalPath(f.directory.path))
        #expect(markerText.contains("argv0=ghostty-test-zero"))
        #expect(markerText.contains("arg1=\(literalArgument)"))
        #expect(f.session.renderedText().contains("GHOSTTY_UNICODE_你好"))
        // Ghostty's macOS `/usr/bin/login` wrapper cannot reliably propagate
        // the shell's status code (upstream Surface.zig documents this). Keep
        // the shell's `exit 7` in the script to prove the requested command
        // ran, while the adapter intentionally reports an unknown status.
        if case .exited(let code) = f.session.state { #expect(code == nil) }
        else { #expect(Bool(false), "Ghostty child did not report an exit state") }
        await f.close()
    }

    @Test func appliesResizeAndContinuesAfterCtrlC() async throws {
        let f = fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        defer { Task { await f.close() } }
        f.session.startGhosttyForTesting(executable: "/bin/sh", argv: ["sh", "-i"], directory: f.directory.path)
        try mount(f)
        f.session.send(data: Data("stty -echo; PS1='__GHOSTTY_PROMPT__> '\nprintf '%s' '__GHOSTTY_'; printf '%s\\n' 'READY__'\n".utf8))
        #expect(await waitFor { f.session.renderedText().contains("__GHOSTTY_READY__") })
        f.session.resize(cols: 97, rows: 31)
        f.session.send(data: Data("printf '%s' '__GHOSTTY_SIZE__'; stty size; printf '%s\\n' '__SIZE_END__'\n".utf8))
        let resized = await waitFor { f.session.renderedText().contains("__GHOSTTY_SIZE__31 97") }
        #expect(resized, "Rendered terminal text: \(f.session.renderedText())")
        f.session.send(data: Data("printf '%s\\n' '__GHOSTTY_SLEEPING__'; sleep 30\n".utf8))
        #expect(await waitFor { f.session.renderedText().contains("__GHOSTTY_SLEEPING__") })
        let promptBeforeInterrupt = occurrences(of: "__GHOSTTY_PROMPT__> ", in: f.session.renderedText())
        f.session.send(data: Data([3]))
        let promptReturned = await waitFor {
            occurrences(of: "__GHOSTTY_PROMPT__> ", in: f.session.renderedText()) > promptBeforeInterrupt
        }
        #expect(promptReturned, "Prompt did not return after Ctrl-C; rendered terminal text: \(f.session.renderedText())")
        f.session.send(data: Data("printf '%s\\n' '__GHOSTTY_AFTER_INT__'; exit\n".utf8))
        let afterInterrupt = await waitFor { f.session.renderedText().contains("__GHOSTTY_AFTER_INT__") }
        #expect(afterInterrupt, "Follow-up command did not run; rendered terminal text: \(f.session.renderedText())")
        #expect(await waitFor { f.session.state.isExited }, "Shell did not exit after follow-up command; rendered terminal text: \(f.session.renderedText())")
        await f.close()
    }

    @Test func unmountAndRemountKeepsGhosttyChildAlive() async throws {
        let f = fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        defer { Task { await f.close() } }
        let pidFile = f.directory.appendingPathComponent("shell.pid")
        f.session.startGhosttyForTesting(executable: "/bin/sh", argv: ["sh", "-i"], directory: f.directory.path)
        try mount(f)
        f.session.send(data: Data("stty -echo\n".utf8))
        f.session.send(data: Data("printf '%s' \"$$\" > \(Self.shellQuote(pidFile.path)); printf '%s' '__GHOSTTY_'; printf '%s\\n' 'MOUNTED__'\n".utf8))
        #expect(await waitFor { f.session.renderedText().contains("__GHOSTTY_MOUNTED__") && FileManager.default.fileExists(atPath: pidFile.path) })
        guard let shellPID = pid(from: pidFile) else {
            #expect(Bool(false), "shell did not write $$ marker")
            await f.close()
            return
        }
        f.session.nativeView.removeFromSuperview()
        #expect(isAlive(shellPID))
        f.window.contentView?.addSubview(f.session.nativeView)
        f.session.nativeView.translatesAutoresizingMaskIntoConstraints = false
        if let content = f.window.contentView {
            NSLayoutConstraint.activate([
                f.session.nativeView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                f.session.nativeView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                f.session.nativeView.topAnchor.constraint(equalTo: content.topAnchor),
                f.session.nativeView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        f.window.layoutIfNeeded()
        f.session.send(data: Data("printf '%s' '__GHOSTTY_'; printf '%s\\n' 'REMOUNTED__'\n".utf8))
        #expect(await waitFor { f.session.renderedText().contains("__GHOSTTY_REMOUNTED__") })
        #expect(isAlive(shellPID))
        await f.close()
    }

    @Test func closeStopsOwnedShellButLeavesUnrelatedChildRunning() async throws {
        let f = fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        defer { Task { await f.close() } }
        let shellPIDFile = f.directory.appendingPathComponent("shell.pid")
        let childPIDFile = f.directory.appendingPathComponent("child.pid")
        let script = "sleep 30 & child=$!; printf '%s' \"$$\" > \(Self.shellQuote(shellPIDFile.path)); printf '%s' \"$child\" > \(Self.shellQuote(childPIDFile.path)); printf '%s\\n' '__GHOSTTY_CLOSE_READY__'; wait"
        f.session.startGhosttyForTesting(executable: "/bin/sh", argv: ["sh", "-c", script], directory: f.directory.path)
        try mount(f)
        #expect(await waitFor { f.session.renderedText().contains("__GHOSTTY_CLOSE_READY__") && FileManager.default.fileExists(atPath: childPIDFile.path) })
        guard let shellPID = pid(from: shellPIDFile), let childPID = pid(from: childPIDFile) else {
            #expect(Bool(false), "shell did not write owned PID markers")
            await f.close()
            return
        }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try? unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        await f.close()
        #expect(!isAlive(shellPID))
        #expect(!isAlive(childPID))
        #expect(unrelated.isRunning)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension TerminalSession.State {
    var isExited: Bool {
        if case .exited = self { return true }
        return false
    }
}
