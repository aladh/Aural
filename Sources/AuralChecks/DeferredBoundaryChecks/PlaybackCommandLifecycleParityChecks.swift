import AuralDomain
import Foundation
@testable import AuralCore

private enum LifecycleKind: String, CaseIterable {
    case transport
    case options
    case transfer

    var commandKind: PlaybackCommandKind {
        switch self {
        case .transport: .transport
        case .options: .options
        case .transfer: .transfer
        }
    }

    var action: String {
        switch self {
        case .transport: "Could not play that Spotify URI"
        case .options: "Could not update repeat"
        case .transfer: "Could not move playback to Speaker B"
        }
    }
}

private enum LifecycleRoute: String, CaseIterable {
    case local
    case remote
}

private enum LifecycleRemoteFailure: Error {
    case boom
}

private final class LifecycleLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let condition = NSCondition()
    private var allowed = false
    private var result: PlaybackEngineResult
    private var storedEnteredCount = 0
    private var storedExecuteCount = 0

    init(result: PlaybackEngineResult, gated: Bool) {
        self.result = result
        allowed = !gated
    }

    var enteredCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedEnteredCount
    }

    var executeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedExecuteCount
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult {
        condition.lock()
        storedEnteredCount += 1
        while !allowed {
            condition.wait()
        }
        storedExecuteCount += 1
        let result = self.result
        allowed = false
        condition.unlock()
        return result
    }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? { nil }
    func configureHighQualityPlayback() {}
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }

    func finish(with result: PlaybackEngineResult) {
        condition.lock()
        self.result = result
        allowed = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor LifecycleRemoteClient: RemotePlaybackClient {
    enum Behavior: Sendable {
        case succeed
        case fail
        case gated
    }

    private let behavior: Behavior
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private(set) var sendCount = 0
    private(set) var completedCount = 0

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {
        sendCount += 1
        defer { completedCount += 1 }
        switch behavior {
        case .succeed:
            return
        case .fail:
            throw LifecycleRemoteFailure.boom
        case .gated:
            if let pendingResult {
                self.pendingResult = nil
                try pendingResult.get()
                return
            }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    func finish(success: Bool) {
        let result: Result<Void, Error> =
            success
            ? .success(())
            : .failure(LifecycleRemoteFailure.boom)
        if let waiting = continuation {
            continuation = nil
            waiting.resume(with: result)
        } else {
            pendingResult = result
        }
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

private actor IdleWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
    }
}

private final class IdleAccount: AccountSession, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAuthorizeCount = 0

    var authorizeCount: Int {
        lock.withLock { storedAuthorizeCount }
    }

    func authorizeInteractively() async throws -> KeymasterTokens {
        lock.withLock { storedAuthorizeCount += 1 }
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

private enum LifecycleCheckFailure: Error { case unavailable }

private struct IdleCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] {
        throw LifecycleCheckFailure.unavailable
    }
    func home() async throws -> PathfinderHome { throw LifecycleCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw LifecycleCheckFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw LifecycleCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw LifecycleCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw LifecycleCheckFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw LifecycleCheckFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw LifecycleCheckFailure.unavailable }
}

private let lifecycleTrackA = CurrentTrack(
    uri: "spotify:track:a",
    title: "A",
    artist: "Artist",
    duration: 200,
    metadataSource: .catalog
)
private let lifecycleTrackB = CurrentTrack(
    uri: "spotify:track:b",
    title: "B",
    artist: "Artist",
    duration: 180,
    metadataSource: .catalog
)
private let lifecycleTrackC = CurrentTrack(
    uri: "spotify:track:c",
    title: "C",
    artist: "Artist",
    duration: 160,
    metadataSource: .catalog
)
private let lifecycleTiming = PlaybackTiming(
    position: 40,
    duration: 200,
    anchoredAt: Date(timeIntervalSince1970: 1_799_999_990)
)
private let lifecycleOwnerA = PlaybackOwner.remote(
    PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true)
)
private let lifecycleExpectedB = PlaybackOwner.uncertain(
    PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker")
)
private let lifecycleRemoteB = PlaybackOwner.remote(
    PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker", isActive: true)
)
private let lifecycleOwnerC = PlaybackOwner.remote(
    PlaybackDevice(id: "phone", name: "Phone", type: "smartphone", isActive: true)
)
private let lifecycleRepeatPlan = RepeatTransitionPlan.planning(
    from: RepeatMode.off.flags,
    to: RepeatMode.context.flags
)

private func lifecycleEnvironment(
    local: any LocalPlaybackEngine,
    remote: any RemotePlaybackClient,
    account: IdleAccount = IdleAccount()
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: remote,
        local: local,
        webQueue: IdleWebQueue(),
        account: account,
        audioOutput: IdleAudio(),
        preferences: IdlePreferences(),
        lifecycle: IdleLifecycle(),
        clock: StickyClock(),
        catalog: IdleCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: IdleAttributes()
    )
}

