// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Spotty",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Spotty", targets: ["SpottyApp"]),
        .library(name: "SpottyCore", targets: ["SpottyCore"]),
        .library(name: "SpottyDomain", targets: ["SpottyDomain"]),
    ],
    targets: [
        .target(
            name: "SpottyPlaybackCore",
            path: "Sources/SpottyPlaybackCore",
            exclude: ["AGENTS.md"],
            sources: ["spotty_playback_shim.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "SpottyCore",
            dependencies: ["SpottyDomain", "SpottyPlaybackCore"],
            path: "Sources/Spotty",
            exclude: [
                "AGENTS.md",
                "Spotify/AGENTS.md",
                "Views/AGENTS.md",
            ],
            linkerSettings: [
                .unsafeFlags(["-LBackend/lib"]),
                .linkedLibrary("spotty_playback"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "SpottyApp",
            dependencies: ["SpottyCore"],
            path: "Sources/SpottyApp"
        ),
        .target(
            name: "SpottyDomain",
            path: "Sources/SpottyDomain",
            exclude: ["AGENTS.md"]
        ),
        .testTarget(
            name: "SpottyDomainTests",
            dependencies: ["SpottyDomain"],
            path: "Tests/SpottyDomainTests"
        ),
        .testTarget(
            name: "SpottyBoundaryTests",
            dependencies: ["SpottyCore"],
            path: "Tests/SpottyBoundaryTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
