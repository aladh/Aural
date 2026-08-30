import AuralDomain
import Foundation
@testable import AuralCore

private final class QueueLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let result: PlaybackEngineResult
    private var storedOperations: [LocalPlaybackOperation] = []

    init(result: PlaybackEngineResult = .ok) {
        self.result = result
    }

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
        return result
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

private enum QueueRemoteFailure: Error { case boom }

private actor QueueRemoteClient: RemotePlaybackClient {
    enum Behavior: Sendable {
        case succeed
        case fail
        case failAfter(Int)
        case park
    }

    private let behavior: Behavior
    private var parked: CheckedContinuation<Void, Error>?
    private var parkID: UInt64 = 0
    private(set) var commands: [SpotifyConnectCommand] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    var sendCount: Int { commands.count }

    func send(_ command: SpotifyConnectCommand, from _: String, to _: String) async throws {
        commands.append(command)
        switch behavior {
        case .succeed:
            return
        case .fail:
            throw QueueRemoteFailure.boom
        case let .failAfter(limit):
            if commands.count > limit {
                throw QueueRemoteFailure.boom
            }
        case .park:
            parkID &+= 1
            let id = parkID
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    parked?.resume(throwing: CancellationError())
                    parked = continuation
                }
            } onCancel: {
                Task { await self.completePark(id: id, success: false, cancelled: true) }
            }
        }
    }

    func completePark(success: Bool) {
        completePark(id: parkID, success: success, cancelled: false)
    }

    private func completePark(id: UInt64, success: Bool, cancelled: Bool) {
        guard id == parkID, let parked else { return }
        self.parked = nil
        if cancelled {
            parked.resume(throwing: CancellationError())
        } else if success {
            parked.resume()
        } else {
            parked.resume(throwing: QueueRemoteFailure.boom)
        }
    }

    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(
            uri: uri, title: "Metadata", artist: "Artist", artworkURL: nil, duration: 180
        )
    }
}

private actor IdleQueueWeb: WebQueueClient {
    func queue() async throws -> [CatalogTrack] { throw URLError(.badServerResponse) }
}

private final class IdleQueueAccount: AccountSession, @unchecked Sendable {
    func authorizeInteractively() async throws -> KeymasterTokens { throw CancellationError() }
    func hasGrant() async -> Bool { false }
    func accessToken() async throws -> String { "fixture-access" }
    func adopt(_: KeymasterTokens) async throws {}
    func clear() async {}
    func revocations() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private final class IdleQueueLifecycle: SystemLifecycleEvents, @unchecked Sendable {
    func events() -> AsyncStream<SystemLifecycleEvent> { AsyncStream { $0.finish() } }
}

private actor IdleQueuePreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private struct IdleQueueAudio: AudioOutputPreparing { func prepareForPlayback() throws {} }
private struct IdleQueueAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

private enum QueueCheckFailure: Error { case unavailable }

private struct IdleQueueCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] { throw QueueCheckFailure.unavailable }
    func home() async throws -> PathfinderHome { throw QueueCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw QueueCheckFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw QueueCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw QueueCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw QueueCheckFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw QueueCheckFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw QueueCheckFailure.unavailable }
}

private func isolatedQueueService(
    hook: (any QueueServiceHook)? = nil
) -> QueueService {
    QueueService(
        webQueue: IdleQueueWeb(),
        metadata: TrackMetadataService(remote: QueueRemoteClient(.succeed)),
        hook: hook
    )
}

private func connectEntry(_ uri: String, occurrence: Int = 0) -> QueueEntry {
    QueueEntry(uri: uri, provider: "connect", occurrence: occurrence)
}

private func queueEnvironment(
    local: any LocalPlaybackEngine = QueueLocalEngine(),
    remote: any RemotePlaybackClient,
    clock: any PlaybackClock = SystemPlaybackClock(),
    queueServiceHook: (any QueueServiceHook)? = nil
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: remote,
        local: local,
        webQueue: IdleQueueWeb(),
        account: IdleQueueAccount(),
        audioOutput: IdleQueueAudio(),
        preferences: IdleQueuePreferences(),
        lifecycle: IdleQueueLifecycle(),
        clock: clock,
        catalog: IdleQueueCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: IdleQueueAttributes(),
        queueServiceHook: queueServiceHook
    )
}

@MainActor
private func seedReady(_ player: PlaybackStore) {
    _ = player.send(.session(.ready), source: .account)
}

@MainActor
private func seedRemoteOwner(_ player: PlaybackStore) {
    seedReady(player)
    _ = player.send(
        .devices(
            PlaybackDeviceSnapshot(
                devices: [
                    PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                    PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true),
                ],
                localDeviceID: "mac",
                revision: 1
            )),
        source: .engineDevices,
        revision: 1
    )
    _ = player.send(
        .owner(.remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
        source: .command
    )
}

@MainActor
private func seedLocalOwner(_ player: PlaybackStore) {
    seedReady(player)
    _ = player.send(
        .owner(.local(PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true))),
        source: .command
    )
}

@MainActor
private func seedAuthoritativeQueue(_ player: PlaybackStore, revision: UInt64 = 4) async {
    let duplicate = "spotify:track:dup"
    let other = "spotify:track:other"
    let entries = [
        QueueEntry(uri: duplicate, provider: "queue", occurrence: 0, uid: "q0"),
        QueueEntry(uri: duplicate, provider: "queue", occurrence: 1, uid: "q1"),
        QueueEntry(uri: other, provider: "queue", occurrence: 2, uid: "q2"),
    ]
    let next = [
        QueueProtocolTrack(uri: duplicate, uid: "q0", provider: "queue"),
        QueueProtocolTrack(uri: duplicate, uid: "q1", provider: "queue"),
        QueueProtocolTrack(uri: other, uid: "q2", provider: "queue"),
        QueueProtocolTrack(uri: "spotify:delimiter", uid: "", provider: "delimiter"),
        QueueProtocolTrack(uri: "spotify:track:autoplay", uid: "a0", provider: "autoplay"),
    ]
    let prev = [QueueProtocolTrack(uri: "spotify:track:prev", uid: "p0", provider: "context")]
    await player.queueService.reset(accountEpoch: player.accountEpoch)
    if let accepted = await player.queueService.acceptConnect(
        entries,
        accountEpoch: player.accountEpoch,
        sourceRevision: revision,
        contextURI: "spotify:track:now",
        engineEpoch: player.engineGeneration,
        protocolNext: next,
        protocolPrev: prev,
        queueRevision: "rev-\(revision)"
    ) {
        player.queueMutation = accepted.mutation
    }
    _ = player.send(
        .queue(
            PlaybackQueueSnapshot(
                entries: entries.map { PlaybackQueueItem($0) },
                source: .connect,
                completeness: .complete,
                revision: revision,
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
                contextURI: "spotify:track:now"
            )),
        source: .engineQueue,
        revision: revision,
        engineEpoch: player.engineGeneration,
        accountEpoch: player.accountEpoch
    )
}

