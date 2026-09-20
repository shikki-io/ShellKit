import Foundation
import Testing

@testable import ShellKit

/// `runStreaming` exists because `run` buffers until exit, which forced every
/// caller needing live output onto a raw `Process` — losing the timeout, the
/// SIGTERM/SIGKILL escalation, the concurrency cap and the pipe-deadlock
/// fixes. kagami's `GoScopeRunner` names this API in a source comment as the
/// missing primitive.
///
/// These tests pin the property that makes it worth having: chunks arrive
/// BEFORE the process exits. A streaming API that delivers everything at the
/// end is `run` with extra steps.
@Suite("TimedShellExecutor.runStreaming")
struct RunStreamingTests {

    /// THE POINT. Three lines, a beat apart. If the first chunk only lands
    /// after exit, this is not streaming.
    @Test("stdout chunks arrive before the process exits")
    func chunksArriveDuringTheRun() async throws {
        let firstChunkAt = Mutex<Date?>(nil)
        let exec = TimedShellExecutor()

        let result = try await exec.runStreaming(
            ["sh", "-c", "echo one; sleep 0.4; echo two"],
            timeout: 10,
            onStdout: { _ in firstChunkAt.withLock { if $0 == nil { $0 = Date() } } }
        )
        let finishedAt = Date()

        let first = try #require(firstChunkAt.withLock { $0 })
        #expect(result.exitCode == 0)
        #expect(
            finishedAt.timeIntervalSince(first) > 0.2,
            "the first chunk must land well before exit — otherwise this is buffering, not streaming"
        )
    }

    /// Streaming must not cost the caller the buffer; `GoScopeRunner` needs
    /// BOTH (live re-emit AND counts parsed from the whole output).
    @Test("the full output is still returned alongside the live chunks")
    func bufferIsStillReturned() async throws {
        let streamed = Mutex(Data())
        let exec = TimedShellExecutor()

        let result = try await exec.runStreaming(
            ["sh", "-c", "printf 'alpha\\nbeta\\n'"],
            timeout: 10,
            onStdout: { chunk in streamed.withLock { $0.append(chunk) } }
        )

        #expect(result.stdoutString.contains("alpha"))
        #expect(result.stdoutString.contains("beta"))
        let live = String(data: streamed.withLock { $0 }, encoding: .utf8) ?? ""
        #expect(live.contains("alpha") && live.contains("beta"), "the sink saw the same bytes")
    }

    @Test("stderr streams independently of stdout")
    func stderrStreamsToo() async throws {
        let err = Mutex(Data())
        let exec = TimedShellExecutor()

        let result = try await exec.runStreaming(
            ["sh", "-c", "printf 'oops\\n' 1>&2"],
            timeout: 10,
            onStderr: { chunk in err.withLock { $0.append(chunk) } }
        )

        #expect(result.stderrString.contains("oops"))
        #expect((String(data: err.withLock { $0 }, encoding: .utf8) ?? "").contains("oops"))
    }

    /// The whole reason to be in ShellKit rather than a raw `Process`: the
    /// timeout still applies. A streaming call that could hang forever would
    /// be strictly worse than what it replaces.
    @Test("the timeout still kills a streaming process")
    func timeoutStillApplies() async throws {
        let exec = TimedShellExecutor()
        await #expect(throws: ShellError.self) {
            _ = try await exec.runStreaming(["sh", "-c", "sleep 30"], timeout: 0.5)
        }
    }

    @Test("no sinks behaves exactly like run")
    func sinklessIsPlainRun() async throws {
        let exec = TimedShellExecutor()
        let result = try await exec.runStreaming(["sh", "-c", "echo plain"], timeout: 10)
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "plain")
    }
}

/// Minimal lock box — the sinks fire on a dispatch source thread.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
