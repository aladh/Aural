import AuralDomain
import Foundation
@testable import AuralCore

private final class GatedPositionEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var didStart = false
    var milliseconds: UInt32 = 42_000

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { .ok }
    func positionMilliseconds() -> UInt32 {
        lock.lock()
        didStart = true
        lock.unlock()
        gate.wait()
        return milliseconds
    }
    func queueSnapshot() -> RustQueueState? { nil }
    func configureHighQualityPlayback() {}
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }

    func release() {
        gate.signal()
    }
}

private final class GatedQueueSnapshotEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var didStart = false
    private var snapshot: RustQueueState?

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStart
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { .ok }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? {
        lock.lock()
        didStart = true
        lock.unlock()
        gate.wait()
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
    func configureHighQualityPlayback() {}
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }

    func release(_ snapshot: RustQueueState) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
        gate.signal()
    }
}

private final class IdleLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }
    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { .ok }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? { nil }
    func configureHighQualityPlayback() {}
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }
}

private actor GatedMetadataRemote: RemotePlaybackClient {
    private var continuation: CheckedContinuation<SpotifyConnectTrackMetadata, Never>?
    private(set) var requestedURI: String?

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        requestedURI = uri
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete(title: String = "Resolved") {
        guard let uri = requestedURI else { return }
        continuation?.resume(
            returning: SpotifyConnectTrackMetadata(
                uri: uri,
                title: title,
                artist: "Artist",
                artworkURL: nil,
                duration: 180
            )
        )
        continuation = nil
    }
}

private actor ImmediateMetadataRemote: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri,
            title: "Resolved",
            artist: "Artist",
            artworkURL: nil,
            duration: 180
        )
    }
}

private actor IdleWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
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

private final class IdleAccount: AccountSession, @unchecked Sendable {
    func authorizeInteractively() async throws -> KeymasterTokens { throw CancellationError() }
    func hasGrant() async -> Bool { false }
    func accessToken() async throws -> String { "fixture-access" }
    func adopt(_: KeymasterTokens) async throws {}
    func clear() async {}
    func revocations() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

private final class IdleLifecycle: SystemLifecycleEvents, @unchecked Sendable {
    func events() -> AsyncStream<SystemLifecycleEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor IdlePreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private actor RecordingOwnerPreferences: PlaybackPreferences {
    private var remoteID: String?

    func seed(_ id: String?) { remoteID = id }
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { remoteID }
    func setLastRemoteDeviceID(_ id: String?) { remoteID = id }
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private struct IdleAudio: AudioOutputPreparing { func prepareForPlayback() throws {} }

private struct StickyClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

private struct IdleAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

private enum OutcomeCheckFailure: Error { case unavailable }

private struct IdleCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] {
        throw OutcomeCheckFailure.unavailable
    }
    func home() async throws -> PathfinderHome { throw OutcomeCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw OutcomeCheckFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw OutcomeCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw OutcomeCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw OutcomeCheckFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw OutcomeCheckFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw OutcomeCheckFailure.unavailable }
}

private func outcomeEnvironment(
    local: any LocalPlaybackEngine = IdleLocalEngine(),
    remote: any RemotePlaybackClient,
    webQueue: any WebQueueClient = IdleWebQueue(),
    preferences: any PlaybackPreferences = IdlePreferences()
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: remote,
        local: local,
        webQueue: webQueue,
        account: IdleAccount(),
        audioOutput: IdleAudio(),
        preferences: preferences,
        lifecycle: IdleLifecycle(),
        clock: StickyClock(),
        catalog: IdleCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: IdleAttributes()
    )
}

@MainActor
private func playbackStore(_ environment: PlaybackEnvironment) -> PlaybackStore {
    PlaybackStore(
        environment: environment,
        feedback: TransientFeedbackPresenter(clock: environment.clock)
    )
}

private func fixtureTrack(_ uri: String, title: String) -> CatalogTrack {
    CatalogTrack(
        id: uri,
        uri: uri,
        title: title,
        artist: "Artist",
        album: "Album",
        duration: 180,
        artworkURL: nil,
        addedAt: nil
    )
}

