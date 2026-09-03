import Foundation
@testable import AuralCore

@MainActor
func runEnginePayloadContractChecks(_ check: CheckRunner) {
    check.suite("Connection snapshot intake source contract") {
        check.noThrow("connection intake projects session phase at the envelope") {
            let engineEvents = try auralSourceFile("Aural/Spotify/PlaybackStore+EngineEvents.swift")
            let dto = try auralSourceFile("Aural/Spotify/PlaybackStore.swift")
            let account = try auralSourceFile("Aural/Spotify/AccountStore.swift")
            let projection = try auralSourceFile("AuralDomain/ConnectionSnapshotProjection.swift")
            check.check(
                "Connect intake projects connection session at the envelope, not on the DTO",
                containsToken(engineEvents, "ConnectionSnapshotProjection.sessionPhase(")
                    && containsToken(engineEvents, "ConnectionSnapshotProjection.resolvedDeviceID(")
                    && containsToken(engineEvents, "localDeviceName: thisDeviceName")
                    && containsToken(engineEvents, "accountStore.receiveEngineConnection(session)")
                    && containsToken(dto, "let thisDeviceName = \"This Mac\"")
                    && !containsToken(dto, "var thisDeviceName")
                    && !containsToken(dto, "deviceName")
                    && containsToken(account, "func receiveEngineConnection(_ session: PlaybackSessionPhase?)")
                    && !containsToken(account, "if connected, ready")
                    && containsToken(projection, "public static func sessionPhase")
                    && containsToken(projection, "public static func resolvedDeviceID")
            )
        }
    }
}

private func auralSourceFile(_ relativePath: String) throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sources = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let url = sources.appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func containsToken(_ source: String, _ token: String) -> Bool {
    source.contains(token)
}
