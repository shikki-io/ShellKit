import Foundation
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - TimedShellExecutor

//
// Canonical async shell executor for the shikki CLI.
//
// Root causes addressed (per @t-completeness audit 2026-05-29/30):
//
//   H6 — Pipe deadlock: `waitUntilExit()` before `readDataToEndOfFile()`.
//         Fix: stdout/stderr drained by child Tasks IN PARALLEL with wait.
//
//   H7 — GCD starvation: 134 sequential `waitUntilExit()` exhaust GCD's
//         64-thread soft limit. Fix: `AsyncSemaphore` caps concurrency at
//         `maxConcurrent` (default 4).
//
//   H2 — `resolveRepoPath()` unguarded: zero timeout guard.
//         Fix: all callers use TimedShellExecutor which has a hard timeout.
//
//   H1/H3 — posix_spawn blocking + SIGTERM ignored: timeout wraps the
//            ENTIRE spawn+wait block; SIGTERM → 1s grace → SIGKILL escalation.
//
//   W1.3 — NSTask kqueue EVFILT_PROC race: `Task.detached { waitUntilExit() }`
//           subscribes to kqueue AFTER posix_spawn returns. Fast children (e.g.
//           `git rev-parse`, `/usr/bin/true`) can exit in the gap → notification
//           missed → infinite block. Fix: use `terminationHandler` (set on the
//           Process object BEFORE proc.run()) which is wired at spawn time by
//           NSTask internally, so exit can never be missed regardless of timing.

