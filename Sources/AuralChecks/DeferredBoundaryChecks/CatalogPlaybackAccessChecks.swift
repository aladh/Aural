import AuralDomain
import Foundation
import Observation
@testable import AuralCore

private final class AccessLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var storedOperations: [LocalPlaybackOperation] = []

    var operations: [LocalPlaybackOperation] {
        lock.lock()
        defer { lock.unlock() }
        return storedOperations
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_ operation: LocalPlaybackOperation) -> PlaybackEngineResult {
        lock.lock()
        storedOperations.append(operation)
        lock.unlock()
        return .ok
    }
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

private final class RecordingAccessAccount: AccountSession, @unchecked Sendable {
    private let lock = NSLock()
    private var storedInteractiveCount = 0

    var interactiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedInteractiveCount
    }

    func authorizeInteractively() async throws -> KeymasterTokens {
        lock.lock()
        storedInteractiveCount += 1
        lock.unlock()
        throw CancellationError()
    }

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

private func accessEnvironment(
    local: any LocalPlaybackEngine = AccessLocalEngine(),
    account: any AccountSession = RecordingAccessAccount()
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: AccessRemoteClient(),
        local: local,
        webQueue: IdleAccessWebQueue(),
        account: account,
        audioOutput: IdleAccessAudio(),
        preferences: IdleAccessPreferences(),
        lifecycle: IdleAccessLifecycle(),
        clock: AccessClock(),
        catalog: IdleAccessCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: IdleAccessAttributes()
    )
}

@MainActor
private func accessStore(
    local: any LocalPlaybackEngine = AccessLocalEngine(),
    account: any AccountSession = RecordingAccessAccount()
) -> PlaybackStore {
    PlaybackStore(
        environment: accessEnvironment(local: local, account: account),
        feedback: TransientFeedbackPresenter(clock: AccessClock(), duration: 4)
    )
}

@MainActor
private func seedLocalReady(_ player: PlaybackStore) {
    _ = player.send(.session(.ready), source: .account)
    _ = player.send(
        .devices(PlaybackDeviceSnapshot(
            devices: [
                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true),
            ],
            localDeviceID: "mac",
            revision: 1
        )),
        source: .engineDevices,
        revision: 1
    )
}

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while clock.now < deadline {
        if Task.isCancelled { return false }
        if await condition() { return true }
        await Task.yield()
    }
    return false
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