private func fixtureQueueSnapshot(
    accountEpoch: UInt64,
    revision: UInt64,
    uri: String,
    title: String
) -> ProvenanceQueueSnapshot {
    ProvenanceQueueSnapshot(
        accountEpoch: accountEpoch,
        revision: revision,
        source: .connect,
        completeness: .complete,
        receivedAt: Date(timeIntervalSince1970: TimeInterval(revision)),
        contextURI: uri,
        entries: [QueueEntry(uri: uri, provider: "connect", occurrence: 0)],
        tracks: [fixtureTrack(uri, title: title)]
    )
}

@MainActor
private func seedReadyLocalPlayback(
    _ player: PlaybackStore,
    uri: String,
    title: String? = "Now",
    metadataSource: MetadataProvenance = .catalog
) {
    let device = PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)
    _ = player.send(.session(.ready), source: .account)
    _ = player.send(
        .devices(
            PlaybackDeviceSnapshot(
                devices: [device],
                localDeviceID: "mac",
                revision: 1
            )),
        source: .engineDevices,
        revision: 1
    )
    _ = player.send(
        .presentation(
            PlaybackPresentationSnapshot(
                currentTrack: CurrentTrack(
                    uri: uri,
                    title: title,
                    artist: title == nil ? nil : "Artist",
                    duration: 200,
                    metadataSource: metadataSource
                ),
                transport: .playing,
                timing: PlaybackTiming(
                    position: 5,
                    duration: 200,
                    anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            )),
        source: .user
    )
}

private func queueSnapshot(
    uri: String,
    revision: UInt64 = 1,
    sessionGeneration: UInt64 = 1
) -> RustQueueState {
    RustQueueState(
        revision: revision,
        sessionGeneration: sessionGeneration,
        track: RustQueueState.Item(uri: uri, provider: "context", uid: "occ-now"),
        protocolNextTracks: [],
        protocolPrevTracks: [],
        queueRevision: "",
        disallowSetQueue: false,
        disallowRemovingFromNextTracks: false
    )
}

@MainActor
private func bumpEngine(_ player: PlaybackStore) {
    _ = player.send(
        .engineConnection(
            EngineConnectionSnapshot(
                session: .ready,
                owner: player.state.owner,
                localDeviceID: player.localDeviceID
            )),
        source: .engineConnection,
        revision: (player.state.sourceRevisions[.engineConnection] ?? 0) + 1,
        engineEpoch: player.engineGeneration + 1
    )
}

