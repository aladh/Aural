import AuralDomain
import Foundation
@testable import AuralCore

private final class RecordingLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
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

private actor RecordingRemoteClient: RemotePlaybackClient {
    private(set) var endpoints: [SpotifyConnectCommand.Kind] = []

    func send(_ command: SpotifyConnectCommand, from _: String, to _: String) async throws {
        endpoints.append(command.endpoint)
    }

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

private actor SuspendedWebQueue: WebQueueClient {
    private var continuation: CheckedContinuation<[CatalogTrack], any Error>?
    private(set) var requestCount = 0

    func queue() async throws -> [CatalogTrack] {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(with tracks: [CatalogTrack]) {
        continuation?.resume(returning: tracks)
        continuation = nil
    }
}

private actor UnavailableWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
    }
}

private actor RateLimitedWebQueue: WebQueueClient {
    private(set) var requestCount = 0

    func queue() async throws -> [CatalogTrack] {
        requestCount += 1
        throw SpotifyWebPlayerAPIError.requestFailed(429)
    }
}

private actor ControlledLibraryCatalog: CatalogProviding {
    private var albumContinuation: CheckedContinuation<[PathfinderAlbum], Never>?
    private var artistContinuation: CheckedContinuation<[PathfinderArtist], Never>?
    private(set) var albumRequestCount = 0
    private(set) var artistRequestCount = 0

    func libraryAlbums() async -> [PathfinderAlbum] {
        albumRequestCount += 1
        return await withCheckedContinuation { albumContinuation = $0 }
    }

    func libraryArtists() async -> [PathfinderArtist] {
        artistRequestCount += 1
        return await withCheckedContinuation { artistContinuation = $0 }
    }

    func completeAlbums() {
        albumContinuation?.resume(returning: [])
        albumContinuation = nil
    }

    func completeArtists() {
        artistContinuation?.resume(returning: [])
        artistContinuation = nil
    }

    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] { throw WorkflowFailure.unavailable }
    func home() async throws -> PathfinderHome { throw WorkflowFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw WorkflowFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw WorkflowFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw WorkflowFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw WorkflowFailure.unavailable }
}

private actor EmptyDetailCatalog: CatalogProviding {
    private(set) var albumRequestCount = 0
    private(set) var artistRequestCount = 0
    private(set) var discographyRequestCount = 0

    func album(id: String) -> PathfinderAlbumUnion {
        albumRequestCount += 1
        return PathfinderAlbumUnion(
            uri: "spotify:album:\(id)",
            name: "Empty Album",
            type: "album",
            date: nil,
            coverArt: nil,
            artists: nil,
            tracksV2: PathfinderAlbumUnion.TrackList(items: [], totalCount: 0)
        )
    }

    func artist(id: String) -> PathfinderArtistUnion {
        artistRequestCount += 1
        return PathfinderArtistUnion(
            uri: "spotify:artist:\(id)",
            id: id,
            profile: PathfinderArtistUnion.Profile(name: "Empty Artist"),
            visuals: nil,
            discography: nil
        )
    }

    func artistDiscography(id: String) -> PathfinderArtistUnion {
        discographyRequestCount += 1
        return PathfinderArtistUnion(
            uri: "spotify:artist:\(id)",
            id: id,
            profile: nil,
            visuals: nil,
            discography: nil
        )
    }

    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] { throw WorkflowFailure.unavailable }
    func home() async throws -> PathfinderHome { throw WorkflowFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw WorkflowFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw WorkflowFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw WorkflowFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw WorkflowFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw WorkflowFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw WorkflowFailure.unavailable }
}