/// Boundary copy of the domain stored-closure detector. `AuralChecks` types are not
/// visible to this executable.
private func storedActionClosureLines(in source: String) -> [String] {
    source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { line in
            guard !line.hasPrefix("//") else { return false }
            if line.hasPrefix("func ") || line.hasPrefix("static func ") { return false }
            return line.contains("-> Void")
                || line.contains(": @MainActor (")
                || line.contains(": @MainActor(")
        }
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

        seedLocalReady(player)
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
        _ = player.send(.owner(.local), source: .command)
        player.setTransport(.paused)

        runner.check(
            "constructing CatalogPlaybackAccess does not observe playback facts",
            !flag.fired
        )
        runner.equal("construction still yields a usable access value", access.isConnected, true)
        await player.shutdownForTermination()
    }

    await runner.suite("CatalogPlaybackAccess identity and live facts") {
        let first = accessStore()
        let second = accessStore()
        let left = CatalogPlaybackAccess(player: first)
        let right = CatalogPlaybackAccess(player: first)
        let other = CatalogPlaybackAccess(player: second)

        runner.check("access values for the same player are equal", left == right)
        runner.check("access values for different players are not equal", left != other)

        seedLocalReady(first)
        runner.check("equality is stable after playback facts change", left == right)
        runner.equal("isConnected follows the store", left.isConnected, first.isConnected)
        runner.equal("accountEpoch follows the store", left.accountEpoch, first.state.accountEpoch)
        runner.equal("canStartPlayback follows the store", left.canStartPlayback, first.canStartPlayback)
        runner.equal("statusText follows the store", left.statusText, first.statusText)

        _ = first.send(
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
        runner.equal("currentTrackURI follows the store", left.currentTrackURI, first.trackURI)
        runner.equal("hasCurrentTrack follows the store", left.hasCurrentTrack, first.hasCurrentTrack)

        let trackFlag = ObservationFlag()
        withObservationTracking {
            _ = left.hasCurrentTrack && left.currentTrackURI == "spotify:track:current"
        } onChange: {
            trackFlag.fired = true
        }
        _ = first.send(
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
            _ = left.isConnected
        } onChange: {
            connectedFlag.fired = true
        }
        _ = first.send(.session(.failed("offline")), source: .account)
        runner.check("a leaf that reads isConnected observes that fact", connectedFlag.fired)

        await first.shutdownForTermination()
        await second.shutdownForTermination()
    }

    await runner.suite("CatalogPlaybackAccess actions route to the store") {
        let account = RecordingAccessAccount()
        let connectPlayer = accessStore(account: account)
        let connectAccess = CatalogPlaybackAccess(player: connectPlayer)
        connectAccess.connect()
        runner.check(
            "connect routes to the account session",
            await waitUntil { account.interactiveCount == 1 }
        )
        await connectPlayer.shutdownForTermination()

        let local = AccessLocalEngine()
        let player = accessStore(local: local)
        seedLocalReady(player)
        let access = CatalogPlaybackAccess(player: player)
        access.playURI("spotify:track:play-uri")
        runner.check(
            "playURI routes to the local engine",
            await waitUntil {
                local.operations.contains { operation in
                    if case .playURI("spotify:track:play-uri") = operation { return true }
                    return false
                }
            }
        )
        runner.check(
            "playURI pending command settles",
            await waitUntil { !player.isPlaybackCommandPending }
        )

        let track = CatalogTrack(
            id: "play-track",
            uri: "spotify:track:play-track",
            title: "Track",
            artist: "Artist",
            album: "Album",
            duration: 100,
            artworkURL: nil,
            addedAt: nil
        )
        access.playTrack(track)
        runner.check(
            "playTrack routes to the local engine",
            await waitUntil {
                local.operations.contains { operation in
                    if case .playURI("spotify:track:play-track") = operation { return true }
                    return false
                }
            }
        )
        runner.check(
            "playTrack pending command settles",
            await waitUntil { !player.isPlaybackCommandPending }
        )

        access.addToQueue(["spotify:track:queued"])
        runner.check(
            "addToQueue routes to the local engine",
            await waitUntil {
                local.operations.contains { operation in
                    if case .addToQueue("spotify:track:queued") = operation { return true }
                    return false
                }
            }
        )

        let playlist = CatalogItem(
            id: "playlist",
            uri: "spotify:playlist:access",
            title: "Playlist",
            subtitle: "Owner",
            artworkURL: nil,
            kind: .playlist
        )
        access.playPlaylist(playlist)
        runner.check(
            "playPlaylist routes to the local engine",
            await waitUntil {
                local.operations.contains { operation in
                    if case .playURI("spotify:playlist:access") = operation { return true }
                    return false
                }
            }
        )
        await player.shutdownForTermination()
    }

    runner.suite("Catalog leaves still read the facts they render") {
        runner.noThrow("catalog leaf sources are readable") {
            let table = try auralSourceFile("Aural/Views/SharedComponents.swift")
            let playlist = try auralSourceFile("Aural/Views/PlaylistDetailView.swift")
            let media = try auralSourceFile("Aural/Views/MediaDetailViews.swift")
            let library = try auralSourceFile("Aural/Views/LibraryViews.swift")
            let home = try auralSourceFile("Aural/Views/HomeView.swift")
            let root = try auralSourceFile("Aural/RootView.swift")
            let access = try auralSourceFile("Aural/CatalogPlaybackAccess.swift")

            runner.check(
                "TrackTable highlights from hasCurrentTrack and currentTrackURI",
                containsToken(table, "playback.hasCurrentTrack && playback.currentTrackURI == track.uri")
            )
            runner.check(
                "TrackTable play and queue respect canStartPlayback",
                containsToken(table, ".disabled(!playback.canStartPlayback)")
                    && containsToken(table, "playback.playTrack(track)")
                    && containsToken(table, "playback.addToQueue(")
            )
            runner.check(
                "playlist detail still keys its load task on account epoch and connection",
                containsToken(playlist, "accountEpoch: playback.accountEpoch")
                    && containsToken(playlist, "isConnected: playback.isConnected")
                    && containsToken(playlist, "guard playback.isConnected else { return }")
            )
            runner.check(
                "playlist detail still uses status copy and connect",
                containsToken(playlist, "Text(playback.statusText)")
                    && containsToken(playlist, "playback.connect()")
                    && containsToken(playlist, "playback.playPlaylist(item)")
            )
            runner.check(
                "album and artist loads still key on account epoch",
                containsToken(media, "accountEpoch: playback.accountEpoch")
                    && containsToken(media, "isConnected: playback.isConnected")
                    && containsToken(media, "playback.playURI(item.uri)")
            )
            runner.check(
                "search and library still observe connection for empty and load states",
                containsToken(library, "if !playback.isConnected")
                    && containsToken(library, "playback.connect()")
                    && containsToken(library, ".task(id: playback.accountEpoch)")
                    && containsToken(home, "else if !playback.isConnected")
            )
            runner.check(
                "liked songs keep account-epoch loading in RootView",
                containsToken(root, ".task(id: catalogPlayback.accountEpoch)")
                    && containsToken(root, "guard catalogPlayback.isConnected else { return }")
            )
            runner.check(
                "access methods call the store without per-body closures",
                containsToken(access, "func connect()")
                    && containsToken(access, "player.connect()")
                    && containsToken(access, "player.play(uri: uri)")
                    && containsToken(access, "player.play(track: track)")
                    && containsToken(access, "player.playPlaylist(item)")
                    && containsToken(access, "player.addToQueue(uris: uris)")
                    && storedActionClosureLines(in: access).isEmpty
            )
        }
    }
}
