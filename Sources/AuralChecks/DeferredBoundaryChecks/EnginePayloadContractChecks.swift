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
        }

        check.noThrow("playback-full decodes a live playing snapshot and options") {
            let state = try decoder.decode(
                RustPlaybackState.self,
                from: enginePayloadFixture(named: "playback-full")
            )
            check.equal("full playback revision", state.revision, 12)
            check.equal("full playback session generation", state.sessionGeneration, 4)
            check.equal("full playback is playing", state.isPlaying, true)
            check.equal("full playback is not paused", state.isPaused, false)
            check.equal("full playback track", state.trackURI, "spotify:track:fixtureNow")
            check.equal("full playback position", state.positionMS, 1_250)
            check.equal("full playback duration", state.durationMS, 180_000)
            check.equal("full playback timestamp", state.timestampMS, 1_700_000_000_000)
            check.equal("full shuffle", state.shuffle, true)
            check.equal("full repeat track", state.repeatTrack, false)
            check.equal("full repeat context", state.repeatContext, true)

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

            let devices = try decoder.decode(
                RustDevicesState.self,
                from: enginePayloadFixture(named: "devices-full")
            ).devices
            let playbackDevices = devices.map {
                PlaybackDevice(id: $0.id, name: $0.name, type: $0.type, isActive: $0.isActive)
            }
            let owner = connectionPlaybackOwner(
                isLocalActive: state.isActiveDevice,
                localDeviceID: state.deviceID,
                localDeviceName: state.deviceName ?? "",
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

private func upcomingEntries(from state: RustQueueState) -> [QueueEntry] {
    QueueProtocolProjection.upcomingEntries(
        from: (state.protocolNextTracks ?? []).map { $0.domainTrack() }
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
