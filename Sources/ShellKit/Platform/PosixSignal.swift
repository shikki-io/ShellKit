//
//  PosixSignal.swift
//  ShellKit
//
//  Spec c8fa126c W5. ShellKit is AIKit's subprocess primitive, excluded from
//  every non-macOS target by `condition: .when(platforms: [.macOS])` in AIKit's
//  manifest. The stated reason was iOS — `Foundation.Process` does not exist
//  there — but the condition also excluded LINUX, where `Process` does exist.
//
//  Measured 2026-11-15 with the Static Linux SDK: the package was ONE
//  diagnostic away from building for `aarch64-swift-linux-musl`.
//
//      Sources/ShellKit/TimedShellExecutor.swift:286:21:
//      error: cannot find 'Darwin' in scope
//
//  `import Darwin` was correctly guarded by `#if canImport(Darwin)`; the two
//  CALLS through it, `Darwin.kill(...)`, were not. That is the exact shape the
//  spec predicted for this wave — "the likely failure is ShellKit being CALLED
//  where the condition only excluded it at LINK time" — and it is why a
//  manifest condition is not a portability check.
//
//  `Sources/ShellKit/Platform/` is the one subtree where a platform condition
//  may appear, the same rule CoreKit and NetKit now carry.
//

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// `kill(2)`, from whichever libc this target has.
///
/// Unqualified on purpose: `kill` is POSIX and every supported libc module
/// exports it, so the import above is the only thing that needs to know which
/// one. A module-qualified `Darwin.kill` compiles on exactly one platform and
/// reads as if it were a Darwin-specific API, which it is not.
///
/// The result is discarded, as it was at both call sites before this function
/// existed: the only failures `kill` reports are ESRCH (the process is already
/// gone, which is the outcome the caller wanted) and EPERM (it is not ours to
/// kill, which a signal cannot fix). Both call sites check `isRunning` first.
@discardableResult
func posixKill(_ pid: pid_t, _ signal: Int32) -> Int32 {
    kill(pid, signal)
}

/// Escalate to an unconditional kill: the child does not get to run cleanup.
///
/// This exists so that **no call site outside `Platform/` names `SIGKILL`**.
/// `SIGKILL` is a libc constant, so naming it at a call site drags a libc import
/// along with it — and that import is what made the previous author reach for
/// `#if canImport(Darwin)` around the escalation in `InteractiveProcess`, which
/// turned "SIGKILL if still alive" into "nothing at all" on Linux.
///
/// It is also the seam for Windows under operator decision D4 (2026-11-15):
/// there is no `SIGKILL` there, and the equivalent is `TerminateProcess` (with
/// `CTRL_BREAK` first when the child is a console process in its own process
/// group). Same function, one `#if os(Windows)` arm here, and the caller keeps
/// one spelling on every OS.
///
/// Graceful stop is **not** this function and never was: that is
/// `Foundation.Process.terminate()`, which sends `SIGTERM`. Both of this
/// package's call sites try that first, wait out a grace period, and only then
/// call this.
@discardableResult
func hardKill(_ pid: pid_t) -> Int32 {
    posixKill(pid, SIGKILL)
}
