import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

// MARK: - Process exit, as the kernel sees it

extension Process {
    /// The child's exit status according to the kernel, even when Foundation
    /// has not noticed the exit yet. Always nil on Darwin and on Windows.
    ///
    /// swift-corelibs-foundation (Linux) learns that a child exited through a
    /// descriptor the child inherits, so a grandchild that outlives its parent
    /// and keeps that descriptor (a backgrounded helper, a credential daemon)
    /// postpones `isRunning == false` and `terminationHandler` until the
    /// grandchild is gone too. Darwin has no such coupling, and neither does
    /// Windows: there, Foundation waits on the child's process HANDLE, which
    /// the kernel signals when that one process exits, whatever its
    /// descendants hold open.
    ///
    /// The probe is `waitid(WNOWAIT)`: it observes the zombie without reaping
    /// it, so Foundation still reaps and reports it whenever it gets there.
    var kernelReportedExitStatus: Int32? {
        #if canImport(Glibc)
        guard isRunning else { return nil }  // Foundation already reaped it; the pid may be reused
        var info = siginfo_t()
        guard waitid(P_PID, id_t(processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT) == 0,
              info._sifields._sigchld.si_pid != 0
        else { return nil }
        return info._sifields._sigchld.si_status
        #else
        return nil
        #endif
    }

    /// `!isRunning`, plus the Linux case above. Identical to `!isRunning` on
    /// Darwin and on Windows.
    var hasExited: Bool {
        !isRunning || kernelReportedExitStatus != nil
    }

    /// The exit status once the child has exited, nil while it runs.
    /// Only call on a launched process.
    var exitStatusIfExited: Int32? {
        if !isRunning { return terminationStatus }
        return kernelReportedExitStatus
    }

    /// Block until the child has exited and return its status.
    /// Darwin and Windows: `waitUntilExit()`. Linux: polls the kernel as well,
    /// because `waitUntilExit()` inherits the Foundation lag described above.
    func waitForExit() -> Int32 {
        #if canImport(Glibc)
        while true {
            if !isRunning { return terminationStatus }
            if let status = kernelReportedExitStatus {
                // Exited but not yet reaped. Foundation normally reaps within
                // milliseconds; give it that long so "exited" also means
                // "reaped", but never wait on a descendant-delayed reap.
                let patience = Date().addingTimeInterval(0.5)
                while isRunning, Date() < patience { Thread.sleep(forTimeInterval: 0.005) }
                return isRunning ? status : terminationStatus
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        #else
        waitUntilExit()
        return terminationStatus
        #endif
    }

    // MARK: - Forced termination

    /// Kill the child immediately, with no chance for it to decline.
    ///
    /// This is the escalation step every teardown in this package ends with,
    /// named once here because the platforms spell it differently:
    ///
    /// - POSIX: `SIGKILL`, which cannot be caught, blocked or ignored.
    ///   `Process.terminate()` is `SIGTERM`, which can be all three.
    /// - Windows: `TerminateProcess`. There are no signals at all, so
    ///   `Process.terminate()` on Windows *already is* `TerminateProcess` —
    ///   the graceful step does not exist and this call is the same kernel
    ///   operation reached a second time. Calling it after the grace period
    ///   is therefore harmless, not redundant: the child may have exited on
    ///   its own in between, and an exited child is skipped by the callers.
    ///
    /// Known gap on Windows, deliberately not papered over: this kills the
    /// child, not its tree. Killing a tree there means assigning the child to
    /// a Job Object when it is created, and Foundation's `Process` owns the
    /// spawn and exposes no hook to do that — so a grandchild survives.
    /// On POSIX the same is true of a grandchild in its own process group.
    /// Tracked as backlog afb8cd83.
    func forceKill() {
        #if canImport(Darwin) || canImport(Glibc)
        kill(processIdentifier, SIGKILL)
        #elseif os(Windows)
        // STATUS: compiles by inspection, unproven on Windows (backlog afb8cd83)
        //
        // `Process.processIdentifier` is the pid; the HANDLE Foundation holds
        // is private, so the pid is re-opened for the one right we need.
        guard let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(processIdentifier)) else {
            return  // already gone, or not ours to kill
        }
        defer { _ = CloseHandle(handle) }
        // Exit code 1: an exit status the caller reads as "killed", matching
        // what a SIGKILLed child reports through Foundation on POSIX.
        _ = TerminateProcess(handle, UINT(1))
        #else
        terminate()
        #endif
    }
}
