import Foundation
import Testing
@testable import ShellKit

/// Spec c8fa126c W5 — the ratchet that keeps ShellKit honest off Apple.
///
/// ## Why this file was rewritten on 2026-11-15
///
/// Its first shape scanned for libc QUALIFIERS (`Darwin.kill`), because that was
/// the shape of the compile error that started the wave. Then the @t panel (run
/// 308f3d72) found two sites where a *portable* call had been re-guarded behind
/// `#if canImport(Darwin)` — no qualifier anywhere, so the scan was green on
/// exactly the defect it existed for. Both arms were empty on Linux: one turned
/// "SIGKILL if still alive" into nothing, the other reinstated the pipe cascade
/// that defeated five PRs.
///
/// Then reconciling `main` into `develop` (#22) showed the second shape was
/// wrong too. It banned EVERY `#if` outside `Platform/`, which this tree cannot
/// satisfy: `main` deliberately carries 16 `#if os(Windows)` branches in
/// `InteractiveProcess`, `PipeReading`, `ProcessExit` and `TimedShellExecutor`,
/// released as 0.6.0 and green on glibc Linux. A rule the tree violates by
/// design is not a ratchet, it is a 42-entry allowance list.
///
/// ## What it bans now, and why exactly this
///
/// BR-L-04 bans **Apple-capability** conditions outside `Platform/`: the ones
/// whose other arm is empty on every non-Apple target, which is what makes a
/// cross build unable to see them. It does NOT ban a POSIX gate naming all its
/// libcs, and it does not ban `os(Windows)`, which is a real second
/// implementation rather than an absent one — operator decision D4 (2026-11-15)
/// says to extend those branches, not replace them. They are tracked in spec
/// c8fa126c as debt to move into `Platform/` when the Windows target is built,
/// one row per file.
///
/// Rule 2 is the hole the reconciliation exposed: a POSIX gate written
/// `canImport(Darwin) || canImport(Glibc)` is **false on musl**, and musl is the
/// only Linux the fleet actually ships (`shi ship --platform linux` produces a
/// static musl binary, decision 7701c618). `v0.6.0` contains zero
/// `canImport(Musl)`, and its Linux CI is native glibc `swift:6.3-jammy`, so
/// nothing in it could see that its entire Linux implementation was absent on
/// the shipping target. Eight gates were widened; one of them,
/// `kernelReportedExitStatus`, could not be widened at all because glibc and
/// musl disagree on `siginfo_t`'s layout — that is what `Platform/PosixWait.swift`
/// is for.
@Suite("ShellKit portability ratchet")
struct ShellKitPortabilityRatchetTests {
    /// The one subtree where a platform condition may appear.
    private static let platformSubtree = "Platform"

    /// A libc module used as a QUALIFIER (`Darwin.kill`) rather than as an
    /// import. The import can be guarded; a qualified call cannot be, short of
    /// wrapping every call site, which is the drift this bans.
    private static let libcQualifiers = ["Darwin.", "Glibc.", "Musl."]

    /// Conditions that are true only on Apple platforms. A block gated on these
    /// alone has an EMPTY other arm everywhere else, which is precisely what no
    /// build — native or cross — can detect.
    private static let appleOnlyTokens = [
        "canImport(Darwin)", "os(macOS)", "os(iOS)", "os(tvOS)", "os(watchOS)", "os(visionOS)",
        "canImport(os)", "canImport(Combine)", "canImport(SwiftUI)",
    ]

    /// Tokens that make a condition a genuine POSIX/second-implementation gate
    /// rather than an Apple-capability one.
    private static let nonAppleTokens = [
        "canImport(Glibc)", "canImport(Musl)", "canImport(WinSDK)", "os(Windows)", "os(Linux)", "os(Android)",
    ]

    // MARK: - Rule 1 — no Apple-capability condition outside Platform/