@MainActor
private func startTrackResolution(_ player: PlaybackStore, uri: String) {
    player.receive(
        RustPlaybackState(
            revision: 1,
            sessionGeneration: player.engineGeneration,
            isPlaying: true,
            isPaused: false,
            trackURI: uri,
            contextURI: "",
            positionMS: 1_000,
            durationMS: 180_000,
            timestampMS: 0,
            shuffle: false,
            repeatTrack: false,
            repeatContext: false
        ),
        revision: 1,
        receivedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
}

@MainActor
private func awaitCapturedEffect(
    _ settlement: PlaybackEffectSettlement?,
    _ runner: CheckRunner,
    registered: String
) async {
    runner.notNil(registered, settlement)
    await settlement?.wait()
}

@MainActor
func runPlaybackEventOutcomeChecks(_ runner: CheckRunner) async {
    await runner.suite("Track metadata outcomes re-enter through PlaybackEvent") {
        let successRemote = GatedMetadataRemote()
        let success = playbackStore(outcomeEnvironment(remote: successRemote))
        startTrackResolution(success, uri: "spotify:track:success")
        runner.check(
            "metadata lookup starts", await waitUntil { await successRemote.requestedURI == "spotify:track:success" })
        success.recordPlayed("spotify:track:success")
        await successRemote.complete()
        runner.check(
            "accepted metadata updates the current track",
            await waitUntil { success.state.currentTrack?.title == "Resolved" }
        )
        runner.equal("accepted metadata uses connect provenance", success.state.currentTrack?.metadataSource, .connect)
        runner.equal(
            "history enrichment waits for reducer acceptance", success.history.entries.first?.title, "Resolved")
        await success.shutdownForTermination()

        let staleEngineRemote = GatedMetadataRemote()
        let staleEngine = playbackStore(outcomeEnvironment(remote: staleEngineRemote))
        startTrackResolution(staleEngine, uri: "spotify:track:stale-engine")
        runner.check(
            "stale-engine metadata lookup starts", await waitUntil { await staleEngineRemote.requestedURI != nil })
        let staleEngineMetadata = staleEngine.effects.settlement(of: .trackMetadata)
        bumpEngine(staleEngine)
        await staleEngineRemote.complete(title: "Late engine")
        await awaitCapturedEffect(
            staleEngineMetadata,
            runner,
            registered: "stale-engine metadata effect is registered before invalidation"
        )
        runner.nil_("stale-engine metadata does not mutate the current title", staleEngine.state.currentTrack?.title)
        runner.check("stale-engine metadata does not create history", staleEngine.history.entries.isEmpty)
        await staleEngine.shutdownForTermination()

        let staleAccountRemote = GatedMetadataRemote()
        let staleAccount = playbackStore(outcomeEnvironment(remote: staleAccountRemote))
        startTrackResolution(staleAccount, uri: "spotify:track:stale-account")
        runner.check(
            "stale-account metadata lookup starts", await waitUntil { await staleAccountRemote.requestedURI != nil })
        staleAccount.recordPlayed("spotify:track:stale-account")
        let staleAccountMetadata = staleAccount.effects.settlement(of: .trackMetadata)
        staleAccount.accountStore.advanceEpoch()
        _ = staleAccount.send(
            .reset(session: .signedOut),
            source: .account,
            accountEpoch: staleAccount.accountEpoch
        )
        await staleAccountRemote.complete(title: "Late account")
        await awaitCapturedEffect(
            staleAccountMetadata,
            runner,
            registered: "stale-account metadata effect is registered before invalidation"
        )
        runner.nil_("stale-account metadata cannot revive a reset track", staleAccount.state.currentTrack)
        runner.equal(
            "stale-account metadata does not enrich history after reset",
            staleAccount.history.entries.first?.title,
            "Unknown track"
        )
        await staleAccount.shutdownForTermination()

        let cancelRemote = GatedMetadataRemote()
        let cancelled = playbackStore(outcomeEnvironment(remote: cancelRemote))
        startTrackResolution(cancelled, uri: "spotify:track:cancelled")
        runner.check("cancelled metadata lookup starts", await waitUntil { await cancelRemote.requestedURI != nil })
        cancelled.recordPlayed("spotify:track:cancelled")
        let cancelledMetadata = cancelled.effects.settlement(of: .trackMetadata)
        cancelled.effects.cancel(.trackMetadata)
        await cancelRemote.complete(title: "Cancelled")
        await awaitCapturedEffect(
            cancelledMetadata,
            runner,
            registered: "cancelled metadata effect is registered before cancellation"
        )
        runner.nil_("cancelled metadata is inert", cancelled.state.currentTrack?.title)
        runner.equal(
            "cancelled metadata does not enrich history", cancelled.history.entries.first?.title, "Unknown track")
        await cancelled.shutdownForTermination()

        let rejectedRemote = GatedMetadataRemote()
        let rejected = playbackStore(outcomeEnvironment(remote: rejectedRemote))
        startTrackResolution(rejected, uri: "spotify:track:original")
        runner.check(
            "reducer-rejection metadata lookup starts",
            await waitUntil { await rejectedRemote.requestedURI == "spotify:track:original" })
        rejected.recordPlayed("spotify:track:original")
        _ = rejected.send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: CurrentTrack(uri: "spotify:track:other", title: "Other", metadataSource: .catalog),
                    transport: .paused,
                    timing: PlaybackTiming(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000))
                )),
            source: .user
        )
        let rejectedMetadata = rejected.effects.settlement(of: .trackMetadata)
        await rejectedRemote.complete(title: "From original")
        await awaitCapturedEffect(
            rejectedMetadata,
            runner,
            registered: "reducer-rejection metadata effect is registered before completion"
        )
        runner.equal(
            "metadata for a previous track is rejected", rejected.state.currentTrack?.uri, "spotify:track:other")
        runner.equal(
            "rejected metadata does not enrich the prior history row", rejected.history.entries.first?.title,
            "Unknown track")
        await rejected.shutdownForTermination()
    }

    await runner.suite("Position refresh outcomes re-enter through timing") {
        let successEngine = GatedPositionEngine()
        let success = playbackStore(
            outcomeEnvironment(local: successEngine, remote: ImmediateMetadataRemote())
        )
        seedReadyLocalPlayback(success, uri: "spotify:track:playing")
        success.refreshPosition()
        runner.check("position refresh starts", await waitUntil { successEngine.hasStarted })
        successEngine.release()
        runner.check(
            "accepted timing replaces the anchored position",
            await waitUntil { success.state.timing.position == 42 }
        )
        await success.shutdownForTermination()

        let staleAccountEngine = GatedPositionEngine()
        let staleAccount = playbackStore(
            outcomeEnvironment(local: staleAccountEngine, remote: ImmediateMetadataRemote())
        )
        seedReadyLocalPlayback(staleAccount, uri: "spotify:track:playing")
        staleAccount.refreshPosition()
        runner.check("stale-account position refresh starts", await waitUntil { staleAccountEngine.hasStarted })
        let staleAccountPosition = staleAccount.effects.settlement(of: .positionRefresh)
        staleAccount.accountStore.advanceEpoch()
        _ = staleAccount.send(
            .reset(session: .signedOut),
            source: .account,
            accountEpoch: staleAccount.accountEpoch
        )
        staleAccountEngine.release()
        await awaitCapturedEffect(
            staleAccountPosition,
            runner,
            registered: "stale-account position refresh is registered before invalidation"
        )
        runner.equal(
            "stale-account position refresh cannot stamp signed-out timing", staleAccount.state.timing.position, 0)
        await staleAccount.shutdownForTermination()

        let staleEngineEngine = GatedPositionEngine()
        let staleEngine = playbackStore(
            outcomeEnvironment(local: staleEngineEngine, remote: ImmediateMetadataRemote())
        )
        seedReadyLocalPlayback(staleEngine, uri: "spotify:track:playing")
        staleEngine.refreshPosition()
        runner.check("stale-engine position refresh starts", await waitUntil { staleEngineEngine.hasStarted })
        let staleEnginePosition = staleEngine.effects.settlement(of: .positionRefresh)
        bumpEngine(staleEngine)
        staleEngineEngine.release()
        await awaitCapturedEffect(
            staleEnginePosition,
            runner,
            registered: "stale-engine position refresh is registered before invalidation"
        )
        runner.equal("stale-engine position refresh is inert", staleEngine.state.timing.position, 5)
        await staleEngine.shutdownForTermination()

        let cancelEngine = GatedPositionEngine()
        let cancelled = playbackStore(
            outcomeEnvironment(local: cancelEngine, remote: ImmediateMetadataRemote())
        )
        seedReadyLocalPlayback(cancelled, uri: "spotify:track:playing")
        cancelled.refreshPosition()
        runner.check("cancelled position refresh starts", await waitUntil { cancelEngine.hasStarted })
        let cancelledPosition = cancelled.effects.settlement(of: .positionRefresh)
        cancelled.effects.cancel(.positionRefresh)
        cancelEngine.release()
        await awaitCapturedEffect(
            cancelledPosition,
            runner,
            registered: "cancelled position refresh is registered before cancellation"
        )
        runner.equal("cancelled position refresh is inert", cancelled.state.timing.position, 5)
        await cancelled.shutdownForTermination()
    }

    await runner.suite("Queue adoption is stamped and gates catalog metadata") {
        let player = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
        _ = player.send(.session(.ready), source: .account)
        player.catalogSession.update(accountEpoch: player.accountEpoch, isAvailable: true)

        let firstURI = "spotify:track:first"
        player.apply(
            fixtureQueueSnapshot(accountEpoch: player.accountEpoch, revision: 1, uri: firstURI, title: "First"),
            engineEpoch: player.engineGeneration
        )
        runner.equal("accepted queue replaces ordering", player.state.queue.entries.first?.uri, firstURI)
        runner.equal(
            "accepted queue retains catalog metadata", player.catalog.metadata.knownTrack(for: firstURI)?.title, "First"
        )

        let duplicateURI = "spotify:track:duplicate"
        player.apply(
            fixtureQueueSnapshot(accountEpoch: player.accountEpoch, revision: 1, uri: duplicateURI, title: "Duplicate"),
            engineEpoch: player.engineGeneration
        )
        runner.equal("a duplicate queue revision is rejected", player.state.queue.entries.first?.uri, firstURI)
        runner.nil_(
            "rejected queue state does not replace catalog metadata",
            player.catalog.metadata.knownTrack(for: duplicateURI))
        runner.equal(
            "rejected queue keeps the accepted catalog row", player.catalog.metadata.knownTrack(for: firstURI)?.title,
            "First")

        let capturedEngine = player.engineGeneration
        bumpEngine(player)
        let staleEngineURI = "spotify:track:stale-engine"
        player.apply(
            fixtureQueueSnapshot(
                accountEpoch: player.accountEpoch, revision: 2, uri: staleEngineURI, title: "Late engine"),
            engineEpoch: capturedEngine
        )
        runner.equal("stale-engine queue adoption is inert", player.state.queue.entries.first?.uri, firstURI)
        runner.nil_(
            "stale-engine queue does not retain catalog metadata",
            player.catalog.metadata.knownTrack(for: staleEngineURI))

        player.accountStore.advanceEpoch()
        _ = player.send(
            .reset(session: .signedOut),
            source: .account,
            accountEpoch: player.accountEpoch
        )
        let staleAccountURI = "spotify:track:stale-account"
        player.apply(
            fixtureQueueSnapshot(accountEpoch: 1, revision: 3, uri: staleAccountURI, title: "Late account"),
            engineEpoch: player.engineGeneration
        )
        runner.check("stale-account queue adoption is inert", player.state.queue.entries.isEmpty)
        runner.nil_(
            "stale-account queue does not retain catalog metadata",
            player.catalog.metadata.knownTrack(for: staleAccountURI))
        await player.shutdownForTermination()

        let webQueue = SuspendedWebQueue()
        let cancelled = playbackStore(
            outcomeEnvironment(remote: ImmediateMetadataRemote(), webQueue: webQueue)
        )
        await cancelled.restore()
        _ = cancelled.send(.session(.ready), source: .account)
        cancelled.catalogSession.update(accountEpoch: cancelled.accountEpoch, isAvailable: true)
        cancelled.refreshQueue()
        runner.check("queue refresh starts", await waitUntil { await webQueue.requestCount == 1 })
        let cancelledQueueRefresh = cancelled.effects.settlement(of: .queueRefresh)
        cancelled.cancelQueueRefresh()
        await webQueue.complete(with: [fixtureTrack("spotify:track:cancelled-queue", title: "Cancelled")])
        await awaitCapturedEffect(
            cancelledQueueRefresh,
            runner,
            registered: "cancelled queue refresh is registered before cancellation"
        )
        runner.check("cancelled queue refresh does not adopt ordering", cancelled.state.queue.entries.isEmpty)
        runner.nil_(
            "cancelled queue refresh does not retain catalog metadata",
            cancelled.catalog.metadata.knownTrack(for: "spotify:track:cancelled-queue")
        )
        await cancelled.shutdownForTermination()
    }

    await runner.suite("Queue snapshot track identity uses captured lifetime") {
        let namedEngine = GatedQueueSnapshotEngine()
        let namedRemote = GatedMetadataRemote()
        let named = playbackStore(
            outcomeEnvironment(local: namedEngine, remote: namedRemote)
        )
        let uri = "spotify:track:same"
        seedReadyLocalPlayback(named, uri: uri)
        named.recordPlayed(uri)
        named.refreshQueueSnapshot()
        runner.check("named queue snapshot fetch starts", await waitUntil { namedEngine.hasStarted })
        let namedSnapshot = named.effects.settlement(of: .queueSnapshot)
        bumpEngine(named)
        namedEngine.release(queueSnapshot(uri: uri))
        await awaitCapturedEffect(
            namedSnapshot,
            runner,
            registered: "stale named snapshot effect is registered before invalidation"
        )
        runner.equal("stale named snapshot cannot replace now-playing title", named.state.currentTrack?.title, "Now")
        runner.equal(
            "stale named snapshot cannot replace now-playing artist", named.state.currentTrack?.artist, "Artist")
        runner.equal(
            "stale named snapshot does not enrich history", named.history.entries.first?.title, "Unknown track")
        runner.nil_("stale named snapshot does not start metadata resolution", await namedRemote.requestedURI)
        await named.shutdownForTermination()

        let missingEngine = GatedQueueSnapshotEngine()
        let missingRemote = GatedMetadataRemote()
        let missing = playbackStore(
            outcomeEnvironment(local: missingEngine, remote: missingRemote)
        )
        seedReadyLocalPlayback(missing, uri: uri, title: nil, metadataSource: .none)
        missing.recordPlayed(uri)
        missing.refreshQueueSnapshot()
        runner.check("nameless queue snapshot fetch starts", await waitUntil { missingEngine.hasStarted })
        let missingSnapshot = missing.effects.settlement(of: .queueSnapshot)
        bumpEngine(missing)
        missingEngine.release(queueSnapshot(uri: uri))
        await awaitCapturedEffect(
            missingSnapshot,
            runner,
            registered: "stale nameless snapshot effect is registered before invalidation"
        )
        runner.nil_("stale nameless snapshot cannot install a title", missing.state.currentTrack?.title)
        runner.equal("stale nameless snapshot keeps the current URI", missing.state.currentTrack?.uri, uri)
        runner.equal(
            "stale nameless snapshot does not enrich history",
            missing.history.entries.first?.title,
            "Unknown track"
        )
        runner.nil_("stale nameless snapshot does not launch a metadata resolver", await missingRemote.requestedURI)
        await missing.shutdownForTermination()

        let watermarkEngine = GatedQueueSnapshotEngine()
        let watermarkStore = playbackStore(
            outcomeEnvironment(local: watermarkEngine, remote: ImmediateMetadataRemote())
        )
        seedReadyLocalPlayback(watermarkStore, uri: uri)
        let before = watermarkStore.connectQueueCallback
        watermarkStore.refreshQueueSnapshot()
        runner.check("watermark snapshot fetch starts", await waitUntil { watermarkEngine.hasStarted })
        let watermarkSnapshot = watermarkStore.effects.settlement(of: .queueSnapshot)
        bumpEngine(watermarkStore)
        watermarkEngine.release(queueSnapshot(uri: uri, revision: 9))
        await awaitCapturedEffect(
            watermarkSnapshot,
            runner,
            registered: "stale watermark snapshot effect is registered before invalidation"
        )
        runner.equal(
            "a stale snapshot does not advance the callback generation",
            watermarkStore.connectQueueCallback.generation,
            before.generation
        )
        runner.equal(
            "a stale snapshot does not advance the callback revision",
            watermarkStore.connectQueueCallback.revision,
            before.revision
        )
        runner.check(
            "a later live callback can still start a fresh revision namespace",
            watermarkStore.acceptsConnectQueueCallback(
                generation: watermarkStore.engineGeneration,
                revision: 1
            )
        )
        await watermarkStore.shutdownForTermination()

        let payloadEngine = GatedQueueSnapshotEngine()
        let payloadStore = playbackStore(
            outcomeEnvironment(local: payloadEngine, remote: ImmediateMetadataRemote())
        )
        await payloadStore.restore()
        seedReadyLocalPlayback(payloadStore, uri: uri)
        let mirroredGeneration = payloadStore.engineGeneration
        let payloadGeneration = mirroredGeneration + 1
        payloadStore.refreshQueueSnapshot()
        runner.check("payload-generation snapshot fetch starts", await waitUntil { payloadEngine.hasStarted })
        payloadEngine.release(
            queueSnapshot(
                uri: uri,
                revision: 3,
                sessionGeneration: payloadGeneration
            )
        )
        runner.check(
            "decoded payload generation stamps reducer state before playback catches up",
            await waitUntil { payloadStore.state.engineEpoch == payloadGeneration }
        )
        runner.equal(
            "decoded payload generation stamps presentation",
            payloadStore.engineGeneration,
            payloadGeneration
        )
        runner.equal(
            "decoded payload generation keeps now-playing title",
            payloadStore.state.currentTrack?.title,
            "Now"
        )
        runner.check(
            "decoded payload generation stamps the mutation snapshot",
            await waitUntil { payloadStore.queueMutation?.engineEpoch == payloadGeneration }
        )
        runner.equal(
            "decoded payload generation does not stamp the pre-await mirror",
            payloadStore.queueMutation?.engineEpoch == mirroredGeneration,
            false
        )
        await payloadStore.shutdownForTermination()

        let bumpedEngine = GatedQueueSnapshotEngine()
        let bumpedStore = playbackStore(
            outcomeEnvironment(local: bumpedEngine, remote: ImmediateMetadataRemote())
        )
        await bumpedStore.restore()
        seedReadyLocalPlayback(bumpedStore, uri: uri)
        let beforeBump = bumpedStore.engineGeneration
        bumpedStore.refreshQueueSnapshot()
        runner.check("bumped-engine snapshot fetch starts", await waitUntil { bumpedEngine.hasStarted })
        bumpEngine(bumpedStore)
        let liveGeneration = bumpedStore.engineGeneration
        runner.check("playback adopted a newer engine epoch during the snapshot await", liveGeneration > beforeBump)
        bumpedEngine.release(
            queueSnapshot(
                uri: uri,
                revision: 4,
                sessionGeneration: liveGeneration
            )
        )
        runner.check(
            "a snapshot decoded after a live engine bump still stamps the payload generation",
            await waitUntil { bumpedStore.state.engineEpoch == liveGeneration }
        )
        runner.equal(
            "a live-generation snapshot keeps reducer epoch aligned", bumpedStore.state.engineEpoch, liveGeneration)
        runner.check(
            "a live-generation snapshot stamps mutation with the payload, not the pre-await mirror",
            await waitUntil { bumpedStore.queueMutation?.engineEpoch == liveGeneration }
        )
        await bumpedStore.shutdownForTermination()

        let stalePayloadEngine = GatedQueueSnapshotEngine()
        let stalePayload = playbackStore(
            outcomeEnvironment(local: stalePayloadEngine, remote: ImmediateMetadataRemote())
        )
        seedReadyLocalPlayback(stalePayload, uri: uri)
        let staleBefore = stalePayload.engineGeneration
        stalePayload.refreshQueueSnapshot()
        runner.check("stale-payload snapshot fetch starts", await waitUntil { stalePayloadEngine.hasStarted })
        let stalePayloadSnapshot = stalePayload.effects.settlement(of: .queueSnapshot)
        bumpEngine(stalePayload)
        stalePayloadEngine.release(
            queueSnapshot(
                uri: uri,
                revision: 5,
                sessionGeneration: staleBefore
            )
        )
        await awaitCapturedEffect(
            stalePayloadSnapshot,
            runner,
            registered: "stale payload snapshot effect is registered before invalidation"
        )
        runner.equal(
            "a stale payload generation cannot replace now-playing title", stalePayload.state.currentTrack?.title, "Now"
        )
        runner.nil_("a stale payload generation does not install mutation", stalePayload.queueMutation)
        await stalePayload.shutdownForTermination()
    }

    await runner.suite("Device owner resolution stamps last-remote context") {
        let mac = ConnectDevice(id: "mac", name: "Mac", type: "computer", isActive: false)
        let phone = ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: false)
        let activePhone = ConnectDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
        let pausedURI = "spotify:track:paused-remote"
        let expectedPhone = PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: false)

        @MainActor
        func seedIdentity(_ player: PlaybackStore) {
            _ = player.send(.session(.ready), source: .account)
            _ = player.send(
                .engineConnection(
                    EngineConnectionSnapshot(
                        session: .ready,
                        owner: .none,
                        localDeviceID: "mac"
                    )),
                source: .engineConnection,
                revision: 1,
                engineEpoch: 1
            )
        }

        let launchPreferences = RecordingOwnerPreferences()
        await launchPreferences.seed("phone")
        let launch = playbackStore(
            outcomeEnvironment(remote: ImmediateMetadataRemote(), preferences: launchPreferences)
        )
        seedIdentity(launch)
        launch.lastRemoteDeviceID = "phone"
        launch.receive([mac, phone], revision: 1, engineEpoch: launch.engineGeneration)
        runner.equal("cluster devices-first with no track is none", launch.state.owner, .none)
        runner.equal(
            "the store stamps last-remote context onto the snapshot", launch.state.devices.lastRemoteDeviceID, "phone")
        _ = launch.send(
            .currentTrack(
                CurrentTrack(
                    uri: pausedURI,
                    title: "Paused",
                    artist: "Artist",
                    duration: 180,
                    metadataSource: .connect
                )),
            source: .enginePlayback,
            revision: 1,
            engineEpoch: launch.engineGeneration
        )
        runner.equal(
            "a later URI adopts the stamped last-remote candidate",
            launch.state.owner,
            .uncertain(expectedPhone)
        )
        runner.equal(
            "devices-then-track stays remote-routable",
            launch.commandRoute,
            .remote(from: "mac", to: "phone")
        )
        await launch.shutdownForTermination()

        let remotePreferences = RecordingOwnerPreferences()
        let remoteActive = playbackStore(
            outcomeEnvironment(remote: ImmediateMetadataRemote(), preferences: remotePreferences)
        )
        seedIdentity(remoteActive)
        remoteActive.receive([mac, activePhone], revision: 1, engineEpoch: remoteActive.engineGeneration)
        runner.equal(
            "an active remote snapshot is remote ownership",
            remoteActive.state.owner,
            .remote(PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true))
        )
        runner.equal(
            "the store records last-remote after an accepted active remote", remoteActive.lastRemoteDeviceID, "phone")
        let preferenceWritten: Bool
        if remoteActive.lastRemoteDeviceID == "phone" {
            preferenceWritten = await waitUntil { await remotePreferences.lastRemoteDeviceID() == "phone" }
        } else {
            preferenceWritten = false
        }
        runner.check("an accepted active remote writes the last-remote preference", preferenceWritten)
        await remoteActive.shutdownForTermination()

        let stale = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
        seedIdentity(stale)
        stale.lastRemoteDeviceID = "phone"
        stale.receive([mac, phone], revision: 4, engineEpoch: stale.engineGeneration)
        let afterDevices = stale.state
        stale.receive([mac, activePhone], revision: 3, engineEpoch: stale.engineGeneration)
        runner.equal("a stale device revision does not replace owner", stale.state, afterDevices)
        stale.receive([mac, activePhone], revision: 5, engineEpoch: 0)
        runner.equal("a stale engine epoch does not replace owner", stale.state, afterDevices)
        let rejected = stale.send(
            .devices(
                PlaybackDeviceSnapshot(
                    devices: [
                        PlaybackDevice(id: "mac", name: "Mac", type: "computer"),
                        PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true),
                    ],
                    localDeviceID: "mac",
                    revision: 5,
                    lastRemoteDeviceID: "phone"
                )),
            source: .engineDevices,
            revision: 5,
            engineEpoch: stale.engineGeneration,
            accountEpoch: 0
        )
        runner.check("a stale account epoch is rejected", !rejected)
        runner.equal("a stale account epoch does not replace owner", stale.state, afterDevices)
        await stale.shutdownForTermination()

        let teardown = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
        seedIdentity(teardown)
        teardown.lastRemoteDeviceID = nil
        let beforeTeardown = teardown.state
        teardown.isTearingDown = true
        teardown.receive([mac, activePhone], revision: 1, engineEpoch: teardown.engineGeneration)
        runner.equal("teardown device intake is inert", teardown.state, beforeTeardown)
        runner.nil_("teardown does not record last-remote from a discarded snapshot", teardown.lastRemoteDeviceID)
        await teardown.shutdownForTermination()
    }

    await runner.suite("Orchestration clock stamps send, timing, and history") {
        let clockNow = Date(timeIntervalSince1970: 1_800_000_000)
        let receipt = Date(timeIntervalSince1970: 1_800_000_050)
        let player = playbackStore(outcomeEnvironment(remote: ImmediateMetadataRemote()))
        seedReadyLocalPlayback(player, uri: "spotify:track:clocked")

        _ = player.setTiming(position: 12)
        runner.equal("setTiming without an anchor uses the injected clock", player.state.timing.anchoredAt, clockNow)
        runner.equal("setTiming preserves the commanded position", player.state.timing.position, 12)

        _ = player.setTiming(position: 40, anchoredAt: receipt)
        runner.equal(
            "an explicit timing anchor is not replaced by clock.now()", player.state.timing.anchoredAt, receipt)

        player.hasReceivedPlaybackSnapshot = true
        player.receive(
            RustPlaybackState(
                revision: 2,
                sessionGeneration: player.engineGeneration,
                isPlaying: true,
                isPaused: false,
                trackURI: "spotify:track:clocked",
                contextURI: "",
                positionMS: 40_000,
                durationMS: 200_000,
                timestampMS: 0,
                shuffle: false,
                repeatTrack: false,
                repeatContext: false
            ),
            revision: 2,
            receivedAt: receipt
        )
        runner.equal(
            "engine intake anchors from receipt time, not the later orchestration clock",
            player.state.timing.anchoredAt,
            receipt
        )
        runner.equal(
            "engine playback records the backend revision, not receipt time",
            player.state.sourceRevisions[.enginePlayback], 2)
        runner.equal(
            "playing snapshots still interpolate from receipt time",
            player.displayedPosition(at: receipt.addingTimeInterval(0.25)),
            40.25
        )

        player.recordPlayed("spotify:track:clocked")
        runner.equal(
            "played history uses the injected orchestration clock", player.history.entries.first?.playedAt, clockNow)
        runner.equal(
            "shuffle history uses the same orchestration clock instant",
            player.playbackHistory()["spotify:track:clocked"],
            clockNow.timeIntervalSince1970
        )
        await player.shutdownForTermination()
    }
}
