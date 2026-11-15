//
//  ProcessStop.swift
//  ShellKit
//
//  Operator decision D4, 2026-11-15 (@db row 36e6b2b7): "Windows stop = best
//  effort, reported honestly."
//
//      1. Same API on every OS.
//      2. Windows: CTRL_BREAK when the child is a console process in its own
//         process group; otherwise TerminateProcess. Nothing is faked.
//      3. The RESULT TYPE carries the truth: it distinguishes hard-terminated
//         from graceful and NEVER labels a hard kill graceful. This is the
//         load-bearing half — the contract is honest reporting, not uniform
//         behaviour.
//      4. macOS/Linux: graceful is Foundation.Process.terminate() (SIGTERM),
//         then SIGKILL after the deadline.
//
//  Why the type ships now, before any Windows target exists: the type IS the
//  contract. Every call site written against a `Bool` "it stopped" would have to
//  be revisited later, and in the meantime the POSIX paths were free to report a
//  hard kill as a clean stop — the exact fabrication D4 exists to prevent, and
//  the same shape as [[a-try-with-a-literal-fallback-fabricates-a-verdict]].
//

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(WinSDK)
    import WinSDK
#endif

/// What actually happened to a child when we asked it to stop.
///
/// There is deliberately no `case stopped`. A caller that needs to know whether
/// the child got to run its cleanup — flush a file, release a lock, write a
/// partial result — must be able to ask, and must not be able to read a kill as
/// a clean exit by accident.
public enum ProcessStopOutcome: String, Sendable, Equatable, CustomStringConvertible {
    /// Nothing was sent: the child had already exited when we looked.
    case alreadyExited

    /// A graceful request was delivered AND the child exited within the grace
    /// period. Only ever returned when the platform actually has a graceful
    /// mechanism and it was used.
    case graceful

    /// The child was killed outright. Either the grace period expired, or this
    /// platform has no graceful request to deliver in the first place. Its
    /// cleanup did not run.
    case hardTerminated

    public var description: String { rawValue }

    /// True when the child was denied its cleanup. The property exists so a
    /// caller can branch on the thing that matters without matching cases, and
    /// so no one is tempted to write `outcome != .graceful` and catch
    /// `.alreadyExited` by mistake.
    public var wasHardKilled: Bool { self == .hardTerminated }
}

/// Deliver this platform's "please exit" request.
///
/// - Returns: `true` when a genuinely graceful request was delivered, so the
///   caller may report `.graceful` if the child then exits. `false` means the
///   platform had nothing polite to send and the caller must NOT report
///   `.graceful` no matter what the child does next.
@discardableResult
func requestGracefulStop(_ process: Process) -> Bool {
    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        // SIGTERM. Catchable and ignorable, which is exactly what makes it
        // graceful — and exactly why the escalation below has to exist.
        process.terminate()
        return true
    #elseif os(Windows)
        // STATUS: compiles by inspection, unproven — no Windows target is built
        // yet (backlog afb8cd83, and #19 ships its own branches the same way).
        //
        // `Process.terminate()` is NOT the graceful step here: on Windows it is
        // already TerminateProcess, a hard kill. Calling it and reporting
        // `.graceful` is the precise lie D4 forbids, so this arm does not call
        // it at all.
        //
        // CTRL_BREAK only reaches a child in its OWN process group. Foundation's
        // `Process` does not pass CREATE_NEW_PROCESS_GROUP and exposes no hook
        // to, so `childIsInItsOwnProcessGroup` is false today and this returns
        // false — meaning "no graceful mechanism available", which is the honest
        // answer rather than a signal fired at our own group. Sending
        // CTRL_BREAK to group 0 would signal THIS process too.
        //
        // When the spawn gains CREATE_NEW_PROCESS_GROUP, this path starts
        // working with no change at any call site. That is the point of putting
        // it here.
        guard childIsInItsOwnProcessGroup(process) else { return false }
        return GenerateConsoleCtrlEvent(DWORD(CTRL_BREAK_EVENT), DWORD(process.processIdentifier))
    #else
        return false
    #endif
}

