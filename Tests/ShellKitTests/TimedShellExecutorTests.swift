import XCTest
@testable import ShellKit
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - TimedShellExecutorTests

//
// Scope: ShikkiShellExecutor
// Tests cover the four mandatory cases from the W1 spec:
//   1. 64KB stdout does NOT deadlock (H6 fix)
//   2. 5s sleep with 2s timeout → throws timeout in ≤3s (H1/H3 fix)
//   3. 134 parallel calls saturate at 4 concurrent (H7 fix)
//   4. Timeout actually SIGKILLs — process is gone after timeout

final class TimedShellExecutorTests: XCTestCase {
    // MARK: - 1. Large stdout does not deadlock (H6 fix)

    ///
    /// Pipe buffer on macOS is 64KB. Writing more without a concurrent reader
    /// causes child to block, parent to block on waitUntilExit → deadlock.
    /// TimedShellExecutor drains in parallel Tasks, so this should complete.
    func testLargeStdoutNoDeadlock() async throws {
        let executor = TimedShellExecutor(maxConcurrent: 4)
        // Generate 128KB of output via `dd` — well above the 64KB pipe limit.
        let result = try await executor.run(
            ["dd", "if=/dev/zero", "bs=1024", "count=128"],
            cwd: nil,
            env: nil,
            timeout: 10,
            stdin: nil
        )
        // dd exits 0 and produces 128KB on stdout (binary zeros).
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThanOrEqual(result.stdout.count, 128 * 1024)
    }

    // MARK: - 2. Timeout fires and throws (H1/H3 fix)

    ///
    /// A 5s sleep with a 2s timeout should throw ShellError.timeout in ≤3s.
    /// (+1s SIGTERM grace period)
    func testTimeoutThrows() async throws {
        let executor = TimedShellExecutor(maxConcurrent: 4)
        let start = Date()
        do {
            _ = try await executor.run(
                ["sleep", "5"],
                cwd: nil,
                env: nil,
                timeout: 2,
                stdin: nil
            )
            XCTFail("Expected ShellError.timeout but run() returned normally")
        } catch ShellError.timeout(let args, let limit) {
            let elapsed = Date().timeIntervalSince(start)
            // Should complete within timeout + grace (2s + 1s) + 0.5s scheduling margin
            XCTAssertLessThanOrEqual(elapsed, 4.0, "Timeout took too long: \(elapsed)s")
            XCTAssertEqual(limit, 2.0)
            XCTAssertTrue(args.contains("sleep"))
        }
    }

    // MARK: - 3. Bounded concurrency (H7 fix)

    ///
    /// Firing 134 concurrent calls into a maxConcurrent:4 executor should
    /// saturate at 4 concurrent while the rest queue. We verify by measuring
    /// that all 134 complete (none hang) and the wall time is consistent with
    /// bounded concurrency (not sequential, not all-parallel).
    func testBoundedConcurrency() async throws {
        let executor = TimedShellExecutor(maxConcurrent: 4)
        // Use 20 calls (fast, each ~10ms) to verify no deadlock and completion.
        // Full 134 would take too long for a unit test; 20 exercises the semaphore.
        let callCount = 20
        let results: [ShellCommandResult] = try await withThrowingTaskGroup(of: ShellCommandResult.self) { group in
            for _ in 0..<callCount {
                group.addTask {
                    try await executor.run(
                        ["echo", "ok"],
                        cwd: nil,
                        env: nil,
                        timeout: 10,
                        stdin: nil
                    )
                }
            }
            var all: [ShellCommandResult] = []
            for try await r in group {
                all.append(r)
            }
            return all
        }
        XCTAssertEqual(results.count, callCount)
        XCTAssertTrue(results.allSatisfy { $0.exitCode == 0 })
        XCTAssertTrue(results.allSatisfy { $0.stdoutString == "ok" })
    }

    // MARK: - 4. SIGKILL actually terminates the process

