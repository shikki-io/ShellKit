import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - FileHandle.readAvailable

extension FileHandle {
    /// Everything that can be read from this handle without blocking, plus
    /// whether the writer side has closed.
    ///
    /// Linux only: Darwin's pump (``PipePump``) keeps using `availableData`.
    /// `availableData` returns one 8 KiB read, and on Linux the dispatch source
    /// behind `readabilityHandler` is edge-triggered, so a handler that reads
    /// once per callback stalls with the rest of a burst still buffered (a
    /// 128 KiB `dd` captured 80 KiB). Reading until `poll` reports nothing more
    /// is the same contract, made robust.
    ///
    /// - Parameter waitingMilliseconds: how long the first `poll` may wait for
    ///   data. The rest of the loop never waits.
    /// - Returns: `data` is whatever arrived; `endOfFile` is true once the
    ///   write-end is closed and the pipe is empty.
    #if canImport(Glibc)
    func readAvailable(waitingMilliseconds: Int32 = 0) -> (data: Data, endOfFile: Bool) {
        var collected = Data()
        let fd = fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var wait = waitingMilliseconds
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, wait)
            wait = 0
            if ready < 0 {
                if errno == EINTR { continue }
                return (collected, true)
            }
            if ready == 0 { return (collected, false) }
            let n = buffer.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                collected.append(contentsOf: buffer.prefix(n))
            } else if n == 0 {
                return (collected, true)
            } else if errno == EINTR || errno == EAGAIN {
                continue
            } else {
                return (collected, true)
            }
        }
    }
    #endif
}

// MARK: - PipePump

/// Delivers a pipe's bytes to `onChunk` as they arrive and calls `onEnd` at EOF.
///
/// Darwin: a `readabilityHandler` (dispatch source), exactly as before.
///
/// Linux: a dedicated thread polling the descriptor in short slices. The
/// dispatch-source route is unusable there for two reasons measured on
/// swift:6.3-jammy: it is edge-triggered (see ``FileHandle/readAvailable``), and
/// tearing a source down while its pipe is being closed crashed libdispatch's
/// event loop in roughly 1 test run in 15. A thread has neither problem, and
/// `Thread.cancel()` is its own stop flag, so there is no shared state to lock.
///
/// The pump retains `handle`, so the descriptor stays open until the thread has
/// exited, however early the owner lets go of the `Pipe`.
final class PipePump {
    private let handle: FileHandle
    private let onChunk: @Sendable (Data) -> Void
    private let onEnd: @Sendable () -> Void
    #if canImport(Glibc)
    private let thread: Thread
    private let exited = DispatchSemaphore(value: 0)
    #endif

    init(
        handle: FileHandle,
        onChunk: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) {
        self.handle = handle
        self.onChunk = onChunk
        self.onEnd = onEnd
        #if canImport(Glibc)
        let exited = self.exited
        self.thread = Thread {
            while !Thread.current.isCancelled {
                let (chunk, endOfFile) = handle.readAvailable(waitingMilliseconds: 20)
                if !chunk.isEmpty { onChunk(chunk) }
                if endOfFile {
                    onEnd()
                    break
                }
            }
            exited.signal()
        }
        #endif
    }

    func start() {
        #if canImport(Glibc)
        thread.start()
        #else
        let onChunk = self.onChunk
        let onEnd = self.onEnd
        handle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {
                onEnd() // EOF — all write-ends closed.
            } else {
                onChunk(chunk)
            }
        }
        #endif
    }

    /// Stop delivering. With `waiting`, return only once no further read can
    /// happen on the descriptor, so the caller may close it (bounded: 2 s).
    /// Safe to call from `onEnd`/`onChunk` themselves; it never waits for itself.
    func stop(waiting: Bool) {
        #if canImport(Glibc)
        thread.cancel()
        if waiting, Thread.current !== thread {
            _ = exited.wait(timeout: .now() + 2)
        }
        #else
        handle.readabilityHandler = nil
        #endif
    }
}
