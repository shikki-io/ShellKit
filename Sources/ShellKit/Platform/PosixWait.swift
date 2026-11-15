//
//  PosixWait.swift
//  ShellKit
//
//  Spec c8fa126c W5, musl pass. `ProcessExit.kernelReportedExitStatus` probes a
//  zombie with `waitid(WNOWAIT)` so Foundation can still reap it — the Linux fix
//  that #15 shipped. Its gate was `#if canImport(Glibc)`, which is FALSE on the
//  static musl triple `shi ship --platform linux` produces (decision 7701c618),
//  so on that target the whole probe compiled to `return nil` and the exit was
//  never observed.
//
//  Widening the gate to musl is NOT enough, and that is the finding: the two
//  libcs disagree on the LAYOUT of the struct, not merely on whether it exists.
//  Measured 2026-11-15 against the Static Linux SDK's own header
//  (musl-1.2.5.sdk/<arch>/usr/include/signal.h:147):
//
//      glibc:  info._sifields._sigchld.si_pid
//      musl:   info.__si_fields.__si_common.__first.__piduid.si_pid
//
//  `si_pid` and `si_status` are C MACROS in musl, so Swift's importer never
//  exposes them and the member path has to be spelled out. The first attempt at
//  this change simply added `|| canImport(Musl)` to the gate and failed with
//
//      ProcessExit.swift:34:20: error: value of type 'siginfo_t'
//        has no member '_sifields'
//
//  which is exactly why one portable accessor belongs here rather than a wider
//  condition at the call site: the call site wants a (pid, status) pair, and
//  three platforms spell that pair three ways.
//
//  Windows: `waitid` has no equivalent and needs none — `ProcessExit` reaches
//  the same answer through `GetExitCodeProcess` on its own branch, which is why
//  this file has no `os(Windows)` arm. Operator decision D4 (2026-11-15) keeps
//  that shape: one portable question, a platform answer at this seam.
//

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)

    /// The child pid and exit status carried by a `SIGCHLD` `siginfo_t`, as filled
    /// by `waitid(2)`.
    ///
    /// - Returns: `nil` when the struct describes no child (`si_pid == 0`), which
    ///   is how `waitid(WNOHANG)` reports "nothing to see yet".
    func siginfoChildExit(_ info: siginfo_t) -> (pid: pid_t, status: Int32)? {
        #if canImport(Darwin)
            // Darwin's siginfo_t is flat: si_pid and si_status are real members.
            let pid = info.si_pid
            let status = info.si_status
        #elseif canImport(Glibc)
            let pid = info._sifields._sigchld.si_pid
            let status = info._sifields._sigchld.si_status
        #elseif canImport(Musl)
            // The macro paths from signal.h, spelled out because Swift cannot see
            // a C macro.
            let pid = info.__si_fields.__si_common.__first.__piduid.si_pid
            let status = info.__si_fields.__si_common.__second.__sigchld.si_status
        #endif
        guard pid != 0 else { return nil }
        return (pid, status)
    }

#endif
