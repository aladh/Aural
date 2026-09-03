import AuralDomain
import Foundation
@testable import AuralCore

@MainActor
func runEnginePayloadContractChecks(_ check: CheckRunner) {
    let decoder = JSONDecoder()

    check.suite("Rust-produced engine payload contracts") {
        check.noThrow("queue-minimal decodes a null current track") {
            let state = try decoder.decode(
                RustQueueState.self,
                from: enginePayloadFixture(named: "queue-minimal")
            )
            check.equal("minimal queue revision", state.revision, 1)
            check.equal("minimal queue session generation", state.sessionGeneration, 1)
            check.nil_("minimal queue has no current track", state.track)
            check.equal("minimal upcoming projection", upcomingEntries(from: state).count, 0)
            check.equal("minimal protocol next", state.protocolNextTracks?.count, 0)
            check.equal("minimal protocol prev", state.protocolPrevTracks?.count, 0)
            check.equal("minimal queue revision string", state.queueRevision, "")
            check.equal("minimal disallow set queue", state.disallowSetQueue, false)
            check.equal("minimal disallow removing", state.disallowRemovingFromNextTracks, false)
        }

        check.noThrow("queue-full decodes occurrence UIDs and protocol metadata") {
            let state = try decoder.decode(
                RustQueueState.self,
                from: enginePayloadFixture(named: "queue-full")
            )
            check.equal("full queue revision", state.revision, 13)
            check.equal("full queue session generation", state.sessionGeneration, 4)
            check.equal("current track URI is context identity", state.track?.uri, "spotify:track:fixtureNow")
            check.equal("current track provider", state.track?.provider, "context")
            check.equal("current track uid", state.track?.uid, "occ-now")
            check.nil_("current track does not carry catalog labels", state.track?.name)
            check.nil_("current track does not carry catalog artist", state.track?.artist)

            let next = upcomingEntries(from: state)
            check.equal("next track count", next.count, 3)
            let first = next[0]
            let duplicate = next[1]
            check.equal("duplicate URI is preserved", first.uri, "spotify:track:fixtureDup")
            check.equal("duplicate URI still matches", duplicate.uri, first.uri)
            check.equal("first occurrence uid", first.uid, "occ-a")
            check.equal("second occurrence uid", duplicate.uid, "occ-b")
            check.equal("first occurrence is typed", first.occurrence, 0)
            check.equal("second occurrence is typed", duplicate.occurrence, 1)
            check.check("duplicate occurrences stay distinct rows", first.id != duplicate.id)
            check.equal("unknown provider is preserved", next[2].provider, "unavailable")
            check.equal("prev protocol provider is context", state.protocolPrevTracks?.first?.provider, "context")
            check.equal("prev uid", state.protocolPrevTracks?.first?.uid, "occ-prev")
            check.equal("queue revision string", state.queueRevision, "fixture-rev-1")
            check.equal("disallow set queue", state.disallowSetQueue, true)
            check.equal("disallow removing from next", state.disallowRemovingFromNextTracks, true)

            let protocolNext = (state.protocolNextTracks ?? []).map { $0.domainTrack() }
            check.equal("protocol next count", protocolNext.count, 5)
            check.equal("protocol next uid", protocolNext[0].uid, "occ-a")
            check.equal("protocol next provider", protocolNext[0].provider, "queue")
            check.equal("protocol next metadata", protocolNext[0].metadata["is_queued"], "true")
            check.equal(
                "protocol next restrictions",
                protocolNext[0].restrictions["disallow_resuming_reasons"],
                ["not_active_device"]
            )
            check.equal("protocol next album", protocolNext[0].albumURI, "spotify:album:fixtureAlbum")
            check.equal("protocol next artist", protocolNext[0].artistURI, "spotify:artist:fixtureArtist")
            check.equal("delimiter survives protocol transport", protocolNext[3].uri, "spotify:delimiter")
            check.equal("omitted protocol uid is empty", protocolNext[4].uid, "")
            check.equal("omitted protocol provider", protocolNext[4].provider, "autoplay")
            check.equal("omitted protocol metadata", protocolNext[4].metadata, [:])
            check.equal("omitted protocol restrictions", protocolNext[4].restrictions, [:])
            check.equal("omitted protocol album", protocolNext[4].albumURI, "")

            let protocolPrev = (state.protocolPrevTracks ?? []).map { $0.domainTrack() }
            check.equal("protocol prev uid", protocolPrev.first?.uid, "occ-prev")
            check.equal(
                "protocol prev context metadata",
                protocolPrev.first?.metadata["context_uri"],
                "spotify:playlist:fixtureContext"
            )
            check.equal("protocol prev removed", protocolPrev.first?.removed, ["removed-reason"])
            check.equal("protocol prev blocked", protocolPrev.first?.blocked, ["blocked-reason"])
        }
    }

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

private func upcomingEntries(from state: RustQueueState) -> [QueueEntry] {
    QueueProtocolProjection.upcomingEntries(
        from: (state.protocolNextTracks ?? []).map { $0.domainTrack() }
    )
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
