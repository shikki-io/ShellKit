//
//  PosixFD.swift
//  ShellKit
//
//  Spec c8fa126c W5, second pass. The @t panel (run 308f3d72) found that W5's
//  first pass fixed the COMPILE error and left the BEHAVIOUR guarded:
//
//      Sources/ShellKit/TimedShellExecutor.swift:204-209   (before this commit)
//      #if canImport(Darwin)
//          fcntl(stdoutPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
//          ...
//      #endif
//
//  On Linux that arm is EMPTY, so no pipe end gets FD_CLOEXEC — and the comment
//  sitting on top of it names exactly what that costs: it is the root cause that
//  defeated PRs #585 -> #596 -> #657 -> #714 -> #719. corelibs-foundation's
//  `Pipe` does not set O_CLOEXEC either, so the cascade hang was reintroduced on
//  Linux by the very guard that documented it.
//
//  WHY A CROSS BUILD CANNOT SEE THIS. `#if canImport(Darwin)` around a portable
//  call compiles perfectly for musl: the compiler simply takes the other arm,
//  which is empty. Exit 0, no diagnostic, hang at run time. Spec §0.6 says "a
//  cross build cannot see a guarded Apple IMPORT"; this is one level deeper, a
//  guarded Apple BEHAVIOUR, and it is why L7c runs the suite on Linux for real.
//
//  WHY THIS LIVES IN Platform/. Two reasons, and the second is the durable one:
//    1. `Sources/ShellKit/Platform/` is the one subtree where a platform
//       condition may appear (BR-L-04, by PATH never by filename), so the libc
//       import belongs here and the call sites stay unconditional.
//    2. Windows has no `FD_CLOEXEC`. Handle inheritance is a property of the
//       handle (`SetHandleInformation` with `HANDLE_FLAG_INHERIT`, or an
//       explicit `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` on the spawn). That is a
//       different mechanism, not a different spelling, so it needs a seam — and
//       this is the seam. Operator decision D4 (2026-11-15) sets the same shape
//       for process stop: one API on every OS, the platform branch at the
//       Platform/DI seam, and the result reported honestly.
//

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Mark a file descriptor close-on-exec, so it is not inherited by any child we
/// spawn after this point.
///
/// This is what keeps `readDataToEndOfFile()` on child N's pipe from waiting on
/// children N+1… to close their inherited copy of the write end. Without it, one
/// slow sibling holds the reader open and the parent blocks on EOF that can
/// never arrive.
///
/// Unqualified `fcntl` on purpose, for the reason `posixKill` documents: a
/// module-qualified `Darwin.fcntl` compiles on exactly one platform and reads as
/// Darwin-specific API, which is the misreading that produced both of these
/// defects.
///
/// - Returns: `true` when the flag was set. The result is `@discardableResult`
///   because the call sites cannot act on a failure — a pipe end that refuses
///   `F_SETFD` is a descriptor we did not open — but it is returned rather than
///   swallowed so a test can assert the syscall actually happened.
@discardableResult
func setCloseOnExec(_ fd: Int32) -> Bool {
    fcntl(fd, F_SETFD, FD_CLOEXEC) != -1
}
