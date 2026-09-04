import Testing
import Foundation
@testable import SpottyCore

@Suite("Connect Device Identity")
struct ConnectDeviceIdentityTests {
    @Test
    @MainActor
    func testConnectDeviceIdentity() {
        do {
            #expect(
                (ConnectDeviceIdentity.advertisedName(computerName: "Studio Mac")) == ("Studio Mac (Spotty)"),
                "Computer Name is followed by the app name")
            #expect(
                (ConnectDeviceIdentity.advertisedName(computerName: "  Studio Mac\n")) == ("Studio Mac (Spotty)"),
                "Computer Name is trimmed")
            #expect(
                (ConnectDeviceIdentity.advertisedName(computerName: nil)) == ("Mac (Spotty)"),
                "missing Computer Name has a natural fallback")
        }

        do {
            do {
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
                #expect((setter < playerInitialization) == true, "identity is written before player initialization")

            } catch {
                Issue.record("\("player initialization cannot skip Connect identity"): unexpected error \(error)")
            }
        }
    }
}

private enum ConnectDeviceIdentityCheckError: Error {
    case missingInitializeFunction
    case missingIdentityConfiguration
}

private func spottyIdentitySourceFile(_ relativePath: String) throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let sources = repositoryRoot.appending(path: "Sources")
    return try String(contentsOf: sources.appending(path: relativePath), encoding: .utf8)
}