#if os(Windows)
    /// Whether `process` can receive a console control event without us hitting
    /// ourselves.
    ///
    /// Always false while Foundation owns the spawn: a child inherits our
    /// process group unless created with `CREATE_NEW_PROCESS_GROUP`, and
    /// `GenerateConsoleCtrlEvent` addresses a GROUP, not a pid. Written as a
    /// named predicate rather than an inline `false` so the precondition is
    /// stated where it is needed and has one place to change.
    func childIsInItsOwnProcessGroup(_ process: Process) -> Bool {
        false
    }
#endif

/// Stop a child and report what actually happened: graceful request, grace
/// period, escalation if needed.
///
/// One implementation for all three subprocess shapes in this package
/// (`TimedShellExecutor`, `InteractiveProcess`, `DetachedProcess`), so the three
/// cannot drift on what "stopped" means — which is how
/// `InteractiveProcess.swift:212` came to wrap its escalation in
/// `#if canImport(Darwin)` while its sibling did not.
///
/// - Parameters:
///   - process: the child.
///   - grace: how long to let it exit on its own after the graceful request.
///   - poll: how often to re-check. Small enough to return promptly, large
///     enough not to spin.
func stopProcess(_ process: Process, grace: TimeInterval, poll: TimeInterval = 0.05) -> ProcessStopOutcome {
    guard !process.hasExited else { return .alreadyExited }

    let askedPolitely = requestGracefulStop(process)

    if askedPolitely {
        let deadline = Date().addingTimeInterval(grace)
        while !process.hasExited, Date() < deadline {
            Thread.sleep(forTimeInterval: poll)
        }
        if process.hasExited { return .graceful }
    }

    // Either the grace period expired, or this platform had nothing graceful to
    // send. Both end the same way, and both report `.hardTerminated` — a
    // platform without a polite option does not get to call the result polite.
    process.forceKill()
    // Wait for the kill to become observable before returning. SIGKILL is
    // immediate but REAPING is not, and `isRunning` reports an unreaped zombie
    // as running — so a caller that checks `isRunning` right after this returns
    // would race, and on Linux would lose (corelibs-foundation reports a zombie
    // as running until it reaps). Returning `.hardTerminated` while the child
    // still looks alive makes the outcome unfalsifiable, which is the one thing
    // this type exists to prevent.
    awaitExitObservable(process, poll: poll)
    return .hardTerminated
}

/// How long to wait for a SIGKILLed child to become observably gone: generous
/// enough for a loaded machine, bounded so this can never itself be the hang.
let killConfirmationWindow: TimeInterval = 2.0

private func awaitExitObservable(_ process: Process, poll: TimeInterval) {
    let deadline = Date().addingTimeInterval(killConfirmationWindow)
    while !process.hasExited, Date() < deadline {
        Thread.sleep(forTimeInterval: poll)
    }
}

private func awaitExitObservableAsync(_ process: Process, poll: TimeInterval) async {
    let deadline = Date().addingTimeInterval(killConfirmationWindow)
    while !process.hasExited, Date() < deadline {
        try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
    }
}

/// The same ladder for an async caller, waiting the grace period with
/// `Task.sleep` instead of `Thread.sleep`.
///
/// This exists as a separate function on purpose rather than as a
/// `Task.detached` wrapper around the synchronous one: `Thread.sleep` inside an
/// async context parks a thread of the cooperative pool, and a subprocess call
/// that parks cooperative threads is what wedged this fleet's runtime for hours
/// at a time ([[sync-subprocess-from-async-wedges-the-runtime]]). The two
/// bodies are deliberately near-identical; the difference that matters is the
/// one word `await`.
func stopProcessAsync(_ process: Process, grace: TimeInterval, poll: TimeInterval = 0.05) async -> ProcessStopOutcome {
    guard !process.hasExited else { return .alreadyExited }

    let askedPolitely = requestGracefulStop(process)

    if askedPolitely {
        let deadline = Date().addingTimeInterval(grace)
        while !process.hasExited, Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        if process.hasExited { return .graceful }
    }

    process.forceKill()
    // Same reason as the synchronous ladder: reaping lags the kill, so return
    // only once the outcome is observable.
    await awaitExitObservableAsync(process, poll: poll)
    return .hardTerminated
}
