# Changelog

Releases before 0.6.0 were tagged without a changelog; `git log v0.5.0..v0.5.1`
and the tags themselves are the record for those.

## 0.6.0 — unreleased

Additive. No existing public API changed, so no consumer needs a source change.

### Added

- `PlatformPaths` — the path spellings that differ per platform, named once so
  no call site carries a literal: `pathSeparator`, `searchPathSeparator`,
  `isAbsolute(_:)`, `searchPath()`, `executableSuffixes()`.
- `canImport(WinSDK)` branches in `InteractiveProcess`, `PipeReading` and
  `ProcessExit`, plus the `DetachedProcess` and `TimedShellExecutor` call sites
  that reached for POSIX directly. The package previously could not compile on
  Windows at all: every platform branch tested `canImport(Darwin)` or
  `canImport(Glibc)`, and neither module exists there.
  - `Process.forceKill()` names the final escalation step once —
    `SIGKILL` on POSIX, `OpenProcess` + `TerminateProcess` on Windows.
  - `WindowsPipeReader` reads a pipe without blocking via `PeekNamedPipe`,
    which is what lets `PipePump.stop(waiting:)` keep promising that no read is
    in flight when the caller closes the descriptor. Windows has neither
    `poll(2)` for pipes nor `O_NONBLOCK`.
  - `PipePump` uses the Linux thread shape on Windows. A dispatch read source
    is not an option there: libdispatch's Windows port backs those with
    sockets, not anonymous pipes.
  - `ExecutableResolver` resolves through `PATHEXT` on Windows, so `git` finds
    `git.exe`, and reads `PATH` case-insensitively (the Windows environment
    block spells it `Path`, and `ProcessInfo.environment` is an ordinary
    case-sensitive dictionary).
  - `TimedShellExecutor.launchPlan` no longer routes a bare name through
    `/usr/bin/env` on Windows, which has no such binary; it resolves the name
    instead. POSIX behaviour is byte-for-byte unchanged.

### Platform status

| Platform | State |
|---|---|
| macOS | proven — `kagami test --scope ShellKitTests --strict` |
| Linux | proven — `.woodpecker/linux-build.yml`, build and full suite |
| Windows | **NOT SUPPORTED YET.** The branches exist and are marked `// STATUS: compiles by inspection, unproven on Windows`. No Windows toolchain has compiled them and no test has run on Windows. `.woodpecker/windows-build.yml` is committed but dormant: it needs an agent labelled `platform: windows/amd64`, and none is registered. Backlog afb8cd83. |

Two Windows gaps are documented in code rather than worked around:

1. `forceKill()` terminates the child, not its tree. A tree kill needs the
   child assigned to a Job Object at creation time, and Foundation's `Process`
   owns the spawn and exposes no hook for it.
2. The pipe reader assumes `_get_osfhandle` round-trips the descriptor that
   swift-corelibs-foundation produced from its HANDLE through
   `_open_osfhandle`. That assumption is unverified.

### Changed

- The short blocking waits in the teardown loops are `Thread.sleep` rather than
  `usleep`, which has no Windows equivalent. Same durations, same behaviour.