public actor TimedShellExecutor: ShellExecutorProtocol {
    /// SIGKILL grace period after SIGTERM. 1 second is sufficient for
    /// well-behaved processes; D-state processes are killed forcibly by SIGKILL.
    private static let sigtermGracePeriod: TimeInterval = 1.0

    /// W1.4 — post-exit pipe-drain grace. After the child exits, its buffered
    /// output flushes within milliseconds; anything later can only come from a
    /// grandchild that inherited the write-end. 2 s is generous for flush and
    /// keeps a daemonized holder from hanging the caller forever.
    private static let drainGracePeriod: TimeInterval = 2.0

    private let semaphore: AsyncSemaphore

    /// Create a new executor.
    ///
    /// - Parameter maxConcurrent: Maximum number of subprocesses running in
    ///   parallel. Callers beyond this limit suspend until a slot is freed.
    ///   Default 4 is conservative to keep GCD thread usage far below the 64
    ///   soft limit even if the entire mop scan races.
    public init(maxConcurrent: Int = 4) {
        semaphore = AsyncSemaphore(limit: maxConcurrent)
    }

    /// Execute a command and return its full output at exit.
    ///
    /// This IS ``runStreaming(_:cwd:env:timeout:stdin:onStdout:onStderr:)``
    /// with no sinks — one implementation, not two. Review on PR #3: *"Did
    /// it's implementation cannot call itself the streaming implementation?
    /// Do be DRY?"* Correct: the first draft duplicated the permit
    /// acquisition, the detached signal and the cancellation handler in both
    /// methods, which is two copies of the concurrency contract that would
    /// have had to be kept in step by hand.
    public func run(
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval = 10,
        stdin: Data? = nil
    ) async throws -> ShellCommandResult {
        try await runStreaming(
            args, cwd: cwd, env: env, timeout: timeout, stdin: stdin,
            onStdout: nil, onStderr: nil
        )
    }

    /// Execute a command, delivering stdout/stderr chunks AS THEY ARRIVE.
    ///
    /// WHY THIS EXISTS. `run` accumulates and returns everything at exit, so
    /// any caller needing live output had to bypass this executor with a raw
    /// `Process` — losing the timeout, the SIGTERM/SIGKILL escalation, the
    /// concurrency cap and the H6 pipe-deadlock fixes that live here. kagami's
    /// `GoScopeRunner` says so in a comment and names this API as the fix:
    ///
    ///   "It CANNOT migrate to ShellKit.TimedShellExecutor yet — that API
    ///    buffers stdout until exit (no streaming callback), which would
    ///    silence a 30s go-test run and kill the live -json re-emit. The
    ///    missing primitive goes UPSTREAM first: ShellKit runStreaming(...)"
    ///
    /// The drain ALREADY received chunks incrementally; it simply had no way
    /// to hand them on. So this is the same code path as `run`, with a sink —
    /// not a second execution mechanism. The full output is still returned, so
    /// a caller can stream AND keep the buffer.
    ///
    /// - Parameters:
    ///   - onStdout: called on a dispatch source thread per chunk. Must be
    ///     cheap and non-blocking: a slow sink stalls the drain, which is what
    ///     re-introduces the pipe-deadlock class (H6). Buffer and hand off.
    ///   - onStderr: same contract for stderr.
    public func runStreaming(
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval = 10,
        stdin: Data? = nil,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ShellCommandResult {
        // Acquire permit — suspends here if concurrency cap is reached (H7 fix).
        await semaphore.wait()
        // W1.1 fix: Task.detached avoids actor-mailbox starvation.
        // Under load the actor mailbox queues deeply; a Task { await self.semaphore.signal() }
        // inherits actor isolation and joins the mailbox queue — it may never execute
        // while all cooperative threads are IDLE waiting on blocked semaphore.wait() calls.
        // Task.detached runs on the cooperative pool without actor isolation, so signal()
        // fires immediately after the subprocess exits, regardless of mailbox depth.
        let semaphore = self.semaphore // capture by value — no self. in closure
        defer { Task.detached { await semaphore.signal() } }

        return try await withTaskCancellationHandler {
            try await Self.spawnAndWait(
                args: args,
                cwd: cwd,
                env: env,
                timeout: timeout,
                stdin: stdin,
                onStdout: onStdout,
                onStderr: onStderr
            )
        } onCancel: {
            // If the outer Task is cancelled, nothing extra to do here —
            // the timeout Task inside spawnAndWait will SIGKILL the process.
        }
    }

    // MARK: - Core spawn implementation (nonisolated static)

    // MARK: - Launch plan

    /// How `args` are launched: an ABSOLUTE `args[0]` is exec'd directly; a
    /// bare name goes through `/usr/bin/env` for the PATH lookup.
    ///
    /// Why the distinction matters: `/usr/bin/env` is a SIP-restricted binary,
    /// and the kernel strips every `DYLD_*` variable from a restricted
    /// process's environment — so a child launched THROUGH it can never
    /// receive `DYLD_FRAMEWORK_PATH` / `DYLD_LIBRARY_PATH`, whatever `env`
    /// said. Measured 2026-09-25 (kagami, spec 6d5f3f5e W2):
    /// `swiftpm-testing-helper` exec'd directly with those two variables ran
    /// 29 events; the same argv through `/usr/bin/env` died in
    /// dlopen(XCTest.framework), exit 133. A caller that resolved its
    /// executable to an absolute path gets exactly the exec it asked for.
    public struct LaunchPlan: Equatable, Sendable {
        public let executable: String
        public let arguments: [String]
    }

    /// Pure and tested: absolute `args[0]` → direct exec; otherwise `/usr/bin/env`.
    public static func launchPlan(for args: [String]) -> LaunchPlan {
        guard let first = args.first, first.hasPrefix("/") else {
            return LaunchPlan(executable: "/usr/bin/env", arguments: args)
        }
        return LaunchPlan(executable: first, arguments: Array(args.dropFirst()))
    }

    private static func spawnAndWait(
        args: [String],
        cwd: String?,
        env: [String: String]?,
        timeout: TimeInterval,
        stdin: Data?,
        onStdout: (@Sendable (Data) -> Void)? = nil,
        onStderr: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ShellCommandResult {
        let start = Date()

        // Build the process.
        let proc = Process()
        let plan = launchPlan(for: args)
        proc.executableURL = URL(fileURLWithPath: plan.executable)
        proc.arguments = plan.arguments

        if let cwd = cwd {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        if let extraEnv = env, !extraEnv.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv {
                merged[k] = v
            }
            proc.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        // W1.2 fix: set FD_CLOEXEC on pipe write-ends (and read-ends defensively)
        // so that when Process() calls posix_spawn for child N, the kernel closes
        // the parent's reference to the write-end of child N-1's pipe — preventing
        // the cascade hang where readDataToEndOfFile() on pipe N-1 blocks waiting
        // for all N..N+78 children to close their inherited copy of the write-end.
        // macOS Pipe() does NOT set O_CLOEXEC by default; this is the root cause
        // that defeated PRs #585 → #596 → #657 → #714 → #719.
        #if canImport(Darwin)
            fcntl(stdoutPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
            fcntl(stderrPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
            fcntl(stdoutPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
            fcntl(stderrPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        #endif
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        if let stdinData = stdin {
            let stdinPipe = Pipe()
            proc.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.writeabilityHandler = { handle in
                handle.write(stdinData)
                handle.closeFile()
                handle.writeabilityHandler = nil
            }
        }

        // W1.3 fix: set terminationHandler BEFORE proc.run() so that child-exit
        // can never be missed regardless of timing (NSTask registers the kqueue
        // EVFILT_PROC/NOTE_EXIT subscription internally when the handler is set,
        // before posix_spawn is called). The old `Task.detached { waitUntilExit() }`
        // pattern subscribed to kqueue AFTER posix_spawn returned — fast children
        // (e.g. `git rev-parse`, `/usr/bin/true`) could exit in that window and
        // the notification was never delivered → infinite block.
        //
        // Guard against double-resume: terminationHandler can fire in a narrow
        // window even if proc.run() throws synchronously on some error paths.
        final class ResumeGuard: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func tryResume(_ body: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                body()
            }
        }
        let guard_ = ResumeGuard()

        // Timeout watchdog: fires concurrently with the wait continuation.
        // SIGTERM → 1s grace → SIGKILL. Cannot be ignored or caught.
        // We use a nonisolated flag to communicate whether the timeout fired
        // before the process exited naturally.
        final class TimeoutFlag: @unchecked Sendable {
            var fired = false
        }
        let timeoutFlag = TimeoutFlag()

        // H6 fix: drain pipes IN PARALLEL with the wait.
        // Reading pipes only after waitUntilExit() deadlocks when child
        // produces >64KB (the pipe kernel buffer size on macOS). Handlers are
        // installed here (before proc.run()) so draining is live by the time
        // the child starts writing — no backpressure window.
        //
        // W1.4 (mop-gh hang, shikki @db c6e806e7): the drains are
        // readabilityHandler-based (dispatch source), NOT a thread blocked in
        // readDataToEndOfFile(). A grandchild that daemonizes holding the
        // inherited write-end (credential-helper pattern) postpones pipe EOF
        // indefinitely — a blocked read() cannot be cancelled on Darwin, but a
        // handler-based drain can be force-finished after the post-exit grace.
        let stdoutDrain = PipeDrain(handle: stdoutPipe.fileHandleForReading, onChunk: onStdout)
        let stderrDrain = PipeDrain(handle: stderrPipe.fileHandleForReading, onChunk: onStderr)

        // Wire handler and run — the continuation resumes when the process exits.
        // proc.run() is called INSIDE the continuation so the handler is wired
        // first. The timeout task is launched before awaiting the continuation
        // so it fires concurrently if the process takes too long.
        // posix_spawn itself can block under extreme load (H1 fix: the entire
        // block is covered by the timeout task launched just below).
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            // Timeout fired: set flag then kill.
            // SIGKILL causes NSTask to invoke terminationHandler, which resumes
            // the continuation — no explicit continuation.resume() needed here.
            timeoutFlag.fired = true
            if proc.isRunning {
                proc.terminate() // SIGTERM
                try? await Task.sleep(nanoseconds: UInt64(Self.sigtermGracePeriod * 1_000_000_000))
                if proc.isRunning {
                    Darwin.kill(proc.processIdentifier, SIGKILL)
                }
            }
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                proc.terminationHandler = { _ in
                    guard_.tryResume { continuation.resume() }
                }
                do {
                    try proc.run()
                } catch {
                    guard_.tryResume {
                        continuation.resume(throwing: ShellError.launchFailed(
                            args: args, underlying: error.localizedDescription
                        ))
                    }
                }
            }
        } catch {
            timeoutTask.cancel()
            throw error
        }
        timeoutTask.cancel()

        let exitCode = proc.terminationStatus
        // W1.4: bound the post-exit drain. The child has exited; give the
        // pipes a short window to flush buffered output, then force-finish
        // with whatever arrived. Without this, `await` here was UNBOUNDED
        // (the timeout watchdog is already cancelled) and a write-end holder
        // hung the caller forever — the live-sampled `shi mop` gh-leg hang.
        let drainGraceTask = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(Self.drainGracePeriod * 1_000_000_000))
            stdoutDrain.forceFinish()
            stderrDrain.forceFinish()
        }
        let stdout = await stdoutDrain.value()
        let stderr = await stderrDrain.value()
        drainGraceTask.cancel()
        let duration = Date().timeIntervalSince(start)

        // Detect timeout: flag was set by the watchdog before process exited.
        if timeoutFlag.fired {
            throw ShellError.timeout(args: args, limit: timeout)
        }

        return ShellCommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr, duration: duration)
    }
}

// MARK: - PipeDrain (W1.4)

/// Handler-based pipe accumulator with a force-finish escape hatch.
///
/// `readabilityHandler` delivers chunks on a dispatch source — no thread is
/// ever parked in `read(2)`, so the drain can always be terminated even when
/// pipe EOF never arrives (a daemonized grandchild holding the write-end).
/// EOF (empty `availableData`) finishes naturally; `forceFinish()` finishes
/// with whatever accumulated.
private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var buffer = Data()
    private var finished = false
    private var continuation: CheckedContinuation<Data, Never>?
    /// Live sink, called on the dispatch source as each chunk lands.
    ///
    /// The drain ALREADY received chunks incrementally — it simply had no way
    /// to hand them on, so every caller that needed live output (a 30s
    /// `go test` re-emitting `-json`, a long build) had to bypass this
    /// executor with a raw `Process`. That bypass is the whole reason
    /// `runStreaming` exists.
    private let onChunk: (@Sendable (Data) -> Void)?

    init(handle: FileHandle, onChunk: (@Sendable (Data) -> Void)? = nil) {
        self.handle = handle
        self.onChunk = onChunk
        handle.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty {
                self.finish() // EOF — all write-ends closed.
            } else {
                self.lock.lock()
                self.buffer.append(chunk)
                self.lock.unlock()
                // Outside the lock: a slow consumer must not stall the drain,
                // which is what re-introduces the pipe-deadlock class (H6).
                self.onChunk?(chunk)
            }
        }
    }

    /// Finish with the accumulated data regardless of EOF (post-exit grace).
    func forceFinish() {
        finish()
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let data = buffer
        lock.unlock()
        handle.readabilityHandler = nil
        cont?.resume(returning: data)
    }

    /// Await the drained data. Resolves on EOF or forceFinish, whichever first.
    func value() async -> Data {
        await withCheckedContinuation { (c: CheckedContinuation<Data, Never>) in
            lock.lock()
            if finished {
                let data = buffer
                lock.unlock()
                c.resume(returning: data)
                return
            }
            continuation = c
            lock.unlock()
        }
    }
}

// MARK: - Convenience extensions

public extension TimedShellExecutor {
    /// Run a command and return stdout as a trimmed string.
    /// Returns empty string on non-zero exit (mirrors legacy `run()` behaviour).
    func runString(
        _ args: [String],
        cwd: String? = nil,
        timeout: TimeInterval = 10
    ) async -> String {
        guard let result = try? await run(args, cwd: cwd, env: nil, timeout: timeout, stdin: nil) else {
            return ""
        }
        return result.stdoutString
    }

    /// Run a command and return the exit code.
    /// Returns -1 on launch failure, `timeout_exit_code` on timeout.
    func runExitCode(
        _ args: [String],
        cwd: String? = nil,
        timeout: TimeInterval = 10
    ) async -> Int32 {
        do {
            let result = try await run(args, cwd: cwd, env: nil, timeout: timeout, stdin: nil)
            return result.exitCode
        } catch ShellError.timeout {
            return -2
        } catch {
            return -1
        }
    }
}
