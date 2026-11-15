import Foundation
import Testing
@testable import ShellKit

/// Operator decision D4, 2026-11-15 (@db row `36e6b2b7`): "Windows stop = best
/// effort, reported honestly… The result type says 'hard-terminated' versus
/// 'graceful', and never labels a hard kill graceful."
///
/// These tests exercise the half of D4 that is load-bearing. The behaviour —
/// SIGTERM then SIGKILL — was already right on POSIX; what was missing is that
/// the caller could not tell which had happened, so a child killed outright read
/// exactly like one that flushed its state and exited.
///
/// Every assertion here runs on macOS, glibc Linux and the static musl triple.
/// The Windows arm cannot be exercised yet (no Windows target is built), and
/// `ProcessStopTests` does not pretend otherwise: what IS tested is that the
/// Windows path cannot report `.graceful`, which is checked at the source level
/// because a test cannot run there.
@Suite("Process stop reports what actually happened (D4)")
struct ProcessStopOutcomeTests {

    /// A child that exits the moment it is asked. The graceful request is
    /// delivered, it exits inside the grace period, so the outcome is
    /// `.graceful` — and crucially NOT `.hardTerminated`, which is what the old
    /// `Void`-returning API left the caller to guess.
    @Test("a child that honours SIGTERM reports .graceful")
    func honouringChildIsGraceful() async throws {
        let proc = try InteractiveProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "while :; do sleep 0.2; done"]
        )
        try await Task.sleep(for: .milliseconds(200))
        #expect(proc.isRunning)

        let outcome = proc.terminate()
        #expect(outcome == .graceful, "a default `sh` dies on SIGTERM; got \(outcome)")
        #expect(outcome.wasHardKilled == false)
        #expect(!proc.isRunning)
    }

    /// The case the result type exists for: the child ignores SIGTERM, the grace
    /// period expires, SIGKILL ends it — and the outcome says so. Reporting
    /// `.graceful` here would be the exact fabrication D4 forbids, because the
    /// child's cleanup provably did not run.
    @Test("a child that ignores SIGTERM reports .hardTerminated, never .graceful")
    func ignoringChildIsHardTerminated() async throws {
        let proc = try InteractiveProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", #"trap "" TERM; while :; do sleep 0.2; done"#]
        )
        // Let the trap install, or we race the shell's startup and the child
        // dies on SIGTERM — passing for the wrong reason.
        try await Task.sleep(for: .milliseconds(300))
        #expect(proc.isRunning, "child exited before the test could signal it")

        let outcome = proc.terminate()
        #expect(outcome == .hardTerminated, "SIGTERM was ignored, so this was a kill; got \(outcome)")
        #expect(outcome.wasHardKilled)
        #expect(!proc.isRunning, "child survived terminate()")
    }

    /// A second `terminate()` reports the truth about the CHILD, not a replay of
    /// the first call. It is already gone, so `.alreadyExited`.
    @Test("terminate() is idempotent and the repeat reports .alreadyExited")
    func repeatTerminateReportsAlreadyExited() async throws {
        let proc = try InteractiveProcess(executablePath: "/bin/sh", arguments: ["-c", "while :; do sleep 0.2; done"])
        try await Task.sleep(for: .milliseconds(200))
        _ = proc.terminate()
        #expect(proc.terminate() == .alreadyExited)
    }

    /// `DetachedProcess` is the second of the three subprocess shapes and must
    /// answer the same question the same way — the drift this type prevents is
    /// three hand-rolled SIGTERM/SIGKILL ladders disagreeing, which is how one
    /// of them ended up with its escalation inside `#if canImport(Darwin)`.
    @Test("DetachedProcess reports the same outcomes through the same seam")
    func detachedProcessReportsOutcomes() async throws {
        let honouring = try DetachedProcess(["/bin/sh", "-c", "sleep 30"])
        #expect(honouring.terminate() == .graceful)
        #expect(honouring.terminate() == .alreadyExited)

        let ignoring = try DetachedProcess(["/bin/sh", "-c", #"trap "" TERM; sleep 30"#])
        try await Task.sleep(for: .milliseconds(300))
        let outcome = ignoring.terminate()
        #expect(outcome == .hardTerminated, "got \(outcome)")
        #expect(!ignoring.isRunning)
    }

    /// A child already dead before we ask gets no signal and no claim of
    /// success: `.alreadyExited` is distinct from `.graceful` on purpose, so
    /// "nothing to do" is never counted as "asked nicely and it complied".
    @Test("an already-exited child reports .alreadyExited, not .graceful")
    func alreadyExitedIsItsOwnAnswer() async throws {
        let proc = try DetachedProcess(["/bin/sh", "-c", "exit 0"])
        _ = await proc.exitCode()
        #expect(proc.terminate() == .alreadyExited)
    }

    // MARK: - The Windows arm, checked at the source level because it cannot run

    /// D4's rule is that a hard kill is never labelled graceful. On POSIX the
    /// tests above prove it by running. On Windows nothing can run yet, so this
    /// pins the two properties that make the rule hold there:
    ///
    /// 1. the Windows arm of `requestGracefulStop` must not call
    ///    `process.terminate()` — on Windows that IS `TerminateProcess`, a hard
    ///    kill, and calling it at the graceful step would make every Windows
    ///    stop report `.graceful`;
    /// 2. `stopProcess` must return `.hardTerminated` whenever no graceful
    ///    request was delivered, which is the state Windows is in today because
    ///    Foundation never spawns into a new process group.
    @Test("the Windows graceful arm cannot report a hard kill as graceful")
    func windowsArmNeverClaimsGraceful() throws {
        let source = try String(
            contentsOf: Self.platformRoot().appending(path: "ProcessStop.swift"),
            encoding: .utf8
        )

        // The arm runs from `#elseif os(Windows)` to the next directive that
        // closes it. Slicing on the next "#" was the first attempt and it
        // returned an empty string, because the arm's own comment mentions
        // `CREATE_NEW_PROCESS_GROUP` after a `#`-free prefix of only whitespace —
        // so the scan ended before any code. Bound it on `#else` instead, which
        // is the directive that actually ends this arm.
        guard let armStart = source.range(of: "#elseif os(Windows)") else {
            Issue.record("the Windows arm of requestGracefulStop has gone — D4 expects it extended, not removed")
            return
        }
        let afterArmStart = source[armStart.upperBound...]
        guard let armEnd = afterArmStart.range(of: "#else") else {
            Issue.record("could not find the end of the Windows arm")
            return
        }
        let arm = String(afterArmStart[..<armEnd.lowerBound])
        #expect(arm.count > 200, "the Windows arm scanned as \(arm.count) chars — slicing drift, not a real arm")

        #expect(
            !arm.contains("process.terminate()"),
            """
            the Windows graceful arm calls process.terminate(), which on Windows \
            is TerminateProcess — a hard kill. Reporting .graceful after it is \
            the fabrication D4 forbids.
            """
        )
        #expect(
            arm.contains("GenerateConsoleCtrlEvent") || arm.contains("CTRL_BREAK"),
            "D4 asks for a CTRL_BREAK attempt when the child is a console process in its own group"
        )
        #expect(
            arm.contains("childIsInItsOwnProcessGroup"),
            "CTRL_BREAK addresses a process GROUP; without the precondition it would signal us too"
        )
        // The honest-reporting invariant, stated once in the implementation:
        // no graceful request delivered => .hardTerminated.
        #expect(source.contains("return .hardTerminated"))
        #expect(
            !source.contains("return .graceful\n    }\n    process.forceKill()"),
            "a .graceful return must be reachable only after a delivered graceful request"
        )
    }

    private static func platformRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) {
                return dir.appending(path: "Sources/ShellKit/Platform", directoryHint: .isDirectory)
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("no Package.swift above \(#filePath)")
    }
}
