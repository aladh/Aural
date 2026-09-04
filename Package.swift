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
        // Vendored stb_vorbis (public domain / MIT, pinned in Vendor/stb_vorbis/UPSTREAM.md).
        // stb_vorbis.c is excluded from `sources`: it is compiled once via #include inside
        // stb_vorbis_impl.c, and compiling it a second time as its own source file would
        // duplicate every symbol it defines.
        .target(
            name: "CVorbis",
            path: "Vendor/stb_vorbis",
            exclude: ["UPSTREAM.md", "LICENSE", "stb_vorbis.c"],
            sources: ["stb_vorbis_impl.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("STB_VORBIS_NO_STDIO"),
                .unsafeFlags(["-Wno-everything"]),
            ]
        ),
        .target(
            name: "AuralCore",
            dependencies: ["AuralDomain", "AuralPlaybackCore", "CVorbis"],
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
