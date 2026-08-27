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
        case park
    }

    private let behavior: Behavior
    private var parked: CheckedContinuation<Void, Error>?
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
        case .park:
            try await withCheckedThrowingContinuation { parked = $0 }
        }
    }

    func completePark(success: Bool) {
        if success {
            parked?.resume()
        } else {
            parked?.resume(throwing: QueueRemoteFailure.boom)
        }
        parked = nil
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

private func queueEnvironment(
    local: any LocalPlaybackEngine = QueueLocalEngine(),
    remote: any RemotePlaybackClient,
    clock: any PlaybackClock = SystemPlaybackClock()
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
        trackAttributes: IdleQueueAttributes()
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
        .devices(PlaybackDeviceSnapshot(
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
private func seedAuthoritativeQueue(_ player: PlaybackStore, revision: UInt64 = 4) {
    let duplicate = "spotify:track:dup"
    let other = "spotify:track:other"
    let entries = [
        QueueEntry(uri: duplicate, provider: "queue", occurrence: 0),
        QueueEntry(uri: duplicate, provider: "queue", occurrence: 1),
        QueueEntry(uri: other, provider: "queue", occurrence: 2),
    ]
    let next = [
        QueueProtocolTrack(uri: duplicate, uid: "q0", provider: "queue"),
        QueueProtocolTrack(uri: duplicate, uid: "q1", provider: "queue"),
        QueueProtocolTrack(uri: other, uid: "q2", provider: "queue"),
        QueueProtocolTrack(uri: "spotify:delimiter", uid: "", provider: "delimiter"),
        QueueProtocolTrack(uri: "spotify:track:autoplay", uid: "a0", provider: "autoplay"),
    ]
    let prev = [QueueProtocolTrack(uri: "spotify:track:prev", uid: "p0", provider: "context")]
    player.queueMutation = QueueMutationSnapshot(
        accountEpoch: player.accountEpoch,
        engineEpoch: player.engineGeneration,
        sourceRevision: revision,
        source: .connect,
        completeness: .complete,
        provisional: false,
        next: next,
        prev: prev,
        queueRevision: "rev-\(revision)"
    )
    _ = player.send(
        .queue(PlaybackQueueSnapshot(
            entries: entries.map { PlaybackQueueItem(id: $0.id, uri: $0.uri, provider: $0.provider) },
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

private func waitUntil(
    timeoutNanoseconds: UInt64 = 200_000_000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if Task.isCancelled { return false }
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

@MainActor
private func yieldPasses(_ count: Int = 8) async {
    for _ in 0 ..< count { await Task.yield() }
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

@MainActor
func runQueueManagementChecks(_ runner: CheckRunner) async {
    runner.suite("Connect set_queue encoding") {
        runner.noThrow("set_queue encodes remaining next_tracks and required prev_tracks") {
            let command = SpotifyConnectCommand.setQueue(
                next: [
                    QueueProtocolTrack(uri: "spotify:track:keep", uid: "q0", provider: "queue"),
                    QueueProtocolTrack(uri: "spotify:delimiter", uid: "", provider: "delimiter"),
                ],
                prev: [QueueProtocolTrack(uri: "spotify:track:prev", uid: "p0", provider: "context")],
                queueRevision: "rev-9"
            )
            let encoded = try JSONEncoder().encode(command)
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            runner.equal("set_queue endpoint is encoded", object?["endpoint"] as? String, "set_queue")
            runner.equal("set_queue revision is encoded", object?["queue_revision"] as? String, "rev-9")
            let next = object?["next_tracks"] as? [[String: Any]]
            runner.equal("next_tracks keeps remaining occurrence uid", next?.first?["uid"] as? String, "q0")
            runner.equal("next_tracks keeps delimiter", next?.last?["uri"] as? String, "spotify:delimiter")
            let prev = object?["prev_tracks"] as? [[String: Any]]
            runner.equal("prev_tracks are preserved", prev?.first?["uri"] as? String, "spotify:track:prev")
            runner.equal("queued metadata marks is_queued", (next?.first?["metadata"] as? [String: String])?["is_queued"], "true")
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

    await runner.suite("Duplicate-occurrence deletion and no local edit") {
        let remote = QueueRemoteClient(.succeed)
        let feedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let player = PlaybackStore(environment: queueEnvironment(remote: remote), feedback: feedback)
        seedRemoteOwner(player)
        seedAuthoritativeQueue(player)
        let secondDuplicate = player.queueNextEntries[1].id
        let before = player.queueNextEntries
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
        seedAuthoritativeQueue(player)
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
        seedAuthoritativeQueue(player)
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
        seedAuthoritativeQueue(local)
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
        seedAuthoritativeQueue(rejected)
        let rejectedID = rejected.queueNextEntries[0].id
        let rejectedBefore = rejected.queueNextEntries
        rejected.removeUpcomingQueueOccurrences(selectedIDs: [rejectedID])
        runner.check("rejected set_queue finished", await waitUntil { failFeedback.message?.kind == .failure })
        runner.equal("rejection does not rewrite presentation", rejected.queueNextEntries, rejectedBefore)
        runner.equal("rejection uses a typed queue failure", failFeedback.message?.text, "Spotify couldn’t update the queue.")
        await rejected.shutdownForTermination()

        let parked = QueueRemoteClient(.park)
        let cancelFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let cancelled = PlaybackStore(environment: queueEnvironment(remote: parked), feedback: cancelFeedback)
        seedRemoteOwner(cancelled)
        seedAuthoritativeQueue(cancelled)
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
        seedAuthoritativeQueue(stale)
        let staleID = stale.queueNextEntries[0].id
        stale.removeUpcomingQueueOccurrences(selectedIDs: [staleID])
        runner.check("stale-account removal started", await waitUntil { await staleRemote.sendCount == 1 })
        stale.accountEpoch &+= 1
        await staleRemote.completePark(success: true)
        await yieldPasses()
        runner.nil_("stale-account removal reports no mutation feedback", staleFeedback.message)
        await stale.shutdownForTermination()

        let missingFeedback = TransientFeedbackPresenter(clock: SystemPlaybackClock(), duration: 4)
        let missing = PlaybackStore(environment: queueEnvironment(remote: QueueRemoteClient(.succeed)), feedback: missingFeedback)
        seedRemoteOwner(missing)
        seedAuthoritativeQueue(missing)
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

    runner.suite("Queue management source contract") {
        runner.noThrow("queue mutation sources are readable") {
            let table = try auralSourceFile("Aural/Views/SharedComponents.swift")
            let panel = try auralSourceFile("Aural/Views/SidePanelView.swift")
            let queue = try auralSourceFile("Aural/Spotify/PlaybackStore+Queue.swift")
            let engine = try auralSourceFile("Aural/Spotify/RustPlaybackEngine.swift")
            let control = try auralSourceFile("Aural/Spotify/PlaybackCore.swift")
            runner.check(
                "Add to Queue is available for multi-selection in visible order",
                containsToken(table, "playback.addToQueue(QueueMutationSelection.addURIs(from: selectedTracks))")
            )
            runner.check(
                "upcoming queue rows use native selection rather than play buttons",
                containsToken(panel, "List(selection: $upcomingSelection)")
                    && containsToken(panel, "onDeleteCommand")
                    && containsToken(panel, "primaryAction:")
                    && !containsToken(panel, "QueueRow(")
            )
            runner.check(
                "removal goes through coordinator set_queue and does not assign queue entries",
                containsToken(queue, ".setQueue(")
                    && containsToken(queue, "performRemote")
                    && !containsToken(queue, "state.queue.entries =")
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
