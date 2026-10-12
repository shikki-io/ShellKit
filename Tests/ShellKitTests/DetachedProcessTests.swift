import XCTest
@testable import ShellKit

// MARK: - DetachedProcessTests
//
// Scope: ShellKitTests
// The fire-and-forget primitive. Each test is a failure mode of the raw
// `Process()` dispatchers this type replaces (shikki#1789: three of them,
// each behind a process-bypass exemption).

final class DetachedProcessTests: XCTestCase {

    private func scratch(_ name: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ShellKit-DetachedProcessTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    // MARK: - 1. The pid is available, which is the whole point

    func testPidIsAvailableAndChildRuns() async throws {
        let child = try DetachedProcess(["/bin/sh", "-c", "sleep 2"])
        XCTAssertGreaterThan(child.processIdentifier, 0, "a tracker cannot reap what it cannot name")
        XCTAssertTrue(child.isRunning)
        child.terminate()
    }

    // MARK: - 2. A chatty child does not block: no pipe, no 64 KiB wall

    func testChattyChildCompletesWithDiscardedOutput() async throws {
        // 400 KiB of stdout — six times the pipe buffer. A piped primitive
        // that nobody drains deadlocks here; this one must exit cleanly.
        let child = try DetachedProcess(["/bin/sh", "-c", "yes shikki | head -50000"])
        let code = await child.exitCode()
        XCTAssertEqual(code, 0)
    }

    // MARK: - 3. Output to a file is appended, both streams, in order

    func testOutputGoesToTheFileAndAppends() async throws {
        let log = scratch("dispatch.log")
        let first = try DetachedProcess(
            ["/bin/sh", "-c", "echo out; echo err 1>&2"], output: .file(log))
        let firstCode = await first.exitCode()
        XCTAssertEqual(firstCode, 0)
        let second = try DetachedProcess(["/bin/sh", "-c", "echo again"], output: .file(log))
        let secondCode = await second.exitCode()
        XCTAssertEqual(secondCode, 0)

        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("out"), text)
        XCTAssertTrue(text.contains("err"), "stderr must land too, or a failure is invisible")
        XCTAssertTrue(text.contains("again"), "the second launch appends, never truncates")
    }

    // MARK: - 4. The exit code survives, so a dispatcher can report honestly

    func testExitCodeIsReported() async throws {
        let child = try DetachedProcess(["/bin/sh", "-c", "exit 42"])
        let code = await child.exitCode()
        XCTAssertEqual(code, 42)
    }

    // MARK: - 5. No shell: an argument is never re-parsed

    func testArgumentsAreNotReparsedByAShell() async throws {
        // Through `sh -c` this would substitute a command. As argv it is text.
        let log = scratch("argv.log")
        let child = try DetachedProcess(
            ["/bin/echo", "$(touch /tmp/shellkit-should-not-exist)"], output: .file(log))
        let code = await child.exitCode()
        XCTAssertEqual(code, 0)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("$(touch"), "argv must reach the child verbatim: \(text)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/shellkit-should-not-exist"))
    }

    // MARK: - 6. A bare name resolves through PATH; an unknown one fails loudly

    func testBareNameResolvesAndUnknownThrows() async throws {
        let child = try DetachedProcess(["true"])
        let code = await child.exitCode()
        XCTAssertEqual(code, 0)

        XCTAssertThrowsError(try DetachedProcess(["definitely-not-a-binary-\(UUID().uuidString)"])) { error in
            guard case ShellError.launchFailed(_, let underlying) = error else {
                return XCTFail("expected .launchFailed, got \(error)")
            }
            XCTAssertTrue(underlying.contains("not found on PATH"), underlying)
        }
    }

    // MARK: - 7. terminate() stops the child and is idempotent

    func testTerminateStopsTheChildAndIsIdempotent() async throws {
        let child = try DetachedProcess(["/bin/sh", "-c", "sleep 30"])
        child.terminate()
        XCTAssertFalse(child.isRunning, "SIGTERM then SIGKILL — no survivor")
        child.terminate()  // must not trap, must not hang
    }

    // MARK: - 8. An empty argv is refused, not spawned

    func testEmptyArgvIsRefused() {
        XCTAssertThrowsError(try DetachedProcess([])) { error in
            guard case ShellError.launchFailed(_, let underlying) = error else {
                return XCTFail("expected .launchFailed, got \(error)")
            }
            XCTAssertEqual(underlying, "empty argv")
        }
    }
}
