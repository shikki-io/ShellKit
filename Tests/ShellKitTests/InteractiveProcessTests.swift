import XCTest
@testable import ShellKit

// MARK: - InteractiveProcessTests
//
// Scope: ShellKitTests
// The line-by-line primitive behind JSON-RPC-over-stdio exchanges. Each
// test is one of the failure modes a hand-rolled version had in
// shikki-chat-mcp's StdioChildMCPToolCaller before this type existed.

final class InteractiveProcessTests: XCTestCase {

    // MARK: - 1. An interleaved exchange: send, read the answer, send again

    func testEchoExchangeInterleaves() throws {
        let child = try InteractiveProcess(executablePath: "/bin/cat")
        defer { child.terminate() }

        try child.sendLine("first")
        XCTAssertEqual(child.readLineString(deadline: Date().addingTimeInterval(5)), "first")
        try child.sendLine("second")
        XCTAssertEqual(child.readLineString(deadline: Date().addingTimeInterval(5)), "second")
    }

    // MARK: - 2. A deadline, not a bare blocking read

    func testReadLineReturnsNilAtDeadlineWhenChildIsSilent() throws {
        let child = try InteractiveProcess(executablePath: "/bin/sleep", arguments: ["30"])
        defer { child.terminate() }

        let start = Date()
        let line = child.readLineString(deadline: Date().addingTimeInterval(1))
        XCTAssertNil(line)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "the read must return at the deadline, not when the child exits")
    }

    // MARK: - 3. EOF is nil, not a hang

    func testReadLineReturnsNilOnEOF() throws {
        let child = try InteractiveProcess(executablePath: "/bin/sh", arguments: ["-c", "echo only; exit 0"])
        defer { child.terminate() }

        XCTAssertEqual(child.readLineString(deadline: Date().addingTimeInterval(5)), "only")
        XCTAssertNil(child.readLineString(deadline: Date().addingTimeInterval(5)))
    }

    // MARK: - 4. stderr is captured, bounded, and does not block stdout

    func testStderrIsDrainedConcurrently() throws {
        // 200 KiB on stderr — three times the pipe buffer — then one stdout line.
        let child = try InteractiveProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "head -c 204800 /dev/zero | tr '\\0' 'e' >&2; echo done"]
        )
        defer { child.terminate() }

        XCTAssertEqual(child.readLineString(deadline: Date().addingTimeInterval(10)), "done")
        XCTAssertLessThanOrEqual(child.stderrText.utf8.count, InteractiveProcess.stderrCapacity)
        XCTAssertTrue(child.stderrText.hasPrefix("eeee"))
    }

    // MARK: - 5. Teardown kills a child that ignores SIGTERM, and reaps it

    func testTerminateEscalatesToSigkillAndReaps() throws {
        let child = try InteractiveProcess(executablePath: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 60"])
        let pid = child.processIdentifier
        XCTAssertTrue(child.isRunning)

        let start = Date()
        child.terminate()
        XCTAssertFalse(child.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), InteractiveProcess.terminationGrace + 2)
        // Reaped: kill(pid, 0) on a reaped pid fails with ESRCH.
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        // Idempotent.
        child.terminate()
    }

    // MARK: - 6. A missing executable is a launch failure, not a crash

    func testLaunchFailureThrows() {
        XCTAssertThrowsError(try InteractiveProcess(executablePath: "/nonexistent/binary")) { error in
            guard case ShellError.launchFailed = error else {
                return XCTFail("expected launchFailed, got \(error)")
            }
        }
    }

    // MARK: - 7. The PATH probe lives here now

    func testExecutableResolverFindsShAndRejectsNonsense() {
        XCTAssertEqual(ExecutableResolver.resolve("sh", searchPath: "/nonexistent:/bin"), "/bin/sh")
        XCTAssertEqual(ExecutableResolver.resolve("/bin/sh"), "/bin/sh")
        XCTAssertNil(ExecutableResolver.resolve("definitely-not-a-binary-2026", searchPath: "/bin:/usr/bin"))
        XCTAssertNil(ExecutableResolver.resolve("/nonexistent/binary"))
    }
}
