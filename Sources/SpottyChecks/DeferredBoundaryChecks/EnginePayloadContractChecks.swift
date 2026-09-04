import Testing
import Foundation
@testable import SpottyCore

@Test
@MainActor
func testEnginePayloadContract() {
    do {
        do {
            do {
                let engineEvents = try spottySourceFile("Spotty/Spotify/PlaybackStore+EngineEvents.swift")
                let dto = try spottySourceFile("Spotty/Spotify/PlaybackStore.swift")
                let account = try spottySourceFile("Spotty/Spotify/AccountStore.swift")
                let projection = try spottySourceFile("SpottyDomain/ConnectionSnapshotProjection.swift")
                #expect(
                    (containsToken(engineEvents, "ConnectionSnapshotProjection.sessionPhase(")
                        && containsToken(engineEvents, "ConnectionSnapshotProjection.resolvedDeviceID(")
                        && containsToken(engineEvents, "localDeviceName: thisDeviceName")
                        && containsToken(engineEvents, "accountStore.receiveEngineConnection(session)")
                        && containsToken(dto, "let thisDeviceName = \"This Mac\"")
                        && !containsToken(dto, "var thisDeviceName")
                        && !containsToken(dto, "deviceName")
                        && containsToken(account, "func receiveEngineConnection(_ session: PlaybackSessionPhase?)")
                        && !containsToken(account, "if connected, ready")
                        && containsToken(projection, "public static func sessionPhase")
                        && containsToken(projection, "public static func resolvedDeviceID")) == true,
                    "Connect intake projects connection session at the envelope, not on the DTO")

            } catch {
                Issue.record("\("connection intake projects session phase at the envelope"): unexpected error \(error)")
            }
        }
    }
}

private func spottySourceFile(_ relativePath: String) throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sources = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let url = sources.appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func containsToken(_ source: String, _ token: String) -> Bool {
    source.contains(token)
}