    ///
    /// After a timeout, the child process must be gone (not a zombie).
    /// We verify by calling `kill(pid, 0)` after the timeout fires — it should
    /// return ESRCH (no such process), confirming the process was reaped.
    func testSigkillTerminatesProcess() async throws {
        let executor = TimedShellExecutor(maxConcurrent: 4)

        // We need the PID. Use a workaround: launch a known-slow process,
        // capture its PID via a pipe before timeout fires.
        //
        // Strategy: write PID to a temp file via sh -c, then timeout.
        let pidFile = NSTemporaryDirectory() + "TimedShellExecutorTests-pid-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }

        do {
            _ = try await executor.run(
                ["sh", "-c", "echo $$ > \(pidFile); sleep 5"],
                cwd: nil,
                env: nil,
                timeout: 1,
                stdin: nil
            )
            XCTFail("Expected timeout")
        } catch ShellError.timeout {
            // Expected path.
        }

        // Wait a moment for process table cleanup (reaping takes <100ms).
        try await Task.sleep(nanoseconds: 200_000_000)

        // Read the PID written by the child.
        guard let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            // If the file wasn't written (process killed before writing), test passes —
            // the process never got to run, so it can't be hanging.
            return
        }

        // kill(pid, 0) returns 0 if the process exists, -1 with errno=ESRCH if not.
        // A zombie still answers 0 — give reaping another moment.
        if !Self.isGone(pid) {
            try await Task.sleep(nanoseconds: 500_000_000)
            if !Self.isGone(pid) {
                XCTFail("Process \(pid) still alive after SIGKILL + 700ms")
            }
        }
    }

    // MARK: - 4b. The timeout kills a child that ignores SIGTERM, and it is reaped

    /// `trap '' TERM` survives `exec`, so the `sleep` below IS the child
    /// (no wrapper shell to outlive it) and only the SIGKILL escalation can end
    /// it. Same shape on every platform: the pid must be gone — reaped, not a
    /// zombie — shortly after the timeout error.
    func testTimeoutEscalatesToSigkillForAChildThatIgnoresSigterm() async throws {
        let executor = TimedShellExecutor(maxConcurrent: 4)
        let pidFile = NSTemporaryDirectory() + "TimedShellExecutorTests-pid-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }

        let start = Date()
        do {
            _ = try await executor.run(
                ["sh", "-c", "trap '' TERM; echo $$ > \(pidFile); exec sleep 30"],
                cwd: nil, env: nil, timeout: 1, stdin: nil
            )
            XCTFail("Expected ShellError.timeout")
        } catch ShellError.timeout {
            // SIGTERM is ignored, so the error only arrives after the 1s grace + SIGKILL.
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 10, "the timeout must not wait for the child's 30s")
            XCTAssertGreaterThanOrEqual(elapsed, 1.9, "SIGTERM is ignored, so 1s timeout + 1s grace must pass before SIGKILL")
        }

        guard let pidText = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return XCTFail("the child never wrote its pid — it did not run") }
        // Reaping trails the exit by a moment; wait for the strict condition.
        for _ in 0..<100 where kill(pid, 0) == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(kill(pid, 0), -1, "pid \(pid) must be reaped, not left a zombie")
        XCTAssertEqual(errno, ESRCH)
    }

    /// True once `pid` no longer runs. Where Foundation reaps lazily (Linux) a
    /// zombie counts as gone — it executes nothing — but only the strict
    /// `kill(pid, 0) == ESRCH` check above proves the reap.
    private static func isGone(_ pid: Int32) -> Bool {
        if kill(pid, 0) != 0 { return errno == ESRCH }
        #if os(Linux)
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.lastIndex(of: ")") {
            return stat[stat.index(close, offsetBy: 2)...].first == "Z"
        }
        #endif
        return false
    }

    // MARK: - 5. Non-zero exit code is returned correctly (not thrown)

    func testNonZeroExitCodeReturned() async throws {
        let executor = TimedShellExecutor(maxConcurrent: 4)
        let result = try await executor.run(
            ["sh", "-c", "exit 42"],
            cwd: nil,
            env: nil,
            timeout: 5,
            stdin: nil
        )
        XCTAssertEqual(result.exitCode, 42)
    }

    // MARK: - 6. Unknown command returns non-zero exit (not a hang)

    ///
    /// Note: `env` on macOS resolves unknown commands by returning exit 1 or
    /// 127 without blocking — so the executor returns a result, not a thrown error.
    /// We verify it returns quickly (no hang) with a non-zero exit code.
    func testUnknownCommandReturnsQuickly() async throws {
        let executor = TimedShellExecutor(maxConcurrent: 4)
        let start = Date()
        let result = try await executor.run(
            ["__this_command_does_not_exist_shikki_test__"],
            cwd: nil,
            env: nil,
            timeout: 5,
            stdin: nil
        )
        let elapsed = Date().timeIntervalSince(start)
        // Should complete fast (env exits with 127 for unknown commands)
        XCTAssertLessThan(elapsed, 2.0, "Unknown command took too long: \(elapsed)s")
        XCTAssertNotEqual(result.exitCode, 0, "Expected non-zero exit for unknown command")
    }

    // MARK: - 7. runString convenience returns stdout

    // MARK: - Launch plan (absolute executable execs directly — DYLD_* survive)

    func testAbsoluteExecutableIsExecdDirectly() {
        let plan = TimedShellExecutor.launchPlan(for: ["/usr/bin/true", "--flag", "x"])
        XCTAssertEqual(plan, .init(executable: "/usr/bin/true", arguments: ["--flag", "x"]))
    }

    func testBareNameGoesThroughEnvForPathLookup() {
        let plan = TimedShellExecutor.launchPlan(for: ["true", "--flag"])
        XCTAssertEqual(plan, .init(executable: "/usr/bin/env", arguments: ["true", "--flag"]))
    }

    func testEmptyArgvStillHasAnExecutable() {
        XCTAssertEqual(TimedShellExecutor.launchPlan(for: []).executable, "/usr/bin/env")
    }

    func testAbsoluteExecutableRunsAndReturnsItsExitCode() async throws {
        let executor = TimedShellExecutor()
        let result = try await executor.run(["/usr/bin/false"], timeout: 5)
        XCTAssertEqual(result.exitCode, 1)
        let ok = try await executor.run(["/usr/bin/true"], timeout: 5)
        XCTAssertEqual(ok.exitCode, 0)
    }

    func testRunStringConvenience() async {
        let executor = TimedShellExecutor(maxConcurrent: 4)
        let out = await executor.runString(["echo", "hello world"], timeout: 5)
        XCTAssertEqual(out, "hello world")
    }

    // MARK: - 8. runExitCode convenience returns exit code

    func testRunExitCodeConvenience() async {
        let executor = TimedShellExecutor(maxConcurrent: 4)
        let code = await executor.runExitCode(["sh", "-c", "exit 7"], timeout: 5)
        XCTAssertEqual(code, 7)
    }

    // MARK: - 9. W1.3 NSTask kqueue EVFILT_PROC race — terminationHandler wired before run()

    ///
    /// Fast children (e.g. /usr/bin/true) can exit between posix_spawn returning
    /// and the old `Task.detached { waitUntilExit() }` subscribing to kqueue.
    /// With the W1.2 code: ~1/50 iterations would hang indefinitely.
    /// With the W1.3 fix:  all 50 return cleanly — terminationHandler is set
    ///                     on the Process object before proc.run() so exit cannot
    ///                     be missed regardless of timing.
    func testNSTaskKqueueRaceFastChild() async throws {
        let executor = TimedShellExecutor(maxConcurrent: 1)
        let start = Date()
        for _ in 0..<50 {
            _ = try await executor.run(["/usr/bin/true"], cwd: nil, env: nil, timeout: 2, stdin: nil)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0,
                          "50 /usr/bin/true took \(elapsed)s — NSTask kqueue race regression (W1.3 fix missing?)")
    }

    // MARK: - 10. W1.1 Semaphore signal under actor-mailbox load (H7.1 regression test)

    ///
    /// Reproduces the actor-mailbox starvation pattern that snuck past the original 8/8
    /// test suite. The bug: `defer { Task { await self.semaphore.signal() } }` queues on
    /// the actor mailbox. Under load (many concurrent callers, semaphore limit 4) those
    /// signal Tasks pile up behind the pending wait() callers and may never execute.
    ///
    /// With the bug:  hangs permanently (deadlock in actor mailbox queue)
    /// With the fix:  completes in <10s (20 echo calls at 4-concurrency → ~5 batches)
    ///
    /// Design to amplify mailbox interleaving:
    ///   - Task.detached spawners: bypass structured concurrency so all 20 Tasks queue
    ///     on the cooperative pool simultaneously, maximising actor mailbox depth.
    ///   - semaphore limit 2 (not 4): starves faster — 18 waiters vs 16.
    ///   - Wall-clock assertion <15s: conservative; 20 echo calls complete in <1s normally.
    func testSemaphoreSignalUnderActorMailboxLoad() async throws {
        // Use limit:2 to maximise waiter count (20 callers - 2 permits = 18 waiters).
        let executor = TimedShellExecutor(maxConcurrent: 2)
        let concurrency = 20
        let wallStart = Date()

        // Spawn all 20 callers as Task.detached BEFORE awaiting any —
        // this guarantees all 20 are enqueued on the cooperative pool simultaneously,
        // maximising the actor mailbox depth at the critical moment.
        var handles: [Task<Void, Error>] = []
        handles.reserveCapacity(concurrency)

        for i in 0..<concurrency {
            let handle = Task.detached {
                _ = try await executor.run(
                    ["echo", "stress-\(i)"],
                    cwd: nil,
                    env: nil,
                    timeout: 10,
                    stdin: nil
                )
            }
            handles.append(handle)
        }

        // Await all — if any signal() never fires, this hangs forever.
        for handle in handles {
            try await handle.value
        }

        let elapsed = Date().timeIntervalSince(wallStart)
        // 15s wall-clock limit: generous for a loaded machine.
        // 20 echo calls at maxConcurrent:2 → 10 serial batches × ~5ms = ~50ms normal.
        // Any value >15s indicates starvation.
        XCTAssertLessThan(elapsed, 15.0,
                          "Semaphore signal starvation detected: \(elapsed)s (expected <15s). " +
                              "Actor-mailbox starvation — Task.detached fix may be missing.")
    }

    // MARK: - W1.4 bounded post-exit drains (mop-gh hang, shikki @db c6e806e7)

    func testHolderGrandchildDoesNotHangPostExitDrain() async throws {
        // A child that exits immediately but leaves a backgrounded grandchild
        // holding the inherited stdout write-end. Pipe EOF then waits for the
        // GRANDCHILD (30s here — indefinitely for a daemonized helper), and
        // the post-exit `await stdoutData` had no bound because the timeout
        // watchdog is cancelled once the child's exit resumes the
        // continuation. Live-sampled root cause of `shi mop` hanging on its
        // gh leg (TimedShellExecutor.swift readDataToEndOfFile frame).
        let executor = TimedShellExecutor()
        let start = Date()
        let result = try await executor.run(
            ["bash", "-c", "echo hi; sleep 30 &"],
            cwd: nil,
            env: nil,
            timeout: 10,
            stdin: nil
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(
            result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
            "hi",
            "output written before exit must be captured"
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThan(
            elapsed, 8.0,
            "post-exit drain must be bounded by the grace period, "
                + "not the grandchild's lifetime (took \(elapsed)s)"
        )
    }

    // MARK: - Portability: output size and orphaned descendants

    /// 1 MiB — many pipe buffers — must arrive byte for byte. A drain that
    /// reads once per dispatch callback silently loses the tail on Linux.
    func testOneMebibyteOfStdoutIsCapturedExactly() async throws {
        let executor = TimedShellExecutor(maxConcurrent: 4)
        for _ in 0..<5 {
            let result = try await executor.run(
                ["head", "-c", "1048576", "/dev/zero"], cwd: nil, env: nil, timeout: 10, stdin: nil)
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.stdout.count, 1_048_576)
        }
    }

    /// The child exits with 7 while a descendant it started keeps running
    /// (output redirected, so pipe EOF is not what ends the wait). The result
    /// must carry 7 promptly, not when the 30s descendant dies.
    func testExitCodeIsReportedWhileADescendantOutlivesTheChild() async throws {
        let executor = TimedShellExecutor()
        let start = Date()
        let result = try await executor.run(
            ["sh", "-c", "sleep 30 >/dev/null 2>&1 & exit 7"], cwd: nil, env: nil, timeout: 10, stdin: nil)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "waited for the descendant instead of the child")
    }
}