@MainActor
private func lifecycleStore(_ environment: PlaybackEnvironment) -> PlaybackStore {
    PlaybackStore(
        environment: environment,
        feedback: TransientFeedbackPresenter(clock: environment.clock)
    )
}

@MainActor
private func seedRoute(_ player: PlaybackStore, _ route: LifecycleRoute) {
    _ = player.send(.session(.ready), source: .account)
    switch route {
    case .local:
        _ = player.send(
            .devices(
                PlaybackDeviceSnapshot(
                    devices: [
                        PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true),
                        PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker"),
                    ],
                    localDeviceID: "mac",
                    revision: 1
                )),
            source: .engineDevices,
            revision: 1
        )
    case .remote:
        _ = player.send(
            .devices(
                PlaybackDeviceSnapshot(
                    devices: [
                        PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: false),
                        PlaybackDevice(id: "speaker-a", name: "Speaker A", type: "speaker", isActive: true),
                        PlaybackDevice(id: "speaker-b", name: "Speaker B", type: "speaker"),
                        PlaybackDevice(id: "phone", name: "Phone", type: "smartphone"),
                    ],
                    localDeviceID: "mac",
                    revision: 1
                )),
            source: .engineDevices,
            revision: 1
        )
        _ = player.send(.owner(lifecycleOwnerA), source: .command)
    }
    _ = player.send(
        .presentation(
            PlaybackPresentationSnapshot(
                currentTrack: lifecycleTrackA,
                transport: .playing,
                timing: lifecycleTiming
            )),
        source: .user
    )
    _ = player.send(.options(PlaybackOptions(shuffle: false, repeatMode: .off)), source: .user)
}

@MainActor
private func startLifecycleCommand(
    _ player: PlaybackStore,
    kind: LifecycleKind,
    completion: @escaping @MainActor (Bool) -> Void
) {
    switch kind {
    case .transport:
        player.performRoutedCommand(
            kind.action,
            expecting: true,
            expectedTiming: PlaybackTiming(
                position: 0, duration: 180, anchoredAt: Date(timeIntervalSince1970: 1_800_000_000)),
            expectedTrack: lifecycleTrackB,
            local: .playURI(lifecycleTrackB.uri),
            remote: .play(uri: lifecycleTrackB.uri),
            completion: completion
        )
    case .options:
        player.performRoutedOperation(
            kind.action,
            kind: .options,
            expectedRepeatFlags: RepeatMode.context.flags,
            local: .repeatOptions(lifecycleRepeatPlan),
            remote: { api, from, to in
                try await RepeatTransitionApplication.applyRemote(lifecycleRepeatPlan) { mutation in
                    try await api.send(.repeatMutation(mutation), from: from, to: to)
                }
            },
            completion: completion
        )
    case .transfer:
        player.performRoutedOperation(
            kind.action,
            kind: .transfer,
            expectedOwner: lifecycleExpectedB,
            local: .transferToDevice("speaker-b"),
            remote: { api, from, to in try await api.send(.pause, from: from, to: to) },
            completion: completion
        )
    }
}

