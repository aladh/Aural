// swift-tools-version: 6.3

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
            exclude: [
                "AGENTS.md",
                "Spotify/AGENTS.md",
                "Views/AGENTS.md",
            ],
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
        .target(
            name: "AuralDomain",
            path: "Sources/AuralDomain",
            exclude: ["AGENTS.md"]
        ),
        // Shared check CLI selection only. Not a CheckRunner/waitUntil library.
        .target(
            name: "AuralCheckSelection",
            path: "Sources/AuralCheckSelection"
        ),
        .executableTarget(
            name: "AuralChecks",
            dependencies: ["AuralDomain", "AuralCheckSelection"],
            exclude: [
                "AGENTS.md",
                "DeferredBoundaryChecks",
            ]
        ),
        .executableTarget(
            name: "AuralBoundaryChecks",
            dependencies: ["AuralCore", "AuralCheckSelection"],
            path: "Sources/AuralChecks/DeferredBoundaryChecks",
            resources: [.copy("Fixtures")]
        ),
    ]
)
