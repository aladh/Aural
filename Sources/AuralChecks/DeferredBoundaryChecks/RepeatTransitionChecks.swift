import AuralDomain
import Foundation
@testable import AuralCore

private enum RepeatCheckFailure: Error { case boom }

private struct RepeatSend: Equatable, Sendable {
    let endpoint: SpotifyConnectCommand.Kind
    let enabled: Bool?
}

private final class RepeatLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let failAtCount: Int?
    private let compensationFails: Bool
    private var storedMutations: [RepeatFlagMutation] = []
    private var storedOperations: [LocalPlaybackOperation] = []

    init(failAtCount: Int? = nil, compensationFails: Bool = false) {
        self.failAtCount = failAtCount
        self.compensationFails = compensationFails
    }

    var mutations: [RepeatFlagMutation] {
        lock.lock()
        defer { lock.unlock() }
        return storedMutations
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
        guard case let .repeatOptions(context, track, rollbackContext, rollbackTrack) = operation else {
            return .ok
        }
        let plan = RepeatTransitionPlan.planning(
            from: RepeatFlags(context: rollbackContext, track: rollbackTrack),
            to: RepeatFlags(context: context, track: track)
        )
        let counter = RepeatMutationCounter()
        return RepeatTransitionApplication.apply(
            plan,
            setContext: { enabled in self.record(.init(flag: .context, enabled: enabled), plan: plan, counter: counter) },
            setTrack: { enabled in self.record(.init(flag: .track, enabled: enabled), plan: plan, counter: counter) }
        )
    }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshotJSON() -> String? { nil }
    func configureHighQualityPlayback() {}
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }

    private func record(
        _ mutation: RepeatFlagMutation,
        plan: RepeatTransitionPlan,
        counter: RepeatMutationCounter
    ) -> PlaybackEngineResult {
        lock.lock()
        storedMutations.append(mutation)
        counter.value += 1
        let count = counter.value
        lock.unlock()
        if let failAtCount, count == failAtCount { return .error }
        if compensationFails, count > plan.mutations.count { return .error }
        return .ok
    }
}

private final class RepeatMutationCounter: @unchecked Sendable {
    var value = 0
}

private actor ScriptedRepeatRemote: RemotePlaybackClient {
    private let failAtCounts: Set<Int>
    private let sleepUntilCancelled: Bool
    private let holdAfterCount: Int?
    private var hold: CheckedContinuation<Void, Never>?
    private(set) var sends: [RepeatSend] = []

    init(
        failAtCounts: Set<Int> = [],
        sleepUntilCancelled: Bool = false,
        holdAfterCount: Int? = nil
    ) {
        self.failAtCounts = failAtCounts
        self.sleepUntilCancelled = sleepUntilCancelled
        self.holdAfterCount = holdAfterCount
    }

    func send(_ command: SpotifyConnectCommand, from _: String, to _: String) async throws {
        sends.append(RepeatSend(endpoint: command.endpoint, enabled: booleanValue(command)))
        if sleepUntilCancelled {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return
        }
        if sends.count == holdAfterCount {
            await withCheckedContinuation { continuation in
                hold = continuation
            }
        }
        if failAtCounts.contains(sends.count) {
            throw RepeatCheckFailure.boom
        }
    }

    func releaseHold() {
        hold?.resume()
        hold = nil
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

    private func booleanValue(_ command: SpotifyConnectCommand) -> Bool? {
        switch command.value {
        case let .boolean(enabled): enabled
        default: nil
        }
    }
}

private actor IdleRepeatWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
    }
}

