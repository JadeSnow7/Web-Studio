import Foundation
import Darwin

nonisolated struct CodexProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

nonisolated enum CodexProcessError: Error, Sendable, Equatable {
    case launchFailed
    case cancelled
    case timedOut
    case outputLimit
}

/// Runs one short-lived CLI process without blocking the caller's actor.
///
/// All process lifetime and continuation state is owned by `State.queue`. The
/// state object is explicitly unchecked Sendable because Foundation's Process,
/// Pipe and DispatchSource APIs use escaping callbacks with no Sendable
/// annotations; the queue is the synchronization invariant.
nonisolated final class CodexProcessRunner: Sendable {
    init() {}

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        input: Data? = nil,
        timeout: Duration,
        maxOutputBytes: Int
    ) async throws -> CodexProcessResult {
        guard maxOutputBytes > 0 else { throw CodexProcessError.outputLimit }
        try Task.checkCancellation()

        let state = State(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            input: input,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.start(continuation: continuation)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private nonisolated final class State: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.huaodong.web-studio.codex-process")
    private let executable: URL
    private let arguments: [String]
    private let workingDirectory: URL?
    private let input: Data?
    private let timeout: Duration
    private let maxOutputBytes: Int
    private let writerStop = StopFlag()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var timer: DispatchWorkItem?
    private var continuation: CheckedContinuation<CodexProcessResult, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var inputFinished = false
    private var processExited = false
    private var exitCode: Int32 = -1
    private var terminalError: CodexProcessError?
    private var finished = false

    init(executable: URL, arguments: [String], workingDirectory: URL?, input: Data?, timeout: Duration, maxOutputBytes: Int) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.input = input
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    func start(continuation: CheckedContinuation<CodexProcessResult, Error>) {
        queue.async {
            self.continuation = continuation
            if self.terminalError != nil {
                self.processExited = true
                self.stdoutEOF = true
                self.stderrEOF = true
                self.inputFinished = true
                self.completeIfReady()
                return
            }
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = Pipe()
            process.executableURL = self.executable
            process.arguments = self.arguments
            process.currentDirectoryURL = self.workingDirectory
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.stdinPipe = stdinPipe

            self.installReader(pipe: stdoutPipe, isStdout: true)
            self.installReader(pipe: stderrPipe, isStdout: false)
            process.terminationHandler = { [weak self] process in
                guard let state = self else { return }
                state.queue.async { state.didExit(process.terminationStatus) }
            }

            do {
                try process.run()
            } catch {
                self.terminalError = .launchFailed
                try? stdinPipe.fileHandleForWriting.close()
                self.inputFinished = true
                self.closeReaders()
                self.processExited = true
                self.completeIfReady()
                return
            }

            let interval = max(0, self.timeout.secondsAsDouble)
            let timer = DispatchWorkItem { [weak self] in self?.timeoutReached() }
            self.timer = timer
            self.queue.asyncAfter(deadline: .now() + interval, execute: timer)
            self.writeInput()
        }
    }

    func cancel() {
        queue.async {
            guard !self.finished else { return }
            self.terminalError = .cancelled
            self.writerStop.set()
            self.terminateOwnedProcess()
            self.completeIfReady()
        }
    }

    private func installReader(pipe: Pipe, isStdout: Bool) {
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.readAvailable(from: fd, source: source, isStdout: isStdout)
        }
        source.setCancelHandler {
            try? pipe.fileHandleForReading.close()
        }
        if isStdout { stdoutSource = source } else { stderrSource = source }
        source.resume()
    }

    private func readAvailable(from fd: Int32, source: DispatchSourceRead, isStdout: Bool) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                if stdout.count + stderr.count + count > maxOutputBytes {
                    terminalError = .outputLimit
                    writerStop.set()
                    if isStdout { stdoutEOF = true } else { stderrEOF = true }
                    source.cancel()
                    terminateOwnedProcess()
                    completeIfReady()
                    return
                }
                let data = Data(buffer[0..<count])
                if isStdout { stdout.append(data) } else { stderr.append(data) }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                if isStdout { stdoutEOF = true; stdoutSource = nil } else { stderrEOF = true; stderrSource = nil }
                source.cancel()
                completeIfReady()
            }
            return
        }
    }

    private func writeInput() {
        guard let input, !input.isEmpty, let handle = stdinPipe else {
            try? stdinPipe?.fileHandleForWriting.close()
            inputFinished = true
            return
        }
        let fileHandle = handle.fileHandleForWriting
        let fd = fileHandle.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var offset = 0
            input.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while offset < raw.count {
                    guard !(self?.writerStop.isSet ?? true) else { return }
                    let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                    if written > 0 { offset += written }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN || errno == EWOULDBLOCK {
                        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&descriptor, 1, 100)
                    } else { break }
                }
            }
            try? fileHandle.close()
            guard let state = self else { return }
            state.queue.async { state.inputClosed() }
        }
    }

    private func inputClosed() { inputFinished = true; completeIfReady() }

    private func timeoutReached() {
        guard !finished else { return }
        terminalError = .timedOut
        writerStop.set()
        if processExited { closeReaders() } else { terminateOwnedProcess() }
        completeIfReady()
    }

    private func terminateOwnedProcess() {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        queue.asyncAfter(deadline: .now() + 1) { [weak self, weak process] in
            guard let self, let process, !self.finished, process.isRunning,
                  process.processIdentifier == pid else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private func didExit(_ status: Int32) {
        guard !finished else { return }
        processExited = true
        exitCode = status
        // Once the owned parent is reaped, an error result must not wait for
        // unrelated descendants that inherited its output descriptors.
        if terminalError != nil { closeReaders() }
        completeIfReady()
    }

    private func closeReaders() {
        stdoutSource?.cancel(); stdoutSource = nil
        stderrSource?.cancel(); stderrSource = nil
        stdoutEOF = true; stderrEOF = true
    }

    private func completeIfReady() {
        guard !finished, processExited, stdoutEOF, stderrEOF, inputFinished, let continuation else { return }
        finished = true
        timer?.cancel(); timer = nil
        closeReaders()
        self.continuation = nil
        if let terminalError { continuation.resume(throwing: terminalError) }
        else { continuation.resume(returning: CodexProcessResult(stdout: stdout, stderr: stderr, exitCode: exitCode)) }
        process?.terminationHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdinPipe = nil
    }
}

private nonisolated final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private extension Duration {
    nonisolated var secondsAsDouble: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
