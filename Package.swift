// swift-tools-version: 6.2
// Emberweft — a native macOS, Apple-Silicon fractal-flame renderer.
// Source-available under PolyForm Noncommercial 1.0.0 (see LICENSE).

import PackageDescription

let package = Package(
    name: "emberweft",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "FlameKit", targets: ["FlameKit"]),
        .library(name: "FlameReference", targets: ["FlameReference"]),
        .library(name: "FlameRenderer", targets: ["FlameRenderer"]),
        .library(name: "FlamePlayer", targets: ["FlamePlayer"]),
        .library(name: "FlameExport", targets: ["FlameExport"]),
        .executable(name: "emberweft", targets: ["EmberweftApp"])
    ],
    targets: [
        // Core genome model + .flam3 parsing/interpolation (no Metal).
        .target(
            name: "FlameKit",
            path: "Sources/FlameKit"
        ),
        // CPU reference renderer: parity oracle, deterministic offline renderer, fallback.
        .target(
            name: "FlameReference",
            dependencies: ["FlameKit"],
            path: "Sources/FlameReference"
        ),
        // Metal compute renderer (chaos game -> histogram -> density filter ->
        // display pipeline). Production path depends on FlameKit only.
        .target(
            name: "FlameRenderer",
            dependencies: ["FlameKit"],
            path: "Sources/FlameRenderer",
            exclude: ["Metal"],
            resources: [.copy("Metal")]
        ),
        // Realtime adaptive playback engine.
        .target(
            name: "FlamePlayer",
            dependencies: ["FlameRenderer", "FlameKit"],
            path: "Sources/FlamePlayer"
        ),
        // AVFoundation offline/long-form export.
        .target(
            name: "FlameExport",
            dependencies: ["FlameRenderer", "FlameKit"],
            path: "Sources/FlameExport"
        ),
        // Testable `emberweft` CLI engine library (render / validate / info).
        .target(
            name: "EmberweftCLI",
            dependencies: ["FlameKit", "FlameReference", "FlameRenderer"],
            path: "Sources/EmberweftCLI"
        ),
        // `emberweft` executable — thin wrapper over the EmberweftCLI library.
        .executableTarget(
            name: "EmberweftApp",
            dependencies: ["EmberweftCLI"],
            path: "Sources/EmberweftApp"
        ),
        .testTarget(
            name: "FlameKitTests",
            dependencies: ["FlameKit"],
            path: "Tests/FlameKitTests"
        ),
        .testTarget(
            name: "FlameReferenceTests",
            dependencies: ["FlameReference", "FlameKit"],
            path: "Tests/FlameReferenceTests"
        ),
        .testTarget(
            name: "FlameRendererTests",
            dependencies: ["FlameRenderer", "FlameReference", "FlameKit"],
            path: "Tests/FlameRendererTests"
        ),
        .testTarget(
            name: "EmberweftCLITests",
            dependencies: ["EmberweftCLI", "FlameKit", "FlameReference", "FlameRenderer"],
            path: "Tests/EmberweftCLITests"
        ),
        .testTarget(
            name: "FlamePlayerTests",
            dependencies: ["FlamePlayer", "FlameRenderer", "FlameReference", "FlameKit"],
            path: "Tests/FlamePlayerTests"
        )
    ]
)