    @Test("no Apple-capability condition outside Platform/, in Sources OR Tests")
    func noAppleCapabilityConditionsOutsidePlatform() throws {
        var offenders: [String] = []
        for (label, root) in Self.scanRoots() {
            let files = try Self.swiftFiles(under: root).filter { !Self.isInPlatformSubtree($0, root: root) }
            #expect(files.count >= 3, "\(label): scanned too few files — locator drift?")
            for file in files {
                for block in try Self.conditionBlocks(of: file) {
                    let arms = block.arms.joined(separator: " || ")
                    let mentionsApple = Self.appleOnlyTokens.contains { arms.contains($0) }
                    let mentionsOther = Self.nonAppleTokens.contains { arms.contains($0) }
                    // Apple tokens WITH a non-Apple arm is a real two-implementation
                    // gate (`#if canImport(Darwin) ... #elseif canImport(Glibc)`),
                    // which is allowed. Apple tokens ALONE are the defect.
                    if mentionsApple, !mentionsOther {
                        offenders.append("\(label)/\(Self.relative(file, root: root)):\(block.line) \(block.arms[0])")
                    }
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            Apple-capability conditions outside Platform/: \(offenders).
            The other arm is EMPTY on every non-Apple target, so neither a native \
            build nor a cross build can see what it removes — it compiles to \
            nothing and hangs, or silently skips a syscall. Move the call into \
            Platform/ behind a portable function (setCloseOnExec, hardKill, \
            siginfoChildExit) and call it unconditionally.
            """
        )
    }

    // MARK: - Rule 2 — a POSIX gate names musl, or it is not a Linux gate

    @Test("no POSIX gate excludes musl — the only Linux the fleet ships")
    func noPosixGateExcludesMusl() throws {
        var offenders: [String] = []
        for (label, root) in Self.scanRoots() {
            for file in try Self.swiftFiles(under: root) {
                for block in try Self.conditionBlocks(of: file) {
                    let arms = block.arms.joined(separator: " || ")
                    guard arms.contains("canImport(Glibc)"), !arms.contains("canImport(Musl)") else { continue }
                    offenders.append("\(label)/\(Self.relative(file, root: root)):\(block.line) \(block.arms.joined(separator: " / "))")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            gates naming Glibc but not Musl: \(offenders).
            `shi ship --platform linux` produces a STATIC MUSL binary (decision \
            7701c618), so a glibc-only gate is absent on the shipping target. \
            Native-glibc CI cannot see this. If the two libcs disagree on an API's \
            shape rather than its presence — as glibc and musl do on siginfo_t — \
            put one accessor in Platform/ instead of widening the gate.
            """
        )
    }

    // MARK: - Rule 3 — no libc-qualified call anywhere, Sources or Tests

    @Test("no libc-qualified call outside Platform/, in Sources OR Tests")
    func noLibcQualifiedCalls() throws {
        var offenders: [String] = []
        for (label, root) in Self.scanRoots() {
            let files = try Self.swiftFiles(under: root).filter { !Self.isInPlatformSubtree($0, root: root) }
            for file in files {
                for (index, raw) in try Self.lines(of: file).enumerated() {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard !line.hasPrefix("//"), !line.hasPrefix("///"), !line.hasPrefix("import "), !line.contains("libcQualifiers"), !line.contains("appleOnlyTokens") else { continue }
                    for qualifier in Self.libcQualifiers where line.contains(qualifier) {
                        offenders.append("\(label)/\(Self.relative(file, root: root)):\(index + 1) \(line)")
                    }
                }
            }
        }
        // `Tests/` is in scope because the musl cross gate builds the LIBRARY
        // only: `Darwin.kill` sat in TimedShellExecutorTests for months and
        // meant the suite could not compile for Linux at all, which no gate
        // could report. Measured in the L7c container, 2026-11-15.
        #expect(offenders.isEmpty, "libc-qualified calls: \(offenders). Use the Platform/ shim.")
    }

    @Test("no Apple-only framework import anywhere — ShellKit is Foundation plus libc")
    func noAppleFrameworkImports() throws {
        let forbidden = ["os", "SwiftUI", "Combine", "Network", "UIKit", "AppKit", "CryptoKit", "Security", "Metal"]
        var offenders: [String] = []
        for (label, root) in Self.scanRoots() {
            for file in try Self.swiftFiles(under: root) {
                for (index, raw) in try Self.lines(of: file).enumerated() {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix("import ") else { continue }
                    let module = line.dropFirst("import ".count).trimmingCharacters(in: .whitespaces)
                    if forbidden.contains(module) {
                        offenders.append("\(label)/\(Self.relative(file, root: root)):\(index + 1) import \(module)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "Apple-only imports: \(offenders)")
    }

    // MARK: - Rule 4 — the seams exist and name every libc

    @Test("every Platform/ shim guards Darwin, Glibc AND Musl")
    func platformShimsCoverEveryLibc() throws {
        let root = Self.sourcesRoot().appending(path: "Platform", directoryHint: .isDirectory)
        let files = try Self.swiftFiles(under: root)
        #expect(files.count >= 3, "expected PosixSignal, PosixFD and PosixWait in Platform/; found \(files.map(\.lastPathComponent))")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            #expect(text.contains("canImport(Darwin)"), "\(name) omits Darwin")
            #expect(text.contains("canImport(Glibc)"), "\(name) omits glibc, the native-Linux fallback")
            #expect(text.contains("canImport(Musl)"), "\(name) omits musl, what the Static Linux SDK targets")
        }
    }

    /// Signal 0 is the POSIX existence probe: it delivers nothing and only reports
    /// whether the process could be signalled, so this is safe on every target.
    @Test("the escalation seam reaches libc on this platform")
    func escalationSeamIsWired() {
        #expect(posixKill(ProcessInfo.processInfo.processIdentifier, 0) == 0)
        #expect(posixKill(pid_t.max, 0) == -1)
    }

    // MARK: - Scanner

    private static func scanRoots() -> [(String, URL)] {
        let packageRoot = sourcesRoot().deletingLastPathComponent().deletingLastPathComponent()
        return [
            ("Sources", sourcesRoot()),
            ("Tests", packageRoot.appending(path: "Tests", directoryHint: .isDirectory)),
        ]
    }

    private struct ConditionBlock {
        let line: Int
        let arms: [String]
    }

    /// Group `#if` / `#elseif` into one block, so a libc chain is judged by the
    /// union of its arms rather than by its first line. Without this, the head of
    /// `#if canImport(Darwin)` / `#elseif canImport(Glibc)` reads as Apple-only.
    private static func conditionBlocks(of file: URL) throws -> [ConditionBlock] {
        var blocks: [ConditionBlock] = []
        var current: (line: Int, arms: [String])?
        var depth = 0
        for (index, raw) in try lines(of: file).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                depth += 1
                if depth == 1 { current = (index + 1, [String(line.dropFirst(4))]) }
            } else if line.hasPrefix("#elseif "), depth == 1 {
                current?.arms.append(String(line.dropFirst(8)))
            } else if line.hasPrefix("#endif") {
                if depth == 1, let block = current {
                    blocks.append(ConditionBlock(line: block.line, arms: block.arms))
                    current = nil
                }
                depth = max(0, depth - 1)
            }
        }
        return blocks
    }

    private static func sourcesRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path) {
                return dir.appending(path: "Sources/ShellKit", directoryHint: .isDirectory)
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("no Package.swift above \(#filePath)")
    }

    private static func lines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
    }

    private static func relative(_ file: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return file.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count))
    }

    private static func isInPlatformSubtree(_ file: URL, root: URL) -> Bool {
        relative(file, root: root)
            .split(separator: "/", omittingEmptySubsequences: true)
            .contains(Substring(platformSubtree))
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