private actor ControlledMetadataRemote: RemotePlaybackClient {
    private var continuations: [String: CheckedContinuation<SpotifyConnectTrackMetadata, any Error>] = [:]
    private(set) var requestedURIs: [String] = []
    private(set) var activeRequests = 0
    private(set) var maximumActiveRequests = 0

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        requestedURIs.append(uri)
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[uri] = continuation
            }
        } onCancel: {
            Task { await self.cancel(uri) }
        }
    }

    func complete(_ uri: String) {
        guard let continuation = continuations.removeValue(forKey: uri) else { return }
        activeRequests -= 1
        continuation.resume(returning: SpotifyConnectTrackMetadata(
            uri: uri,
            title: "Title \(uri)",
            artist: "Artist",
            artworkURL: nil,
            duration: 180
        ))
    }

    private func cancel(_ uri: String) {
        guard let continuation = continuations.removeValue(forKey: uri) else { return }
        activeRequests -= 1
        continuation.resume(throwing: CancellationError())
    }
}

private enum WorkflowFailure: Error { case unavailable }

private final class WorkflowEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<RustPlaybackEventEnvelope>.Continuation?
    private var storage: [String: Int] = [:]

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
        }
    }

    func emit(_ envelope: RustPlaybackEventEnvelope) {
        lock.lock(); let continuation = continuation; lock.unlock()
        continuation?.yield(envelope)
    }

    func count(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storage[name, default: 0]
    }

    private func record(_ name: String) {
        lock.lock(); storage[name, default: 0] += 1; lock.unlock()
    }

    func authorizeStreaming(with _: String) -> Int32 { record("authorize"); return 0 }
    func initialize() -> PlaybackEngineResult { record("initialize"); return .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { record("execute"); return .ok }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshotJSON() -> String? { nil }
    func configureHighQualityPlayback() { record("configure") }
    func shutdown() -> PlaybackEngineResult { record("shutdown"); return .ok }
    func cleanup() { record("cleanup") }
    func clearStreamingCredentials() { record("clearCredentials") }
    func disconnect() -> PlaybackEngineResult { record("disconnect"); return .ok }
    func forceReconnect() -> Int32 { record("reconnect"); return 0 }
}

private final class WorkflowAccount: AccountSession, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?
    private var clearStorage = 0
    var hasStoredGrant = true

    var clearCount: Int {
        lock.lock(); defer { lock.unlock() }
        return clearStorage
    }

    func authorizeInteractively() async throws -> KeymasterTokens {
        KeymasterTokens(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            expiresAt: .distantFuture,
            username: "fixture-user"
        )
    }
    func hasGrant() async -> Bool { hasStoredGrant }
    func accessToken() async throws -> String { "fixture-access" }
    func adopt(_: KeymasterTokens) async throws {}
    func clear() async { lock.withLock { clearStorage += 1 } }
    func revocations() -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
        }
    }
    func revoke() {
        lock.lock(); let continuation = continuation; lock.unlock()
        continuation?.yield(())
    }
}

private final class WorkflowLifecycle: SystemLifecycleEvents, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<SystemLifecycleEvent>.Continuation?
    func events() -> AsyncStream<SystemLifecycleEvent> {
        AsyncStream { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
        }
    }
    func emit(_ event: SystemLifecycleEvent) {
        lock.lock(); let continuation = continuation; lock.unlock()
        continuation?.yield(event)
    }
}

private actor WorkflowPreferences: PlaybackPreferences {
    var shuffle = false
    var remoteID: String?
    var history: [String: TimeInterval] = [:]
    func shuffleEnabled() -> Bool { shuffle }
    func setShuffleEnabled(_ enabled: Bool) { shuffle = enabled }
    func lastRemoteDeviceID() -> String? { remoteID }
    func setLastRemoteDeviceID(_ id: String?) { remoteID = id }
    func shuffleHistory() -> [String: TimeInterval] { history }
    func setShuffleHistory(_ value: [String: TimeInterval]) { history = value }
}

private struct WorkflowAudio: AudioOutputPreparing { func prepareForPlayback() throws {} }
private struct WorkflowClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {}
}
private struct WorkflowAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}
private struct WorkflowCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] { throw WorkflowFailure.unavailable }
    func home() async throws -> PathfinderHome { throw WorkflowFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw WorkflowFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw WorkflowFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw WorkflowFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw WorkflowFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw WorkflowFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw WorkflowFailure.unavailable }
}

