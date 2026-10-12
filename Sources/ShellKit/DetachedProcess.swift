import Foundation

// MARK: - DetachedProcess
//
// The fire-and-forget half of the subprocess seam.
//
// `TimedShellExecutor.run` waits for the child and collects its output;
// `InteractiveProcess` speaks to it line by line over pipes. Neither fits the
// third shape every dispatcher needs: start a long-running command, do NOT
// wait for it, and keep a handle so it can be reaped later.
//
// Why it could not be built on the other two (shikki#1789, operator review
// 2026-10-12 "is it normal to not use ShellKit here?"): a dispatched agent
// prints megabytes. Any primitive that pipes stdout and does not drain it
// blocks the child once the 64 KiB pipe buffer fills, so the agent wedges
// mid-run. A detached child's output must go to a file or to /dev/null,
// never to a pipe nobody reads. Lacking that, three shikki dispatchers each
// hand-rolled `Process()` behind a bypass exemption and lost the timeout, the
// stderr and — in two of them — the exit code.
//
// What this type guarantees:
//   * the child's pid is available, so a tracker can SIGTERM it on session
//     exit (shikki's `KernelSubprocessTracker` had to read it off a raw
//     `Process` for exactly this reason);
//   * output lands where the caller said: discarded, or appended to a file;
//   * `terminate()` is SIGTERM → grace → SIGKILL, like `InteractiveProcess`;
//   * `exitCode()` awaits the child without blocking a thread, so a caller
//     that DOES want the result can have it without a second primitive.

/// Where a detached child's stdout and stderr go. Never a pipe: nobody is
/// reading one, and a full pipe stops the child.
public enum DetachedOutput: Sendable, Equatable {
    /// `/dev/null` — the dispatcher only cares that the child started.
    case discard
    /// Appended to this file, created if absent. Both streams, one file, so
    /// the interleaving the operator reads matches what the child printed.
    case file(URL)
}

/// A child started and deliberately not awaited.
public final class DetachedProcess: @unchecked Sendable {
    /// How long SIGTERM gets before SIGKILL. Same contract as ``InteractiveProcess``.
    public static let terminationGrace: TimeInterval = 2.0

    private let process: Process
    private let lock = NSLock()
    private var reaped = false

    /// The spawned child's pid. Zero only if the spawn threw.
    public var processIdentifier: Int32 { process.processIdentifier }

    /// Whether the child is still running.
    public var isRunning: Bool { process.isRunning }

    /// Spawn `args` and return without waiting.
    ///
    /// - Parameters:
    ///   - args: argv. The first element is the executable: an absolute path is
    ///     exec'd directly, a bare name is resolved through ``ExecutableResolver``
    ///     against `PATH`. There is no shell, so no element is ever re-parsed —
    ///     a path with a space or a `$(…)` is an argument, not a command.
    ///   - environment: extra variables merged over the parent's environment.
    ///   - currentDirectory: working directory; nil inherits the parent's.
    ///   - output: where stdout and stderr go (``DetachedOutput``).
    /// - Throws: ``ShellError/launchFailed(args:underlying:)`` when argv is
    ///   empty, the executable cannot be resolved, the output file cannot be
    ///   opened, or `posix_spawn` fails.
    public init(
        _ args: [String],
        environment: [String: String] = [:],
        currentDirectory: String? = nil,
        output: DetachedOutput = .discard
    ) throws {
        let executable = try Self.resolveExecutable(args)
        let sink = try Self.openSink(output, args: args)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = Array(args.dropFirst())
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = sink
        proc.standardError = sink
        proc.environment = Self.mergedEnvironment(environment)
        if let currentDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        process = proc

        defer {
            // Our copy of a file's write end is not the child's: close it so the
            // handle is not held for the child's whole life. nullDevice is shared.
            if case .file = output { try? sink.close() }
        }
        do {
            try proc.run()
        } catch {
            throw ShellError.launchFailed(args: args, underlying: "\(error)")
        }
    }

    // MARK: - Spawn inputs, one decision each

    /// An absolute `args[0]` is exec'd as given; a bare name is looked up on
    /// `PATH` through ``ExecutableResolver``. Empty argv is a caller error.
    private static func resolveExecutable(_ args: [String]) throws -> String {
        guard let name = args.first, !name.isEmpty else {
            throw ShellError.launchFailed(args: args, underlying: "empty argv")
        }
        if name.hasPrefix("/") { return name }
        guard let found = ExecutableResolver.resolve(name) else {
            throw ShellError.launchFailed(args: args, underlying: "\(name) not found on PATH")
        }
        return found
    }

    /// The handle both streams are pointed at. Never a pipe — see the type's note.
    private static func openSink(_ output: DetachedOutput, args: [String]) throws -> FileHandle {
        switch output {
        case .discard:
            return FileHandle.nullDevice
        case .file(let url):
            let fm = FileManager.default
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                throw ShellError.launchFailed(
                    args: args, underlying: "cannot open \(url.path) for writing")
            }
            handle.seekToEndOfFile()
            return handle
        }
    }

    /// Extra variables merged over the parent's environment, or nil to inherit
    /// it unchanged (a non-nil `environment` on `Process` replaces it wholly).
    private static func mergedEnvironment(_ extra: [String: String]) -> [String: String]? {
        guard !extra.isEmpty else { return nil }
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in extra { merged[key] = value }
        return merged
    }

    /// The child's exit code, awaited without blocking a cooperative thread.
    /// Returns immediately once the child has already exited.
    public func exitCode() async -> Int32 {
        if !process.isRunning { return process.terminationStatus }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [process] in
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    /// SIGTERM, a grace period, then SIGKILL. Idempotent: a second call on an
    /// exited child does nothing.
    public func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped else { return }
        reaped = true
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(Self.terminationGrace)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