private final class IdleRepeatAccount: AccountSession, @unchecked Sendable {
    func authorizeInteractively() async throws -> KeymasterTokens {
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

private final class IdleRepeatLifecycle: SystemLifecycleEvents, @unchecked Sendable {
    func events() -> AsyncStream<SystemLifecycleEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor IdleRepeatPreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private struct IdleRepeatAudio: AudioOutputPreparing { func prepareForPlayback() throws {} }

private struct StickyRepeatClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

private struct IdleRepeatAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

private enum RepeatCatalogFailure: Error { case unavailable }

private struct IdleRepeatCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] { throw RepeatCatalogFailure.unavailable }
    func home() async throws -> PathfinderHome { throw RepeatCatalogFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw RepeatCatalogFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw RepeatCatalogFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw RepeatCatalogFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw RepeatCatalogFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw RepeatCatalogFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw RepeatCatalogFailure.unavailable }
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

private func repeatEnvironment(
    local: any LocalPlaybackEngine,
    remote: any RemotePlaybackClient
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: remote,
        local: local,
        webQueue: IdleRepeatWebQueue(),
        account: IdleRepeatAccount(),
        audioOutput: IdleRepeatAudio(),
        preferences: IdleRepeatPreferences(),
        lifecycle: IdleRepeatLifecycle(),
        clock: StickyRepeatClock(),
        catalog: IdleRepeatCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: IdleRepeatAttributes()
    )
}

@MainActor
private func playbackStore(_ environment: PlaybackEnvironment) -> PlaybackStore {
    PlaybackStore(
        environment: environment,
        feedback: TransientFeedbackPresenter(clock: environment.clock)
    )
}

@MainActor
private func seedReadyRemote(_ player: PlaybackStore) {
    _ = player.send(.session(.ready), source: .account)
    _ = player.send(
        .devices(PlaybackDeviceSnapshot(
            devices: [
                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true)
            ],
            localDeviceID: "mac",
            revision: 1
        )),
        source: .engineDevices,
        revision: 1
    )
}

@MainActor
private func seedReadyLocal(_ player: PlaybackStore) {
    _ = player.send(.session(.ready), source: .account)
    _ = player.send(
        .devices(PlaybackDeviceSnapshot(
            devices: [
                PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)
            ],
            localDeviceID: "mac",
            revision: 1
        )),
        source: .engineDevices,
        revision: 1
    )
}

