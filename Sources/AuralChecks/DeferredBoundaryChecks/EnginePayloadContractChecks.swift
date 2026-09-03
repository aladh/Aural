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

        check.noThrow("inactive connection without a device id waits for local identity") {
            let devices = projectedDevices(
                from: try decoder.decode(
                    RustDevicesState.self,
                    from: enginePayloadFixture(named: "devices-full")
                )
            )
            check.equal(
                "active device without local identity waits",
                AuralDomain.connectCommandRoute(
                    isLocalActive: false,
                    localDeviceID: nil,
                    devices: devices
                ),
                .waitingForLocalIdentity
            )
        }

        check.noThrow("active local connection owns playback") {
            let devices = projectedDevices(
                from: try decoder.decode(
                    RustDevicesState.self,
                    from: enginePayloadFixture(named: "devices-full")
                )
            )
            let playbackDevices = devices.map {
                PlaybackDevice(id: $0.id, name: $0.name, type: $0.type, isActive: $0.isActive)
            }
            let owner = connectionPlaybackOwner(
                isLocalActive: true,
                localDeviceID: "fixture-mac",
                localDeviceName: devices.first { $0.id == "fixture-mac" }?.name ?? "This Mac",
                devices: playbackDevices,
                currentTrackURI: "spotify:track:fixtureNow",
                previousOwner: .none,
                lastRemoteDeviceID: nil
            )
            check.equal(
                "active local connection owns playback",
                owner,
                .local(PlaybackDevice(id: "fixture-mac", name: "Fixture Mac", type: "Computer", isActive: true))
            )
            check.equal(
                "local ownership routes locally",
                AuralDomain.connectCommandRoute(owner: owner, localDeviceID: "fixture-mac"),
                .local
            )
        }

        check.noThrow("devices-full decodes activity and local identity") {
            let state = try decoder.decode(
                RustDevicesState.self,
                from: enginePayloadFixture(named: "devices-full")
            )
            check.equal("devices revision", state.revision, 15)
            check.equal("devices session generation", state.sessionGeneration, 6)
            check.equal("cluster active device id", state.activeDeviceID, "fixture-mac")
            let raw = try JSONSerialization.jsonObject(
                with: enginePayloadFixture(named: "devices-full")
            )
            let rawDevices = (raw as? [String: Any])?["devices"] as? [[String: Any]]
            check.equal("protocol member count", rawDevices?.count, 3)
            check.check(
                "protocol members omit presentation activity",
                rawDevices?.allSatisfy { $0["is_active"] == nil } == true
            )
            check.check(
                "protocol members omit unused Web API volume fields",
                rawDevices?.allSatisfy {
                    $0["volume_percent"] == nil && $0["disable_volume"] == nil
                } == true
            )
            let devices = projectedDevices(from: state)
            check.equal("device count", devices.count, 3)

            let mac = devices[0]
            let speaker = devices[1]
            let unknown = devices[2]
            check.equal("local computer id", mac.id, "fixture-mac")
            check.equal("local computer is active", mac.isActive, true)
            check.equal("local computer type", mac.type, "Computer")
            check.equal(
                "local computer display name",
                mac.displayName(localDeviceID: "fixture-mac"),
                "Fixture Mac (This Mac)"
            )
            check.equal("speaker is inactive", speaker.isActive, false)
            check.equal("speaker type", speaker.type, "Speaker")
            check.equal("unknown type maps to the default icon", unknown.symbolName, "hifispeaker")
            check.equal("unknown type is preserved", unknown.type, "TOASTER")

            check.equal(
                "active local device routes locally",
                AuralDomain.connectCommandRoute(
                    isLocalActive: mac.isActive,
                    localDeviceID: mac.id,
                    devices: devices
                ),
                .local
            )
            check.equal(
                "an active local computer in the snapshot wins over a speaker fallback",
                AuralDomain.connectCommandRoute(
                    isLocalActive: false,
                    localDeviceID: mac.id,
                    devices: devices,
                    fallbackRemoteDeviceID: speaker.id
                ),
                .local
            )
            check.equal(
                "decoded speaker identity stays remotely addressable when it is the listed target",
                AuralDomain.connectCommandRoute(
                    isLocalActive: false,
                    localDeviceID: mac.id,
                    devices: [speaker, unknown],
                    fallbackRemoteDeviceID: speaker.id
                ),
                .remote(from: "fixture-mac", to: "fixture-speaker")
            )
        }
    }

    check.suite("Connect device intake source contract") {
        check.noThrow("device intake projects once from protocol members") {
            let engineEvents = try auralSourceFile("Aural/Spotify/PlaybackStore+EngineEvents.swift")
            let dto = try auralSourceFile("Aural/Spotify/PlaybackStore.swift")
            let projection = try auralSourceFile("AuralDomain/ConnectDeviceProjection.swift")
            check.check(
                "Connect intake projects devices at the envelope, not on the DTO",
                containsToken(engineEvents, "ConnectDeviceProjection.devices(")
                    && containsToken(engineEvents, "from: state.devices")
                    && containsToken(engineEvents, "activeDeviceID: state.activeDeviceID")
                    && containsToken(dto, "let devices: [ConnectProtocolDevice]")
                    && !containsToken(dto, "func devices(")
                    && containsToken(projection, "public static func isActive")
                    && containsToken(projection, "public static func devices(")
            )
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

private func projectedDevices(from state: RustDevicesState) -> [ConnectDevice] {
    ConnectDeviceProjection.devices(
        from: state.devices,
        activeDeviceID: state.activeDeviceID
    )
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
