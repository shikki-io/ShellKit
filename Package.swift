// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShellKit",
    // `platforms` constrains Apple platforms only — Linux and Windows take no
    // entry here and are gated by CI instead:
    //   * macOS: the local gate, `kagami test --scope ShellKitTests --strict`.
    //   * Linux: `.woodpecker/linux-build.yml` builds AND runs the whole suite,
    //     because signals, pipes and exit detection are exactly where Darwin
    //     and Linux differ.
    //   * Windows: `canImport(WinSDK)` branches exist in InteractiveProcess,
    //     PipeReading and ProcessExit, but NOT ONE OF THEM HAS BEEN COMPILED BY
    //     A WINDOWS TOOLCHAIN. `.woodpecker/windows-build.yml` is committed and
    //     stays dormant until an agent labelled `platform: windows/amd64`
    //     exists. Every such branch is marked `// STATUS: compiles by
    //     inspection, unproven on Windows` and tracked as backlog afb8cd83.
    //     Nothing here, in the README or in the CHANGELOG claims Windows
    //     support until that pipeline is green.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShellKit", targets: ["ShellKit"]),
    ],
    targets: [
        // Leaf package: Foundation only. Zero ShiKit / shikki-monorepo deps.
        // Contains the canonical async subprocess primitives extracted from
        // Sources/ShiKit/Shell/ per features/shellkit-hoist-2026-06-04.md W1.
        .target(name: "ShellKit"),
        .testTarget(
            name: "ShellKitTests",
            dependencies: ["ShellKit"]
        ),
    ]
)