@MainActor
private func yieldPasses(_ count: Int = 8) async {
    for _ in 0..<count { await Task.yield() }
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

private func jsonStringMap(_ value: Any?) -> [String: String] {
    if let typed = value as? [String: String] { return typed }
    guard let object = value as? [String: Any] else { return [:] }
    return object.reduce(into: [:]) { result, pair in
        if let string = pair.value as? String {
            result[pair.key] = string
        }
    }
}

@MainActor
private func invokeKeyboardQueueDelete(player: PlaybackStore, selectedIDs: Set<String>) {
    let selectedCount = QueueMutationSelection.orderedUpcoming(
        selectedIDs: selectedIDs,
        in: player.queueNextEntries
    ).count
    guard
        QueueMutationSelection.keyboardCommand(
            deleteOrBackspace: true,
            selectedUpcomingCount: selectedCount,
            isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: selectedIDs)
        ) == .removeUpcomingOccurrences
    else {
        return
    }
    player.removeUpcomingQueueOccurrences(selectedIDs: selectedIDs)
}

private func connectQueueEnvelope(
    sequence: UInt64,
    revision: UInt64,
    sessionGeneration: UInt64
) -> RustPlaybackEventEnvelope {
    RustPlaybackEventEnvelope(
        sequence: sequence,
        receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
        event: .queue(connectQueueState(revision: revision, sessionGeneration: sessionGeneration))
    )
}

private func connectQueueState(revision: UInt64, sessionGeneration: UInt64) -> RustQueueState {
    let next = [
        ("spotify:track:dup", "q0"),
        ("spotify:track:other", "q2"),
    ]
    return RustQueueState(
        track: RustQueueState.Item(
            uri: "spotify:track:now",
            name: "Now",
            artist: "Artist",
            imageURL: "",
            durationMS: 1
        ),
        nextTracks: next.map { RustQueueState.QueueItem(uri: $0.0, provider: "queue", uid: $0.1) },
        prevTracks: [],
        protocolNextTracks: next.map {
            RustQueueState.ProtocolTrack(
                uri: $0.0,
                uid: $0.1,
                provider: "queue",
                metadata: [:],
                removed: [],
                blocked: [],
                restrictions: [:],
                albumURI: "",
                disallowReasons: [],
                artistURI: ""
            )
        },
        protocolPrevTracks: [],
        queueRevision: "rev-\(revision)",
        disallowSetQueue: false,
        disallowRemovingFromNextTracks: false,
        revision: revision,
        sessionGeneration: sessionGeneration
    )
}

