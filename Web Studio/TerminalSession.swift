import AppKit
import Combine
import Darwin
import Foundation
import SwiftTerm

private struct PTYExit: Sendable { let code: Int32? }

/// All descriptor, process and dispatch-source state is serialized here. The
/// MainActor session only owns the SwiftTerm view and publishes UI state.
private final class PTYProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.huaodong.web-studio.pty", qos: .userInitiated)
    private var pid: pid_t = 0; private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?; private var writeSource: DispatchSourceWrite?; private var reapTimer: DispatchSourceTimer?; private var killTimer: DispatchSourceTimer?
    private var closing = false; private var finished = false; private var readClosed = false
    private var deliveryPending = false; private var pending = Data(); private var pendingInput = Data(); private let pendingLimit = 256 * 1024
    private var readSuspended = false; private var pendingExit: PTYExit?
    private var ownedGroup: pid_t = 0
    private var keepAlive: PTYProcess?
    var onStart: ((Bool, String?) -> Void)?; var onOutput: ((Data) -> Void)?; var onExit: ((PTYExit) -> Void)?; var onIOFailure: ((String) -> Void)?
    func currentPID() async -> pid_t? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: pid > 0 ? pid : nil) }
        }
    }

    func start(executable: String, argv: [String], environment: [String: String], directory: String?, cols: Int, rows: Int) {
        queue.async { [self] in
            guard !closing else { return }
            var args = argv.map { strdup($0) } + [nil]; var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            let result = args.withUnsafeMutableBufferPointer { ab in env.withUnsafeMutableBufferPointer { eb in
                (directory ?? "").withCString { dir in executable.withCString { exe in
                    studio_pty_spawn(exe, ab.baseAddress!, eb.baseAddress!, directory == nil ? nil : dir, UInt16(clamping: cols), UInt16(clamping: rows))
                }}
            }}
            args.dropLast().forEach { free($0) }; env.dropLast().forEach { free($0) }
            if closing {
                // close() may run before forkpty returns. Do not adopt the
                // child after the backend has already completed; clean up
                // the exact pid/fd returned by this spawn instead.
                if result.pid > 0 {
                    _ = kill(-result.pid, SIGHUP)
                    _ = kill(result.pid, SIGTERM)
                    _ = studio_pty_close(result.master_fd)
                    var ignored: Int32 = 0
                    repeat { } while waitpid(result.pid, &ignored, 0) < 0 && errno == EINTR
                } else if result.master_fd >= 0 {
                    _ = studio_pty_close(result.master_fd)
                }
                return
            }
            guard result.pid > 0, result.master_fd >= 0 else {
                let detail = result.error_stage == 3 ? "Unable to change directory: " : result.error_stage == 4 ? "Unable to execute terminal: " : result.error_stage == 7 ? "Sandbox denied controlling terminal: " : "Unable to start terminal: "
                onStart?(false, detail + String(cString: strerror(result.error_number))); finished = true; keepAlive = nil; return
            }
            pid = result.pid; fd = result.master_fd; keepAlive = self
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            readSource = source; source.resume()
            onStart?(true, nil); beginReaping()
        }
    }

    func write(_ data: Data) { queue.async { [self] in
        guard fd >= 0, pid > 0, pendingExit == nil, !closing, !finished else { return }
        guard pendingInput.count + data.count <= pendingLimit else { onIOFailure?("Terminal input buffer is full."); return }
        pendingInput.append(data); armWriteSource(); drainWrites()
    } }
    private func armWriteSource() {
        guard writeSource == nil, fd >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainWrites() }
        source.setCancelHandler { }
        writeSource = source; source.resume()
    }
    private func drainWrites() {
        guard fd >= 0, pid > 0, pendingExit == nil, !closing, !finished else { return }
        var budget = 32 * 1024
        while !pendingInput.isEmpty && budget > 0 {
            let amount = min(pendingInput.count, budget)
            let n = pendingInput.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, amount) }
            if n > 0 { pendingInput.removeFirst(n); budget -= n; continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN { return }
            let message = String(cString: strerror(errno)); onIOFailure?("Terminal input failed: \(message)"); pendingInput.removeAll(); return
        }
        if pendingInput.isEmpty { writeSource?.cancel(); writeSource = nil }
    }
    func resize(cols: Int, rows: Int) { queue.async { [self] in guard fd >= 0, !finished else { return }; _ = studio_pty_resize(fd, UInt16(clamping: cols), UInt16(clamping: rows)) } }
    func close() { queue.async { [self] in
        guard !finished else { return }; closing = true; pendingInput.removeAll(); writeSource?.cancel(); writeSource = nil
        if fd >= 0 {
            let foreground = tcgetpgrp(fd)
            ownedGroup = (foreground > 0 && getsid(foreground) == pid) ? foreground : pid
            if pid > 0 { _ = kill(-pid, SIGHUP); _ = kill(-pid, SIGTERM) }
            if ownedGroup > 0, ownedGroup != pid { _ = kill(-ownedGroup, SIGHUP); _ = kill(-ownedGroup, SIGTERM) }
            closeFD()
        }
        else if pid > 0 { _ = kill(pid, SIGTERM) }
        else {
            // A close can race the asynchronous spawn. Finish the backend
            // even when forkpty has not returned yet so closeAndWait cannot
            // leave a continuation suspended forever.
            finish(PTYExit(code: nil))
            return
        }
        scheduleKill(); reapNow()
    } }

    private func readAvailable() {
        guard fd >= 0, !readClosed else { return }; var bytes = [UInt8](repeating: 0, count: 32 * 1024); let n = Darwin.read(fd, &bytes, bytes.count)
        if n > 0 { pending.append(contentsOf: bytes[0..<n]); deliverOnce(); if pending.count >= pendingLimit, !readSuspended { readSource?.suspend(); readSuspended = true }; return }
        if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { readClosed = true; readSource?.cancel(); readSource = nil; reapNow() }
    }
    private func deliverOnce() {
        guard !deliveryPending, !pending.isEmpty else { return }; deliveryPending = true; let amount = min(pending.count, 32 * 1024)
        let chunk = Data(pending.prefix(amount)); pending.removeFirst(amount)
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.onOutput?(chunk); self.queue.async { [self] in
            self.deliveryPending = false
            if self.readSuspended, self.pending.count < self.pendingLimit { self.readSource?.resume(); self.readSuspended = false }
            if !self.pending.isEmpty { self.deliverOnce() }
            if let exit = self.pendingExit, !self.deliveryPending {
                self.drainOutput()
                if !self.pending.isEmpty { self.deliverOnce() }
                if !self.deliveryPending, self.pending.isEmpty { self.pendingExit = nil; self.finalize(exit) }
            }
        } }
    }
    private func beginReaping() { let timer = DispatchSource.makeTimerSource(queue: queue); timer.schedule(deadline: .now(), repeating: .milliseconds(100)); timer.setEventHandler { [weak self] in self?.reapNow() }; timer.resume(); reapTimer = timer }
    private func reapNow() {
        guard pid > 0, !finished else { return }; var status: Int32 = 0; var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        if result < 0 && errno == ECHILD { pid = 0; ownedGroup = 0; killTimer?.cancel(); killTimer = nil; finish(PTYExit(code: nil)); return }
        guard result == pid else { return }
        pid = 0; ownedGroup = 0; killTimer?.cancel(); killTimer = nil
        drainOutput(); var exited: Int32 = 0; let code = studio_pty_exit_code(status, &exited); finish(PTYExit(code: exited == 1 ? code : nil))
    }
    private func finish(_ exit: PTYExit) { guard !finished else { return }; pendingExit = exit; pendingInput.removeAll(); writeSource?.cancel(); writeSource = nil; reapTimer?.cancel(); reapTimer = nil; drainOutput(); if !deliveryPending, pending.isEmpty { pendingExit = nil; finalize(exit) } }
    private func finalize(_ exit: PTYExit) { guard !finished else { return }; finished = true; pendingInput.removeAll(); writeSource?.cancel(); writeSource = nil; reapTimer?.cancel(); reapTimer = nil; killTimer?.cancel(); killTimer = nil; if readSuspended { readSource?.resume(); readSuspended = false }; readSource?.cancel(); readSource = nil; closeFD(); pid = 0; keepAlive = nil; let callback = onExit; onExit = nil; callback?(exit) }
    private func drainOutput() { guard fd >= 0 else { return }; var bytes = [UInt8](repeating: 0, count: 32 * 1024); while pending.count < pendingLimit { let n = Darwin.read(fd, &bytes, bytes.count); if n > 0 { pending.append(contentsOf: bytes[0..<n]); continue }; if n < 0 && errno == EINTR { continue }; if n < 0 && errno == EAGAIN { break }; break }; deliverOnce() }
    private func signalOwnedGroup(_ signal: Int32) { guard ownedGroup > 0 else { return }; _ = kill(-ownedGroup, signal) }
    private func scheduleKill() { killTimer?.cancel(); let timer = DispatchSource.makeTimerSource(queue: queue); timer.schedule(deadline: .now() + .milliseconds(350)); timer.setEventHandler { [weak self] in guard let self, !self.finished else { return }; if self.ownedGroup > 0 { _ = kill(-self.ownedGroup, SIGKILL) }; if self.pid > 0 { _ = kill(self.pid, SIGKILL) }; self.killTimer?.cancel(); self.killTimer = nil }; timer.resume(); killTimer = timer }
    private func closeFD() { guard fd >= 0 else { return }; _ = studio_pty_close(fd); fd = -1 }
}