@MainActor
func runWorkflowChecks(_ runner: CheckRunner) async {
    runner.suite("Sidebar navigation serialization") {
        let selection = SidebarSelection.playlist("spotify:playlist:sensitive-fixture")
        runner.equal("selection round-trips through scene storage", SidebarSelection(rawValue: selection.rawValue), selection)
        runner.equal("diagnostics retain the media kind", selection.diagnosticLabel, "media:playlist")
        runner.check("diagnostics omit the Spotify entity id", !selection.diagnosticLabel.contains("sensitive-fixture"))
    }

    await runner.suite("Injected playback coordinator") {
        let local = RecordingLocalEngine()
        let remote = RecordingRemoteClient()
        let coordinator = PlaybackCoordinator(local: local, remote: remote)

        let localResult: Result<Void, PlaybackCommandFailure>
        do {
            localResult = try await coordinator.performLocalCommand(.pause)
        } catch {
            runner.check("fake local command succeeds", false)
            return
        }
        try? await coordinator.performRemote(.shuffle(true), from: "source", to: "target")

        if case .success = localResult {
            runner.check("fake local command succeeds", true)
        } else {
            runner.check("fake local command succeeds", false)
        }
        runner.equal("one local command recorded", local.operations.count, 1)
        if case .pause? = local.operations.first {
            runner.check("pause command reaches injected engine", true)
        } else {
            runner.check("pause command reaches injected engine", false)
        }
        let endpoints = await remote.endpoints
        runner.equal("one remote command recorded", endpoints.count, 1)
        runner.equal("shuffle reaches injected remote", endpoints.first, .shuffle)
    }

    await runner.suite("Queue workflow invalidation") {
        let webQueue = SuspendedWebQueue()
        let remote = RecordingRemoteClient()
        let service = QueueService(
            webQueue: webQueue,
            metadata: TrackMetadataService(remote: remote)
        )
        await service.reset(accountEpoch: 7)

        let refresh = Task {
            await service.refresh(
                fallbackEntries: [],
                currentTrackURI: "spotify:track:old",
                accountEpoch: 7
            )
        }
        while await webQueue.requestCount == 0 { await Task.yield() }

        await service.reset(accountEpoch: 8)
        await webQueue.complete(with: [workflowTrack("spotify:track:stale")])
        let staleResult = await refresh.value
        runner.nil_("old-account web result is rejected after reset", staleResult)

        let accepted = await service.acceptConnect(
            [QueueEntry(uri: "spotify:track:fresh", provider: "connect", occurrence: 0)],
            accountEpoch: 8,
            sourceRevision: 1,
            contextURI: "spotify:track:fresh"
        )
        runner.equal("new-account queue remains authoritative", accepted?.accountEpoch, 8)
        runner.equal("new-account queue retains fresh entry", accepted?.entries.first?.uri, "spotify:track:fresh")

        let wrongAccount = await service.acceptConnect(
            [QueueEntry(uri: "spotify:track:wrong", provider: "connect", occurrence: 0)],
            accountEpoch: 7,
            sourceRevision: 2,
            contextURI: "spotify:track:wrong"
        )
        runner.nil_("a stale account cannot read the replacement queue", wrongAccount)
    }

    await runner.suite("Queue rate-limit cooldown and metadata bounds") {
        let webQueue = RateLimitedWebQueue()
        let service = QueueService(
            webQueue: webQueue,
            metadata: TrackMetadataService(remote: RecordingRemoteClient()),
            clock: WorkflowClock()
        )
        await service.reset(accountEpoch: 1)
        _ = await service.refresh(fallbackEntries: [], currentTrackURI: nil, accountEpoch: 1)
        _ = await service.refresh(fallbackEntries: [], currentTrackURI: nil, accountEpoch: 1)
        runner.equal("a 429 starts a session cooldown instead of retrying on every open", await webQueue.requestCount, 1)

        await service.reset(accountEpoch: 2)
        _ = await service.refresh(fallbackEntries: [], currentTrackURI: nil, accountEpoch: 2)
        runner.equal("a new account gets a fresh Web queue capability probe", await webQueue.requestCount, 2)

        let old = workflowQueueSnapshot(
            revision: 1,
            contextURI: "spotify:track:old",
            entryURI: "spotify:track:old"
        )
        let replacement = workflowQueueSnapshot(
            revision: 2,
            contextURI: "spotify:track:new",
            entryURI: "spotify:track:new"
        )
        let merged = mergeQueueSnapshots(current: old, incoming: replacement)
        runner.equal("replacement queues discard unreachable metadata", merged.tracks.map(\.uri), ["spotify:track:new"])

        let connectUID = workflowQueueSnapshot(
            revision: 4,
            contextURI: "spotify:track:same",
            entryURI: "spotify:track:same",
            uid: "occ-4"
        )
        let webLabels = workflowQueueSnapshot(
            revision: 5,
            contextURI: "spotify:track:same",
            entryURI: "spotify:track:same",
            source: .webAPI,
            provider: "web-api"
        )
        let labeled = mergeQueueSnapshots(current: connectUID, incoming: webLabels)
        runner.equal(
            "Web metadata merge keeps the Connect occurrence uid for the same URI index",
            labeled.entries.first?.uid ?? "",
            "occ-4"
        )
        let changedURI = workflowQueueSnapshot(
            revision: 6,
            contextURI: "spotify:track:changed",
            entryURI: "spotify:track:changed"
        )
        runner.equal(
            "Web metadata merge does not invent a uid when the URI at that index changed",
            mergeQueueSnapshots(current: connectUID, incoming: changedURI).entries.first?.uid ?? "",
            ""
        )
    }

    await runner.suite("Progressive queue metadata") {
        let remote = ControlledMetadataRemote()
        let metadata = TrackMetadataService(remote: remote)
        let service = QueueService(webQueue: UnavailableWebQueue(), metadata: metadata)
        await service.reset(accountEpoch: 3)
        let entries = (0 ..< 12).map {
            QueueEntry(uri: "spotify:track:\($0)", provider: "queue", occurrence: $0)
        }
        var updates: [ProvenanceQueueSnapshot] = []
        let refresh = Task {
            await service.refresh(
                fallbackEntries: entries,
                cachedTracks: [workflowTrack("spotify:track:0"), workflowTrack("spotify:track:1")],
                currentTrackURI: "spotify:track:current",
                accountEpoch: 3,
                onUpdate: { updates.append($0) }
            )
        }

        while await remote.requestedURIs.count < 8 { await Task.yield() }
        runner.equal("queue ordering is published before network hydration completes", updates.first?.entries.count, 12)
        runner.equal("cached metadata is included in the first update", updates.first?.tracks.count, 2)
        runner.equal("metadata concurrency is bounded", await remote.maximumActiveRequests, 8)

        let initiallyRequested = await remote.requestedURIs
        if let first = initiallyRequested.first { await remote.complete(first) }
        while await remote.requestedURIs.count < 9 { await Task.yield() }
        runner.check("a completed lookup publishes an incremental update", updates.contains { $0.tracks.count == 3 })

        var completed: Set<String> = Set(initiallyRequested.prefix(1))
        while completed.count < 10 {
            for uri in await remote.requestedURIs where completed.insert(uri).inserted {
                await remote.complete(uri)
            }
            await Task.yield()
        }
        let final = await refresh.value
        runner.equal("all queue metadata eventually hydrates", final?.tracks.count, 12)
        runner.equal("hydration completion marks the queue complete", final?.completeness, .complete)
        runner.equal("queue ordering never changes during enrichment", final?.entries.map(\.id), entries.map(\.id))
    }

    await runner.suite("Shared metadata request coalescing") {
        let remote = ControlledMetadataRemote()
        let metadata = TrackMetadataService(remote: remote)
        let uri = "spotify:track:shared"
        let first = Task { try? await metadata.metadata(for: uri) }
        let second = Task { try? await metadata.metadata(for: uri) }
        while await remote.requestedURIs.isEmpty { await Task.yield() }
        runner.equal("concurrent consumers issue one remote lookup", await remote.requestedURIs.count, 1)
        await remote.complete(uri)
        let values = await [first.value, second.value]
        runner.equal("both consumers receive the shared result", values.compactMap { $0 }.count, 2)
        _ = try? await metadata.metadata(for: uri)
        runner.equal("the account-scoped cache avoids a second lookup", await remote.requestedURIs.count, 1)
    }

    runner.suite("Bounded queue metadata retention") {
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(
            attributesProvider: WorkflowAttributes(),
            session: session
        )
        let queued = workflowTrack("spotify:track:queued")
        let unrelated = workflowTrack("spotify:track:unrelated")

        metadata.retainTracks(from: .queue, for: [queued.uri])
        metadata.replaceTracks([queued], from: .playlist)
        metadata.replaceTracks([unrelated], from: .playlist)
        metadata.replaceTracks([], from: .queue)
        metadata.replaceTracks([], from: .playlist)

        runner.equal(
            "visited playlist metadata survives for the active queue",
            metadata.knownTrack(for: queued.uri)?.uri,
            queued.uri
        )
        runner.nil_(
            "unrelated playlist metadata is not retained with the queue",
            metadata.knownTrack(for: unrelated.uri)
        )

        metadata.retainTracks(from: .queue, for: [])
        metadata.replaceTracks([], from: .queue)
        runner.nil_("queue metadata is released when its ordering clears", metadata.knownTrack(for: queued.uri))
    }

    await runner.suite("Independent library section lifetimes") {
        let provider = ControlledLibraryCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(
            attributesProvider: WorkflowAttributes(),
            session: session
        )
        let store = HomeLibraryStore(provider: provider, metadata: metadata, session: session)

        let albums = Task { await store.loadAlbums() }
        while await provider.albumRequestCount == 0 { await Task.yield() }
        let albumFollower = Task { await store.loadAlbums() }
        let artists = Task { await store.loadArtists() }
        while await provider.artistRequestCount == 0 { await Task.yield() }

        runner.equal("duplicate requests for one section coalesce", await provider.albumRequestCount, 1)

        await provider.completeAlbums()
        await provider.completeArtists()
        await albums.value
        await albumFollower.value
        await artists.value

        runner.check("overlapping album load remains current", store.loadedSections.contains(.albums))
        runner.check("overlapping artist load remains current", store.loadedSections.contains(.artists))
        runner.check("both independent loading indicators finish", !store.isLoading)
    }

    await runner.suite("Empty media detail caching") {
        let provider = EmptyDetailCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let metadata = CatalogMetadataRepository(
            attributesProvider: WorkflowAttributes(),
            session: session
        )
        let albumStore = AlbumDetailStore(provider: provider, metadata: metadata, session: session)
        let artistStore = ArtistDetailStore(provider: provider, session: session)
        let album = CatalogItem(
            id: "empty-album",
            uri: "spotify:album:empty-album",
            title: "Empty Album",
            subtitle: "",
            artworkURL: nil,
            kind: .album
        )
        let artist = CatalogItem(
            id: "empty-artist",
            uri: "spotify:artist:empty-artist",
            title: "Empty Artist",
            subtitle: "",
            artworkURL: nil,
            kind: .artist
        )

        await albumStore.load(album)
        await albumStore.load(album)
        await artistStore.load(artist)
        await artistStore.load(artist)

        runner.equal("an empty album is still a completed load", await provider.albumRequestCount, 1)
        runner.equal("an empty artist overview is still a completed load", await provider.artistRequestCount, 1)
        runner.equal("an empty discography is still a completed load", await provider.discographyRequestCount, 1)

        session.update(accountEpoch: 1, isAvailable: false)
        session.update(accountEpoch: 1, isAvailable: true)
        await albumStore.load(album)
        await artistStore.load(artist)
        runner.equal("a new catalog session reloads the album", await provider.albumRequestCount, 2)
        runner.equal("a new catalog session reloads the artist", await provider.artistRequestCount, 2)
    }

    await runner.suite("Complete PlaybackStore lifecycle with injected environment") {
        let engine = WorkflowEngine()
        let account = WorkflowAccount()
        let lifecycle = WorkflowLifecycle()
        let environment = PlaybackEnvironment(
            remote: RecordingRemoteClient(),
            local: engine,
            webQueue: UnavailableWebQueue(),
            account: account,
            audioOutput: WorkflowAudio(),
            preferences: WorkflowPreferences(),
            lifecycle: lifecycle,
            clock: WorkflowClock(),
            catalog: WorkflowCatalog(),
            playlistMutations: UnavailablePlaylistMutations(),
            trackAttributes: WorkflowAttributes()
        )
        let player = PlaybackStore(
            environment: environment,
            feedback: TransientFeedbackPresenter(clock: environment.clock)
        )
        await player.restore()
        runner.equal("stored grant restores the real store", player.phase, .ready)
        runner.equal("engine initializes once", engine.count("initialize"), 1)

        lifecycle.emit(.willSleep)
        while engine.count("disconnect") == 0 { await Task.yield() }
        lifecycle.emit(.didWake)
        while engine.count("reconnect") == 0 { await Task.yield() }
        runner.equal("sleep disconnects once", engine.count("disconnect"), 1)
        runner.equal("wake reconnects once", engine.count("reconnect"), 1)

        let oldEpoch = player.state.accountEpoch
        await player.logout()
        runner.equal("logout clears the grant", account.clearCount, 1)
        runner.equal("logout advances account identity", player.state.accountEpoch, oldEpoch + 1)
        runner.equal("logout shuts the engine down once", engine.count("shutdown"), 1)
        runner.equal("logout clears presentation", player.trackURI, "")

        engine.emit(RustPlaybackEventEnvelope(
            sequence: 99,
            receivedAt: Date(),
            event: .playback(RustPlaybackState(
                revision: 99,
                sessionGeneration: 0,
                isPlaying: true,
                isPaused: false,
                trackURI: "spotify:track:stale",
                positionMS: 1_000,
                durationMS: 10_000,
                timestampMS: nil,
                shuffle: false,
                repeatTrack: false,
                repeatContext: false
            ))
        ))
        await Task.yield()
        runner.equal("old engine callback cannot repopulate signed-out state", player.trackURI, "")

        await player.shutdownForTermination()
        await player.shutdownForTermination()
        runner.equal("termination shutdown is idempotent", engine.count("shutdown"), 2)
    }
}

private func workflowTrack(_ uri: String) -> CatalogTrack {
    CatalogTrack(
        id: uri,
        uri: uri,
        title: "Track",
        artist: "Artist",
        album: "Album",
        duration: 180,
        artworkURL: nil,
        addedAt: nil
    )
}

private func workflowQueueSnapshot(
    revision: UInt64,
    contextURI: String,
    entryURI: String,
    source: QueueSnapshotSource = .connect,
    uid: String = "",
    provider: String = "connect"
) -> ProvenanceQueueSnapshot {
    ProvenanceQueueSnapshot(
        accountEpoch: 1,
        revision: revision,
        source: source,
        completeness: .complete,
        receivedAt: Date(timeIntervalSince1970: TimeInterval(revision)),
        contextURI: contextURI,
        entries: [QueueEntry(uri: entryURI, provider: provider, occurrence: 0, uid: uid)],
        tracks: [workflowTrack(entryURI)]
    )
}
