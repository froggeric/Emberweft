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
        .executable(name: "emberweft", targets: ["EmberweftCLI"])
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
        // Metal compute renderer (chaos game -> histogram -> density filter -> palette).
        .target(
            name: "FlameRenderer",
            dependencies: ["FlameKit"],
            path: "Sources/FlameRenderer"
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
        // `emberweft` command-line tool (render / animate / validate / info).
        .executableTarget(
            name: "EmberweftCLI",
            dependencies: ["FlameKit", "FlameReference", "FlameRenderer"],
            path: "Sources/EmberweftCLI"
        ),
        .testTarget(
            name: "FlameKitTests",
            dependencies: ["FlameKit"],
            path: "Tests/FlameKitTests"
        )
    ]
)