@MainActor
func runQueueManagementChecks(_ runner: CheckRunner) async {
    runner.suite("Connect set_queue encoding") {
        runner.noThrow("set_queue encodes remaining next_tracks and required prev_tracks") {
            let command = SpotifyConnectCommand.setQueue(
                next: [
                    QueueProtocolTrack(
                        uri: "spotify:track:keep",
                        uid: "q0",
                        provider: "queue",
                        metadata: ["aural.sentinel": "keep-me", "is_queued": "true"]
                    ),
                    QueueProtocolTrack(
                        uri: "spotify:delimiter",
                        uid: "",
                        provider: "delimiter",
                        metadata: ["aural.sentinel": "delimiter-keep"]
                    ),
                    QueueProtocolTrack(
                        uri: "spotify:track:autoplay",
                        uid: "a0",
                        provider: "autoplay",
                        metadata: ["aural.sentinel": "autoplay-keep"]
                    ),
                ],
                prev: [
                    QueueProtocolTrack(
                        uri: "spotify:track:prev",
                        uid: "p0",
                        provider: "context",
                        metadata: ["aural.sentinel": "prev-keep"]
                    )
                ],
                queueRevision: "rev-9"
            )
            let encoded = try JSONEncoder().encode(command)
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            runner.equal("set_queue endpoint is encoded", object?["endpoint"] as? String, "set_queue")
            runner.equal("set_queue revision is encoded", object?["queue_revision"] as? String, "rev-9")
            let next = object?["next_tracks"] as? [[String: Any]]
            runner.equal("next_tracks keeps remaining occurrence uid", next?.first?["uid"] as? String, "q0")
            runner.equal("next_tracks keeps delimiter", next?[1]["uri"] as? String, "spotify:delimiter")
            runner.equal("next_tracks keeps autoplay", next?.last?["uri"] as? String, "spotify:track:autoplay")
            let prev = object?["prev_tracks"] as? [[String: Any]]
            runner.equal("prev_tracks are preserved", prev?.first?["uri"] as? String, "spotify:track:prev")
            runner.equal(
                "incoming metadata is not synthesized",
                jsonStringMap(next?.first?["metadata"])["aural.sentinel"] ?? "",
                "keep-me"
            )
            runner.equal(
                "queued is_queued survives only when present on the snapshot",
                jsonStringMap(next?.first?["metadata"])["is_queued"] ?? "",
                "true"
            )
            runner.equal(
                "delimiter sentinel metadata survives encode",
                jsonStringMap(next?[1]["metadata"])["aural.sentinel"] ?? "",
                "delimiter-keep"
            )
            runner.equal(
                "autoplay sentinel metadata survives encode",
                jsonStringMap(next?.last?["metadata"])["aural.sentinel"] ?? "",
                "autoplay-keep"
            )
            runner.equal(
                "prev_tracks sentinel metadata survives encode",
                jsonStringMap(prev?.first?["metadata"])["aural.sentinel"] ?? "",
                "prev-keep"
            )
        }
    }

    runner.suite("Rust protocol JSON round-trips metadata into set_queue") {
        runner.noThrow("sentinel metadata survives Rust JSON, Swift decode, and Connect encode") {
            let rustJSON = """
                {
                  "protocol_next_tracks": [
                    {
                      "uri": "spotify:track:keep",
                      "uid": "q0",
                      "provider": "queue",
                      "metadata": {"aural.sentinel": "keep-me", "is_queued": "true"},
                      "album_uri": "spotify:album:fixture",
                      "artist_uri": "spotify:artist:fixture"
                    },
                    {
                      "uri": "spotify:delimiter",
                      "uid": "",
                      "provider": "delimiter",
                      "metadata": {"aural.sentinel": "delimiter-keep"}
                    },
                    {
                      "uri": "spotify:track:autoplay",
                      "uid": "a0",
                      "provider": "autoplay",
                      "metadata": {"aural.sentinel": "autoplay-keep"}
                    }
                  ],
                  "protocol_prev_tracks": [
                    {
                      "uri": "spotify:track:prev",
                      "uid": "p0",
                      "provider": "context",
                      "metadata": {"aural.sentinel": "prev-keep"},
                      "removed": ["removed-reason"]
                    }
                  ],
                  "queue_revision": "rev-roundtrip"
                }
                """
            let state = try JSONDecoder().decode(
                RustQueueState.self,
                from: Data(rustJSON.utf8)
            )
            let next = (state.protocolNextTracks ?? []).map { $0.domainTrack() }
            let prev = (state.protocolPrevTracks ?? []).map { $0.domainTrack() }
            runner.equal("decoded next sentinel", next.first?.metadata["aural.sentinel"] ?? "", "keep-me")
            runner.equal("decoded album_uri", next.first?.albumURI ?? "", "spotify:album:fixture")
            runner.equal("decoded prev removed", prev.first?.removed ?? [], ["removed-reason"])
            let encoded = try JSONEncoder().encode(
                SpotifyConnectCommand.setQueue(
                    next: next,
                    prev: prev,
                    queueRevision: state.queueRevision ?? ""
                )
            )
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            let encodedNext = object?["next_tracks"] as? [[String: Any]]
            let encodedPrev = object?["prev_tracks"] as? [[String: Any]]
            runner.equal(
                "round-trip next sentinel",
                jsonStringMap(encodedNext?.first?["metadata"])["aural.sentinel"] ?? "",
                "keep-me"
            )
            runner.equal(
                "round-trip delimiter sentinel",
                jsonStringMap(encodedNext?[1]["metadata"])["aural.sentinel"] ?? "",
                "delimiter-keep"
            )
            runner.equal(
                "round-trip autoplay sentinel",
                jsonStringMap(encodedNext?.last?["metadata"])["aural.sentinel"] ?? "",
                "autoplay-keep"
            )
            runner.equal(
                "round-trip prev sentinel",
                jsonStringMap(encodedPrev?.first?["metadata"])["aural.sentinel"] ?? "",
                "prev-keep"
            )
            runner.equal(
                "round-trip prev removed", encodedPrev?.first?["removed"] as? [String] ?? [], ["removed-reason"])
            runner.equal(
                "round-trip album_uri", encodedNext?.first?["album_uri"] as? String ?? "", "spotify:album:fixture")
        }
    }

    await runner.suite("Ordered multi-add routing") {
        let remote = QueueRemoteClient(.succeed)
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
        seedRemoteOwner(player)
        player.addToQueue(uris: ["spotify:track:one", "spotify:track:one", "spotify:track:two"])
        runner.check("ordered add finished", await waitUntil { await remote.sendCount == 3 })
        let endpoints = await remote.commands.map(\.endpoint)
        runner.equal(
            "multi-add sends add_to_queue in visible order, including duplicate URIs",
            endpoints,
            [.addToQueue, .addToQueue, .addToQueue]
        )
        runner.equal("multi-add reports a batch success", feedback.message?.text, "Added 3 songs to Queue")
        runner.equal("multi-add success is not a playback notice", player.transientCommandError, nil)
        await player.shutdownForTermination()
    }

    await runner.suite("Ordered multi-add partial failure feedback") {
        let remote = QueueRemoteClient(.failAfter(2))
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
        seedRemoteOwner(player)
        let before = player.queueNextEntries
        player.addToQueue(uris: ["spotify:track:one", "spotify:track:two", "spotify:track:three"])
        runner.check("partial add finished", await waitUntil { feedback.message?.kind == .informational })
        runner.equal("two commands completed before failure", await remote.sendCount, 3)
        runner.equal(
            "partial add reports completed versus requested",
            feedback.message?.text,
            "Added 2 of 3 songs to Queue"
        )
        runner.equal("partial add does not rewrite presentation", player.queueNextEntries, before)
        await player.shutdownForTermination()

        let none = QueueRemoteClient(.fail)
        let noneFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let nonePlayer = PlaybackStore(environment: queueEnvironment(remote: none), feedback: noneFeedback)
        seedRemoteOwner(nonePlayer)
        nonePlayer.addToQueue(uris: ["spotify:track:one", "spotify:track:two"])
        runner.check("zero-success add finished", await waitUntil { noneFeedback.message?.kind == .failure })
        runner.equal(
            "zero completed commands keep the batch failure message",
            noneFeedback.message?.text,
            "Could not add those tracks to the queue."
        )
        await nonePlayer.shutdownForTermination()
    }

    await runner.suite("Duplicate-occurrence deletion and no local edit") {
        let remote = QueueRemoteClient(.succeed)
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let secondDuplicate = player.queueNextEntries[1].id
        let before = player.queueNextEntries
        runner.equal("projection keeps typed upcoming occurrences", before.map(\.occurrence), [0, 1, 2])
        runner.equal("projection keeps occurrence uids", before.map(\.uid), ["q0", "q1", "q2"])
        player.removeUpcomingQueueOccurrences(selectedIDs: [secondDuplicate])
        runner.check("set_queue was sent", await waitUntil { await remote.sendCount == 1 })
        let command = await remote.commands.first
        runner.equal("removal uses set_queue", command?.endpoint, .setQueue)
        runner.equal(
            "removal keeps the first duplicate occurrence",
            command?.nextTracks?.map(\.uid),
            ["q0", "q2", "", "a0"]
        )
        runner.equal(
            "removal preserves prev_tracks",
            command?.prevTracks?.map(\.uid),
            ["p0"]
        )
        runner.equal("success does not locally rewrite presentation", player.queueNextEntries, before)
        runner.equal("removal reports through transient feedback", feedback.message?.text, "Removed from Queue")
        await player.shutdownForTermination()
    }

    await runner.suite("Delete enablement, now-playing, and history exclusion") {
        let remote = QueueRemoteClient(.succeed)
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let upcoming = player.queueNextEntries
        runner.check(
            "Delete is enabled for a complete remote upcoming selection",
            player.canRemoveUpcomingQueue(selectedIDs: [upcoming[0].id])
        )
        runner.equal(
            "keyboard routing matches enablement",
            QueueMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                selectedUpcomingCount: 1,
                isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: [upcoming[0].id])
            ),
            .removeUpcomingOccurrences
        )
        player.removeUpcomingQueueOccurrences(selectedIDs: ["now-playing"])
        runner.equal(
            "now-playing cannot be removed",
            feedback.message?.text,
            QueueMutationRefusal.nowPlayingOrHistory.feedbackMessage
        )
        runner.equal("now-playing refusal does not send a command", await remote.sendCount, 0)
        player.removeUpcomingQueueOccurrences(selectedIDs: Set(player.history.entries.map(\.id)))
        runner.check("empty history selection is a no-op or not a mutation", await remote.sendCount == 0)
        await player.shutdownForTermination()
    }

    await runner.suite("Incomplete, restricted, and unsupported capability") {
        let remote = QueueRemoteClient(.succeed)
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let id = player.queueNextEntries[0].id
        let before = player.queueNextEntries

        player.queueMutation?.completeness = .partial
        player.removeUpcomingQueueOccurrences(selectedIDs: [id])
        runner.equal(
            "partial provenance explains and does not mutate",
            feedback.message?.text,
            QueueMutationRefusal.incompleteProvenance.feedbackMessage
        )
        runner.equal("partial provenance leaves presentation intact", player.queueNextEntries, before)

        player.queueMutation?.completeness = .complete
        player.queueMutation?.disallowSetQueue = true
        player.removeUpcomingQueueOccurrences(selectedIDs: [id])
        runner.equal(
            "restricted snapshots explain and do not mutate",
            feedback.message?.text,
            QueueMutationRefusal.restricted.feedbackMessage
        )

        let localFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let local = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: localFeedback)
        seedLocalOwner(local)
        await seedAuthoritativeQueue(local)
        let localID = local.queueNextEntries[0].id
        let localBefore = local.queueNextEntries
        local.removeUpcomingQueueOccurrences(selectedIDs: [localID])
        runner.equal(
            "local owner is disabled with a typed explanation",
            localFeedback.message?.text,
            QueueMutationRefusal.localOwnerUnsupported.feedbackMessage
        )
        runner.equal("local owner does not send set_queue", await remote.sendCount, 0)
        runner.equal("local owner leaves presentation intact", local.queueNextEntries, localBefore)
        await player.shutdownForTermination()
        await local.shutdownForTermination()
    }

    await runner.suite("Stale identity, cancellation, rejection, and reconciliation") {
        let failing = QueueRemoteClient(.fail)
        let failFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let rejected = PlaybackStore(environment: queueEnvironment(remote: failing), feedback: failFeedback)
        seedRemoteOwner(rejected)
        await seedAuthoritativeQueue(rejected)
        let rejectedID = rejected.queueNextEntries[0].id
        let rejectedBefore = rejected.queueNextEntries
        rejected.removeUpcomingQueueOccurrences(selectedIDs: [rejectedID])
        runner.check("rejected set_queue finished", await waitUntil { failFeedback.message?.kind == .failure })
        runner.equal("rejection does not rewrite presentation", rejected.queueNextEntries, rejectedBefore)
        runner.equal(
            "rejection uses a typed queue failure", failFeedback.message?.text, "Spotify couldn’t update the queue.")
        await rejected.shutdownForTermination()

        let parked = QueueRemoteClient(.park)
        let cancelFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let cancelled = PlaybackStore(environment: queueEnvironment(remote: parked), feedback: cancelFeedback)
        seedRemoteOwner(cancelled)
        await seedAuthoritativeQueue(cancelled)
        let cancelID = cancelled.queueNextEntries[0].id
        let cancelBefore = cancelled.queueNextEntries
        cancelled.removeUpcomingQueueOccurrences(selectedIDs: [cancelID])
        runner.check("cancelled removal started", await waitUntil { await parked.sendCount == 1 })
        cancelled.effects.cancelAccountScoped()
        await parked.completePark(success: false)
        await yieldPasses()
        runner.nil_("cancelled removal reports no mutation feedback", cancelFeedback.message)
        runner.equal("cancelled removal does not locally edit", cancelled.queueNextEntries, cancelBefore)
        await cancelled.shutdownForTermination()

        let staleRemote = QueueRemoteClient(.park)
        let staleFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let stale = PlaybackStore(environment: queueEnvironment(remote: staleRemote), feedback: staleFeedback)
        seedRemoteOwner(stale)
        await seedAuthoritativeQueue(stale)
        let staleID = stale.queueNextEntries[0].id
        stale.removeUpcomingQueueOccurrences(selectedIDs: [staleID])
        runner.check("stale-account removal started", await waitUntil { await staleRemote.sendCount == 1 })
        stale.accountStore.advanceEpoch()
        await staleRemote.completePark(success: true)
        await yieldPasses()
        runner.nil_("stale-account removal reports no mutation feedback", staleFeedback.message)
        await stale.shutdownForTermination()

        let missingFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let missing = PlaybackStore(
            environment: queueEnvironment(remote: QueueRemoteClient(.succeed)), feedback: missingFeedback)
        seedRemoteOwner(missing)
        await seedAuthoritativeQueue(missing)
        let beforeMissing = missing.queueNextEntries
        missing.removeUpcomingQueueOccurrences(selectedIDs: ["0-missing-spotify:track:nope"])
        runner.equal(
            "stale identities explain and do not mutate",
            missingFeedback.message?.text,
            QueueMutationRefusal.staleIdentities.feedbackMessage
        )
        runner.equal("stale identities leave presentation intact", missing.queueNextEntries, beforeMissing)
        await missing.shutdownForTermination()
    }

    await runner.suite("Overlapping authoritative replacements") {
        let parked = QueueRemoteClient(.park)
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let player = PlaybackStore(environment: queueEnvironment(remote: parked), feedback: feedback)
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let firstID = player.queueNextEntries[0].id
        let secondID = player.queueNextEntries[1].id
        let before = player.queueNextEntries
        player.removeUpcomingQueueOccurrences(selectedIDs: [firstID])
        runner.check("first replacement started", await waitUntil { await parked.sendCount == 1 })
        runner.check(
            "an in-flight replacement disables further removal",
            !player.canRemoveUpcomingQueue(selectedIDs: [secondID])
        )
        runner.nil_(
            "keyboard Delete is gated while a replacement is in flight",
            QueueMutationSelection.keyboardCommand(
                deleteOrBackspace: true,
                selectedUpcomingCount: 1,
                isRemovalAllowed: player.canRemoveUpcomingQueue(selectedIDs: [secondID])
            )
        )
        invokeKeyboardQueueDelete(player: player, selectedIDs: [secondID])
        player.removeUpcomingQueueOccurrences(selectedIDs: [secondID])
        await yieldPasses()
        runner.equal("a second in-flight removal does not send another set_queue", await parked.sendCount, 1)
        runner.nil_("a second in-flight removal does not toast", feedback.message)
        runner.equal("in-flight overlap does not edit presentation", player.queueNextEntries, before)
        await parked.completePark(success: true)
        runner.check(
            "the first replacement finished",
            await waitUntil { feedback.message?.text == "Removed from Queue" }
        )
        runner.nil_("a finished replacement releases the in-flight gate", player.queueReplacementToken)
        runner.equal(
            "committed mutation excludes the occurrence Spotify already dropped",
            player.queueMutation?.next.map(\.uid),
            ["q1", "q2", "", "a0"]
        )
        runner.check(
            "stale visible selection cannot remove until Connect reconciles",
            !player.canRemoveUpcomingQueue(selectedIDs: [firstID])
        )
        player.removeUpcomingQueueOccurrences(selectedIDs: [firstID])
        runner.equal(
            "a follow-up from the stale visible list fails closed",
            feedback.message?.text,
            QueueMutationRefusal.incompleteProvenance.feedbackMessage
        )
        runner.equal("fail-closed follow-up does not send another set_queue", await parked.sendCount, 1)
        await player.shutdownForTermination()
    }

    await runner.suite("Web inspector refresh keeps Connect occurrence order") {
        let remote = QueueRemoteClient(.succeed)
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let before = player.queueNextEntries
        let mutationBefore = player.queueMutation
        player.apply(
            ProvenanceQueueSnapshot(
                accountEpoch: player.accountEpoch,
                revision: 80,
                source: .webAPI,
                completeness: .complete,
                receivedAt: Date(timeIntervalSince1970: 1_800_000_080),
                contextURI: "spotify:track:now",
                entries: [
                    QueueEntry(uri: "spotify:track:reordered", provider: "web-api", occurrence: 0),
                    QueueEntry(uri: "spotify:track:dup", provider: "web-api", occurrence: 1),
                ],
                tracks: [
                    CatalogTrack(
                        id: "spotify:track:dup",
                        uri: "spotify:track:dup",
                        title: "Web Title",
                        artist: "Web Artist",
                        album: "",
                        duration: 180,
                        artworkURL: nil,
                        addedAt: nil
                    )
                ]
            ),
            engineEpoch: player.engineGeneration
        )
        runner.equal(
            "Web refresh does not reorder Connect upcoming entries", player.queueNextEntries.map(\.uri),
            before.map(\.uri))
        runner.equal(
            "Web refresh does not replace Connect occurrence uids", player.queueNextEntries.map(\.uid),
            before.map(\.uid))
        runner.equal("Web refresh does not replace the Connect mutation snapshot", player.queueMutation, mutationBefore)
        runner.check(
            "Connect mutation still matches the visible upcoming list",
            player.canRemoveUpcomingQueue(selectedIDs: [before[0].id])
        )
        await player.shutdownForTermination()
    }

    await runner.suite("Connect queue stamps payload session generation") {
        let remote = QueueRemoteClient(.succeed)
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
        await player.restore()
        seedRemoteOwner(player)
        let mirroredGeneration = player.engineGeneration
        let payloadGeneration = mirroredGeneration + 1
        runner.check(
            "queue can arrive before playback has adopted the payload generation",
            payloadGeneration > mirroredGeneration)

        player.receive(
            connectQueueEnvelope(
                sequence: 1,
                revision: 1,
                sessionGeneration: payloadGeneration
            )
        )
        runner.check(
            "G+1 queue adopts reducer engine epoch from the payload",
            await waitUntil { player.state.engineEpoch == payloadGeneration }
        )
        runner.equal("G+1 queue presentation stamps the payload generation", player.engineGeneration, payloadGeneration)
        runner.equal("G+1 queue presentation keeps the payload track", player.state.currentTrack?.title, "Now")
        runner.check(
            "G+1 queue mutation snapshot uses the payload generation",
            await waitUntil { player.queueMutation?.engineEpoch == payloadGeneration }
        )
        runner.equal(
            "G+1 queue does not leave mutation on the stale mirror",
            player.queueMutation?.engineEpoch == mirroredGeneration,
            false
        )
        runner.equal(
            "callback watermark records the payload generation", player.connectQueueCallback.generation,
            payloadGeneration)
        runner.equal("callback watermark records the payload revision", player.connectQueueCallback.revision, 1)

        let afterFirst = player.connectQueueCallback
        let mutationAfterFirst = player.queueMutation
        let trackAfterFirst = player.state.currentTrack
        player.receive(
            connectQueueEnvelope(
                sequence: 2,
                revision: 1,
                sessionGeneration: payloadGeneration
            )
        )
        await yieldPasses()
        runner.equal(
            "identical redelivery does not advance the callback watermark", player.connectQueueCallback, afterFirst)
        runner.equal(
            "identical redelivery does not replace mutation identity", player.queueMutation, mutationAfterFirst)
        runner.equal(
            "identical redelivery does not replace now-playing identity", player.state.currentTrack, trackAfterFirst)

        player.receive(
            connectQueueEnvelope(
                sequence: 3,
                revision: 2,
                sessionGeneration: mirroredGeneration
            )
        )
        await yieldPasses()
        runner.equal(
            "a stale generation does not advance the callback watermark", player.connectQueueCallback, afterFirst)
        runner.equal("a stale generation does not replace mutation identity", player.queueMutation, mutationAfterFirst)
        runner.equal(
            "a stale generation does not replace now-playing identity", player.state.currentTrack, trackAfterFirst)
        await player.shutdownForTermination()

        let teardownFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let teardown = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: teardownFeedback)
        seedRemoteOwner(teardown)
        let teardownMirror = teardown.engineGeneration
        teardown.isTearingDown = true
        teardown.receive(
            connectQueueEnvelope(
                sequence: 1,
                revision: 1,
                sessionGeneration: teardownMirror + 1
            )
        )
        await yieldPasses()
        runner.equal("teardown queue intake does not adopt the payload engine epoch", teardown.state.engineEpoch, 0)
        runner.nil_("teardown queue intake does not install mutation", teardown.queueMutation)
        runner.nil_("teardown queue intake does not install now-playing", teardown.state.currentTrack)
        runner.equal(
            "teardown queue intake does not record callback identity", teardown.connectQueueCallback.generation, 0)
        await teardown.shutdownForTermination()
    }

    await runner.suite("Connect accept invalidation after suspension") {
        let remote = QueueRemoteClient(.succeed)
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let hook = QueueServiceTestHook()
        let player = PlaybackStore(
            environment: queueEnvironment(remote: remote, queueServiceHook: hook),
            feedback: feedback
        )
        seedRemoteOwner(player)
        await player.queueService.reset(accountEpoch: player.accountEpoch)
        await hook.parkNextConnectAccept()
        player.receive(
            connectQueueEnvelope(
                sequence: 1,
                revision: 1,
                sessionGeneration: player.engineGeneration
            )
        )
        runner.check(
            "connect accept parked after actor hop",
            await waitUntil { await hook.connectAcceptIsParked() }
        )
        player.accountStore.advanceEpoch()
        player.engineGeneration &+= 1
        player.queueMutation = nil
        await hook.resumeConnectAccept()
        await yieldPasses()
        runner.nil_("account and engine invalidation after accept does not restore mutation", player.queueMutation)
        runner.check("invalidated accept does not populate presentation", player.queueNextEntries.isEmpty)

        await player.queueService.reset(accountEpoch: player.accountEpoch)
        await hook.parkNextConnectAccept()
        player.receive(
            connectQueueEnvelope(
                sequence: 2,
                revision: 2,
                sessionGeneration: player.engineGeneration
            )
        )
        runner.check(
            "teardown accept parked",
            await waitUntil { await hook.connectAcceptIsParked() }
        )
        player.isTearingDown = true
        player.queueMutation = nil
        player.effects.cancelAccountScoped()
        await yieldPasses(20)
        runner.nil_("cancelled teardown accept does not restore mutation", player.queueMutation)
        await player.shutdownForTermination()
    }

    await runner.suite("View refresh cancel does not own account queue effects") {
        let parked = QueueRemoteClient(.park)
        let replacementFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let replacement = PlaybackStore(
            environment: queueEnvironment(remote: parked),
            feedback: replacementFeedback
        )
        seedRemoteOwner(replacement)
        await seedAuthoritativeQueue(replacement)
        let removalID = replacement.queueNextEntries[0].id
        replacement.removeUpcomingQueueOccurrences(selectedIDs: [removalID])
        runner.check("parked replacement started", await waitUntil { await parked.sendCount == 1 })
        replacement.cancelQueueRefresh()
        await yieldPasses()
        runner.equal("closing the inspector does not cancel set_queue", await parked.sendCount, 1)
        runner.nil_("inspector close does not toast a cancelled replacement", replacementFeedback.message)
        await parked.completePark(success: true)
        runner.check(
            "replacement still completes after inspector close",
            await waitUntil { replacementFeedback.message?.text == "Removed from Queue" }
        )
        runner.equal(
            "inspector close did not drop the committed mutation",
            replacement.queueMutation?.next.map(\.uid),
            ["q1", "q2", "", "a0"]
        )
        await replacement.shutdownForTermination()

        let acceptFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let acceptHook = QueueServiceTestHook()
        let accept = PlaybackStore(
            environment: queueEnvironment(remote: QueueRemoteClient(.succeed), queueServiceHook: acceptHook),
            feedback: acceptFeedback
        )
        seedRemoteOwner(accept)
        await accept.queueService.reset(accountEpoch: accept.accountEpoch)
        await acceptHook.parkNextConnectAccept()
        accept.receive(
            connectQueueEnvelope(
                sequence: 1,
                revision: 1,
                sessionGeneration: accept.engineGeneration
            )
        )
        runner.check(
            "connect accept parked before inspector close",
            await waitUntil { await acceptHook.connectAcceptIsParked() }
        )
        accept.cancelQueueRefresh()
        await yieldPasses()
        runner.check(
            "closing the inspector does not cancel Connect intake",
            await acceptHook.connectAcceptIsParked()
        )
        await acceptHook.resumeConnectAccept()
        runner.check(
            "Connect accept still applies after inspector close",
            await waitUntil { accept.queueMutation?.next.map(\.uid) == ["q0", "q2"] }
        )
        await accept.shutdownForTermination()

        let teardownRemote = QueueRemoteClient(.park)
        let teardownFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let teardownHook = QueueServiceTestHook()
        let teardown = PlaybackStore(
            environment: queueEnvironment(remote: teardownRemote, queueServiceHook: teardownHook),
            feedback: teardownFeedback
        )
        seedRemoteOwner(teardown)
        await seedAuthoritativeQueue(teardown)
        teardown.removeUpcomingQueueOccurrences(selectedIDs: [teardown.queueNextEntries[0].id])
        runner.check("teardown replacement started", await waitUntil { await teardownRemote.sendCount == 1 })
        await teardownHook.parkNextConnectAccept()
        teardown.receive(
            connectQueueEnvelope(
                sequence: 1,
                revision: 8,
                sessionGeneration: teardown.engineGeneration
            )
        )
        runner.check(
            "teardown accept parked",
            await waitUntil { await teardownHook.connectAcceptIsParked() }
        )
        teardown.queueMutation = nil
        teardown.effects.cancelAccountScoped()
        await yieldPasses(20)
        runner.nil_("account teardown cancels replacement feedback", teardownFeedback.message)
        await teardownRemote.completePark(success: true)
        await yieldPasses()
        runner.nil_(
            "account teardown does not restore replacement mutation from a cancelled task", teardown.queueMutation)
        await teardown.shutdownForTermination()
    }

    await runner.suite("Committed replacement invalidation after suspension") {
        let remote = QueueRemoteClient(.succeed)
        let epochFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let epochHook = QueueServiceTestHook()
        let epochPlayer = PlaybackStore(
            environment: queueEnvironment(remote: remote, queueServiceHook: epochHook),
            feedback: epochFeedback
        )
        seedRemoteOwner(epochPlayer)
        await seedAuthoritativeQueue(epochPlayer)
        await epochHook.parkNextCommittedReplacement()
        epochPlayer.removeUpcomingQueueOccurrences(selectedIDs: [epochPlayer.queueNextEntries[0].id])
        runner.check("set_queue reached the remote", await waitUntil { await remote.sendCount == 1 })
        runner.check(
            "committed replacement parked after the actor hop",
            await waitUntil { await epochHook.committedReplacementIsParked() }
        )
        epochPlayer.accountStore.advanceEpoch()
        epochPlayer.engineGeneration &+= 1
        epochPlayer.queueMutation = nil
        await epochHook.resumeCommittedReplacement()
        await yieldPasses()
        runner.nil_("epoch invalidation after commit hop does not restore mutation", epochPlayer.queueMutation)
        runner.nil_("epoch invalidation after commit hop does not toast success", epochFeedback.message)
        await epochPlayer.shutdownForTermination()

        let cancelRemote = QueueRemoteClient(.succeed)
        let cancelFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let cancelHook = QueueServiceTestHook()
        let cancelPlayer = PlaybackStore(
            environment: queueEnvironment(remote: cancelRemote, queueServiceHook: cancelHook),
            feedback: cancelFeedback
        )
        seedRemoteOwner(cancelPlayer)
        await seedAuthoritativeQueue(cancelPlayer)
        await cancelHook.parkNextCommittedReplacement()
        cancelPlayer.removeUpcomingQueueOccurrences(selectedIDs: [cancelPlayer.queueNextEntries[0].id])
        runner.check(
            "cancelled committed replacement parked",
            await waitUntil { await cancelHook.committedReplacementIsParked() }
        )
        cancelPlayer.queueMutation = nil
        cancelPlayer.effects.cancelAccountScoped()
        await yieldPasses(20)
        runner.nil_("cancelled committed replacement does not restore mutation", cancelPlayer.queueMutation)
        runner.nil_("cancelled committed replacement does not toast", cancelFeedback.message)
        runner.nil_("cancelled committed replacement releases the in-flight gate", cancelPlayer.queueReplacementToken)
        await cancelPlayer.shutdownForTermination()
    }

    await runner.suite("Keyboard Delete matches context-menu enablement") {
        let remote = QueueRemoteClient(.succeed)
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
        seedRemoteOwner(player)
        await seedAuthoritativeQueue(player)
        let allowedID = player.queueNextEntries[0].id
        invokeKeyboardQueueDelete(player: player, selectedIDs: [allowedID])
        runner.check("allowed keyboard Delete sends set_queue", await waitUntil { await remote.sendCount == 1 })

        invokeKeyboardQueueDelete(player: player, selectedIDs: [])
        runner.equal("empty keyboard selection does not send another command", await remote.sendCount, 1)

        player.queueMutation?.disallowSetQueue = true
        let restrictedBefore = feedback.message?.text
        invokeKeyboardQueueDelete(player: player, selectedIDs: [player.queueNextEntries[1].id])
        runner.equal("restricted keyboard Delete does not send set_queue", await remote.sendCount, 1)
        runner.equal("restricted keyboard Delete does not toast", feedback.message?.text, restrictedBefore)
        await player.shutdownForTermination()

        let localFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let local = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: localFeedback)
        seedLocalOwner(local)
        await seedAuthoritativeQueue(local)
        invokeKeyboardQueueDelete(player: local, selectedIDs: [local.queueNextEntries[0].id])
        runner.equal("local-owner keyboard Delete does not send set_queue", await remote.sendCount, 1)
        runner.nil_("local-owner keyboard Delete does not toast", localFeedback.message)
        await local.shutdownForTermination()
    }

    await runner.suite("QueueService hook ownership") {
        let service = isolatedQueueService()
        await service.reset(accountEpoch: 1)
        let accepted = await service.acceptConnect(
            [connectEntry("spotify:track:a")],
            accountEpoch: 1,
            sourceRevision: 1,
            contextURI: "spotify:track:now",
            engineEpoch: 7,
            protocolNext: [QueueProtocolTrack(uri: "spotify:track:a", uid: "q0", provider: "queue")],
            queueRevision: "rev-1"
        )
        runner.equal("nil hook acceptConnect returns the Connect revision", accepted?.snapshot.revision, 1)
        let committed = await service.recordCommittedReplacement(
            QueueReplacement(
                next: [QueueProtocolTrack(uri: "spotify:track:b", uid: "q1", provider: "queue")],
                prev: [],
                queueRevision: "rev-2",
                removedCount: 1
            ),
            accountEpoch: 1,
            engineEpoch: 7
        )
        runner.equal("nil hook recordCommittedReplacement updates protocol next", committed?.next.first?.uid, "q1")

        let acceptHook = QueueServiceTestHook()
        let acceptService = isolatedQueueService(hook: acceptHook)
        await acceptService.reset(accountEpoch: 1)
        await acceptHook.parkNextConnectAccept()
        let acceptTask = Task {
            await acceptService.acceptConnect(
                [connectEntry("spotify:track:parked")],
                accountEpoch: 1,
                sourceRevision: 4,
                contextURI: "spotify:track:now"
            )
        }
        let acceptParked = await waitUntil { await acceptHook.connectAcceptIsParked() }
        runner.check("acceptConnect parks", acceptParked)
        if acceptParked {
            await acceptHook.resumeConnectAccept()
            await acceptHook.resumeConnectAccept()
            runner.equal("acceptConnect applies after one resume", (await acceptTask.value)?.snapshot.revision, 4)
            runner.equal("a second acceptConnect resume is inert", await acceptHook.connectAcceptIsParked(), false)
        }

        await acceptHook.parkNextConnectAccept()
        let cancelledTask = Task {
            await acceptService.acceptConnect(
                [connectEntry("spotify:track:cancel")],
                accountEpoch: 1,
                sourceRevision: 5,
                contextURI: nil
            )
        }
        runner.check(
            "cancellable acceptConnect parks",
            await waitUntil { await acceptHook.connectAcceptIsParked() }
        )
        cancelledTask.cancel()
        let acceptReleased = await waitUntil { await acceptHook.connectAcceptIsParked() == false }
        runner.check("cancellation does not leak an acceptConnect continuation", acceptReleased)
        if acceptReleased {
            runner.nil_("cancelled parked acceptConnect does not apply", await cancelledTask.value)
        }

        let replaceHook = QueueServiceTestHook()
        let replaceService = isolatedQueueService(hook: replaceHook)
        await replaceService.reset(accountEpoch: 1)
        _ = await replaceService.acceptConnect(
            [connectEntry("spotify:track:a")],
            accountEpoch: 1,
            sourceRevision: 1,
            contextURI: nil,
            engineEpoch: 3,
            protocolNext: [QueueProtocolTrack(uri: "spotify:track:a", uid: "q0", provider: "queue")],
            queueRevision: "rev-1"
        )
        await replaceHook.parkNextCommittedReplacement()
        let replaceTask = Task {
            await replaceService.recordCommittedReplacement(
                QueueReplacement(
                    next: [QueueProtocolTrack(uri: "spotify:track:b", uid: "q1", provider: "queue")],
                    prev: [],
                    queueRevision: "rev-2",
                    removedCount: 1
                ),
                accountEpoch: 1,
                engineEpoch: 3
            )
        }
        runner.check(
            "recordCommittedReplacement parks",
            await waitUntil { await replaceHook.committedReplacementIsParked() }
        )
        await replaceHook.resumeCommittedReplacement()
        await replaceHook.resumeCommittedReplacement()
        runner.equal(
            "recordCommittedReplacement commits after one resume",
            (await replaceTask.value)?.next.first?.uid,
            "q1"
        )
        runner.equal(
            "a second replacement resume is inert",
            await replaceHook.committedReplacementIsParked(),
            false
        )
    }

    runner.suite("Queue management source contract") {
        runner.noThrow("queue mutation sources are readable") {
            let table = try auralSourceFile("Aural/Views/SharedComponents.swift")
            let panel = try auralSourceFile("Aural/Views/SidePanelView.swift")
            let queue = try auralSourceFile("Aural/Spotify/PlaybackStore+Queue.swift")
            let engine = try auralSourceFile("Aural/Spotify/RustPlaybackEngine.swift")
            let control = try auralSourceFile("Aural/Spotify/PlaybackCore.swift")
            let engineEvents = try auralSourceFile("Aural/Spotify/PlaybackStore+EngineEvents.swift")
            let queueService = try auralSourceFile("Aural/Spotify/QueueService.swift")
            let projections = try auralSourceFile("Aural/Spotify/PlaybackStore+Projections.swift")
            let models = try auralSourceFile("AuralDomain/PlaybackPanelModels.swift")
            runner.check(
                "Connect intake binds occurrence uids into selectable identity",
                containsToken(engineEvents, "uid: item.uid ?? \"\"")
                    && containsToken(models, "uid: String")
            )
            runner.check(
                "Add to Queue is available for multi-selection in visible order",
                containsToken(table, "playback.addToQueue(QueueMutationSelection.addURIs(from: selectedTracks))")
            )
            runner.check(
                "upcoming queue rows use native selection rather than play buttons",
                containsToken(panel, "List(selection: $upcomingSelection)")
                    && containsToken(panel, "onDeleteCommand")
                    && containsToken(panel, "QueueMutationSelection.keyboardCommand")
                    && containsToken(panel, "canRemoveUpcomingQueue(selectedIDs: upcomingSelection)")
                    && containsToken(panel, "primaryAction:")
                    && !containsToken(panel, "QueueRow(")
            )
            runner.check(
                "removal goes through coordinator set_queue and does not assign queue entries",
                containsToken(queue, ".setQueue(")
                    && containsToken(queue, "performRemote")
                    && containsToken(queue, "queueReplacement")
                    && containsToken(queue, "queueReplacementToken")
                    && containsToken(queue, "finishQueueReplacementIfCurrent")
                    && containsToken(queue, "recordCommittedReplacement")
                    && !containsToken(queue, "state.queue.entries =")
            )
            runner.check(
                "inspector close cancels only view-owned queue refresh",
                containsToken(queue, "effects.cancel(.queueRefresh)")
                    && containsToken(queue, "effects.cancel(.queueSnapshot)")
                    && !containsToken(queue, "effects.cancel(.connectQueueAccept)")
                    && !containsToken(queue, "effects.cancel(.queueReplacement)")
            )
            runner.check(
                "queue snapshot refresh stamps decoded payload generation",
                containsToken(queue, "engineEpoch: state.sessionGeneration")
                    && containsToken(queue, "if state.sessionGeneration == nil")
            )
            runner.check(
                "Connect queue accept is registered on the effect registry",
                containsToken(engineEvents, "connectQueueAccept")
                    && containsToken(engineEvents, "Task.isCancelled")
                    && containsToken(engineEvents, "accountEpoch == epoch")
                    && containsToken(engineEvents, "engineGeneration <= engineEpoch")
            )
            runner.check(
                "Connect queue callbacks stamp payload sessionGeneration rather than the engineGeneration mirror",
                containsToken(
                    engineEvents, "receive(state, revision: state.revision, engineEpoch: state.sessionGeneration)")
                    && containsToken(engineEvents, "capturedEngineEpoch ?? state.sessionGeneration ?? engineGeneration")
            )
            runner.check(
                "typed occurrence crosses queue merge and presentation without reparsing identity",
                containsToken(queueService, "occurrence: item.occurrence")
                    && containsToken(projections, "occurrence: $0.occurrence")
                    && !containsToken(queueService, "queueOccurrence(")
                    && !containsToken(projections, "queueOccurrence(")
                    && !containsToken(queueService, "split(separator: \"-\"")
                    && !containsToken(projections, "split(separator: \"-\"")
            )
            runner.check(
                "local engine still has no set_queue operation",
                !containsToken(engine, "setQueue")
                    && !containsToken(control, "set_queue")
                    && containsToken(control, "aural_playback_add_to_queue")
            )
        }
    }
}
