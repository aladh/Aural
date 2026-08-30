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
        guard case let .repeatOptions(plan) = operation else {
            return .ok
        }
        let counter = RepeatMutationCounter()
        return RepeatTransitionApplication.apply(plan) { mutation in
            self.record(mutation, plan: plan, counter: counter)
        }
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
    private(set) var completedSends = 0

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
        defer { completedSends += 1 }
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

private func auralSourceFile(_ relativePath: String) throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sources = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let url = sources.appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func containsToken(_ source: String, _ token: String) -> Bool {
    source.contains(token)
}

private func playbackStoreStateAssignments(_ source: String) -> [String] {
    matchingPlaybackStoreStateLines(source, pattern: #"(?<![\w.])state\s*=(?!=)"#)
        .filter { !$0.contains("let state") }
}

private func playbackStoreStateMemberMutations(_ source: String) -> [String] {
    matchingPlaybackStoreStateLines(source, pattern: #"(?<![\w.])state\.[A-Za-z0-9_.\[\]]+\s*=(?!=)"#)
        .filter { !$0.contains("let state") }
}

private func matchingPlaybackStoreStateLines(_ source: String, pattern: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    return source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return nil }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        guard regex.firstMatch(in: trimmed, range: range) != nil else { return nil }
        return trimmed
    }
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
private func sendRepeatSnapshot(
    _ player: PlaybackStore,
    mode: RepeatMode,
    flags: RepeatFlags? = nil,
    revision: UInt64
) {
    _ = player.send(
        .enginePlayback(EnginePlaybackSnapshot(
            transport: .paused,
            trackURI: nil,
            timing: PlaybackTiming(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)),
            shuffle: false,
            repeatMode: mode,
            repeatFlags: flags ?? mode.flags
        )),
        source: .enginePlayback,
        revision: revision
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
            let result = RepeatTransitionApplication.apply(plan) { mutation in
                count += 1
                calls.append(mutation)
                if count == failAtCount { return .error }
                if compensationFails, count > plan.mutations.count { return .error }
                return .ok
            }
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
        sendRepeatSnapshot(player, mode: .context, revision: 3)
        runner.equal("engine snapshot keeps context repeat", player.repeatMode, RepeatMode.context)
        await remote.releaseHold()
        let finished = await waitUntil { player.state.pendingCommands[.options] == nil }
        runner.check("stale failure completion arrives", finished)
        runner.equal("a later failure does not clobber the engine repeat snapshot", player.repeatMode, RepeatMode.context)
        runner.nil_("confirmed repeat then failure has no command notice", player.transientCommandError)
        await player.shutdownForTermination()
    }

    await runner.suite("Raw both-true flags plan both-off; ordinary track is one send") {
        let bothTrueRemote = ScriptedRepeatRemote()
        let bothTruePlayer = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: bothTrueRemote)
        )
        seedReadyRemote(bothTruePlayer)
        bothTruePlayer.setRepeat(mode: .track, flags: RepeatFlags(context: true, track: true))
        runner.equal("both-true still displays as track", bothTruePlayer.repeatMode, RepeatMode.track)
        runner.equal(
            "both-true raw flags are retained on options",
            bothTruePlayer.state.options.repeatFlags,
            RepeatFlags(context: true, track: true)
        )
        bothTruePlayer.cycleRepeat()
        let bothFinished = await waitUntil { bothTruePlayer.state.pendingCommands[.options] == nil }
        runner.check("both-true track → off finishes", bothFinished)
        runner.equal(
            "both-true track → off clears both flags",
            await bothTrueRemote.sends,
            [
                RepeatSend(endpoint: .repeatContext, enabled: false),
                RepeatSend(endpoint: .repeatTrack, enabled: false),
            ]
        )
        runner.equal("both-true track → off shows off", bothTruePlayer.repeatMode, RepeatMode.off)
        await bothTruePlayer.shutdownForTermination()

        let ordinaryRemote = ScriptedRepeatRemote()
        let ordinaryPlayer = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: ordinaryRemote)
        )
        seedReadyRemote(ordinaryPlayer)
        ordinaryPlayer.setRepeatMode(.track)
        ordinaryPlayer.cycleRepeat()
        let ordinaryFinished = await waitUntil { ordinaryPlayer.state.pendingCommands[.options] == nil }
        runner.check("ordinary track → off finishes", ordinaryFinished)
        runner.equal(
            "ordinary track → off still sends only track off",
            await ordinaryRemote.sends,
            [RepeatSend(endpoint: .repeatTrack, enabled: false)]
        )
        await ordinaryPlayer.shutdownForTermination()
    }

    await runner.suite("Context → track intermediate off restores previous context") {
        let remote = ScriptedRepeatRemote(failAtCounts: [2], holdAfterCount: 2)
        let player = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: remote)
        )
        seedReadyRemote(player)
        player.setRepeatMode(.context)
        player.cycleRepeat()
        let held = await waitUntil { await remote.sends.count == 2 }
        runner.check("second mutation is held after context-off", held)
        sendRepeatSnapshot(
            player,
            mode: .off,
            flags: RepeatFlags(context: false, track: false),
            revision: 4
        )
        runner.equal("intermediate engine sample shows off", player.repeatMode, RepeatMode.off)
        await remote.releaseHold()
        let finished = await waitUntil { player.state.pendingCommands[.options] == nil }
        runner.check("compensated second-step failure finishes", finished)
        runner.equal(
            "compensation still ran after the intermediate off snapshot",
            await remote.sends,
            [
                RepeatSend(endpoint: .repeatContext, enabled: false),
                RepeatSend(endpoint: .repeatTrack, enabled: true),
                RepeatSend(endpoint: .repeatContext, enabled: true),
            ]
        )
        runner.equal("intermediate off plus successful compensation restores context UI", player.repeatMode, RepeatMode.context)
        runner.equal(
            "restored context flags match the captured previous pair",
            player.state.options.repeatFlags,
            RepeatMode.context.flags
        )
        runner.equal("the failed command still reports Could not update repeat", player.transientCommandError, "Could not update repeat")
        await player.shutdownForTermination()
    }

    await runner.suite("Both-true intermediate snapshot restores previous raw flags") {
        let remote = ScriptedRepeatRemote(failAtCounts: [2], holdAfterCount: 1)
        let player = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: remote)
        )
        seedReadyRemote(player)
        let priorBothTrue = RepeatFlags(context: true, track: true)
        let intermediateFlags = RepeatFlags(context: false, track: true)
        player.setRepeat(mode: .track, flags: priorBothTrue)
        player.cycleRepeat()
        let held = await waitUntil { await remote.sends.count == 1 }
        runner.check("first both-off mutation is held after context-off", held)
        sendRepeatSnapshot(player, mode: .track, flags: intermediateFlags, revision: 7)
        runner.equal("intermediate both-true step still displays as track", player.repeatMode, RepeatMode.track)
        runner.equal(
            "intermediate raw flags are context off, track on",
            player.state.options.repeatFlags,
            intermediateFlags
        )
        await remote.releaseHold()
        let finished = await waitUntil { player.state.pendingCommands[.options] == nil }
        runner.check("compensated both-true second-step failure finishes", finished)
        runner.equal(
            "compensation restores context after the intermediate track snapshot",
            await remote.sends,
            [
                RepeatSend(endpoint: .repeatContext, enabled: false),
                RepeatSend(endpoint: .repeatTrack, enabled: false),
                RepeatSend(endpoint: .repeatContext, enabled: true),
            ]
        )
        runner.equal("store restored previous track after compensation", player.repeatMode, RepeatMode.track)
        runner.equal(
            "store restored captured both-true raw flags",
            player.state.options.repeatFlags,
            priorBothTrue
        )
        runner.equal(
            "a later track → off from restored flags plans both mutations",
            RepeatTransitionPlan.planning(from: player.state.options.repeatFlags, to: RepeatMode.off.flags).mutations,
            [
                RepeatFlagMutation(flag: .context, enabled: false),
                RepeatFlagMutation(flag: .track, enabled: false),
            ]
        )
        runner.equal("the failed command still reports Could not update repeat", player.transientCommandError, "Could not update repeat")
        await player.shutdownForTermination()
    }

    await runner.suite("Target and unrelated snapshots survive repeat failure") {
        let targetRemote = ScriptedRepeatRemote(failAtCounts: [2], holdAfterCount: 2)
        let targetPlayer = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: targetRemote)
        )
        seedReadyRemote(targetPlayer)
        targetPlayer.setRepeatMode(.context)
        targetPlayer.cycleRepeat()
        let targetHeld = await waitUntil { await targetRemote.sends.count == 2 }
        runner.check("target snapshot is injected before second-step failure", targetHeld)
        sendRepeatSnapshot(targetPlayer, mode: .track, revision: 5)
        await targetRemote.releaseHold()
        let targetFinished = await waitUntil { targetPlayer.state.pendingCommands[.options] == nil }
        runner.check("target snapshot failure finishes", targetFinished)
        runner.equal("a later target track snapshot remains track", targetPlayer.repeatMode, RepeatMode.track)
        runner.nil_("confirmed target repeat then failure has no command notice", targetPlayer.transientCommandError)
        await targetPlayer.shutdownForTermination()

        let unrelatedRemote = ScriptedRepeatRemote(failAtCounts: [1], holdAfterCount: 1)
        let unrelatedPlayer = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: unrelatedRemote)
        )
        seedReadyRemote(unrelatedPlayer)
        unrelatedPlayer.cycleRepeat()
        let unrelatedHeld = await waitUntil { await unrelatedRemote.sends.count == 1 }
        runner.check("unrelated snapshot is injected before first-step failure", unrelatedHeld)
        sendRepeatSnapshot(unrelatedPlayer, mode: .track, revision: 6)
        await unrelatedRemote.releaseHold()
        let unrelatedFinished = await waitUntil { unrelatedPlayer.state.pendingCommands[.options] == nil }
        runner.check("unrelated snapshot failure finishes", unrelatedFinished)
        runner.equal("unrelated newer authoritative track remains preserved", unrelatedPlayer.repeatMode, RepeatMode.track)
        runner.nil_("superseded repeat then failure stays inert", unrelatedPlayer.transientCommandError)
        await unrelatedPlayer.shutdownForTermination()
    }

    await runner.suite("Repeat cancellation and teardown stay inert") {
        let sleeping = ScriptedRepeatRemote(sleepUntilCancelled: true)
        let cancelStore = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: sleeping)
        )
        seedReadyRemote(cancelStore)
        cancelStore.cycleRepeat()
        let sendStarted = await waitUntil { await sleeping.sends.count == 1 }
        runner.check("cancelled repeat send started", sendStarted)
        runner.check("remote repeat is pending before cancellation", cancelStore.state.pendingCommands[.options] != nil)
        if let commandID = cancelStore.state.pendingCommands[.options]?.id {
            cancelStore.effects.cancel(.command(commandID))
        }
        let cancellationSettled = await waitUntil { await sleeping.completedSends == 1 }
        runner.check("cancelled repeat transport exits", cancellationSettled)
        runner.equal("cancelled repeat keeps the optimistic mode", cancelStore.repeatMode, RepeatMode.context)
        runner.nil_("cancelled repeat has no notice", cancelStore.transientCommandError)
        await cancelStore.shutdownForTermination()

        let teardownRemote = ScriptedRepeatRemote(sleepUntilCancelled: true)
        let teardownStore = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: teardownRemote)
        )
        seedReadyRemote(teardownStore)
        teardownStore.cycleRepeat()
        let teardownSendStarted = await waitUntil { await teardownRemote.sends.count == 1 }
        runner.check("teardown repeat send started", teardownSendStarted)
        runner.check("repeat is pending before teardown", teardownStore.state.pendingCommands[.options] != nil)
        await teardownStore.shutdownForTermination()
        let teardownSettled = await waitUntil { await teardownRemote.completedSends == 1 }
        runner.check("teardown repeat transport exits", teardownSettled)
        runner.nil_("teardown leaves no pending options command", teardownStore.state.pendingCommands[.options])
        runner.nil_("teardown repeat has no command notice", teardownStore.transientCommandError)
    }

    await runner.suite("Local store first-step failure and success") {
        let failing = RepeatLocalEngine(failAtCount: 1)
        let failed = playbackStore(
            repeatEnvironment(local: failing, remote: ScriptedRepeatRemote())
        )
        seedReadyLocal(failed)
        failed.cycleRepeat()
        runner.equal("local off → context presents context before completion", failed.repeatMode, RepeatMode.context)
        let failedFinished = await waitUntil { failed.state.pendingCommands[.options] == nil }
        runner.check("local first-step failure finishes", failedFinished)
        runner.equal(
            "local first-step failure performs no compensation",
            failing.mutations,
            [RepeatFlagMutation(flag: .context, enabled: true)]
        )
        runner.equal("local first-step failure rolls back the optimistic mode", failed.repeatMode, RepeatMode.off)
        runner.equal("local first-step failure reports Could not update repeat", failed.transientCommandError, "Could not update repeat")
        await failed.shutdownForTermination()

        let succeeding = RepeatLocalEngine()
        let accepted = playbackStore(
            repeatEnvironment(local: succeeding, remote: ScriptedRepeatRemote())
        )
        seedReadyLocal(accepted)
        accepted.cycleRepeat()
        let acceptedFinished = await waitUntil { accepted.state.pendingCommands[.options] == nil }
        runner.check("local off → context success finishes", acceptedFinished)
        runner.equal(
            "local off → context success sends only context on",
            succeeding.mutations,
            [RepeatFlagMutation(flag: .context, enabled: true)]
        )
        runner.equal("local off → context success keeps context", accepted.repeatMode, RepeatMode.context)
        runner.nil_("local off → context success has no command notice", accepted.transientCommandError)
        await accepted.shutdownForTermination()
    }

    await runner.suite("Lagging, non-authoritative, stale, and duplicate repeat stay correct") {
        let laggingRemote = ScriptedRepeatRemote(failAtCounts: [1], holdAfterCount: 1)
        let lagging = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: laggingRemote)
        )
        seedReadyRemote(lagging)
        lagging.cycleRepeat()
        let lagHeld = await waitUntil { await laggingRemote.sends.count == 1 }
        runner.check("lagging repeat send is held", lagHeld)
        sendRepeatSnapshot(lagging, mode: .off, revision: 2)
        runner.equal("a lagging off snapshot keeps optimistic context", lagging.repeatMode, RepeatMode.context)
        runner.notNil("a lagging off snapshot keeps rollback ownership", lagging.state.pendingCommands[.options])
        await laggingRemote.releaseHold()
        let lagFinished = await waitUntil { lagging.state.pendingCommands[.options] == nil }
        runner.check("lagging prior then rejection finishes", lagFinished)
        runner.equal("lagging prior then rejection restores off", lagging.repeatMode, RepeatMode.off)
        runner.equal("lagging prior then rejection reports Could not update repeat", lagging.transientCommandError, "Could not update repeat")
        await lagging.shutdownForTermination()

        let userRemote = ScriptedRepeatRemote(failAtCounts: [1], holdAfterCount: 1)
        let userStore = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: userRemote)
        )
        seedReadyRemote(userStore)
        userStore.cycleRepeat()
        let userHeld = await waitUntil { await userRemote.sends.count == 1 }
        runner.check("user options repeat send is held", userHeld)
        _ = userStore.send(
            .options(PlaybackOptions(shuffle: true, repeatMode: .context, repeatFlags: RepeatMode.context.flags)),
            source: .user
        )
        runner.equal("a matching user options event keeps optimistic context", userStore.repeatMode, RepeatMode.context)
        runner.equal("a matching user options event still adopts shuffle", userStore.state.options.shuffle, true)
        runner.notNil("a matching user options event keeps the pending repeat command", userStore.state.pendingCommands[.options])
        runner.check(
            "a matching user options event does not record confirmation",
            userStore.state.transportCommandResolutions.isEmpty
        )
        await userRemote.releaseHold()
        let userFinished = await waitUntil { userStore.state.pendingCommands[.options] == nil }
        runner.check("user options then rejection finishes", userFinished)
        runner.equal("rejection after only a matching user options event restores off", userStore.repeatMode, RepeatMode.off)
        await userStore.shutdownForTermination()

        let staleRemote = ScriptedRepeatRemote(sleepUntilCancelled: true)
        let staleStore = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: staleRemote)
        )
        seedReadyRemote(staleStore)
        staleStore.cycleRepeat()
        let stalePending = await waitUntil { staleStore.state.pendingCommands[.options] != nil }
        runner.check("repeat is pending before an engine-epoch bump", stalePending)
        let optimisticRepeat = staleStore.repeatMode
        _ = staleStore.send(
            .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
            source: .engineConnection,
            revision: 1,
            engineEpoch: staleStore.engineGeneration + 1
        )
        runner.nil_("an engine-epoch bump drops the pending repeat", staleStore.state.pendingCommands[.options])
        runner.equal("an engine-epoch bump does not roll back context", staleStore.repeatMode, optimisticRepeat)
        runner.check("an engine-epoch bump clears repeat confirmation state", staleStore.state.transportCommandResolutions.isEmpty)
        await staleStore.shutdownForTermination()

        let accountRemote = ScriptedRepeatRemote(sleepUntilCancelled: true)
        let accountStore = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: accountRemote)
        )
        seedReadyRemote(accountStore)
        accountStore.cycleRepeat()
        let accountPending = await waitUntil { accountStore.state.pendingCommands[.options] != nil }
        runner.check("repeat is pending before an account-epoch bump", accountPending)
        accountStore.accountStore.advanceEpoch()
        _ = accountStore.send(.reset(session: .signedOut), source: .account, accountEpoch: accountStore.accountEpoch)
        runner.nil_("an account-epoch bump drops pending repeat", accountStore.state.pendingCommands[.options])
        runner.equal("an account-epoch bump signs out", accountStore.state.session, PlaybackSessionPhase.signedOut)
        runner.equal("an account-epoch bump does not keep signed-in repeat", accountStore.repeatMode, RepeatMode.off)
        await accountStore.shutdownForTermination()

        let joining = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: ScriptedRepeatRemote())
        )
        _ = joining.send(.session(.ready), source: .account)
        _ = joining.send(
            .owner(.uncertain(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
            source: .command
        )
        let joiningBefore = joining.state
        joining.cycleRepeat()
        runner.equal("route refusal leaves repeat unchanged", joining.state.options.repeatMode, joiningBefore.options.repeatMode)
        runner.check("route refusal does not start a pending repeat", joining.state.pendingCommands.isEmpty)
        await joining.shutdownForTermination()

        let duplicateRemote = ScriptedRepeatRemote(sleepUntilCancelled: true)
        let duplicateStore = playbackStore(
            repeatEnvironment(local: RepeatLocalEngine(), remote: duplicateRemote)
        )
        seedReadyRemote(duplicateStore)
        duplicateStore.cycleRepeat()
        let repeatPending = await waitUntil { duplicateStore.state.pendingCommands[.options] != nil }
        runner.check("the first repeat is pending before a duplicate", repeatPending)
        let afterFirstRepeat = duplicateStore.state
        duplicateStore.cycleRepeat()
        runner.equal("a duplicate repeat does not change options", duplicateStore.state.options, afterFirstRepeat.options)
        runner.equal("a duplicate repeat keeps the original command", duplicateStore.state.pendingCommands[.options]?.id, afterFirstRepeat.pendingCommands[.options]?.id)
        if let commandID = duplicateStore.state.pendingCommands[.options]?.id {
            duplicateStore.effects.cancel(.command(commandID))
        }
        await duplicateStore.shutdownForTermination()
    }

    runner.suite("PlaybackStore.state has a single reducer commit writer") {
        runner.noThrow("PlaybackStore sources are readable") {
            let files = [
                "Aural/Spotify/PlaybackStore.swift",
                "Aural/Spotify/PlaybackStore+Commands.swift",
                "Aural/Spotify/PlaybackStore+EngineEvents.swift",
                "Aural/Spotify/PlaybackStore+History.swift",
                "Aural/Spotify/PlaybackStore+Projections.swift",
                "Aural/Spotify/PlaybackStore+Queue.swift",
                "Aural/Spotify/PlaybackStore+Session.swift",
                "Aural/Spotify/PlaybackStore+Transport.swift",
            ]
            let sources = try files.map(auralSourceFile)
            let assignments = sources.flatMap(playbackStoreStateAssignments)
            runner.equal(
                "PlaybackStore.state assignments are the declaration and send commit",
                assignments,
                [
                    "private(set) var state = PlaybackState(accountEpoch: 1)",
                    "state = next",
                ]
            )
            let mutations = sources.flatMap(playbackStoreStateMemberMutations)
            runner.equal("PlaybackStore files have no direct state member mutation", mutations, [String]())
            let store = try auralSourceFile("Aural/Spotify/PlaybackStore.swift")
            runner.check(
                "send is the only accepted reducer commit for PlaybackStore.state",
                containsToken(store, "if accepted {")
                    && containsToken(store, "state = next")
                    && containsToken(store, "PlaybackReducer.reduce")
            )
            runner.check(
                "cycleRepeat no longer assigns presentation outside the reducer",
                !containsToken(try auralSourceFile("Aural/Spotify/PlaybackStore+Transport.swift"), "setRepeat(")
                    && !containsToken(try auralSourceFile("Aural/Spotify/PlaybackStore+Transport.swift"), "reconcileRepeatCommandFailure")
            )
        }
    }
}
