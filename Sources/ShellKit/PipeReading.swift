import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
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
    /// Windows has its own reader (``WindowsPipeReader``) rather than an
    /// extension here, because it must hold the Win32 HANDLE it was built
    /// with instead of asking for a descriptor per read.
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

// MARK: - WindowsPipeReader

#if os(Windows)
/// Non-blocking reads of an anonymous pipe on Windows.
///
/// Windows has no `poll(2)` for pipes and no `O_NONBLOCK`: a `ReadFile` on a
/// synchronous pipe handle blocks until at least one byte arrives, and nothing
/// can cancel it from another thread. `PeekNamedPipe` is the platform's answer —
/// it reports how many bytes are already buffered without consuming them — so
/// the pump asks first and only ever reads a count it knows is there. That is
/// what keeps ``PipePump/stop(waiting:)`` able to promise that no read is in
/// flight, which is the whole contract its callers close descriptors on.
///
/// The HANDLE is taken once, at construction: on Windows
/// swift-corelibs-foundation answers `FileHandle.fileDescriptor` by wrapping
/// its HANDLE in a fresh CRT descriptor through `_open_osfhandle`, so asking
/// per read would allocate a descriptor per read.
///
/// STATUS: compiles by inspection, unproven on Windows (backlog afb8cd83) —
/// in particular the assumption that `_get_osfhandle` round-trips the
/// descriptor Foundation handed out.
/// `@unchecked Sendable` because the stored value is a kernel handle, and the
/// reader is used by exactly one thread per pipe: the pump owns the child's
/// stderr handle, `InteractiveProcess.readLine` owns its stdout handle. Two
/// threads calling `ReadFile` on one pipe would interleave bytes, which is why
/// that single-reader rule is the type's contract and not an accident.
struct WindowsPipeReader: @unchecked Sendable {
    /// Typed as a raw pointer rather than `HANDLE`: the Windows overlay
    /// imports `HANDLE` as an implicitly-unwrapped optional, and a stored
    /// property that cannot be nil says more than one that merely is not.
    private let handle: UnsafeMutableRawPointer

    /// nil when the descriptor carries no usable Win32 handle.
    init?(_ fileHandle: FileHandle) {
        let raw = _get_osfhandle(fileHandle.fileDescriptor)
        guard raw != -1, let handle = UnsafeMutableRawPointer(bitPattern: Int(raw)) else { return nil }
        self.handle = handle
    }

    /// Whatever is buffered right now, and whether every write-end is closed.
    /// Never waits: the caller decides how long to sleep between calls.
    func readAvailable() -> (data: Data, endOfFile: Bool) {
        var available: DWORD = 0
        guard PeekNamedPipe(handle, nil, 0, nil, &available, nil).boolValue else {
            // ERROR_BROKEN_PIPE is the normal end of a child's output, not a
            // fault: the last write-end closed. Any other failure is equally
            // terminal for a pump — there is nothing left to read either way.
            return (Data(), true)
        }
        guard available > 0 else { return (Data(), false) }

        var buffer = [UInt8](repeating: 0, count: Int(available))
        var read: DWORD = 0
        let ok = buffer.withUnsafeMutableBytes {
            ReadFile(handle, $0.baseAddress, available, &read, nil).boolValue
        }
        guard ok, read > 0 else { return (Data(), true) }
        return (Data(buffer.prefix(Int(read))), false)
    }

    /// One byte, or nil when nothing is buffered. `endOfFile` distinguishes
    /// "not yet" from "never again" — ``InteractiveProcess/readLine(deadline:)``
    /// needs both, because only one of them ends its loop.
    func readByte() -> (byte: UInt8?, endOfFile: Bool) {
        var available: DWORD = 0
        guard PeekNamedPipe(handle, nil, 0, nil, &available, nil).boolValue else {
            return (nil, true)
        }
        guard available > 0 else { return (nil, false) }

        var byte: UInt8 = 0
        var read: DWORD = 0
        let ok = withUnsafeMutableBytes(of: &byte) {
            ReadFile(handle, $0.baseAddress, 1, &read, nil).boolValue
        }
        guard ok, read == 1 else { return (nil, true) }
        return (byte, false)
    }
}
#endif

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
/// Windows: the same thread shape as Linux, over ``WindowsPipeReader`` instead
/// of `poll`. A dispatch read source is not an option: libdispatch's Windows
/// port backs those with sockets, not anonymous pipes, and `readabilityHandler`
/// is built on one.
///
/// The pump retains `handle`, so the descriptor stays open until the thread has
/// exited, however early the owner lets go of the `Pipe`.
final class PipePump {
    private let handle: FileHandle
    private let onChunk: @Sendable (Data) -> Void
    private let onEnd: @Sendable () -> Void
    #if canImport(Glibc) || os(Windows)
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
        #elseif os(Windows)
        // STATUS: compiles by inspection, unproven on Windows (backlog afb8cd83)
        let exited = self.exited
        let reader = WindowsPipeReader(handle)
        self.thread = Thread {
            guard let reader else {
                onEnd()  // no readable handle: treat as an empty stream, never hang
                exited.signal()
                return
            }
            while !Thread.current.isCancelled {
                let (chunk, endOfFile) = reader.readAvailable()
                if !chunk.isEmpty { onChunk(chunk) }
                if endOfFile {
                    onEnd()
                    break
                }
                // `PeekNamedPipe` does not wait, so the wait is here. Same
                // 20 ms slice Linux passes to `poll`.
                if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.02) }
            }
            exited.signal()
        }
        #endif
    }

    func start() {
        #if canImport(Glibc) || os(Windows)
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
        #if canImport(Glibc) || os(Windows)
        thread.cancel()
        if waiting, Thread.current !== thread {
            _ = exited.wait(timeout: .now() + 2)
        }
        #else
        handle.readabilityHandler = nil
        #endif
    }
}
