import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - ExecutableResolver

/// Resolves an executable name to an absolute path the way a shell would —
/// so no consumer has to hand-roll the `PATH` probe (shikki-chat-mcp#5,
/// `ChildMCPToolCaller.swift:121`).
public enum ExecutableResolver {
    /// - Parameters:
    ///   - name: an absolute path (returned as-is when executable) or a bare
    ///     name looked up in `searchPath`.
    ///   - searchPath: colon-separated directories; the process `PATH` by default.
    /// - Returns: the absolute path, or nil when nothing executable matches.
    public static func resolve(
        _ name: String,
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String? {
        let fm = FileManager.default
        if name.hasPrefix("/") {
            return fm.isExecutableFile(atPath: name) ? name : nil
        }
        for dir in (searchPath ?? "").split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - InteractiveProcess

/// A child process spoken to line by line — the primitive behind every
/// JSON-RPC-over-stdio exchange (an MCP server, a language server).
///
/// `TimedShellExecutor.run` is one-shot: it writes stdin once and reads to
/// EOF. A stdio protocol interleaves — send `initialize`, wait for its
/// answer, send the next request — and each step must fail with its own
/// reason. This type owns that shape, and the three things every hand-rolled
/// version got wrong at least once:
///
/// - stderr is drained concurrently into a bounded sink, so a chatty child
///   can neither deadlock the exchange (64 KiB pipe) nor grow our memory;
/// - every read has a deadline, polled, never a bare blocking `read(2)`;
/// - teardown is one function: close stdin, SIGTERM, grace, SIGKILL, and
///   `waitUntilExit` so no zombie is left behind, on every path.
public final class InteractiveProcess: @unchecked Sendable {
    /// How long SIGTERM gets before SIGKILL.
    public static let terminationGrace: TimeInterval = 2.0
    /// How much of the child's stderr is kept (the tail is what matters).
    public static let stderrCapacity = 64 * 1024

    private let process: Process
    private let stdinWriter: FileHandle
    private let stdoutReader: FileHandle
    private let stderrReader: FileHandle
    private let stderrSink = BoundedSink(capacity: InteractiveProcess.stderrCapacity)
    private let lock = NSLock()
    private var tornDown = false
    /// Set once `run()` succeeded. `waitUntilExit()` on a Process that never
    /// launched blocks forever — the first version of this type hung the
    /// whole test bundle from `deinit` after a failed spawn.
    private var launched = false

    /// The spawned child's pid.
    public var processIdentifier: Int32 { process.processIdentifier }
    /// Whether the child is still running.
    public var isRunning: Bool { process.isRunning }
    /// Everything the child wrote to stderr so far (bounded), trimmed.
    public var stderrText: String { stderrSink.text() }

    /// Spawn `executablePath` with pipes on all three streams.
    ///
    /// - Parameters:
    ///   - executablePath: an absolute path — resolve names with ``ExecutableResolver``.
    ///   - arguments: the child's argv after its name.
    ///   - environment: extra variables merged over the parent's environment.
    ///   - currentDirectory: working directory; nil inherits the parent's.
    /// - Throws: ``ShellError/launchFailed(args:underlying:)`` when the spawn fails.
    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: String? = nil
    ) throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        #if canImport(Darwin)
        // Same rule as TimedShellExecutor (W1.2): no pipe end leaks into the
        // next child we spawn, or a reader can wait on a stranger's copy.
        let pipeEnds = [
            stdinPipe.fileHandleForWriting, stdinPipe.fileHandleForReading,
            stdoutPipe.fileHandleForWriting, stdoutPipe.fileHandleForReading,
            stderrPipe.fileHandleForWriting, stderrPipe.fileHandleForReading,
        ]
        for fd in pipeEnds {
            fcntl(fd.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        #endif

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        if !environment.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in environment { merged[k] = v }
            proc.environment = merged
        }
        if let currentDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        process = proc
        stdinWriter = stdinPipe.fileHandleForWriting
        stdoutReader = stdoutPipe.fileHandleForReading
        stderrReader = stderrPipe.fileHandleForReading

        // Drain stderr from the start: a child may complain before we read.
        let sink = stderrSink
        stderrReader.readabilityHandler = { handle in
            sink.append(handle.availableData)
        }

        do {
            try proc.run()
            launched = true
        } catch {
            stderrReader.readabilityHandler = nil
            tornDown = true   // nothing to reap; deinit must not wait on it
            throw ShellError.launchFailed(args: [executablePath] + arguments, underlying: error.localizedDescription)
        }
    }

    deinit {
        terminate()
    }

    // MARK: Writing

    /// Write `data` followed by a newline to the child's stdin.
    public func sendLine(_ data: Data) throws {
        guard !isTornDown else { throw ShellError.launchFailed(args: [], underlying: "process already terminated") }
        stdinWriter.write(data + Data("\n".utf8))
    }

    /// Write a UTF-8 string followed by a newline to the child's stdin.
    public func sendLine(_ text: String) throws {
        try sendLine(Data(text.utf8))
    }

    // MARK: Reading

    /// Read one line (without its newline) from the child's stdout.
    ///
    /// Waits until a full line arrived, the child closed stdout, or
    /// `deadline` passed — polled, never a bare blocking read, so a child
    /// that holds stdout open and never answers cannot wedge the caller.
    /// - Returns: the line, or nil on EOF or deadline.
    public func readLine(deadline: Date) -> Data? {
        var line = Data()
        let fd = stdoutReader.fileDescriptor
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(min(remaining * 1000, 1000))   // re-test the deadline at least every second
            let ready = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, ms) }
            if ready < 0 { return nil }
            if ready == 0 { continue }

            var byte: UInt8 = 0
            let n = withUnsafeMutableBytes(of: &byte) { Foundation.read(fd, $0.baseAddress, 1) }
            if n <= 0 { break }        // EOF or error
            if byte == 0x0A { break }  // newline
            line.append(byte)
        }
        return line.isEmpty ? nil : line
    }

    /// Same as ``readLine(deadline:)``, decoded as UTF-8.
    public func readLineString(deadline: Date) -> String? {
        readLine(deadline: deadline).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Teardown

    /// Close stdin, SIGTERM, wait ``terminationGrace``, SIGKILL if still
    /// alive, and reap. Idempotent; safe on every exit path.
    public func terminate() {
        lock.lock()
        if tornDown { lock.unlock(); return }
        tornDown = true
        lock.unlock()

        stderrReader.readabilityHandler = nil
        try? stdinWriter.close()
        if launched {
            if process.isRunning {
                process.terminate()                                   // SIGTERM
                let grace = Date().addingTimeInterval(Self.terminationGrace)
                while process.isRunning, Date() < grace {
                    usleep(20_000)
                }
                if process.isRunning {
                    #if canImport(Darwin)
                    Darwin.kill(process.processIdentifier, SIGKILL)   // escalate
                    #endif
                }
            }
            process.waitUntilExit()                                   // reap, always
        }
        try? stdoutReader.close()
        try? stderrReader.close()
    }

    private var isTornDown: Bool {
        lock.lock(); defer { lock.unlock() }
        return tornDown
    }
}

// MARK: - BoundedSink

/// Thread-safe, bounded byte accumulator for a child's stderr.
private final class BoundedSink: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard bytes.count < capacity else { return }
        bytes.append(chunk.prefix(capacity - bytes.count))
    }

    func text() -> String {
        lock.lock()
        let data = bytes
        lock.unlock()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
