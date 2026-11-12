import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

// MARK: - PlatformPaths

/// The path spellings that differ between the platforms this package runs on,
/// named once so no call site carries a literal.
public enum PlatformPaths {
    /// What separates one directory from the next inside a path.
    public static var pathSeparator: Character {
        #if os(Windows)
        return "\\"
        #else
        return "/"
        #endif
    }

    /// What separates one directory from the next inside `PATH`.
    /// `:` everywhere but Windows, where a path can contain a colon (`C:`).
    public static var searchPathSeparator: Character {
        #if os(Windows)
        return ";"
        #else
        return ":"
        #endif
    }

    /// Whether `path` names a location on its own, needing no `PATH` lookup.
    ///
    /// POSIX: a leading `/`. Windows: a drive-qualified path (`C:\tools\x.exe`,
    /// and `C:/tools/x.exe`, which every Windows API accepts) or a UNC share
    /// (`\\host\share\x.exe`). A bare `\x.exe` is drive-relative, not absolute.
    public static func isAbsolute(_ path: String) -> Bool {
        #if os(Windows)
        // STATUS: compiles by inspection, unproven on Windows (backlog afb8cd83)
        if path.hasPrefix("\\\\") || path.hasPrefix("//") { return true }  // UNC
        let chars = Array(path)
        guard chars.count >= 3, chars[0].isLetter, chars[1] == ":" else { return false }
        return chars[2] == "\\" || chars[2] == "/"
        #else
        return path.hasPrefix("/")
        #endif
    }

    /// The process `PATH`.
    ///
    /// Windows environment names are case-insensitive and the block usually
    /// spells this one `Path`, while `ProcessInfo.environment` is an ordinary
    /// case-sensitive Swift dictionary — so a plain `environment["PATH"]`
    /// subscript finds nothing there. This asks the way each platform answers.
    public static func searchPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["PATH"] { return path }
        #if os(Windows)
        // STATUS: compiles by inspection, unproven on Windows (backlog afb8cd83)
        return environment.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value
        #else
        return nil
        #endif
    }

    /// The suffixes a bare name may acquire before it names a program.
    ///
    /// POSIX: none — an executable is executable by its mode bits. Windows:
    /// the ones in `PATHEXT`, which is how `where.exe` and every shell find
    /// `git` when the file on disk is `git.exe`. The empty string is first, so
    /// a name given with its extension is still tried as written.
    public static func executableSuffixes() -> [String] {
        #if os(Windows)
        // STATUS: compiles by inspection, unproven on Windows (backlog afb8cd83)
        let environment = ProcessInfo.processInfo.environment
        let pathext = environment.first { $0.key.caseInsensitiveCompare("PATHEXT") == .orderedSame }?.value
            ?? ".COM;.EXE;.BAT;.CMD"
        let suffixes = pathext
            .split(separator: searchPathSeparator)
            .map(String.init)
            .filter { !$0.isEmpty }
        return [""] + suffixes
        #else
        return [""]
        #endif
    }
}

// MARK: - ExecutableResolver

