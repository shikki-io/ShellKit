import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Process exit, as the kernel sees it

extension Process {
    /// The child's exit status according to the kernel, even when Foundation
    /// has not noticed the exit yet. Always nil on Darwin.
    ///
    /// swift-corelibs-foundation (Linux) learns that a child exited through a
    /// descriptor the child inherits, so a grandchild that outlives its parent
    /// and keeps that descriptor (a backgrounded helper, a credential daemon)
    /// postpones `isRunning == false` and `terminationHandler` until the
    /// grandchild is gone too. Darwin has no such coupling.
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

    /// `!isRunning`, plus the Linux case above. Identical to `!isRunning` on Darwin.
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
    /// Darwin: `waitUntilExit()`. Linux: polls the kernel as well, because
    /// `waitUntilExit()` inherits the Foundation lag described above.
    func waitForExit() -> Int32 {
        #if canImport(Glibc)
        while true {
            if !isRunning { return terminationStatus }
            if let status = kernelReportedExitStatus {
                // Exited but not yet reaped. Foundation normally reaps within
                // milliseconds; give it that long so "exited" also means
                // "reaped", but never wait on a descendant-delayed reap.
                let patience = Date().addingTimeInterval(0.5)
                while isRunning, Date() < patience { usleep(5_000) }
                return isRunning ? status : terminationStatus
            }
            usleep(10_000)
        }
        #else
        waitUntilExit()
        return terminationStatus
        #endif
    }
}
