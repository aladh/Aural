import Testing
import Foundation
@testable import SpottyCore

@Suite("Engine Payload Contract")
struct EnginePayloadContractTests {
    @Test
    @MainActor
    func testEnginePayloadContract() {
        do {
            do {
                do {
                    let engineEvents = try spottySourceFile("Spotty/Spotify/PlaybackStore+EngineEvents.swift")
                    let dto = try spottySourceFile("Spotty/Spotify/PlaybackStore.swift")
                    let account = try spottySourceFile("Spotty/Spotify/AccountStore.swift")
                    let bridge = try spottySourceFile("Spotty/Spotify/PlaybackCore.swift")
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
                            && containsToken(bridge, "isActiveDevice: snapshot.is_active_device != 0")
                            && containsToken(bridge, "credentialsRejected: snapshot.credentials_rejected != 0")
                            && containsToken(bridge, "trackURI: optionalCString(snapshot.track_uri) ?? \"\"")
                            && containsToken(
                                bridge,
                                "private static func optionalCString(_ pointer: UnsafePointer<CChar>?) -> String?")
                            && containsToken(bridge, "defer { spotty_playback_free_string(pointer) }")
                            && containsToken(projection, "public static func sessionPhase")
                            && containsToken(projection, "public static func resolvedDeviceID")) == true,
                        "C snapshots are copied and projected at the Swift intake boundary")

                } catch {
                    Issue.record(
                        "\("connection intake projects session phase at the envelope"): unexpected error \(error)")
                }
            }
        }
    }
}

private func spottySourceFile(_ relativePath: String) throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let url = repositoryRoot.appending(path: "Sources").appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func containsToken(_ source: String, _ token: String) -> Bool {
    source.contains(token)
}