/// Resolves an executable name to an absolute path the way a shell would —
/// so no consumer has to hand-roll the `PATH` probe (shikki-chat-mcp#5,
/// `ChildMCPToolCaller.swift:121`).
public enum ExecutableResolver {
    /// - Parameters:
    ///   - name: an absolute path (returned as-is when executable) or a bare
    ///     name looked up in `searchPath`. On Windows a bare name is also
    ///     tried with each `PATHEXT` suffix, so `git` finds `git.exe`.
    ///   - searchPath: the platform's `PATH`-style list — colon-separated on
    ///     POSIX, semicolon-separated on Windows; the process `PATH` by default.
    /// - Returns: the absolute path, or nil when nothing executable matches.
    public static func resolve(
        _ name: String,
        searchPath: String? = PlatformPaths.searchPath()
    ) -> String? {
        let fm = FileManager.default
        let suffixes = PlatformPaths.executableSuffixes()

        if PlatformPaths.isAbsolute(name) {
            return suffixes
                .map { name + $0 }
                .first { fm.isExecutableFile(atPath: $0) }
        }

        let separator = PlatformPaths.pathSeparator
        for dir in (searchPath ?? "").split(separator: PlatformPaths.searchPathSeparator) where !dir.isEmpty {
            for suffix in suffixes {
                let candidate = "\(dir)\(separator)\(name)\(suffix)"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
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
///   `waitUntilExit` so no zombie is left behind, on every path. On Windows
///   there are no signals, so both steps are `TerminateProcess` — see
///   ``Process/forceKill()``.
public final class InteractiveProcess: @unchecked Sendable {
    /// How long SIGTERM gets before SIGKILL.
    public static let terminationGrace: TimeInterval = 2.0
    /// How much of the child's stderr is kept (the tail is what matters).
    public static let stderrCapacity = 64 * 1024

    private let process: Process
    private let stdinWriter: FileHandle
    private let stdoutReader: FileHandle
    private let stderrReader: FileHandle
    private let stderrPump: PipePump
    private let stderrSink = BoundedSink(capacity: InteractiveProcess.stderrCapacity)
    private let lock = NSLock()
    private var tornDown = false
    /// Set once `run()` succeeded. `waitUntilExit()` on a Process that never
    /// launched blocks forever — the first version of this type hung the
    /// whole test bundle from `deinit` after a failed spawn.
    private var launched = false
    #if os(Windows)
    /// Built once: on Windows every `FileHandle.fileDescriptor` allocates a
    /// fresh CRT descriptor over the same handle.
    private let stdoutWindowsReader: WindowsPipeReader?
    #endif

    /// The spawned child's pid.
    public var processIdentifier: Int32 { process.processIdentifier }
    /// Whether the child is still running.
    public var isRunning: Bool { !process.hasExited }
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
        #if canImport(Darwin) || canImport(Glibc)
        // Same rule as TimedShellExecutor (W1.2): no pipe end leaks into the
        // next child we spawn, or a reader can wait on a stranger's copy.
        //
        // Windows needs no equivalent: handles are not inherited unless a
        // spawn asks for them, and Foundation's `Process` passes the three it
        // wires explicitly rather than handing over everything open.
        let pipeEnds = [
            stdinPipe.fileHandleForWriting, stdinPipe.fileHandleForReading,
            stdoutPipe.fileHandleForWriting, stdoutPipe.fileHandleForReading,
            stderrPipe.fileHandleForWriting, stderrPipe.fileHandleForReading,
        ]
        for fd in pipeEnds {
            _ = fcntl(fd.fileDescriptor, F_SETFD, FD_CLOEXEC)
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
        #if os(Windows)
        stdoutWindowsReader = WindowsPipeReader(stdoutPipe.fileHandleForReading)
        #endif

        // Drain stderr from the start: a child may complain before we read.
        let sink = stderrSink
        stderrPump = PipePump(handle: stderrReader, onChunk: { sink.append($0) }, onEnd: {})
        stderrPump.start()

        do {
            try proc.run()
            launched = true
        } catch {
            stderrPump.stop(waiting: true)
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
        #if canImport(Darwin) || canImport(Glibc)
        return readLinePOSIX(deadline: deadline)
        #elseif os(Windows)
        return readLineWindows(deadline: deadline)
        #else
        return nil
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    /// `poll` for readability, then one byte: a line reader must not consume
    /// the byte after the newline, so it cannot read in blocks.
    private func readLinePOSIX(deadline: Date) -> Data? {
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
    #endif

    #if os(Windows)
    /// STATUS: compiles by inspection, unproven on Windows (backlog afb8cd83)
    ///
    /// Same byte-at-a-time shape as the POSIX path, for the same reason. What
    /// differs is the wait: Windows cannot block on a pipe until it is
    /// readable, so a peek that finds nothing sleeps a slice instead, bounded
    /// by whatever is left of the caller's deadline.
    private func readLineWindows(deadline: Date) -> Data? {
        guard let reader = stdoutWindowsReader else { return nil }
        var line = Data()
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }

            let (byte, endOfFile) = reader.readByte()
            guard let byte else {
                if endOfFile { break }                                  // EOF
                Thread.sleep(forTimeInterval: min(remaining, 0.005))
                continue
            }
            if byte == 0x0A { break }  // newline
            line.append(byte)
        }
        return line.isEmpty ? nil : line
    }
    #endif

    /// Same as ``readLine(deadline:)``, decoded as UTF-8.
    public func readLineString(deadline: Date) -> String? {
        readLine(deadline: deadline).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Teardown

    /// Close stdin, ask the child to stop, wait ``terminationGrace``, kill it
    /// if still alive, and reap. Idempotent; safe on every exit path.
    public func terminate() {
        lock.lock()
        if tornDown { lock.unlock(); return }
        tornDown = true
        lock.unlock()

        stderrPump.stop(waiting: true)  // no read can race the close() below
        try? stdinWriter.close()
        if launched {
            if !process.hasExited {
                process.terminate()                                   // SIGTERM (POSIX)
                let grace = Date().addingTimeInterval(Self.terminationGrace)
                while !process.hasExited, Date() < grace {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if !process.hasExited {
                    process.forceKill()                               // escalate
                }
            }
            _ = process.waitForExit()                                 // reap, always
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
