import Foundation
import Testing
@testable import ShellKit

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Spec c8fa126c W5, second pass — the two Linux hangs the @t panel found
/// (run 308f3d72) in the code W5's first pass had already "fixed".
///
/// Both were `#if canImport(Darwin)` wrapped around a *portable* call, so on
/// Linux the arm was empty. Neither a macOS test run nor a musl cross build can
/// see that: the tests take the Darwin arm, and the cross build compiles the
/// empty one. These tests fail on Linux before the fix and pass on both after,
/// which is the only shape of evidence that distinguishes the two.
///
/// Why these assertions and not a timing race. The obvious pipe test — spawn a
/// short-lived child beside a long-lived one and time the short one — depends on
/// the two spawns overlapping, so it passes or fails with machine load. Two
/// separate suites in this fleet were caught doing exactly that today
/// (`ShellKitDetached` and shi-secrets' `ShiSecretsBrokerProcessE2E`, both
/// green at one commit and hung at another with no code change between). So
/// these assert the mechanism on the real file descriptors instead: a
/// deterministic question with the same answer under any load.
@Suite("Linux hang regressions — guarded portable calls")
struct LinuxHangRegressionTests {

    // MARK: - Hang 1: the SIGKILL escalation was Darwin-only

    /// `InteractiveProcess.terminate()` promises, in its own doc comment,
    /// "Close stdin, SIGTERM, wait terminationGrace, SIGKILL if still alive, and
    /// reap." Until 2026-11-15 the SIGKILL step was inside
    /// `#if canImport(Darwin)`, so on Linux a child that ignores SIGTERM was
    /// never killed — and the `process.waitUntilExit()` on the next line blocked
    /// forever, with no timeout above it.
    ///
    /// `trap "" TERM` makes the child ignore SIGTERM, which is what a shell, an
    /// editor or a language server does while it has unsaved state. So this is
    /// not a contrived child.
    @Test("a child that ignores SIGTERM is still killed, and terminate() returns")
    func sigtermIgnoringChildIsStillKilled() async throws {
        let proc = try InteractiveProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", #"trap "" TERM; while :; do sleep 0.2; done"#]
        )
        // The initialiser spawns; there is no separate launch step.
        // Let the trap install before signalling, or we race the shell's startup
        // and may SIGTERM a process that has not yet ignored it — which would
        // pass for the wrong reason.
        try await Task.sleep(for: .milliseconds(300))
        #expect(proc.isRunning, "child exited before the test could signal it")

        // terminate() is synchronous and, before the fix, unbounded. Run it off
        // the test task and race a deadline so a regression is a FAILURE with a
        // message, never a suite that stops reporting. That distinction is the
        // whole lesson of backlog 55a120b1.
        let returned = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await Task.detached { proc.terminate() }.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(
            returned,
            """
            terminate() did not return within 20 s. The SIGKILL escalation is \
            missing on this platform, so waitUntilExit() is blocked on a child \
            that ignores SIGTERM. terminationGrace is \
            \(InteractiveProcess.terminationGrace) s.
            """
        )
        #expect(!proc.isRunning, "child survived terminate()")
    }

    /// The seam itself, independent of any child: `hardKill` must reach libc on
    /// whatever platform this is. Signal 0 is the POSIX existence probe — it
    /// delivers nothing — so `posixKill(ourPid, 0)` is safe, and a pid that
    /// cannot exist must report failure rather than trap.
    @Test("the escalation seam reaches libc on this platform")
    func escalationSeamIsWired() {
        #expect(posixKill(ProcessInfo.processInfo.processIdentifier, 0) == 0)
        #expect(posixKill(pid_t.max, 0) == -1)
    }

    // MARK: - Hang 2: FD_CLOEXEC was Darwin-only

    /// The cascade this prevents is documented in `TimedShellExecutor` as the
    /// root cause that defeated five consecutive PRs (#585 → #596 → #657 → #714
    /// → #719): without close-on-exec, child N+1 inherits the write end of child
    /// N's pipe, so `readDataToEndOfFile()` on pipe N waits for an unrelated
    /// process to exit.
    ///
    /// corelibs-foundation's `Pipe` does not set `O_CLOEXEC` either, so Linux
    /// needed this at least as much as Darwin — and until 2026-11-15 it was the
    /// one platform that did not get it.
    @Test("setCloseOnExec actually sets FD_CLOEXEC on a real descriptor")
    func closeOnExecIsSetOnARealDescriptor() throws {
        let pipe = Pipe()
        let fd = pipe.fileHandleForWriting.fileDescriptor

        let before = fcntl(fd, F_GETFD)
        try #require(before != -1, "F_GETFD failed on a fresh Pipe descriptor")
        #expect(
            before & FD_CLOEXEC == 0,
            "Foundation's Pipe already set FD_CLOEXEC — this platform changed and the shim's reason needs re-reading"
        )

        #expect(setCloseOnExec(fd), "fcntl(F_SETFD) reported failure")

        let after = fcntl(fd, F_GETFD)
        try #require(after != -1)
        #expect(after & FD_CLOEXEC != 0, "FD_CLOEXEC is not set — children will inherit this write end")

        try? pipe.fileHandleForWriting.close()
        try? pipe.fileHandleForReading.close()
    }

    /// The integration half: every pipe end an `InteractiveProcess` creates must
    /// carry the flag. This is the assertion that fails on Linux before the fix,
    /// because the loop that sets it was inside `#if canImport(Darwin)`.
    ///
    /// It reads the live descriptors of a launched process rather than
    /// re-implementing the setup, so it cannot pass while the product skips the
    /// call — the mistake of testing a helper and shipping an unused one.
    @Test("every pipe end of a launched InteractiveProcess is close-on-exec")
    func launchedProcessPipeEndsAreCloseOnExec() async throws {
        let proc = try InteractiveProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "while :; do sleep 0.2; done"]
        )
        defer { proc.terminate() }

        var leaked: [String] = []
        for (name, fd) in proc.pipeDescriptors {
            let flags = fcntl(fd, F_GETFD)
            try #require(flags != -1, "F_GETFD failed for \(name) (fd \(fd))")
            if flags & FD_CLOEXEC == 0 { leaked.append("\(name) (fd \(fd))") }
        }

        #expect(
            leaked.isEmpty,
            """
            pipe ends without FD_CLOEXEC: \(leaked). The next child spawned by \
            this process inherits them, and a reader on this process's pipe will \
            then wait for that unrelated child to exit — the #585…#719 cascade.
            """
        )
    }
}
