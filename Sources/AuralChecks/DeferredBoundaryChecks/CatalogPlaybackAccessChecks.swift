import AuralDomain
import Foundation
import Observation
@testable import AuralCore

private final class AccessLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { .ok }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshotJSON() -> String? { nil }
    func configureHighQualityPlayback() {}
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }
}

private actor AccessRemoteClient: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}
    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri,
            title: "Metadata",
            artist: "Artist",
            artworkURL: nil,
            duration: 180
        )
    }
}

private final class IdleAccessAccount: AccountSession, @unchecked Sendable {
    func authorizeInteractively() async throws -> KeymasterTokens { throw CancellationError() }
    func hasGrant() async -> Bool { false }
    func accessToken() async throws -> String { "fixture-access" }
    func adopt(_: KeymasterTokens) async throws {}
    func clear() async {}
    func revocations() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

private actor IdleAccessWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
    }
}

private final class IdleAccessLifecycle: SystemLifecycleEvents, @unchecked Sendable {
    func events() -> AsyncStream<SystemLifecycleEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor IdleAccessPreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private struct IdleAccessAudio: AudioOutputPreparing { func prepareForPlayback() throws {} }

private struct IdleAccessAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

private enum AccessCheckFailure: Error { case unavailable }

private struct IdleAccessCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] { throw AccessCheckFailure.unavailable }
    func home() async throws -> PathfinderHome { throw AccessCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw AccessCheckFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw AccessCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw AccessCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw AccessCheckFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw AccessCheckFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw AccessCheckFailure.unavailable }
}

private struct AccessClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {}
}

private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
private func accessStore() -> PlaybackStore {
    PlaybackStore(
        environment: PlaybackEnvironment(
            remote: AccessRemoteClient(),
            local: AccessLocalEngine(),
            webQueue: IdleAccessWebQueue(),
            account: IdleAccessAccount(),
            audioOutput: IdleAccessAudio(),
            preferences: IdleAccessPreferences(),
            lifecycle: IdleAccessLifecycle(),
            clock: AccessClock(),
            catalog: IdleAccessCatalog(),
            playlistMutations: UnavailablePlaylistMutations(),
            trackAttributes: IdleAccessAttributes()
        ),
        feedback: TransientFeedbackPresenter(clock: AccessClock(), duration: 4)
    )
}

@MainActor
func runCatalogPlaybackAccessChecks(_ runner: CheckRunner) async {
    await runner.suite("CatalogPlaybackAccess construction is fact-lazy") {
        let player = accessStore()
        let flag = ObservationFlag()
        let access = withObservationTracking {
            CatalogPlaybackAccess(player: player)
        } onChange: {
            flag.fired = true
        }

        _ = player.send(.session(.ready), source: .account)
        _ = player.send(
            .presentation(PlaybackPresentationSnapshot(
                currentTrack: CurrentTrack(
                    uri: "spotify:track:access",
                    title: "Access",
                    artist: "Artist",
                    duration: 180,
                    metadataSource: .catalog
                ),
                transport: .playing,
                timing: PlaybackTiming(
                    position: 1,
                    duration: 180,
                    anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )),
            source: .user
        )
        player.setTransport(.paused)

        runner.check(
            "constructing CatalogPlaybackAccess does not observe playback facts",
            !flag.fired
        )
        runner.equal("a later fact read still follows the store", access.isConnected, true)
        await player.shutdownForTermination()
    }

    await runner.suite("CatalogPlaybackAccess leaves observe computed facts") {
        let player = accessStore()
        let access = CatalogPlaybackAccess(player: player)
        _ = player.send(.session(.ready), source: .account)
        runner.equal("isConnected follows the store", access.isConnected, player.isConnected)
        runner.equal("accountEpoch follows the store", access.accountEpoch, player.state.accountEpoch)
        runner.equal("canStartPlayback follows the store", access.canStartPlayback, player.canStartPlayback)
        runner.equal("statusText follows the store", access.statusText, player.statusText)

        _ = player.send(
            .presentation(PlaybackPresentationSnapshot(
                currentTrack: CurrentTrack(
                    uri: "spotify:track:current",
                    title: "Current",
                    artist: "Artist",
                    duration: 120,
                    metadataSource: .catalog
                ),
                transport: .paused,
                timing: PlaybackTiming(
                    position: 0,
                    duration: 120,
                    anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )),
            source: .user
        )
        runner.equal("currentTrackURI follows the store", access.currentTrackURI, player.trackURI)
        runner.equal("hasCurrentTrack follows the store", access.hasCurrentTrack, player.hasCurrentTrack)

        let trackFlag = ObservationFlag()
        withObservationTracking {
            _ = access.hasCurrentTrack && access.currentTrackURI == "spotify:track:current"
        } onChange: {
            trackFlag.fired = true
        }
        _ = player.send(
            .presentation(PlaybackPresentationSnapshot(
                currentTrack: CurrentTrack(
                    uri: "spotify:track:next",
                    title: "Next",
                    artist: "Artist",
                    duration: 90,
                    metadataSource: .catalog
                ),
                transport: .paused,
                timing: PlaybackTiming(
                    position: 0,
                    duration: 90,
                    anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )),
            source: .user
        )
        runner.check("a leaf that reads the current track observes URI changes", trackFlag.fired)

        let connectedFlag = ObservationFlag()
        withObservationTracking {
            _ = access.isConnected
        } onChange: {
            connectedFlag.fired = true
        }
        _ = player.send(.session(.failed("offline")), source: .account)
        runner.check("a leaf that reads isConnected observes that fact", connectedFlag.fired)

        await player.shutdownForTermination()
    }
}