@MainActor
func runRepeatTransitionChecks(_ runner: CheckRunner) async {
    runner.suite("Local repeat transition application") {
        func record(
            from: RepeatMode,
            to: RepeatMode,
            failAtCount: Int? = nil,
            compensationFails: Bool = false
        ) -> (calls: [RepeatFlagMutation], result: PlaybackEngineResult) {
            var calls: [RepeatFlagMutation] = []
            var count = 0
            let plan = RepeatTransitionPlan.planning(from: from.flags, to: to.flags)
            let result = RepeatTransitionApplication.apply(
                plan,
                setContext: { enabled in
                    count += 1
                    calls.append(RepeatFlagMutation(flag: .context, enabled: enabled))
                    if count == failAtCount { return .error }
                    if compensationFails, count > plan.mutations.count { return .error }
                    return .ok
                },
                setTrack: { enabled in
                    count += 1
                    calls.append(RepeatFlagMutation(flag: .track, enabled: enabled))
                    if count == failAtCount { return .error }
                    if compensationFails, count > plan.mutations.count { return .error }
                    return .ok
                }
            )
            return (calls, result)
        }

        let offToContext = record(from: .off, to: .context)
        runner.equal(
            "local off → context sends only context on",
            offToContext.calls,
            [RepeatFlagMutation(flag: .context, enabled: true)]
        )
        runner.equal("local off → context succeeds", offToContext.result, .ok)

        let contextToTrack = record(from: .context, to: .track)
        runner.equal(
            "local context → track sends context off then track on",
            contextToTrack.calls,
            [
                RepeatFlagMutation(flag: .context, enabled: false),
                RepeatFlagMutation(flag: .track, enabled: true),
            ]
        )
        runner.equal("local context → track succeeds", contextToTrack.result, .ok)

        let trackToOff = record(from: .track, to: .off)
        runner.equal(
            "local track → off sends only track off",
            trackToOff.calls,
            [RepeatFlagMutation(flag: .track, enabled: false)]
        )
        runner.equal("local track → off succeeds", trackToOff.result, .ok)

        let firstStep = record(from: .off, to: .context, failAtCount: 1)
        runner.equal(
            "local first-step failure performs no compensation",
            firstStep.calls,
            [RepeatFlagMutation(flag: .context, enabled: true)]
        )
        runner.equal("local first-step failure is an error", firstStep.result, .error)

        let secondStep = record(from: .context, to: .track, failAtCount: 2)
        runner.equal(
            "local second-step failure attempts compensation",
            secondStep.calls,
            [
                RepeatFlagMutation(flag: .context, enabled: false),
                RepeatFlagMutation(flag: .track, enabled: true),
                RepeatFlagMutation(flag: .context, enabled: true),
            ]
        )
        runner.equal("local second-step failure remains an error", secondStep.result, .error)

        let compensationFailure = record(from: .context, to: .track, failAtCount: 2, compensationFails: true)
        runner.equal(
            "local compensation failure still records the rollback attempt",
            compensationFailure.calls,
            [
                RepeatFlagMutation(flag: .context, enabled: false),
                RepeatFlagMutation(flag: .track, enabled: true),
                RepeatFlagMutation(flag: .context, enabled: true),
            ]
        )
        runner.equal("local compensation failure does not claim success", compensationFailure.result, .error)
    }

    await runner.suite("Remote repeat success sends only changed flags") {
        struct Case: Sendable {
            let from: RepeatMode
            let expected: [RepeatSend]
            let label: String
        }
        let cases: [Case] = [
            Case(
                from: .off,
                expected: [RepeatSend(endpoint: .repeatContext, enabled: true)],
                label: "off → context"
            ),
            Case(
                from: .context,
                expected: [
                    RepeatSend(endpoint: .repeatContext, enabled: false),
                    RepeatSend(endpoint: .repeatTrack, enabled: true),
                ],
                label: "context → track"
            ),
            Case(
                from: .track,
                expected: [RepeatSend(endpoint: .repeatTrack, enabled: false)],
                label: "track → off"
            ),
        ]
        for item in cases {
            let remote = ScriptedRepeatRemote()
            let player = playbackStore(
                repeatEnvironment(local: RepeatLocalEngine(), remote: remote)
            )
            seedReadyRemote(player)
            player.setRepeatMode(item.from)
            player.cycleRepeat()
            let finished = await waitUntil { player.state.pendingCommands[.options] == nil }
            runner.check("\(item.label) finishes", finished)
            runner.equal("\(item.label) sends", await remote.sends, item.expected)
            runner.equal("\(item.label) keeps the optimistic mode", player.repeatMode, item.from.next)
            runner.nil_("\(item.label) has no command notice", player.transientCommandError)
            runner.equal(
                "\(item.label) command count matches changed flags",
                await remote.sends.count,
                item.expected.count
            )
            await player.shutdownForTermination()
        }
    }

    await runner.suite("Remote first-step failure performs no compensation") {
        let remote = ScriptedRepeatRemote(failAtCounts: [1])
        let player = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: remote)
        )
        seedReadyRemote(player)
        player.cycleRepeat()
        let finished = await waitUntil { player.state.pendingCommands[.options] == nil }
        runner.check("first-step failure finishes", finished)
        runner.equal(
            "first-step failure sends only the required mutation",
            await remote.sends,
            [RepeatSend(endpoint: .repeatContext, enabled: true)]
        )
        runner.equal("first-step failure rolls back the optimistic mode", player.repeatMode, RepeatMode.off)
        runner.equal("first-step failure reports Could not update repeat", player.transientCommandError, "Could not update repeat")
        await player.shutdownForTermination()
    }

    await runner.suite("Remote second-step failure compensates and reports failure") {
        let remote = ScriptedRepeatRemote(failAtCounts: [2])
        let player = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: remote)
        )
        seedReadyRemote(player)
        player.setRepeatMode(.context)
        player.cycleRepeat()
        let finished = await waitUntil { player.state.pendingCommands[.options] == nil }
        runner.check("second-step failure finishes", finished)
        runner.equal(
            "second-step failure records best-effort compensation",
            await remote.sends,
            [
                RepeatSend(endpoint: .repeatContext, enabled: false),
                RepeatSend(endpoint: .repeatTrack, enabled: true),
                RepeatSend(endpoint: .repeatContext, enabled: true),
            ]
        )
        runner.equal("second-step failure rolls back to the captured previous mode", player.repeatMode, RepeatMode.context)
        runner.equal("second-step failure reports Could not update repeat", player.transientCommandError, "Could not update repeat")
        await player.shutdownForTermination()
    }

    await runner.suite("Remote compensation failure remains a command failure") {
        let remote = ScriptedRepeatRemote(failAtCounts: [2, 3])
        let player = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: remote)
        )
        seedReadyRemote(player)
        player.setRepeatMode(.context)
        player.cycleRepeat()
        let finished = await waitUntil { player.state.pendingCommands[.options] == nil }
        runner.check("compensation failure finishes", finished)
        runner.equal(
            "compensation failure still attempted the rollback send",
            await remote.sends,
            [
                RepeatSend(endpoint: .repeatContext, enabled: false),
                RepeatSend(endpoint: .repeatTrack, enabled: true),
                RepeatSend(endpoint: .repeatContext, enabled: true),
            ]
        )
        runner.equal("compensation failure does not claim success", player.repeatMode, RepeatMode.context)
        runner.equal("compensation failure reports Could not update repeat", player.transientCommandError, "Could not update repeat")
        await player.shutdownForTermination()
    }

    await runner.suite("Local store second-step failure attempts rollback") {
        let local = RepeatLocalEngine(failAtCount: 2)
        let player = playbackStore(
            repeatEnvironment(local: local, remote: ScriptedRepeatRemote())
        )
        seedReadyLocal(player)
        player.setRepeatMode(.context)
        player.cycleRepeat()
        let finished = await waitUntil { player.state.pendingCommands[.options] == nil }
        runner.check("local second-step failure finishes", finished)
        runner.equal(
            "local engine records compensation in documented order",
            local.mutations,
            [
                RepeatFlagMutation(flag: .context, enabled: false),
                RepeatFlagMutation(flag: .track, enabled: true),
                RepeatFlagMutation(flag: .context, enabled: true),
            ]
        )
        runner.equal("local second-step failure rolls back the optimistic mode", player.repeatMode, RepeatMode.context)
        runner.equal("local second-step failure reports Could not update repeat", player.transientCommandError, "Could not update repeat")
        await player.shutdownForTermination()
    }

    await runner.suite("Authoritative engine repeat snapshot is not clobbered") {
        let remote = ScriptedRepeatRemote(failAtCounts: [1], holdAfterCount: 1)
        let player = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: remote)
        )
        seedReadyRemote(player)
        player.cycleRepeat()
        let held = await waitUntil { await remote.sends.count == 1 }
        runner.check("repeat send is held before failure", held)
        runner.equal("optimistic repeat is context before the snapshot", player.repeatMode, RepeatMode.context)
        _ = player.send(
            .enginePlayback(EnginePlaybackSnapshot(
                transport: .paused,
                trackURI: nil,
                timing: PlaybackTiming(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)),
                shuffle: false,
                repeatMode: .context
            )),
            source: .enginePlayback,
            revision: 3
        )
        runner.equal("engine snapshot keeps context repeat", player.repeatMode, RepeatMode.context)
        await remote.releaseHold()
        let finished = await waitUntil { player.state.pendingCommands[.options] == nil }
        runner.check("stale failure completion arrives", finished)
        runner.equal("a later failure does not clobber the engine repeat snapshot", player.repeatMode, RepeatMode.context)
        runner.equal("the failed command still reports Could not update repeat", player.transientCommandError, "Could not update repeat")
        await player.shutdownForTermination()
    }

    await runner.suite("Repeat cancellation and teardown stay inert") {
        let sleeping = ScriptedRepeatRemote(sleepUntilCancelled: true)
        let cancelStore = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: sleeping)
        )
        seedReadyRemote(cancelStore)
        cancelStore.cycleRepeat()
        let pendingReady = await waitUntil { cancelStore.state.pendingCommands[.options] != nil }
        runner.check("remote repeat is pending before cancellation", pendingReady)
        if let commandID = cancelStore.state.pendingCommands[.options]?.id {
            cancelStore.effects.cancel(.command(commandID))
        }
        _ = await waitUntil { await sleeping.sends.count == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        runner.equal("cancelled repeat keeps the optimistic mode", cancelStore.repeatMode, RepeatMode.context)
        runner.nil_("cancelled repeat has no notice", cancelStore.transientCommandError)
        await cancelStore.shutdownForTermination()

        let teardownRemote = ScriptedRepeatRemote(sleepUntilCancelled: true)
        let teardownStore = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: teardownRemote)
        )
        seedReadyRemote(teardownStore)
        teardownStore.cycleRepeat()
        let teardownPending = await waitUntil { teardownStore.state.pendingCommands[.options] != nil }
        runner.check("repeat is pending before teardown", teardownPending)
        await teardownStore.shutdownForTermination()
        try? await Task.sleep(nanoseconds: 20_000_000)
        runner.nil_("teardown leaves no pending options command", teardownStore.state.pendingCommands[.options])
        runner.nil_("teardown repeat has no command notice", teardownStore.transientCommandError)
    }
}
