// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Aural",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Aural", targets: ["AuralApp"]),
        .library(name: "AuralCore", targets: ["AuralCore"]),
        .library(name: "AuralDomain", targets: ["AuralDomain"]),
        .executable(name: "AuralChecks", targets: ["AuralChecks"]),
        .executable(name: "AuralBoundaryChecks", targets: ["AuralBoundaryChecks"]),
    ],
    targets: [
        .systemLibrary(
            name: "AuralPlaybackCore",
            path: "Sources/AuralPlaybackCore"
        ),
        .target(
            name: "AuralCore",
            dependencies: ["AuralDomain", "AuralPlaybackCore"],
            path: "Sources/Aural",
            linkerSettings: [
                .unsafeFlags(["-LBackend/lib"]),
                .linkedLibrary("aural_playback"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "AuralApp",
            dependencies: ["AuralCore"],
            path: "Sources/AuralApp"
        ),
        .target(name: "AuralDomain"),
        .executableTarget(
            name: "AuralChecks",
            dependencies: ["AuralDomain"],
            exclude: [
                "DeferredBoundaryChecks",
                "LegacyLogicChecks.swift",
            ]
        ),
        .executableTarget(
            name: "AuralBoundaryChecks",
            dependencies: ["AuralCore"],
            path: "Sources/AuralChecks/DeferredBoundaryChecks",
            exclude: ["README.md"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
