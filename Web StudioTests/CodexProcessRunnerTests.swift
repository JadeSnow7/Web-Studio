import Foundation
import Testing
@testable import Web_Studio

@Suite(.serialized)
struct CodexProcessRunnerTests {
    private let runner = CodexProcessRunner()

    @Test func capturesBothStreamsAndExitStatus() async throws {
        let result = try await shell("printf out; printf err >&2; exit 7")
        #expect(String(data: result.stdout, encoding: .utf8) == "out")
        #expect(String(data: result.stderr, encoding: .utf8) == "err")
        #expect(result.exitCode == 7)
    }

    @Test func drainsPipeSizedInputAndOutputConcurrently() async throws {
        let input = Data(repeating: 65, count: 256 * 1024)
        let result = try await shell("wc -c", input: input, timeout: .seconds(5), maxOutputBytes: 1_024)
        #expect(String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "262144")
    }

    @Test func drainsLargeMixedStreamsWithoutDeadlock() async throws {
        let result = try await shell("yes o | head -c 131072; yes e | head -c 131072 >&2", timeout: .seconds(5), maxOutputBytes: 300_000)
        #expect(result.stdout.count == 131_072)
        #expect(result.stderr.count == 131_072)
    }

    @Test func timeoutKillsProcessIgnoringTerminate() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CodexProcessError.timedOut) {
            _ = try await self.shell("trap '' TERM; exec sleep 30", timeout: .milliseconds(100))
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func timeoutDoesNotWaitForInheritedOutputPipe() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CodexProcessError.timedOut) {
            _ = try await self.shell("(sleep 30)& trap '' TERM; wait", timeout: .milliseconds(100))
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func timeoutBoundsAlreadyExitedParentWithInheritedPipe() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CodexProcessError.timedOut) {
            _ = try await self.shell("(sleep 5)& exit 0", timeout: .milliseconds(100))
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test func timeoutStopsBlockedInputWriterHeldByDescendant() async throws {
        let input = Data(repeating: 65, count: 4 * 1024 * 1024)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CodexProcessError.timedOut) {
            _ = try await self.shell("(sleep 5)& exit 0", input: input, timeout: .milliseconds(100), maxOutputBytes: 1000)
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test func cancellationReapsProcess() async throws {
        let task = Task { try await self.shell("trap '' TERM; exec sleep 30", timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CodexProcessError.cancelled) { _ = try await task.value }
    }

    @Test func outputLimitTerminatesAndReportsError() async throws {
        await #expect(throws: CodexProcessError.outputLimit) {
            _ = try await self.shell("exec yes x", timeout: .seconds(5), maxOutputBytes: 4 * 1024)
        }
    }

    @Test func missingExecutableReportsLaunchFailure() async throws {
        await #expect(throws: CodexProcessError.launchFailed) {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/definitely/missing/codex"), arguments: [], timeout: .seconds(1), maxOutputBytes: 1024)
        }
    }

    @Test func cancellationBeforeStartIsObserved() async throws {
        let task = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], timeout: .seconds(1), maxOutputBytes: 1024) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private func shell(_ command: String, input: Data? = nil, timeout: Duration = .seconds(2), maxOutputBytes: Int = 2 * 1024 * 1024) async throws -> CodexProcessResult {
        try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], input: input, timeout: timeout, maxOutputBytes: maxOutputBytes)
    }
}
