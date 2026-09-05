// swift-tools-version: 6.3

import Foundation
import PackageDescription

private let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let playbackManifestURL =
    packageRoot
    .appendingPathComponent("Backend")
    .appendingPathComponent("spotty-playback")
    .appendingPathComponent("artifact-manifest.json")

// BEGIN GENERATED PLAYBACK ARTIFACT PIN. Run Backend/spotty-playback/update-artifact-manifest.sh
// after publishing a new immutable XCFramework; keep this block synchronized with the manifest.
private let generatedPlaybackArtifactURL =
    "https://github.com/aladh/Spotty/releases/download/spotty-playback-core-5a45cacc6a9921418f60214d26eebabeb54d45c662025c0a4f3a3e5d84df4675/SpottyPlaybackCore.xcframework.zip"
private let generatedPlaybackArtifactChecksum = "c6e5a528bf4eb5a500a31c5a8f2b024ab199cd4efb849f5a6542701e25e3ed2c"
// END GENERATED PLAYBACK ARTIFACT PIN

private struct PlaybackTargetSelection {
    let target: Target
}

private func pathRelativeToPackageRoot(_ url: URL) -> String {
    let baseComponents = packageRoot.standardizedFileURL.pathComponents
    let targetComponents = url.standardizedFileURL.pathComponents
    var commonCount = 0
    while commonCount < baseComponents.count,
        commonCount < targetComponents.count,
        baseComponents[commonCount] == targetComponents[commonCount]
    {
        commonCount += 1
    }
    let parentComponents = Array(repeating: "..", count: baseComponents.count - commonCount)
    let childComponents = Array(targetComponents.dropFirst(commonCount))
    return (parentComponents + childComponents).joined(separator: "/")
}

private func manifestString(
    _ key: String,
    from manifest: [String: Any],
    context: String = "artifact manifest"
) -> String {
    guard let value = manifest[key] as? String, !value.isEmpty else {
        fatalError("\(context) is missing a non-empty \(key) string")
    }
    return value
}

private func remotePlaybackTarget() -> PlaybackTargetSelection {
    guard
        let data = try? Data(contentsOf: playbackManifestURL),
        let object = try? JSONSerialization.jsonObject(with: data),
        let manifest = object as? [String: Any],
        let artifact = manifest["artifact"] as? [String: Any]
    else {
        fatalError("Unable to read playback artifact manifest at \(playbackManifestURL.path)")
    }

    let urlString = manifestString("url", from: artifact, context: "playback artifact")
    guard
        let url = URL(string: urlString),
        url.scheme == "https",
        url.host != nil,
        url.query == nil,
        url.fragment == nil
    else {
        fatalError("Playback artifact URL must be an immutable HTTPS URL without query or fragment")
    }

    let checksum = manifestString("checksum", from: artifact, context: "playback artifact")
    guard checksum.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
        fatalError("Playback artifact checksum must be a 64-character SHA-256 hex string")
    }
    guard checksum.range(of: "^0{64}$", options: .regularExpression) == nil else {
        fatalError("Playback artifact checksum is still the placeholder value")
    }
    guard
        urlString == generatedPlaybackArtifactURL,
        checksum.lowercased() == generatedPlaybackArtifactChecksum.lowercased()
    else {
        fatalError(
            "artifact-manifest.json is out of sync with the generated Package.swift playback pin"
        )
    }

    return PlaybackTargetSelection(
        target: .binaryTarget(name: "SpottyPlaybackCore", url: urlString, checksum: checksum)
    )
}

private func playbackTarget() -> PlaybackTargetSelection {
    guard let override = ProcessInfo.processInfo.environment["SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK"] else {
        return remotePlaybackTarget()
    }

    let url = URL(fileURLWithPath: override, relativeTo: packageRoot).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        fatalError("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK must point to an existing XCFramework directory")
    }
    guard url.pathExtension == "xcframework" else {
        fatalError("SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK must point to a .xcframework directory")
    }
    let provenanceURL = url.appendingPathComponent("spotty_playback_provenance.json")
    guard
        let data = try? Data(contentsOf: provenanceURL),
        let object = try? JSONSerialization.jsonObject(with: data),
        let provenance = object as? [String: Any],
        let source = provenance["source"] as? [String: Any]
    else {
        fatalError(
            "SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK must contain spotty_playback_provenance.json"
        )
    }
    let sourceDigest = manifestString(
        "engineInputDigest",
        from: source,
        context: "playback provenance source"
    )
    let libraryDigest = manifestString(
        "librarySHA256",
        from: provenance,
        context: "playback provenance"
    )
    let digestPattern = "^[0-9a-fA-F]{64}$"
    guard
        sourceDigest.range(of: digestPattern, options: .regularExpression) != nil,
        libraryDigest.range(of: digestPattern, options: .regularExpression) != nil
    else {
        fatalError("Playback provenance digests must be 64-character SHA-256 hex strings")
    }

    return PlaybackTargetSelection(
        target: .binaryTarget(name: "SpottyPlaybackCore", path: pathRelativeToPackageRoot(url))
    )
}

private let playbackSelection = playbackTarget()

let package = Package(
    name: "Spotty",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Spotty", targets: ["SpottyApp"]),
        .library(name: "SpottyCore", targets: ["SpottyCore"]),
        .library(name: "SpottyDomain", targets: ["SpottyDomain"]),
    ],
    targets: [
        playbackSelection.target,
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