@MainActor
private func confirm(_ player: PlaybackStore, kind: LifecycleKind, revision: UInt64) {
    switch kind {
    case .transport:
        _ = player.send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: lifecycleTrackB.uri,
                    timing: PlaybackTiming(
                        position: 0, duration: 180, anchoredAt: Date(timeIntervalSince1970: 1_800_000_000))
                )),
            source: .enginePlayback,
            revision: revision
        )
    case .options:
        _ = player.send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: lifecycleTrackA.uri,
                    timing: lifecycleTiming,
                    repeatMode: .context,
                    repeatFlags: RepeatMode.context.flags
                )),
            source: .enginePlayback,
            revision: revision
        )
    case .transfer:
        _ = player.send(
            .engineConnection(
                EngineConnectionSnapshot(
                    session: .ready,
                    owner: lifecycleRemoteB,
                    localDeviceID: "mac"
                )),
            source: .engineConnection,
            revision: revision
        )
    }
}

@MainActor
private func supersede(_ player: PlaybackStore, kind: LifecycleKind, revision: UInt64) {
    switch kind {
    case .transport:
        _ = player.send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: lifecycleTrackC.uri,
                    timing: PlaybackTiming(
                        position: 0, duration: 160, anchoredAt: Date(timeIntervalSince1970: 1_800_000_000))
                )),
            source: .enginePlayback,
            revision: revision
        )
    case .options:
        _ = player.send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: .playing,
                    trackURI: lifecycleTrackA.uri,
                    timing: lifecycleTiming,
                    repeatMode: .track,
                    repeatFlags: RepeatMode.track.flags
                )),
            source: .enginePlayback,
            revision: revision
        )
    case .transfer:
        _ = player.send(
            .engineConnection(
                EngineConnectionSnapshot(
                    session: .ready,
                    owner: lifecycleOwnerC,
                    localDeviceID: "mac"
                )),
            source: .engineConnection,
            revision: revision
        )
    }
}

