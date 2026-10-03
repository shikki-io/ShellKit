import Foundation

// MARK: - AsyncSemaphore
//
// Hand-rolled bounded-concurrency semaphore using Swift Concurrency.
// No external dependencies (no swift-async-algorithms).
//
// Root cause addressed: H7 GCD starvation — 134 sequential
// `waitUntilExit()` calls consumed GCD's 64-thread soft limit, preventing
// asyncAfter guard closures from ever being scheduled.
//
// This actor caps concurrent shell executions at `maxConcurrent` (default 4),
// ensuring GCD threads are never fully exhausted by subprocess waiters.

public actor AsyncSemaphore {
    private let limit: Int
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>]

    public init(limit: Int) {
        precondition(limit > 0, "AsyncSemaphore limit must be > 0")
        self.limit = limit
        self.count = limit
        self.waiters = []
    }

    /// Acquire a permit. Suspends if none are available.
    public func wait() async {
        // `empty_count` is a COLLECTION rule — `array.count > 0` -> `isEmpty`.
        // `count` here is a permit counter, not a collection, and "is the
        // semaphore empty?" is ambiguous (no permits, or no waiters?). PR #8
        // applied the rule mechanically and wrote `!isEmpty` without defining
        // `isEmpty`, so the branch did not compile — caught by the ShellKit
        // gate, not by GitHub's MERGEABLE.
        // swiftlint:disable:next empty_count
        if count > 0 {
            count -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Release a permit. Resumes the oldest waiter if any.
    public func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            count += 1
        }
    }
}
