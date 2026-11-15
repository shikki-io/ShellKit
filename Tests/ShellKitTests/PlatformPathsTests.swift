import Foundation
import Testing

@testable import ShellKit

/// `PlatformPaths` exists because the Windows port (spec 8badc87f W31) found
/// path spellings hardcoded in three places: a `/` prefix standing for
/// "absolute", a `:` standing for the `PATH` separator, and a `/` joining a
/// directory to a name. None of the three is right on Windows.
///
/// What these tests can and cannot prove, stated plainly: the suite runs on
/// macOS and on Linux, so they pin the POSIX side and they pin that the
/// refactor did not change it. The `os(Windows)` branches are compiled out
/// here and are NOT covered — they carry
/// `// STATUS: compiles by inspection, unproven on Windows` and backlog
/// afb8cd83 for exactly that reason. Asserting Windows behaviour from a Mac
/// would be a test of this file's own assumptions, not of the platform.
@Suite("PlatformPaths — the separators and the PATH probe")
struct PlatformPathsTests {

    // MARK: - 1. Separators come from the platform

    @Test("the separators are the running platform's, not a literal")
    func separatorsAreThePlatformsOwn() {
        #if os(Windows)
        #expect(PlatformPaths.pathSeparator == "\\")
        #expect(PlatformPaths.searchPathSeparator == ";")
        #else
        #expect(PlatformPaths.pathSeparator == "/")
        #expect(PlatformPaths.searchPathSeparator == ":")
        #endif
    }

    // MARK: - 2. isAbsolute, on this platform

    @Test("a rooted path is absolute and a bare or relative name is not")
    func absolutenessIsDecidedByThePlatform() {
        #if os(Windows)
        #expect(PlatformPaths.isAbsolute("C:\\Windows\\System32\\cmd.exe"))
        #expect(PlatformPaths.isAbsolute("C:/Windows/System32/cmd.exe"))
        #expect(PlatformPaths.isAbsolute("\\\\host\\share\\tool.exe"))
        #expect(!PlatformPaths.isAbsolute("\\drive-relative.exe"))
        #else
        #expect(PlatformPaths.isAbsolute("/bin/sh"))
        #expect(!PlatformPaths.isAbsolute("C:\\Windows\\System32\\cmd.exe"))
        #endif
        #expect(!PlatformPaths.isAbsolute("sh"))
        #expect(!PlatformPaths.isAbsolute("./sh"))
        #expect(!PlatformPaths.isAbsolute(""))
    }

    // MARK: - 3. The PATH probe answers

    @Test("searchPath finds the process PATH")
    func searchPathFindsThePATH() throws {
        let path = try #require(
            PlatformPaths.searchPath(),
            "a test process always runs with a PATH; an empty probe would silently stop every bare-name lookup"
        )
        #expect(!path.isEmpty)
    }

    // MARK: - 4. Executable suffixes

    @Test("the empty suffix comes first, so a name given in full is tried as written")
    func suffixesStartWithTheNameAsGiven() {
        let suffixes = PlatformPaths.executableSuffixes()
        #expect(suffixes.first?.isEmpty == true)
        #if os(Windows)
        #expect(suffixes.count > 1)  // PATHEXT, or the documented default
        #else
        #expect(suffixes == [""])    // mode bits decide; there is no suffix
        #endif
    }

    // MARK: - 5. The refactor did not move ExecutableResolver

    /// `ExecutableResolver` now goes through `PlatformPaths` for all three of
    /// the literals it used to carry. These are the same assertions
    /// `InteractiveProcessTests` makes, kept here as the regression guard for
    /// the refactor itself: if a separator or the absoluteness test is wrong,
    /// every bare-name spawn in the fleet stops resolving.
    @Test("a bare name still resolves through PATH, and nonsense still returns nil")
    func resolverBehaviourIsUnchangedOnPOSIX() {
        #if !os(Windows)
        #expect(ExecutableResolver.resolve("sh", searchPath: "/nonexistent:/bin") == "/bin/sh")
        #expect(ExecutableResolver.resolve("/bin/sh") == "/bin/sh")
        #expect(ExecutableResolver.resolve("definitely-not-a-binary-2026", searchPath: "/bin:/usr/bin") == nil)
        #expect(ExecutableResolver.resolve("/nonexistent/binary") == nil)
        // An empty search path searches nothing — the pre-refactor contract.
        #expect(ExecutableResolver.resolve("sh", searchPath: nil) == nil)
        #endif
    }

    // MARK: - 6. launchPlan keeps its POSIX shape

    /// The `/usr/bin/env` delegation is a measured macOS decision (DYLD_* is
    /// stripped from a SIP-restricted binary's children), so the Windows
    /// branch must not have disturbed it.
    @Test("launchPlan still delegates a bare name to /usr/bin/env on POSIX")
    func launchPlanIsUnchangedOnPOSIX() {
        #if !os(Windows)
        #expect(
            TimedShellExecutor.launchPlan(for: ["true", "--flag"])
                == .init(executable: "/usr/bin/env", arguments: ["true", "--flag"])
        )
        #expect(
            TimedShellExecutor.launchPlan(for: ["/usr/bin/true", "--flag"])
                == .init(executable: "/usr/bin/true", arguments: ["--flag"])
        )
        #endif
    }
}