@MainActor
func runPlaybackCommandLifecycleParityChecks(_ runner: CheckRunner) async {
    await runner.suite("Waiting route never admits playback commands") {
        for kind in LifecycleKind.allCases {
            let player = lifecycleStore(
                lifecycleEnvironment(
                    local: LifecycleLocalEngine(result: .ok, gated: false),
                    remote: LifecycleRemoteClient(.succeed)
                )
            )
            _ = player.send(.session(.ready), source: .account)
            _ = player.send(.owner(.uncertain(nil)), source: .command)
            var completions: [Bool] = []
            startLifecycleCommand(player, kind: kind) { completions.append($0) }
            runner.equal("\(kind.rawValue) waiting route completes immediately as failure", completions, [false])
            runner.check(
                "\(kind.rawValue) waiting route does not create a pending command", player.state.pendingCommands.isEmpty
            )
            await player.shutdownForTermination()
        }
    }

    await runner.suite("Local and remote command lifecycle parity") {
        for route in LifecycleRoute.allCases {
            for kind in LifecycleKind.allCases {
                let label = "\(route.rawValue) \(kind.rawValue)"

                let successAccount = IdleAccount()
                let success = lifecycleStore(
                    lifecycleEnvironment(
                        local: LifecycleLocalEngine(result: .ok, gated: false),
                        remote: LifecycleRemoteClient(.succeed),
                        account: successAccount
                    )
                )
                seedRoute(success, route)
                var successCompletions: [Bool] = []
                startLifecycleCommand(success, kind: kind) { successCompletions.append($0) }
                let successFinished = await waitUntil { !successCompletions.isEmpty }
                runner.check("\(label) success finishes", successFinished)
                runner.equal("\(label) confirmation-free success completion", successCompletions, [true])
                runner.nil_("\(label) success has no command notice", success.transientCommandError)
                runner.equal("\(label) success does not reconnect", successAccount.authorizeCount, 0)
                runner.nil_(
                    "\(label) success leaves no pending command", success.state.pendingCommands[kind.commandKind])
                await success.shutdownForTermination()

                let rejected = lifecycleStore(
                    lifecycleEnvironment(
                        local: LifecycleLocalEngine(result: .error, gated: false),
                        remote: LifecycleRemoteClient(.fail)
                    )
                )
                seedRoute(rejected, route)
                var rejectedCompletions: [Bool] = []
                startLifecycleCommand(rejected, kind: kind) { rejectedCompletions.append($0) }
                let rejectedFinished = await waitUntil { !rejectedCompletions.isEmpty }
                runner.check("\(label) rejection finishes", rejectedFinished)
                runner.equal("\(label) rejection completion", rejectedCompletions, [false])
                runner.equal("\(label) rejection uses the action notice", rejected.transientCommandError, kind.action)
                runner.nil_(
                    "\(label) rejection leaves no pending command", rejected.state.pendingCommands[kind.commandKind])
                await rejected.shutdownForTermination()

                if route == .local {
                    let reconnectAccount = IdleAccount()
                    let reconnect = lifecycleStore(
                        lifecycleEnvironment(
                            local: LifecycleLocalEngine(
                                result: PlaybackEngineResult(rawValue: -2),
                                gated: false
                            ),
                            remote: LifecycleRemoteClient(.succeed),
                            account: reconnectAccount
                        )
                    )
                    seedRoute(reconnect, route)
                    var reconnectCompletions: [Bool] = []
                    startLifecycleCommand(reconnect, kind: kind) { reconnectCompletions.append($0) }
                    let reconnectFinished = await waitUntil { !reconnectCompletions.isEmpty }
                    runner.check("\(label) reconnect-required finishes", reconnectFinished)
                    runner.equal("\(label) reconnect-required completion", reconnectCompletions, [false])
                    runner.equal(
                        "\(label) reconnect-required uses the action notice", reconnect.transientCommandError,
                        kind.action)
                    let reconnectStarted = await waitUntil { reconnectAccount.authorizeCount == 1 }
                    runner.check("\(label) reconnect-required starts connect", reconnectStarted)
                    runner.equal("\(label) reconnect-required connect count", reconnectAccount.authorizeCount, 1)
                    await reconnect.shutdownForTermination()
                }

                let duplicateLocal = LifecycleLocalEngine(result: .ok, gated: true)
                let duplicateRemote = LifecycleRemoteClient(.gated)
                let duplicate = lifecycleStore(
                    lifecycleEnvironment(local: duplicateLocal, remote: duplicateRemote)
                )
                seedRoute(duplicate, route)
                var firstCompletions: [Bool] = []
                var duplicateCompletions: [Bool] = []
                startLifecycleCommand(duplicate, kind: kind) { firstCompletions.append($0) }
                let pendingReady = await waitUntil { duplicate.state.pendingCommands[kind.commandKind] != nil }
                runner.check("\(label) first command is pending before a duplicate", pendingReady)
                let firstID = duplicate.state.pendingCommands[kind.commandKind]?.id
                startLifecycleCommand(duplicate, kind: kind) { duplicateCompletions.append($0) }
                runner.equal("\(label) duplicate completes immediately as failure", duplicateCompletions, [false])
                runner.equal(
                    "\(label) duplicate keeps the original command",
                    duplicate.state.pendingCommands[kind.commandKind]?.id, firstID)
                if route == .local {
                    duplicateLocal.finish(with: .ok)
                } else {
                    await duplicateRemote.finish(success: true)
                }
                let duplicateFinished = await waitUntil { !firstCompletions.isEmpty }
                runner.check("\(label) first command finishes after the duplicate refusal", duplicateFinished)
                await duplicate.shutdownForTermination()

                let confirmLocal = LifecycleLocalEngine(result: .error, gated: true)
                let confirmRemote = LifecycleRemoteClient(.gated)
                let confirmed = lifecycleStore(
                    lifecycleEnvironment(local: confirmLocal, remote: confirmRemote)
                )
                seedRoute(confirmed, route)
                var confirmedCompletions: [Bool] = []
                startLifecycleCommand(confirmed, kind: kind) { confirmedCompletions.append($0) }
                let confirmPending = await waitUntil { confirmed.state.pendingCommands[kind.commandKind] != nil }
                runner.check("\(label) command is pending before confirmation", confirmPending)
                let confirmedID = confirmed.state.pendingCommands[kind.commandKind]?.id
                confirm(confirmed, kind: kind, revision: 1)
                runner.nil_(
                    "\(label) authoritative snapshot confirms the command",
                    confirmed.state.pendingCommands[kind.commandKind])
                runner.equal(
                    "\(label) authoritative snapshot records confirmation",
                    confirmedID.flatMap { confirmed.state.transportCommandResolutions[$0] },
                    Optional(PlaybackTransportCommandResolution.confirmed)
                )
                if route == .local {
                    confirmLocal.finish(with: .error)
                } else {
                    await confirmRemote.finish(success: false)
                }
                let confirmFinished = await waitUntil { !confirmedCompletions.isEmpty }
                runner.check("\(label) confirmed command still finishes", confirmFinished)
                runner.equal(
                    "\(label) confirmed then coordinator failure reports success", confirmedCompletions, [true])
                await confirmed.shutdownForTermination()

                let supersedeLocal = LifecycleLocalEngine(result: .error, gated: true)
                let supersedeRemote = LifecycleRemoteClient(.gated)
                let superseded = lifecycleStore(
                    lifecycleEnvironment(local: supersedeLocal, remote: supersedeRemote)
                )
                seedRoute(superseded, route)
                var supersededCompletions: [Bool] = []
                startLifecycleCommand(superseded, kind: kind) { supersededCompletions.append($0) }
                let supersedePending = await waitUntil { superseded.state.pendingCommands[kind.commandKind] != nil }
                runner.check("\(label) command is pending before supersession", supersedePending)
                supersede(superseded, kind: kind, revision: 1)
                runner.nil_(
                    "\(label) unrelated snapshot clears the pending command",
                    superseded.state.pendingCommands[kind.commandKind])
                if route == .local {
                    supersedeLocal.finish(with: .error)
                    let supersedeReached = await waitUntil { supersedeLocal.executeCount == 1 }
                    runner.check("\(label) superseded command still reaches the local fixture", supersedeReached)
                } else {
                    await supersedeRemote.finish(success: false)
                    let supersedeReached = await waitUntil { await supersedeRemote.sendCount >= 1 }
                    runner.check("\(label) superseded command still reaches the remote fixture", supersedeReached)
                }
                runner.check(
                    "\(label) superseded then coordinator failure reports no completion", supersededCompletions.isEmpty)
                runner.nil_(
                    "\(label) superseded then coordinator failure has no notice", superseded.transientCommandError)
                await superseded.shutdownForTermination()

                let staleLocal = LifecycleLocalEngine(result: .ok, gated: true)
                let staleRemote = LifecycleRemoteClient(.gated)
                let stale = lifecycleStore(
                    lifecycleEnvironment(local: staleLocal, remote: staleRemote)
                )
                seedRoute(stale, route)
                var staleCompletions: [Bool] = []
                startLifecycleCommand(stale, kind: kind) { staleCompletions.append($0) }
                let stalePending = await waitUntil { stale.state.pendingCommands[kind.commandKind] != nil }
                runner.check("\(label) command is pending before an engine-epoch bump", stalePending)
                _ = stale.send(
                    .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                    source: .engineConnection,
                    revision: 1,
                    engineEpoch: stale.engineGeneration + 1
                )
                runner.nil_(
                    "\(label) engine-epoch bump drops the pending command",
                    stale.state.pendingCommands[kind.commandKind])
                if route == .local {
                    staleLocal.finish(with: .ok)
                    let staleReached = await waitUntil { staleLocal.executeCount == 1 }
                    runner.check("\(label) stale command still reaches the local fixture", staleReached)
                } else {
                    await staleRemote.finish(success: true)
                    let staleReached = await waitUntil { await staleRemote.sendCount >= 1 }
                    runner.check("\(label) stale command still reaches the remote fixture", staleReached)
                }
                runner.check("\(label) stale finish reports no completion", staleCompletions.isEmpty)
                await stale.shutdownForTermination()

                let cancelLocal = LifecycleLocalEngine(result: .ok, gated: true)
                let cancelRemote = LifecycleRemoteClient(.gated)
                let cancelled = lifecycleStore(
                    lifecycleEnvironment(local: cancelLocal, remote: cancelRemote)
                )
                seedRoute(cancelled, route)
                let prior = cancelled.state
                var cancelCompletions: [Bool] = []
                startLifecycleCommand(cancelled, kind: kind) { cancelCompletions.append($0) }
                let cancelPending = await waitUntil { cancelled.state.pendingCommands[kind.commandKind] != nil }
                runner.check("\(label) command is pending before cancellation", cancelPending)
                let cancelReached = await waitUntil {
                    if route == .local { return cancelLocal.enteredCount == 1 }
                    return await cancelRemote.sendCount >= 1
                }
                runner.check("\(label) cancelled command still reaches the fixture", cancelReached)
                let cancelledID = cancelled.state.pendingCommands[kind.commandKind]?.id
                runner.notNil("\(label) cancelled command has an id", cancelledID)
                if let commandID = cancelledID {
                    cancelled.effects.cancel(.command(commandID))
                }
                let cancelSettled = await waitUntil {
                    cancelled.state.pendingCommands[kind.commandKind] == nil && !cancelCompletions.isEmpty
                }
                runner.check("\(label) ordinary cancellation settles", cancelSettled)
                runner.equal("\(label) ordinary cancellation reports failure once", cancelCompletions, [false])
                runner.nil_(
                    "\(label) ordinary cancellation clears the pending command",
                    cancelled.state.pendingCommands[kind.commandKind])
                runner.nil_("\(label) ordinary cancellation has no command notice", cancelled.transientCommandError)
                runner.equal(
                    "\(label) ordinary cancellation restores captured transport", cancelled.state.transport,
                    prior.transport)
                runner.equal(
                    "\(label) ordinary cancellation restores captured timing", cancelled.state.timing, prior.timing)
                runner.equal(
                    "\(label) ordinary cancellation restores captured track", cancelled.state.currentTrack,
                    prior.currentTrack)
                runner.equal(
                    "\(label) ordinary cancellation restores captured options", cancelled.state.options, prior.options)
                runner.equal(
                    "\(label) ordinary cancellation restores captured owner", cancelled.state.owner, prior.owner)
                if route == .local {
                    cancelLocal.finish(with: .ok)
                } else {
                    await cancelRemote.finish(success: true)
                }
                let cancelledFixtureReleased = await waitUntil {
                    if route == .local { return cancelLocal.executeCount == 1 }
                    return await cancelRemote.completedCount == 1
                }
                runner.check("\(label) cancelled fixture releases before reuse", cancelledFixtureReleased)

                var nextCompletions: [Bool] = []
                startLifecycleCommand(cancelled, kind: kind) { nextCompletions.append($0) }
                let nextPending = await waitUntil { cancelled.state.pendingCommands[kind.commandKind] != nil }
                runner.check("\(label) same-kind command is admitted after cancellation", nextPending)
                runner.check(
                    "\(label) the later command is a new id",
                    cancelled.state.pendingCommands[kind.commandKind]?.id != cancelledID
                )
                let nextReached = await waitUntil {
                    if route == .local { return cancelLocal.enteredCount == 2 }
                    return await cancelRemote.sendCount >= 2
                }
                runner.check("\(label) later command reaches the fixture before completion", nextReached)
                if route == .local {
                    cancelLocal.finish(with: .ok)
                } else {
                    await cancelRemote.finish(success: true)
                }
                let nextFinished = await waitUntil { !nextCompletions.isEmpty }
                runner.check("\(label) later command after cancellation finishes", nextFinished)
                runner.equal("\(label) later command after cancellation succeeds", nextCompletions, [true])
                await cancelled.shutdownForTermination()

                let confirmCancelLocal = LifecycleLocalEngine(result: .ok, gated: true)
                let confirmCancelRemote = LifecycleRemoteClient(.gated)
                let confirmCancelled = lifecycleStore(
                    lifecycleEnvironment(local: confirmCancelLocal, remote: confirmCancelRemote)
                )
                seedRoute(confirmCancelled, route)
                var confirmCancelCompletions: [Bool] = []
                startLifecycleCommand(confirmCancelled, kind: kind) { confirmCancelCompletions.append($0) }
                let confirmCancelPending = await waitUntil {
                    confirmCancelled.state.pendingCommands[kind.commandKind] != nil
                }
                runner.check("\(label) command is pending before confirmed cancellation", confirmCancelPending)
                let confirmCancelID = confirmCancelled.state.pendingCommands[kind.commandKind]?.id
                confirm(confirmCancelled, kind: kind, revision: 1)
                runner.nil_(
                    "\(label) confirmation clears the pending command before cancel",
                    confirmCancelled.state.pendingCommands[kind.commandKind])
                if let commandID = confirmCancelID {
                    confirmCancelled.effects.cancel(.command(commandID))
                }
                runner.check("\(label) confirmed cancellation reports no completion", confirmCancelCompletions.isEmpty)
                runner.nil_("\(label) confirmed cancellation has no notice", confirmCancelled.transientCommandError)
                if kind == .transport {
                    runner.equal(
                        "\(label) confirmed cancellation keeps the target track",
                        confirmCancelled.state.currentTrack?.uri, lifecycleTrackB.uri)
                }
                if kind == .options {
                    runner.equal(
                        "\(label) confirmed cancellation keeps context repeat",
                        confirmCancelled.state.options.repeatMode, RepeatMode.context)
                }
                if kind == .transfer {
                    runner.equal(
                        "\(label) confirmed cancellation keeps the target owner", confirmCancelled.state.owner,
                        lifecycleRemoteB)
                }
                if route == .local {
                    confirmCancelLocal.finish(with: .ok)
                } else {
                    await confirmCancelRemote.finish(success: true)
                }
                await confirmCancelled.shutdownForTermination()

                let supersedeCancelLocal = LifecycleLocalEngine(result: .ok, gated: true)
                let supersedeCancelRemote = LifecycleRemoteClient(.gated)
                let supersedeCancelled = lifecycleStore(
                    lifecycleEnvironment(local: supersedeCancelLocal, remote: supersedeCancelRemote)
                )
                seedRoute(supersedeCancelled, route)
                var supersedeCancelCompletions: [Bool] = []
                startLifecycleCommand(supersedeCancelled, kind: kind) { supersedeCancelCompletions.append($0) }
                let supersedeCancelPending = await waitUntil {
                    supersedeCancelled.state.pendingCommands[kind.commandKind] != nil
                }
                runner.check("\(label) command is pending before superseded cancellation", supersedeCancelPending)
                let supersedeCancelID = supersedeCancelled.state.pendingCommands[kind.commandKind]?.id
                supersede(supersedeCancelled, kind: kind, revision: 1)
                runner.nil_(
                    "\(label) supersession clears the pending command before cancel",
                    supersedeCancelled.state.pendingCommands[kind.commandKind])
                if let commandID = supersedeCancelID {
                    supersedeCancelled.effects.cancel(.command(commandID))
                }
                runner.check(
                    "\(label) superseded cancellation reports no completion", supersedeCancelCompletions.isEmpty)
                runner.nil_("\(label) superseded cancellation has no notice", supersedeCancelled.transientCommandError)
                if kind == .transport {
                    runner.equal(
                        "\(label) superseded cancellation keeps the unrelated track",
                        supersedeCancelled.state.currentTrack?.uri, lifecycleTrackC.uri)
                }
                if kind == .options {
                    runner.equal(
                        "\(label) superseded cancellation keeps track repeat",
                        supersedeCancelled.state.options.repeatMode, RepeatMode.track)
                }
                if kind == .transfer {
                    runner.equal(
                        "\(label) superseded cancellation keeps the unrelated owner", supersedeCancelled.state.owner,
                        lifecycleOwnerC)
                }
                if route == .local {
                    supersedeCancelLocal.finish(with: .ok)
                } else {
                    await supersedeCancelRemote.finish(success: true)
                }
                await supersedeCancelled.shutdownForTermination()

                let staleCancelLocal = LifecycleLocalEngine(result: .ok, gated: true)
                let staleCancelRemote = LifecycleRemoteClient(.gated)
                let staleCancelled = lifecycleStore(
                    lifecycleEnvironment(local: staleCancelLocal, remote: staleCancelRemote)
                )
                seedRoute(staleCancelled, route)
                var staleCancelCompletions: [Bool] = []
                startLifecycleCommand(staleCancelled, kind: kind) { staleCancelCompletions.append($0) }
                let staleCancelPending = await waitUntil {
                    staleCancelled.state.pendingCommands[kind.commandKind] != nil
                }
                runner.check("\(label) command is pending before stale cancellation", staleCancelPending)
                let staleCancelID = staleCancelled.state.pendingCommands[kind.commandKind]?.id
                _ = staleCancelled.send(
                    .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
                    source: .engineConnection,
                    revision: 1,
                    engineEpoch: staleCancelled.engineGeneration + 1
                )
                runner.nil_(
                    "\(label) engine-epoch bump drops the pending command before cancel",
                    staleCancelled.state.pendingCommands[kind.commandKind])
                if let commandID = staleCancelID {
                    staleCancelled.effects.cancel(.command(commandID))
                }
                runner.check("\(label) stale cancellation reports no completion", staleCancelCompletions.isEmpty)
                if route == .local {
                    staleCancelLocal.finish(with: .ok)
                } else {
                    await staleCancelRemote.finish(success: true)
                }
                await staleCancelled.shutdownForTermination()

                let teardownLocal = LifecycleLocalEngine(result: .ok, gated: true)
                let teardownRemote = LifecycleRemoteClient(.gated)
                let teardown = lifecycleStore(
                    lifecycleEnvironment(local: teardownLocal, remote: teardownRemote)
                )
                seedRoute(teardown, route)
                var teardownCompletions: [Bool] = []
                startLifecycleCommand(teardown, kind: kind) { teardownCompletions.append($0) }
                let teardownPending = await waitUntil { teardown.state.pendingCommands[kind.commandKind] != nil }
                runner.check("\(label) command is pending before teardown", teardownPending)
                let teardownReached = await waitUntil {
                    if route == .local { return teardownLocal.enteredCount == 1 }
                    return await teardownRemote.sendCount >= 1
                }
                runner.check("\(label) teardown command still reaches the fixture", teardownReached)
                // Local execute is a blocking coordinator call. Shutdown awaits
                // shutdownEngine on that same actor, so the fixture must be released first.
                if route == .local {
                    teardownLocal.finish(with: .ok)
                } else {
                    await teardownRemote.finish(success: true)
                }
                await teardown.shutdownForTermination()
                for _ in 0..<50 { await Task.yield() }
                runner.check("\(label) teardown reports no completion", teardownCompletions.isEmpty)
                runner.nil_(
                    "\(label) teardown leaves no pending command", teardown.state.pendingCommands[kind.commandKind])
            }
        }
    }
}
