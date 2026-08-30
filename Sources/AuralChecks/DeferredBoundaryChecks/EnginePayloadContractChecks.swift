import AuralDomain
import Foundation
@testable import AuralCore

@MainActor
func runEnginePayloadContractChecks(_ check: CheckRunner) {
    let decoder = JSONDecoder()

    check.suite("Rust-produced engine payload contracts") {
        check.noThrow("playback-minimal decodes an empty track") {
            let state = try decoder.decode(
                RustPlaybackState.self,
                from: enginePayloadFixture(named: "playback-minimal")
            )
            check.equal("minimal playback revision", state.revision, 1)
            check.equal("minimal playback session generation", state.sessionGeneration, 1)
            check.equal("minimal playback is stopped", state.isPlaying, false)
            check.equal("minimal playback is not paused", state.isPaused, false)
            check.equal("minimal playback has no track", state.trackURI, "")
            check.equal("minimal playback position", state.positionMS, 0)
            check.equal("minimal playback duration", state.durationMS, 0)
            check.equal("minimal playback timestamp", state.timestampMS, 0)
            check.equal("minimal shuffle", state.shuffle, false)
            check.equal("minimal repeat track", state.repeatTrack, false)
            check.equal("minimal repeat context", state.repeatContext, false)

            let snapshot = enginePlaybackSnapshot(from: state, receivedAt: Date(timeIntervalSince1970: 0))
            check.equal("empty track maps to stopped", snapshot.transport, .stopped)
            check.nil_("empty track URI is nullable in the reducer snapshot", snapshot.trackURI)
        }

        check.noThrow("playback-full decodes paused overlay and options") {
            let state = try decoder.decode(
                RustPlaybackState.self,
                from: enginePayloadFixture(named: "playback-full")
            )
            check.equal("full playback revision", state.revision, 12)
            check.equal("full playback session generation", state.sessionGeneration, 4)
            check.check("raw playing+paused bits decode together", state.isPlaying && state.isPaused == true)
            check.equal("full playback track", state.trackURI, "spotify:track:fixtureNow")
            check.equal("full playback position", state.positionMS, 1_250)
            check.equal("full playback duration", state.durationMS, 180_000)
            check.equal("full playback timestamp", state.timestampMS, 1_700_000_000_000)
            check.equal("full shuffle", state.shuffle, true)
            check.equal("full repeat track", state.repeatTrack, false)
            check.equal("full repeat context", state.repeatContext, true)

            let snapshot = enginePlaybackSnapshot(from: state, receivedAt: Date(timeIntervalSince1970: 1_700_000_000))
            check.equal("paused overlay is not playing", snapshot.transport, .paused)
            check.equal("reducer keeps the track URI", snapshot.trackURI, "spotify:track:fixtureNow")
            check.equal("reducer keeps shuffle", snapshot.shuffle, true)
            check.equal("reducer keeps repeat context", snapshot.repeatFlags?.context, true)
            check.equal("reducer keeps repeat track off", snapshot.repeatFlags?.track, false)

            _ = try decodeIgnoringUnknownFields(
                RustPlaybackState.self,
                from: enginePayloadFixture(named: "playback-full")
            )
        }

        check.noThrow("queue-minimal decodes a null current track") {
            let state = try decoder.decode(
                RustQueueState.self,
                from: enginePayloadFixture(named: "queue-minimal")
            )
            check.equal("minimal queue revision", state.revision, 1)
            check.equal("minimal queue session generation", state.sessionGeneration, 1)
            check.nil_("minimal queue has no current track", state.track)
            check.equal("minimal next tracks", state.nextTracks?.count, 0)
            check.equal("minimal prev tracks", state.prevTracks?.count, 0)
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
            check.equal("current track name", state.track?.name, "Fixture Track")
            check.equal("current track artist", state.track?.artist, "Fixture Artist")
            check.equal(
                "current track artwork",
                state.track?.imageURL,
                "https://example.test/fixture-cover.jpg"
            )
            check.equal("current track duration", state.track?.durationMS, 180_000)

            let next = state.nextTracks ?? []
            check.equal("next track count", next.count, 3)
            let first = QueueEntry(
                uri: next[0].uri,
                provider: next[0].provider,
                occurrence: 0,
                uid: next[0].uid ?? ""
            )
            let duplicate = QueueEntry(
                uri: next[1].uri,
                provider: next[1].provider,
                occurrence: 1,
                uid: next[1].uid ?? ""
            )
            check.equal("duplicate URI is preserved", first.uri, "spotify:track:fixtureDup")
            check.equal("duplicate URI still matches", duplicate.uri, first.uri)
            check.equal("first occurrence uid", first.uid, "occ-a")
            check.equal("second occurrence uid", duplicate.uid, "occ-b")
            check.check("duplicate occurrences stay distinct rows", first.id != duplicate.id)
            check.equal("unknown provider is preserved", next[2].provider, "unavailable")
            check.equal("prev provider is context", state.prevTracks?.first?.provider, "context")
            check.equal("prev uid", state.prevTracks?.first?.uid, "occ-prev")
            check.equal("queue revision string", state.queueRevision, "fixture-rev-1")
            check.equal("disallow set queue", state.disallowSetQueue, true)
            check.equal("disallow removing from next", state.disallowRemovingFromNextTracks, true)

            let protocolNext = (state.protocolNextTracks ?? []).map { $0.domainTrack() }
            check.equal("protocol next count", protocolNext.count, 2)
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
            check.equal("omitted protocol uid is empty", protocolNext[1].uid, "")
            check.equal("omitted protocol provider", protocolNext[1].provider, "autoplay")
            check.equal("omitted protocol metadata", protocolNext[1].metadata, [:])
            check.equal("omitted protocol restrictions", protocolNext[1].restrictions, [:])
            check.equal("omitted protocol album", protocolNext[1].albumURI, "")

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

        check.noThrow("connection-minimal decodes disconnected identity") {
            let state = try decoder.decode(
                RustConnectionState.self,
                from: enginePayloadFixture(named: "connection-minimal")
            )
            check.equal("minimal connection revision", state.revision, 2)
            check.equal("minimal connection session generation", state.sessionGeneration, 1)
            check.equal("minimal session is disconnected", state.sessionConnected, false)
            check.equal("minimal spirc is not ready", state.spircReady, false)
            check.equal("minimal device is not active", state.isActiveDevice, false)
            check.nil_("minimal device id is omitted as null", state.deviceID)
            check.equal("minimal device name is empty", state.deviceName, "")
            check.equal("minimal last error", state.lastError, "fixture-session-timeout")

            let session: PlaybackSessionPhase = (state.sessionConnected && state.spircReady)
                ? .ready
                : .failed(state.lastError ?? "")
            check.equal("disconnected connection maps to failure", session, .failed("fixture-session-timeout"))
            let devices = try decoder.decode(
                RustDevicesState.self,
                from: enginePayloadFixture(named: "devices-full")
            ).devices
            check.equal(
                "active device without local identity waits",
                AuralDomain.connectCommandRoute(
                    isLocalActive: state.isActiveDevice,
                    localDeviceID: state.deviceID,
                    devices: devices
                ),
                .waitingForLocalIdentity
            )
        }

        check.noThrow("connection-full decodes local ownership") {
            let state = try decoder.decode(
                RustConnectionState.self,
                from: enginePayloadFixture(named: "connection-full")
            )
            check.equal("full connection revision", state.revision, 14)
            check.equal("full connection session generation", state.sessionGeneration, 5)
            check.equal("full session is connected", state.sessionConnected, true)
            check.equal("full spirc is ready", state.spircReady, true)
            check.equal("full device is locally active", state.isActiveDevice, true)
            check.equal("full local device id", state.deviceID, "fixture-mac")
            check.equal("full local device name", state.deviceName, "Fixture Mac")
            check.nil_("full last error is null", state.lastError)

            let owner = connectionPlaybackOwner(
                isLocalActive: state.isActiveDevice,
                localDeviceID: state.deviceID,
                localDeviceName: state.deviceName ?? "",
                devices: [
                    PlaybackDevice(id: "fixture-mac", name: "Fixture Mac", type: "Computer", isActive: true),
                ],
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
                AuralDomain.connectCommandRoute(owner: owner, localDeviceID: state.deviceID),
                .local
            )

            _ = try decodeIgnoringUnknownFields(
                RustConnectionState.self,
                from: enginePayloadFixture(named: "connection-full")
            )
        }

        check.noThrow("devices-full decodes activity and local identity") {
            let state = try decoder.decode(
                RustDevicesState.self,
                from: enginePayloadFixture(named: "devices-full")
            )
            check.equal("devices revision", state.revision, 15)
            check.equal("devices session generation", state.sessionGeneration, 6)
            check.equal("device count", state.devices.count, 3)

            let mac = state.devices[0]
            let speaker = state.devices[1]
            let unknown = state.devices[2]
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
                    devices: state.devices
                ),
                .local
            )
            check.equal(
                "an active local computer in the snapshot wins over a speaker fallback",
                AuralDomain.connectCommandRoute(
                    isLocalActive: false,
                    localDeviceID: mac.id,
                    devices: state.devices,
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
}

private func enginePlaybackSnapshot(
    from state: RustPlaybackState,
    receivedAt: Date
) -> EnginePlaybackSnapshot {
    let snapshotIsPlaying = state.isPlaying && !(state.isPaused ?? false)
    let transport: PlaybackTransportState = snapshotIsPlaying
        ? .playing
        : (state.trackURI.isEmpty ? .stopped : .paused)
    let flags = RepeatFlags(
        context: state.repeatContext ?? false,
        track: state.repeatTrack ?? false
    )
    return EnginePlaybackSnapshot(
        transport: transport,
        trackURI: state.trackURI.isEmpty ? nil : state.trackURI,
        timing: PlaybackTiming(
            position: AuralDomain.playbackSnapshotPosition(
                positionMilliseconds: state.positionMS,
                durationMilliseconds: state.durationMS,
                timestampMilliseconds: state.timestampMS,
                isPlaying: transport == .playing,
                now: receivedAt
            ),
            duration: TimeInterval(max(0, state.durationMS)) / 1_000,
            anchoredAt: receivedAt
        ),
        shuffle: state.shuffle,
        repeatMode: RepeatMode(context: flags.context, track: flags.track),
        repeatFlags: flags
    )
}

private func decodeIgnoringUnknownFields<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let object = try JSONSerialization.jsonObject(with: data)
    guard var dictionary = object as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    dictionary["future_contract_field"] = "ignored"
    let extra = try JSONSerialization.data(withJSONObject: dictionary)
    return try JSONDecoder().decode(type, from: extra)
}