@MainActor final class TerminalSession: NSObject, ObservableObject, TerminalViewDelegate {
    enum State: Equatable { case idle, starting, running, exited(Int32?), failed(String), interrupted }
    let resourceID: UUID; let terminalView: TerminalView
    private(set) var ghosttyView: GhosttyTerminalView?
    private var lastGhosttySnapshot = ""
    var nativeView: NSView { ghosttyView ?? terminalView }
    @Published private(set) var state: State = .idle; @Published private(set) var knownDirectory: String?
    private var securityScopedURL: URL?; private let process = PTYProcess(); private var closeRequested = false
    private var ioFailureMessage: String?
    private var processStarted = false
    private var processFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(resourceID: UUID, frame: CGRect = .zero) {
        self.resourceID = resourceID; terminalView = TerminalView(frame: frame); super.init(); terminalView.terminalDelegate = self
        process.onStart = { [weak self] ok, error in Task { @MainActor in
            guard let self else { return }
            if ok && !self.closeRequested && !self.processFinished {
                self.processStarted = true
                self.state = .running
            } else if !ok {
                self.processFinished = true
                self.securityScopedURL?.stopAccessingSecurityScopedResource()
                self.securityScopedURL = nil
                self.state = .failed(error ?? "Unable to start terminal")
                self.resumeWaiters()
            }
        } }
        process.onOutput = { [weak self] data in guard let self, !self.closeRequested else { return }; self.terminalView.feed(byteArray: Array(data)[...]) }
        process.onExit = { [weak self] exit in Task { @MainActor in
            guard let self else { return }
            self.securityScopedURL?.stopAccessingSecurityScopedResource()
            self.securityScopedURL = nil
            self.processFinished = true
            self.state = self.ioFailureMessage.map(State.failed) ?? (self.closeRequested ? .interrupted : .exited(exit.code))
            self.resumeWaiters()
        } }
        process.onIOFailure = { [weak self] message in Task { @MainActor in
            guard let self, self.state == .running || self.state == .starting else { return }
            self.ioFailureMessage = message; self.state = .failed(message); self.process.close()
        } }
        terminalView.getTerminal().changeScrollback(2000)
    }
    func startLocal(directory: String? = nil) { let cwd = directory ?? FileManager.default.homeDirectoryForCurrentUser.path; knownDirectory = cwd; start(executable: "/bin/zsh", argv: ["zsh", "-il"], directory: cwd) }
    func setKnownDirectory(_ directory: String) { if state == .idle { knownDirectory = directory } }
    /// Internal launch seam used by the bounded PTY integration tests.
    func startForTesting(executable: String, argv: [String], directory: String) {
        knownDirectory = directory
        start(executable: executable, argv: argv, directory: directory, useGhostty: false)
    }
    /// Production-backend seam for focused Ghostty integration tests.
    func startGhosttyForTesting(executable: String, argv: [String], directory: String) {
        knownDirectory = directory
        start(executable: executable, argv: argv, directory: directory, useGhostty: true)
    }
    func actualPID() async -> pid_t? { await process.currentPID() }
    func retainSecurityScope(_ url: URL) { if url.startAccessingSecurityScopedResource() { securityScopedURL = url } }
    func startSSH(host: String, user: String, port: Int, knownHosts: String) {
        guard Self.validToken(host), user.isEmpty || Self.validToken(user), (1...65535).contains(port) else { state = .failed("Invalid SSH connection details"); return }
        let args = ["ssh", "-o", "StrictHostKeyChecking=ask", "-o", "UserKnownHostsFile=\(knownHosts)", "-p", "\(port)"] + (user.isEmpty ? [] : ["-l", user]) + [host]
        let cwd = FileManager.default.homeDirectoryForCurrentUser.path; knownDirectory = cwd; start(executable: "/usr/bin/ssh", argv: args, directory: cwd)
    }
    private func start(executable: String, argv: [String], directory: String, useGhostty: Bool = true) {
        guard state == .idle else { return }; state = .starting; processStarted = true; let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ["HOME": home, "ZDOTDIR": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color"]
        if executable == "/usr/bin/ssh", let authSocket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !authSocket.isEmpty {
            environment["SSH_AUTH_SOCK"] = authSocket
        }
        // The production path is a single Ghostty-owned PTY/surface. The
        // SwiftTerm PTY remains available through startForTesting so the
        // existing deterministic adapter tests continue to exercise cleanup.
        let command = ([executable] + argv.dropFirst()).map(Self.shellQuote).joined(separator: " ")
        let waitAfterCommand = true
        if useGhostty, let view = GhosttyTerminalRuntime.shared.makeView(directory: directory, environment: environment, command: command, waitAfterCommand: waitAfterCommand) {
            ghosttyView = view
            view.onDirectoryChange = { [weak self] directory in
                guard let self, !directory.isEmpty,
                      directory.hasPrefix("/"),
                      !directory.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return }
                self.knownDirectory = directory
            }
            view.onChildExit = { [weak self, weak view] code in
                guard let self, let view, !self.processFinished else { return }
                self.processFinished = true
                self.lastGhosttySnapshot = view.renderedText()
                self.state = self.closeRequested ? .interrupted : .exited(code)
                self.resumeWaiters()
            }
            state = .running
        } else {
            if useGhostty {
                state = .failed("GhosttyKit could not create the terminal surface.")
                processStarted = false
            } else {
                process.start(executable: executable, argv: argv, environment: environment, directory: directory, cols: terminalView.getTerminal().cols, rows: terminalView.getTerminal().rows)
            }
        }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { process.write(Data(data)) }
    func send(data: Data) {
        if let ghosttyView { ghosttyView.send(data: data) }
        else { process.write(data) }
    }
    func resize(cols: Int, rows: Int) {
        if let ghosttyView { ghosttyView.resize(cols: cols, rows: rows) }
        else { process.resize(cols: cols, rows: rows) }
    }
    func renderedText() -> String {
        if let ghosttyView { return ghosttyView.renderedText() }
        if !lastGhosttySnapshot.isEmpty { return lastGhosttySnapshot }
        let raw = terminalView.getTerminal().getBufferAsData()
        return (String(data: raw, encoding: .utf8) ?? "").replacingOccurrences(of: "\0", with: "")
    }
    func renderedSnapshot(maxBytes: Int = 64 * 1024) -> Data {
        Data(renderedText().utf8.prefix(max(0, maxBytes)))
    }
    func close(interrupted: Bool = false) {
        guard !closeRequested else { return }
        closeRequested = true
        if state == .idle {
            state = interrupted ? .interrupted : .exited(nil)
            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
            resumeWaiters()
        }
        if let ghosttyView {
            ghosttyView.close()
            if interrupted { state = .interrupted }
        } else {
            process.close()
        }
    }
    func closeAndWait() async {
        if processStarted && !processFinished {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
                close()
            }
        } else { close() }
    }
    private func resumeWaiters() { let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
    private static func validToken(_ value: String) -> Bool { !value.isEmpty && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f && !$0.properties.isWhitespace && $0 != "/" && $0 != "\\" && $0 != "\n" && $0 != "\r" } }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { resize(cols: newCols, rows: newRows) }; func setTerminalTitle(source: TerminalView, title: String) {}; func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { guard let directory, !directory.isEmpty, !directory.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return }; let url = directory.hasPrefix("/") ? URL(fileURLWithPath: directory) : URL(string: directory); guard let url, url.isFileURL, url.path.hasPrefix("/") else { return }; knownDirectory = url.path }; func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) { if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) { NSWorkspace.shared.open(url) } }; func bell(source: TerminalView) {}; func clipboardCopy(source: TerminalView, content: Data) {}; func clipboardRead(source: TerminalView) -> Data? { nil }; func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}; func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
