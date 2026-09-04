import Foundation
@testable import SpottyCore

@MainActor
func runConnectDeviceIdentityChecks(_ runner: CheckRunner) {
    runner.suite("Connect device identity") {
        runner.equal(
            "Computer Name is followed by the app name",
            ConnectDeviceIdentity.advertisedName(computerName: "Studio Mac"),
            "Studio Mac (Spotty)"
        )
        runner.equal(
            "Computer Name is trimmed",
            ConnectDeviceIdentity.advertisedName(computerName: "  Studio Mac\n"),
            "Studio Mac (Spotty)"
        )
        runner.equal(
            "missing Computer Name has a natural fallback",
            ConnectDeviceIdentity.advertisedName(computerName: nil),
            "Mac (Spotty)"
        )
    }

    runner.noThrow("player initialization cannot skip Connect identity") {
        let source = try spottyIdentitySourceFile("Spotty/Spotify/PlaybackCore.swift")
        guard
            let initializeStart = source.range(of: "static func initialize() -> Result {")?.lowerBound,
            let initializeEnd = source.range(of: "static func play(uri:")?.lowerBound
        else {
            throw ConnectDeviceIdentityCheckError.missingInitializeFunction
        }
        let initialize = source[initializeStart..<initializeEnd]
        guard
            let setter = initialize.range(of: "spotty_playback_set_device_name")?.lowerBound,
            let playerInitialization = initialize.range(of: "spotty_playback_init_player")?.lowerBound
        else {
            throw ConnectDeviceIdentityCheckError.missingIdentityConfiguration
        }
        runner.check(
            "identity is written before player initialization",
            setter < playerInitialization
        )
    }
}

private enum ConnectDeviceIdentityCheckError: Error {
    case missingInitializeFunction
    case missingIdentityConfiguration
}

private func spottyIdentitySourceFile(_ relativePath: String) throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sources = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: sources.appending(path: relativePath), encoding: .utf8)
}
