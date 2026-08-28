import AuralDomain
import Foundation
@testable import AuralCore

private final class ScriptedLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let result: PlaybackEngineResult
    private var storedOperations: [LocalPlaybackOperation] = []

    init(result: PlaybackEngineResult) {
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

private final class GatedLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let condition = NSCondition()
    private var allowed = false
    private var result: PlaybackEngineResult

    init(result: PlaybackEngineResult = .error) {
        self.result = result
    }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult { .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult {
        condition.lock()
        while !allowed {
            condition.wait()
        }
        let result = self.result
        condition.unlock()
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

    func finish(with result: PlaybackEngineResult) {
        condition.lock()
        self.result = result
        allowed = true
        condition.broadcast()
        condition.unlock()
    }
}

private enum FixtureRemoteFailure: Error {
    case boom
}

private actor GatedFailingRemoteClient: RemotePlaybackClient {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var sendCount = 0

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {
        sendCount += 1
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func fail() {
        continuation?.resume(throwing: FixtureRemoteFailure.boom)
        continuation = nil
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

private actor ScriptedRemoteClient: RemotePlaybackClient {
    enum Behavior: Sendable {
        case succeed
        case fail
        case sleepUntilCancelled
    }

    private let behavior: Behavior
    private(set) var sendCount = 0

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {
        sendCount += 1
        switch behavior {
        case .succeed:
            return
        case .fail:
            throw FixtureRemoteFailure.boom
        case .sleepUntilCancelled:
            try await Task.sleep(nanoseconds: 60_000_000_000)
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

private enum CommandCheckFailure: Error { case unavailable }

private struct IdleCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] { throw CommandCheckFailure.unavailable }
    func home() async throws -> PathfinderHome { throw CommandCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw CommandCheckFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw CommandCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw CommandCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw CommandCheckFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw CommandCheckFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw CommandCheckFailure.unavailable }
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

@MainActor
private func localCommandOutcome(
    _ coordinator: PlaybackCoordinator,
    _ runner: CheckRunner,
    label: String
) async -> Result<Void, PlaybackCommandFailure>? {
    do {
        return try await coordinator.performLocalCommand(.pause)
    } catch {
        runner.check(label, false)
        return nil
    }
}

private func commandEnvironment(
    local: any LocalPlaybackEngine,
    remote: any RemotePlaybackClient,
    account: any AccountSession = IdleAccount()
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
private func playbackStore(_ environment: PlaybackEnvironment) -> PlaybackStore {
    PlaybackStore(
        environment: environment,
        feedback: TransientFeedbackPresenter(clock: environment.clock)
    )
}

@MainActor
func runPlaybackCommandFailureChecks(_ runner: CheckRunner) async {
    runner.suite("Playback command failure mapping") {
        switch PlaybackCommandFailure.from(engineResult: .ok) {
        case .success:
            runner.check("local success is a typed success", true)
        case .failure:
            runner.check("local success is a typed success", false)
        }
        switch PlaybackCommandFailure.from(engineResult: .error) {
        case .success:
            runner.check("engine error is rejected", false)
        case let .failure(failure):
            runner.equal("engine error is rejected", failure, .rejected)
        }
        switch PlaybackCommandFailure.from(engineResult: PlaybackEngineResult(rawValue: -2)) {
        case .success:
            runner.check("session disconnected is reconnect-required", false)
        case let .failure(failure):
            runner.equal("session disconnected is reconnect-required", failure, .reconnectRequired)
        }
        switch PlaybackCommandFailure.from(engineResult: PlaybackEngineResult(rawValue: -3)) {
        case .success:
            runner.check("session not connected is reconnect-required", false)
        case let .failure(failure):
            runner.equal("session not connected is reconnect-required", failure, .reconnectRequired)
        }
        switch PlaybackCommandFailure.from(engineResult: PlaybackEngineResult(rawValue: -99)) {
        case .success:
            runner.check("an unrecognized engine code is unavailable", false)
        case let .failure(failure):
            runner.equal("an unrecognized engine code is unavailable", failure, .unavailable)
        }
    }

    await runner.suite("Coordinator local command outcomes") {
        let successCoordinator = PlaybackCoordinator(
            local: ScriptedLocalEngine(result: .ok),
            remote: ScriptedRemoteClient(.succeed)
        )
        if let success = await localCommandOutcome(successCoordinator, runner, label: "local success") {
            if case .success = success {
                runner.check("local success", true)
            } else {
                runner.check("local success", false)
            }
        }

        let rejectedCoordinator = PlaybackCoordinator(
            local: ScriptedLocalEngine(result: .error),
            remote: ScriptedRemoteClient(.succeed)
        )
        if let rejected = await localCommandOutcome(rejectedCoordinator, runner, label: "local rejection") {
            if case let .failure(failure) = rejected {
                runner.equal("local rejection", failure, .rejected)
            } else {
                runner.check("local rejection", false)
            }
        }

        let reconnectCoordinator = PlaybackCoordinator(
            local: ScriptedLocalEngine(result: PlaybackEngineResult(rawValue: -2)),
            remote: ScriptedRemoteClient(.succeed)
        )
        if let reconnect = await localCommandOutcome(
            reconnectCoordinator,
            runner,
            label: "local reconnect-required"
        ) {
            if case let .failure(failure) = reconnect {
                runner.equal("local reconnect-required", failure, .reconnectRequired)
            } else {
                runner.check("local reconnect-required", false)
            }
        }
    }

    await runner.suite("Coordinator remote command outcomes") {
        let success = try? await PlaybackCoordinator(
            local: ScriptedLocalEngine(result: .ok),
            remote: ScriptedRemoteClient(.succeed)
        ).performRemoteCommand { remote in
            try await remote.send(.pause, from: "from", to: "to")
        }
        if case .success? = success {
            runner.check("remote success", true)
        } else {
            runner.check("remote success", false)
        }

        let rejected = try? await PlaybackCoordinator(
            local: ScriptedLocalEngine(result: .ok),
            remote: ScriptedRemoteClient(.fail)
        ).performRemoteCommand { remote in
            try await remote.send(.pause, from: "from", to: "to")
        }
        if case let .failure(failure)? = rejected {
            runner.equal("remote rejection", failure, .remoteRejected)
        } else {
            runner.check("remote rejection", false)
        }

        let sleepingRemote = ScriptedRemoteClient(.sleepUntilCancelled)
        let coordinator = PlaybackCoordinator(
            local: ScriptedLocalEngine(result: .ok),
            remote: sleepingRemote
        )
        let cancelled = Task {
            try await coordinator.performRemoteCommand { client in
                try await client.send(.pause, from: "from", to: "to")
            }
        }
        let sendStarted = await waitUntil { await sleepingRemote.sendCount == 1 }
        runner.check("remote send has started before cancellation", sendStarted)
        cancelled.cancel()
        var sawCancellation = false
        var operationalResult: Result<Void, PlaybackCommandFailure>?
        do {
            operationalResult = try await cancelled.value
        } catch is CancellationError {
            sawCancellation = true
        } catch {
            sawCancellation = false
        }
        runner.check("remote cancellation throws CancellationError", sawCancellation)
        runner.nil_("remote cancellation is not an operational failure", operationalResult)
    }

    await runner.suite("Store local command outcomes") {
        let action = "Pause was rejected"

        @MainActor
        func runLocal(_ result: PlaybackEngineResult, account: IdleAccount = IdleAccount()) async -> (
            completions: [Bool],
            notice: String?,
            authorizeCount: Int,
            player: PlaybackStore
        ) {
            let player = playbackStore(
                commandEnvironment(
                    local: ScriptedLocalEngine(result: result),
                    remote: ScriptedRemoteClient(.succeed),
                    account: account
                )
            )
            var completions: [Bool] = []
            player.performCommand(action, expecting: false, operation: .pause) { completions.append($0) }
            _ = await waitUntil { !completions.isEmpty || player.state.pendingCommands[.transport] == nil }
            _ = await waitUntil { !completions.isEmpty }
            return (completions, player.transientCommandError, account.authorizeCount, player)
        }

        let success = await runLocal(.ok)
        runner.equal("local success completion", success.completions, [true])
        runner.nil_("local success has no command notice", success.notice)
        runner.equal("local success does not reconnect", success.authorizeCount, 0)
        await success.player.shutdownForTermination()

        let rejected = await runLocal(.error)
        runner.equal("local rejection completion", rejected.completions, [false])
        runner.equal("local rejection uses the action notice", rejected.notice, action)
        runner.equal("local rejection does not reconnect", rejected.authorizeCount, 0)
        await rejected.player.shutdownForTermination()

        let reconnectAccount = IdleAccount()
        let reconnect = await runLocal(PlaybackEngineResult(rawValue: -2), account: reconnectAccount)
        runner.equal("reconnect-required completion", reconnect.completions, [false])
        runner.equal("reconnect-required uses the action notice", reconnect.notice, action)
        _ = await waitUntil { reconnectAccount.authorizeCount == 1 }
        runner.equal("reconnect-required starts connect after an accepted finish", reconnectAccount.authorizeCount, 1)
        await reconnect.player.shutdownForTermination()
    }

    await runner.suite("Store remote rejection and cancellation") {
        let action = "Pause was rejected"

        @MainActor
        func prepareRemoteStore(remote: ScriptedRemoteClient) -> PlaybackStore {
            let player = playbackStore(
                commandEnvironment(
                    local: ScriptedLocalEngine(result: .ok),
                    remote: remote
                )
            )
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
            return player
        }

        let rejecting = ScriptedRemoteClient(.fail)
        let rejectionStore = prepareRemoteStore(remote: rejecting)
        var rejectionCompletions: [Bool] = []
        rejectionStore.performRoutedCommand(
            action,
            expecting: false,
            local: .pause,
            remote: .pause
        ) { rejectionCompletions.append($0) }
        _ = await waitUntil { !rejectionCompletions.isEmpty }
        runner.equal("remote rejection completion", rejectionCompletions, [false])
        runner.equal("remote rejection uses the action notice", rejectionStore.transientCommandError, action)
        await rejectionStore.shutdownForTermination()

        let sleeping = ScriptedRemoteClient(.sleepUntilCancelled)
        let cancelStore = prepareRemoteStore(remote: sleeping)
        var cancelCompletions: [Bool] = []
        cancelStore.performRoutedCommand(
            action,
            expecting: false,
            local: .pause,
            remote: .pause
        ) { cancelCompletions.append($0) }
        let pendingReady = await waitUntil { cancelStore.state.pendingCommands[.transport] != nil }
        runner.check("remote command is pending before cancellation", pendingReady)
        if let commandID = cancelStore.state.pendingCommands[.transport]?.id {
            cancelStore.effects.cancel(.command(commandID))
        }
        _ = await waitUntil { await sleeping.sendCount == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        runner.check("cancelled remote command reports no completion", cancelCompletions.isEmpty)
        runner.nil_("cancelled remote command has no notice", cancelStore.transientCommandError)
        await cancelStore.shutdownForTermination()
    }

    await runner.suite("Store toggle and seek presentation ownership") {
        let clockNow = Date(timeIntervalSince1970: 1_800_000_000)
        let playingAnchor = clockNow.addingTimeInterval(-10)
        let priorPlayingTiming = PlaybackTiming(position: 40, duration: 200, anchoredAt: playingAnchor)
        let frozenPauseTiming = PlaybackTiming(
            position: AuralDomain.interpolatedPlaybackPosition(
                anchor: 40,
                anchoredAt: playingAnchor,
                now: clockNow,
                isPlaying: true,
                duration: 200
            ),
            duration: 200,
            anchoredAt: clockNow
        )
        let pausedTiming = PlaybackTiming(position: 50, duration: 200, anchoredAt: playingAnchor)
        let resumeTiming = PlaybackTiming(position: 50, duration: 200, anchoredAt: clockNow)

        @MainActor
        func seedRemotePlayback(
            _ player: PlaybackStore,
            transport: PlaybackTransportState,
            timing: PlaybackTiming
        ) {
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
            _ = player.send(
                .presentation(PlaybackPresentationSnapshot(
                    currentTrack: CurrentTrack(
                        uri: "spotify:track:fixture",
                        title: "Now",
                        artist: "Artist",
                        duration: 200,
                        metadataSource: .catalog
                    ),
                    transport: transport,
                    timing: timing
                )),
                source: .user
            )
        }

        let pauseFailStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.fail))
        )
        seedRemotePlayback(pauseFailStore, transport: .playing, timing: priorPlayingTiming)
        runner.check("remote pause can toggle before the command", pauseFailStore.canTogglePlayback)
        pauseFailStore.togglePlayback()
        runner.equal("remote pause applies paused transport before completion", pauseFailStore.state.transport, .paused)
        runner.equal("remote pause freezes displayed timing before completion", pauseFailStore.state.timing, frozenPauseTiming)
        _ = await waitUntil { pauseFailStore.state.pendingCommands[.transport] == nil }
        runner.equal("remote pause rejection restores playing", pauseFailStore.state.transport, .playing)
        runner.equal("remote pause rejection restores exact prior timing", pauseFailStore.state.timing, priorPlayingTiming)
        runner.equal("remote pause rejection uses the action notice", pauseFailStore.transientCommandError, "Pause was rejected")
        await pauseFailStore.shutdownForTermination()

        let resumeFailStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.fail))
        )
        seedRemotePlayback(resumeFailStore, transport: .paused, timing: pausedTiming)
        resumeFailStore.togglePlayback()
        runner.equal("remote resume applies playing before completion", resumeFailStore.state.transport, .playing)
        runner.equal("remote resume re-anchors from the injected clock", resumeFailStore.state.timing, resumeTiming)
        _ = await waitUntil { resumeFailStore.state.pendingCommands[.transport] == nil }
        runner.equal("remote resume rejection restores paused", resumeFailStore.state.transport, .paused)
        runner.equal("remote resume rejection restores exact prior timing", resumeFailStore.state.timing, pausedTiming)
        await resumeFailStore.shutdownForTermination()

        let pauseOkStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
        )
        seedRemotePlayback(pauseOkStore, transport: .playing, timing: priorPlayingTiming)
        pauseOkStore.togglePlayback()
        _ = await waitUntil { pauseOkStore.state.pendingCommands[.transport] == nil }
        runner.equal("accepted remote pause keeps paused transport", pauseOkStore.state.transport, .paused)
        runner.equal("accepted remote pause keeps frozen timing", pauseOkStore.state.timing, frozenPauseTiming)
        runner.nil_("accepted remote pause has no command notice", pauseOkStore.transientCommandError)
        await pauseOkStore.shutdownForTermination()

        let seekFailStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.fail))
        )
        seedRemotePlayback(seekFailStore, transport: .playing, timing: priorPlayingTiming)
        seekFailStore.seek(to: 0.4)
        runner.equal("seek applies optimistic timing before completion", seekFailStore.state.timing.position, 80)
        runner.equal("seek leaves transport playing", seekFailStore.state.transport, .playing)
        _ = await waitUntil { seekFailStore.state.pendingCommands[.seek] == nil }
        runner.equal("rejected seek restores exact prior timing", seekFailStore.state.timing, priorPlayingTiming)
        runner.equal("rejected seek uses the action notice", seekFailStore.transientCommandError, "Seek was rejected")
        await seekFailStore.shutdownForTermination()

        let seekOkStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
        )
        seedRemotePlayback(seekOkStore, transport: .paused, timing: pausedTiming)
        seekOkStore.seek(to: 0.4)
        _ = await waitUntil { seekOkStore.state.pendingCommands[.seek] == nil }
        runner.equal("accepted seek keeps optimistic timing", seekOkStore.state.timing.position, 80)
        runner.equal("accepted seek does not change transport", seekOkStore.state.transport, .paused)
        await seekOkStore.shutdownForTermination()

        let localSeekFail = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .error), remote: ScriptedRemoteClient(.succeed))
        )
        _ = localSeekFail.send(.session(.ready), source: .account)
        _ = localSeekFail.send(
            .devices(PlaybackDeviceSnapshot(
                devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                localDeviceID: "mac",
                revision: 1
            )),
            source: .engineDevices,
            revision: 1
        )
        _ = localSeekFail.send(
            .presentation(PlaybackPresentationSnapshot(
                currentTrack: CurrentTrack(
                    uri: "spotify:track:fixture",
                    title: "Now",
                    artist: "Artist",
                    duration: 200,
                    metadataSource: .catalog
                ),
                transport: .playing,
                timing: priorPlayingTiming
            )),
            source: .user
        )
        localSeekFail.seek(to: 0.4)
        runner.equal("local seek applies optimistic timing", localSeekFail.state.timing.position, 80)
        _ = await waitUntil { localSeekFail.state.pendingCommands[.seek] == nil }
        runner.equal("local seek rejection restores exact prior timing", localSeekFail.state.timing, priorPlayingTiming)
        await localSeekFail.shutdownForTermination()

        let joining = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
        )
        _ = joining.send(.session(.ready), source: .account)
        _ = joining.send(.owner(.uncertain(nil)), source: .command)
        _ = joining.send(
            .presentation(PlaybackPresentationSnapshot(
                currentTrack: CurrentTrack(
                    uri: "spotify:track:fixture",
                    title: "Now",
                    artist: "Artist",
                    duration: 200,
                    metadataSource: .catalog
                ),
                transport: .playing,
                timing: priorPlayingTiming
            )),
            source: .user
        )
        let joiningBefore = joining.state
        joining.togglePlayback()
        joining.seek(to: 0.5)
        runner.equal("route refusal leaves presentation unchanged", joining.state.transport, joiningBefore.transport)
        runner.equal("route refusal leaves timing unchanged", joining.state.timing, joiningBefore.timing)
        runner.check("route refusal does not start a pending command", joining.state.pendingCommands.isEmpty)
        runner.equal(
            "route refusal still surfaces the joining notice",
            joining.transientCommandError,
            "Aural is still joining Spotify Connect."
        )
        await joining.shutdownForTermination()

        let duplicateRemote = ScriptedRemoteClient(.sleepUntilCancelled)
        let duplicateStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: duplicateRemote)
        )
        seedRemotePlayback(duplicateStore, transport: .playing, timing: priorPlayingTiming)
        duplicateStore.seek(to: 0.4)
        let seekPending = await waitUntil { duplicateStore.state.pendingCommands[.seek] != nil }
        runner.check("the first seek is pending before a duplicate toggle", seekPending)
        let afterSeek = duplicateStore.state
        duplicateStore.togglePlayback()
        runner.equal("a duplicate toggle does not change transport", duplicateStore.state.transport, afterSeek.transport)
        runner.equal("a duplicate toggle does not change timing", duplicateStore.state.timing, afterSeek.timing)
        runner.nil_("a duplicate toggle does not start a transport command", duplicateStore.state.pendingCommands[.transport])
        if let commandID = duplicateStore.state.pendingCommands[.seek]?.id {
            duplicateStore.effects.cancel(.command(commandID))
        }
        await duplicateStore.shutdownForTermination()

        let cancelRemote = ScriptedRemoteClient(.sleepUntilCancelled)
        let cancelStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: cancelRemote)
        )
        seedRemotePlayback(cancelStore, transport: .playing, timing: priorPlayingTiming)
        cancelStore.togglePlayback()
        let pausePending = await waitUntil { cancelStore.state.pendingCommands[.transport] != nil }
        runner.check("remote pause is pending before cancellation", pausePending)
        let optimisticCancel = cancelStore.state
        if let commandID = cancelStore.state.pendingCommands[.transport]?.id {
            cancelStore.effects.cancel(.command(commandID))
        }
        _ = await waitUntil { await cancelRemote.sendCount == 1 }
        runner.equal("cancellation does not roll back optimistic pause", cancelStore.state.transport, optimisticCancel.transport)
        runner.equal("cancellation does not roll back frozen timing", cancelStore.state.timing, optimisticCancel.timing)
        runner.equal(
            "cancellation leaves the pending command until teardown",
            cancelStore.state.pendingCommands[.transport]?.id,
            optimisticCancel.pendingCommands[.transport]?.id
        )
        runner.nil_("cancellation does not surface a command notice", cancelStore.transientCommandError)
        await cancelStore.shutdownForTermination()

        let staleStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.sleepUntilCancelled))
        )
        seedRemotePlayback(staleStore, transport: .playing, timing: priorPlayingTiming)
        staleStore.seek(to: 0.4)
        let stalePending = await waitUntil { staleStore.state.pendingCommands[.seek] != nil }
        runner.check("seek is pending before an engine-epoch bump", stalePending)
        let optimisticSeekTiming = staleStore.state.timing
        _ = staleStore.send(
            .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
            source: .engineConnection,
            revision: 1,
            engineEpoch: staleStore.engineGeneration + 1
        )
        runner.nil_("an engine-epoch bump drops the pending seek", staleStore.state.pendingCommands[.seek])
        runner.equal("an engine-epoch bump does not roll back seek timing", staleStore.state.timing, optimisticSeekTiming)
        await staleStore.shutdownForTermination()

        let trackSwitchRemote = GatedFailingRemoteClient()
        let trackSwitchStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: trackSwitchRemote)
        )
        seedRemotePlayback(trackSwitchStore, transport: .playing, timing: priorPlayingTiming)
        trackSwitchStore.seek(to: 0.4)
        let trackSwitchPending = await waitUntil { trackSwitchStore.state.pendingCommands[.seek] != nil }
        runner.check("seek is pending before a same-engine track switch", trackSwitchPending)
        let sendStarted = await waitUntil { await trackSwitchRemote.sendCount == 1 }
        runner.check("the seek has reached the remote client before the track switch", sendStarted)
        let trackBTiming = PlaybackTiming(position: 0, duration: 180, anchoredAt: clockNow)
        _ = trackSwitchStore.send(
            .enginePlayback(EnginePlaybackSnapshot(
                transport: .playing,
                trackURI: "spotify:track:other",
                timing: trackBTiming
            )),
            source: .enginePlayback,
            revision: 1
        )
        runner.equal("a track switch adopts the new track URI", trackSwitchStore.state.currentTrack?.uri, "spotify:track:other")
        runner.equal("a track switch adopts the incoming timing", trackSwitchStore.state.timing, trackBTiming)
        runner.nil_("a track switch clears the old pending seek", trackSwitchStore.state.pendingCommands[.seek])
        let afterTrackSwitch = trackSwitchStore.state
        await trackSwitchRemote.fail()
        for _ in 0..<50 { await Task.yield() }
        runner.equal("a rejected finish after a track switch leaves timing unchanged", trackSwitchStore.state.timing, afterTrackSwitch.timing)
        runner.equal(
            "a rejected finish after a track switch leaves the new track",
            trackSwitchStore.state.currentTrack?.uri,
            "spotify:track:other"
        )
        runner.nil_("a rejected finish after a track switch does not surface a seek notice", trackSwitchStore.transientCommandError)
        await trackSwitchStore.shutdownForTermination()
    }

    await runner.suite("Store play target presentation ownership") {
        let clockNow = Date(timeIntervalSince1970: 1_800_000_000)
        let playingAnchor = clockNow.addingTimeInterval(-10)
        let priorPlayingTiming = PlaybackTiming(position: 40, duration: 200, anchoredAt: playingAnchor)
        let trackA = CatalogTrack(
            id: "a",
            uri: "spotify:track:a",
            title: "A",
            artist: "Artist",
            album: "Album",
            duration: 200,
            artworkURL: nil,
            addedAt: nil
        )
        let trackB = CatalogTrack(
            id: "b",
            uri: "spotify:track:b",
            title: "B",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil,
            addedAt: nil
        )
        let optimisticTiming = PlaybackTiming(position: 0, duration: 180, anchoredAt: clockNow)

        @MainActor
        func seedPlayingA(_ player: PlaybackStore, local: Bool) {
            _ = player.send(.session(.ready), source: .account)
            if local {
                _ = player.send(
                    .devices(PlaybackDeviceSnapshot(
                        devices: [PlaybackDevice(id: "mac", name: "Mac", type: "computer", isActive: true)],
                        localDeviceID: "mac",
                        revision: 1
                    )),
                    source: .engineDevices,
                    revision: 1
                )
            } else {
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
            _ = player.send(
                .presentation(PlaybackPresentationSnapshot(
                    currentTrack: CurrentTrack(
                        uri: trackA.uri,
                        title: trackA.title,
                        artist: trackA.artist,
                        duration: trackA.duration,
                        metadataSource: .catalog
                    ),
                    transport: .playing,
                    timing: priorPlayingTiming
                )),
                source: .user
            )
        }

        @MainActor
        func sendEnginePlayback(
            _ player: PlaybackStore,
            uri: String?,
            transport: PlaybackTransportState,
            timing: PlaybackTiming,
            revision: UInt64
        ) {
            _ = player.send(
                .enginePlayback(EnginePlaybackSnapshot(
                    transport: transport,
                    trackURI: uri,
                    timing: timing
                )),
                source: .enginePlayback,
                revision: revision
            )
        }

        let localRejected = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .error), remote: ScriptedRemoteClient(.succeed))
        )
        seedPlayingA(localRejected, local: true)
        localRejected.play(track: trackB)
        runner.equal("local play presents B before completion", localRejected.state.currentTrack?.uri, trackB.uri)
        runner.equal("local play applies playing before completion", localRejected.state.transport, .playing)
        runner.equal("local play applies target timing before completion", localRejected.state.timing, optimisticTiming)
        _ = await waitUntil { localRejected.state.pendingCommands[.transport] == nil }
        runner.equal("local play rejection restores A", localRejected.state.currentTrack?.uri, trackA.uri)
        runner.equal("local play rejection restores exact prior timing", localRejected.state.timing, priorPlayingTiming)
        runner.check("local play rejection does not record B", !localRejected.history.entries.contains { $0.uri == trackB.uri })
        runner.equal("local play rejection uses the action notice", localRejected.transientCommandError, "Could not play that Spotify URI")
        await localRejected.shutdownForTermination()

        let localAccepted = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
        )
        seedPlayingA(localAccepted, local: true)
        localAccepted.play(track: trackB)
        _ = await waitUntil { localAccepted.state.pendingCommands[.transport] == nil }
        runner.equal("accepted local play keeps B", localAccepted.state.currentTrack?.uri, trackB.uri)
        runner.equal("accepted local play keeps playing", localAccepted.state.transport, .playing)
        runner.check("accepted local play records B", localAccepted.history.entries.contains { $0.uri == trackB.uri })
        await localAccepted.shutdownForTermination()

        let remoteRejected = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.fail))
        )
        seedPlayingA(remoteRejected, local: false)
        remoteRejected.play(track: trackB)
        runner.equal("remote play presents B before completion", remoteRejected.state.currentTrack?.uri, trackB.uri)
        _ = await waitUntil { remoteRejected.state.pendingCommands[.transport] == nil }
        runner.equal("remote play rejection restores A", remoteRejected.state.currentTrack?.uri, trackA.uri)
        runner.equal("remote play rejection restores exact prior timing", remoteRejected.state.timing, priorPlayingTiming)
        runner.check("remote play rejection does not record B", !remoteRejected.history.entries.contains { $0.uri == trackB.uri })
        await remoteRejected.shutdownForTermination()

        let remoteAccepted = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
        )
        seedPlayingA(remoteAccepted, local: false)
        remoteAccepted.play(track: trackB)
        _ = await waitUntil { remoteAccepted.state.pendingCommands[.transport] == nil }
        runner.equal("accepted remote play keeps B", remoteAccepted.state.currentTrack?.uri, trackB.uri)
        runner.check("accepted remote play records B", remoteAccepted.history.entries.contains { $0.uri == trackB.uri })
        await remoteAccepted.shutdownForTermination()

        let laggingRemote = GatedFailingRemoteClient()
        let laggingStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: laggingRemote)
        )
        seedPlayingA(laggingStore, local: false)
        laggingStore.play(track: trackB)
        let laggingPending = await waitUntil { laggingStore.state.pendingCommands[.transport] != nil }
        runner.check("remote play is pending before a lagging A snapshot", laggingPending)
        _ = await waitUntil { await laggingRemote.sendCount == 1 }
        sendEnginePlayback(
            laggingStore,
            uri: trackA.uri,
            transport: .playing,
            timing: PlaybackTiming(position: 44, duration: 200, anchoredAt: clockNow),
            revision: 1
        )
        runner.equal("a lagging A snapshot keeps optimistic B", laggingStore.state.currentTrack?.uri, trackB.uri)
        runner.equal("a lagging A snapshot keeps B timing", laggingStore.state.timing, optimisticTiming)
        runner.notNil("a lagging A snapshot keeps rollback ownership", laggingStore.state.pendingCommands[.transport])
        await laggingRemote.fail()
        _ = await waitUntil { laggingStore.state.pendingCommands[.transport] == nil }
        runner.equal("lagging A then rejection restores A", laggingStore.state.currentTrack?.uri, trackA.uri)
        runner.equal("lagging A then rejection restores exact timing", laggingStore.state.timing, priorPlayingTiming)
        runner.check("lagging A then rejection does not record B", !laggingStore.history.entries.contains { $0.uri == trackB.uri })
        await laggingStore.shutdownForTermination()

        let confirmRemote = GatedFailingRemoteClient()
        let confirmStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: confirmRemote)
        )
        seedPlayingA(confirmStore, local: false)
        confirmStore.play(track: trackB)
        _ = await waitUntil { confirmStore.state.pendingCommands[.transport] != nil }
        _ = await waitUntil { await confirmRemote.sendCount == 1 }
        let confirmedCommandID = confirmStore.state.pendingCommands[.transport]?.id
        sendEnginePlayback(
            confirmStore,
            uri: trackB.uri,
            transport: .playing,
            timing: PlaybackTiming(position: 1, duration: 180, anchoredAt: clockNow),
            revision: 1
        )
        runner.nil_("an authoritative B snapshot confirms the play", confirmStore.state.pendingCommands[.transport])
        runner.equal(
            "an authoritative B snapshot records confirmation",
            confirmedCommandID.flatMap { confirmStore.state.transportCommandResolutions[$0] },
            Optional(PlaybackTransportCommandResolution.confirmed)
        )
        await confirmRemote.fail()
        _ = await waitUntil { confirmStore.history.entries.contains { $0.uri == trackB.uri } }
        runner.equal("confirmed B then failure keeps B", confirmStore.state.currentTrack?.uri, trackB.uri)
        runner.nil_("confirmed B then failure has no command notice", confirmStore.transientCommandError)
        runner.check("confirmed B then failure still records B", confirmStore.history.entries.contains { $0.uri == trackB.uri })
        await confirmStore.shutdownForTermination()

        let supersedeRemote = GatedFailingRemoteClient()
        let supersedeStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: supersedeRemote)
        )
        seedPlayingA(supersedeStore, local: false)
        supersedeStore.play(track: trackB)
        _ = await waitUntil { supersedeStore.state.pendingCommands[.transport] != nil }
        _ = await waitUntil { await supersedeRemote.sendCount == 1 }
        let trackCTiming = PlaybackTiming(position: 8, duration: 240, anchoredAt: clockNow)
        sendEnginePlayback(
            supersedeStore,
            uri: "spotify:track:c",
            transport: .playing,
            timing: trackCTiming,
            revision: 1
        )
        runner.equal("an unrelated C snapshot adopts C", supersedeStore.state.currentTrack?.uri, "spotify:track:c")
        runner.nil_("an unrelated C snapshot clears B rollback", supersedeStore.state.pendingCommands[.transport])
        await supersedeRemote.fail()
        for _ in 0..<50 { await Task.yield() }
        runner.equal("C supersession then failure leaves C", supersedeStore.state.currentTrack?.uri, "spotify:track:c")
        runner.equal("C supersession then failure keeps C timing", supersedeStore.state.timing, trackCTiming)
        runner.check("C supersession then failure does not record B", !supersedeStore.history.entries.contains { $0.uri == trackB.uri })
        runner.nil_("C supersession then failure has no play notice", supersedeStore.transientCommandError)
        await supersedeStore.shutdownForTermination()

        let nilRemote = GatedFailingRemoteClient()
        let nilStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: nilRemote)
        )
        seedPlayingA(nilStore, local: false)
        nilStore.play(track: trackB)
        _ = await waitUntil { nilStore.state.pendingCommands[.transport] != nil }
        _ = await waitUntil { await nilRemote.sendCount == 1 }
        sendEnginePlayback(
            nilStore,
            uri: nil,
            transport: .stopped,
            timing: PlaybackTiming(anchoredAt: clockNow),
            revision: 1
        )
        runner.nil_("a nil snapshot clears the optimistic track", nilStore.state.currentTrack)
        await nilRemote.fail()
        for _ in 0..<50 { await Task.yield() }
        runner.nil_("nil supersession then failure stays cleared", nilStore.state.currentTrack)
        runner.check("nil supersession then failure does not record B", !nilStore.history.entries.contains { $0.uri == trackB.uri })
        await nilStore.shutdownForTermination()

        let joining = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
        )
        _ = joining.send(.session(.ready), source: .account)
        _ = joining.send(.owner(.uncertain(nil)), source: .command)
        _ = joining.send(
            .presentation(PlaybackPresentationSnapshot(
                currentTrack: CurrentTrack(
                    uri: trackA.uri,
                    title: trackA.title,
                    artist: trackA.artist,
                    duration: trackA.duration,
                    metadataSource: .catalog
                ),
                transport: .playing,
                timing: priorPlayingTiming
            )),
            source: .user
        )
        let joiningBefore = joining.state
        joining.play(track: trackB)
        runner.equal("route refusal leaves the current track unchanged", joining.state.currentTrack, joiningBefore.currentTrack)
        runner.equal("route refusal leaves timing unchanged", joining.state.timing, joiningBefore.timing)
        runner.check("route refusal does not start a pending play", joining.state.pendingCommands.isEmpty)
        runner.check("route refusal does not record B", joining.history.entries.isEmpty)
        await joining.shutdownForTermination()

        let duplicateRemote = ScriptedRemoteClient(.sleepUntilCancelled)
        let duplicateStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: duplicateRemote)
        )
        seedPlayingA(duplicateStore, local: false)
        duplicateStore.play(track: trackB)
        let playPending = await waitUntil { duplicateStore.state.pendingCommands[.transport] != nil }
        runner.check("the first play is pending before a duplicate", playPending)
        let afterFirstPlay = duplicateStore.state
        duplicateStore.play(track: trackB)
        runner.equal("a duplicate play does not change presentation", duplicateStore.state.currentTrack, afterFirstPlay.currentTrack)
        runner.equal("a duplicate play keeps the original command", duplicateStore.state.pendingCommands[.transport]?.id, afterFirstPlay.pendingCommands[.transport]?.id)
        if let commandID = duplicateStore.state.pendingCommands[.transport]?.id {
            duplicateStore.effects.cancel(.command(commandID))
        }
        await duplicateStore.shutdownForTermination()

        let cancelRemote = ScriptedRemoteClient(.sleepUntilCancelled)
        let cancelStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: cancelRemote)
        )
        seedPlayingA(cancelStore, local: false)
        cancelStore.play(track: trackB)
        let cancelPending = await waitUntil { cancelStore.state.pendingCommands[.transport] != nil }
        runner.check("remote play is pending before cancellation", cancelPending)
        let optimisticCancel = cancelStore.state
        if let commandID = cancelStore.state.pendingCommands[.transport]?.id {
            cancelStore.effects.cancel(.command(commandID))
        }
        _ = await waitUntil { await cancelRemote.sendCount == 1 }
        runner.equal("cancellation keeps optimistic B", cancelStore.state.currentTrack, optimisticCancel.currentTrack)
        runner.equal("cancellation leaves the pending play until teardown", cancelStore.state.pendingCommands[.transport]?.id, optimisticCancel.pendingCommands[.transport]?.id)
        runner.check("cancellation does not record B", cancelStore.history.entries.isEmpty)
        await cancelStore.shutdownForTermination()

        let staleStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.sleepUntilCancelled))
        )
        seedPlayingA(staleStore, local: false)
        staleStore.play(track: trackB)
        let stalePending = await waitUntil { staleStore.state.pendingCommands[.transport] != nil }
        runner.check("play is pending before an engine-epoch bump", stalePending)
        let optimisticPlay = staleStore.state
        _ = staleStore.send(
            .engineConnection(EngineConnectionSnapshot(session: .recovering, owner: .none, localDeviceID: nil)),
            source: .engineConnection,
            revision: 1,
            engineEpoch: staleStore.engineGeneration + 1
        )
        runner.nil_("an engine-epoch bump drops the pending play", staleStore.state.pendingCommands[.transport])
        runner.equal("an engine-epoch bump does not roll back B", staleStore.state.currentTrack?.uri, optimisticPlay.currentTrack?.uri)
        runner.check("an engine-epoch bump clears play confirmation state", staleStore.state.transportCommandResolutions.isEmpty)
        await staleStore.shutdownForTermination()

        let playlistStore = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .error), remote: ScriptedRemoteClient(.succeed))
        )
        seedPlayingA(playlistStore, local: true)
        let playlist = CatalogItem(
            id: "pl",
            uri: "spotify:playlist:loaded",
            title: "Mix",
            subtitle: "Me",
            artworkURL: nil,
            kind: .playlist
        )
        playlistStore.catalog.playlistStore.replaceLoadedPlaylist(uri: playlist.uri, tracks: [trackB])
        playlistStore.playPlaylist(playlist)
        runner.equal("a loaded playlist presents the known first track", playlistStore.state.currentTrack?.uri, trackB.uri)
        _ = await waitUntil { playlistStore.state.pendingCommands[.transport] == nil }
        runner.equal("a rejected loaded playlist restores A", playlistStore.state.currentTrack?.uri, trackA.uri)
        runner.check("a rejected loaded playlist does not record B", !playlistStore.history.entries.contains { $0.uri == trackB.uri })
        await playlistStore.shutdownForTermination()

        let unknownPlaylist = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
        )
        seedPlayingA(unknownPlaylist, local: true)
        let unknown = CatalogItem(
            id: "other",
            uri: "spotify:playlist:unknown",
            title: "Other",
            subtitle: "Me",
            artworkURL: nil,
            kind: .playlist
        )
        unknownPlaylist.playPlaylist(unknown)
        runner.equal("an unknown playlist does not invent a first track", unknownPlaylist.state.currentTrack?.uri, trackA.uri)
        _ = await waitUntil { unknownPlaylist.state.pendingCommands[.transport] == nil }
        runner.equal("an accepted unknown playlist keeps A until the engine speaks", unknownPlaylist.state.currentTrack?.uri, trackA.uri)
        runner.check("an unknown playlist does not record a first track", unknownPlaylist.history.entries.isEmpty)
        await unknownPlaylist.shutdownForTermination()

        let rawURI = playbackStore(
            commandEnvironment(local: ScriptedLocalEngine(result: .ok), remote: ScriptedRemoteClient(.succeed))
        )
        seedPlayingA(rawURI, local: true)
        rawURI.play(uri: trackB.uri)
        runner.equal("raw play(uri:) does not invent track metadata", rawURI.state.currentTrack?.uri, trackA.uri)
        _ = await waitUntil { rawURI.state.pendingCommands[.transport] == nil }
        runner.equal("accepted raw play(uri:) still keeps A until the engine speaks", rawURI.state.currentTrack?.uri, trackA.uri)
        runner.check("accepted raw play(uri:) records the URI", rawURI.history.entries.contains { $0.uri == trackB.uri })
        await rawURI.shutdownForTermination()

        let localGate = GatedLocalEngine()
        let localRace = playbackStore(
            commandEnvironment(local: localGate, remote: ScriptedRemoteClient(.succeed))
        )
        seedPlayingA(localRace, local: true)
        localRace.play(track: trackB)
        let localRacePending = await waitUntil { localRace.state.pendingCommands[.transport] != nil }
        runner.check("local play is pending before a lagging A snapshot", localRacePending)
        sendEnginePlayback(
            localRace,
            uri: trackA.uri,
            transport: .playing,
            timing: PlaybackTiming(position: 44, duration: 200, anchoredAt: clockNow),
            revision: 1
        )
        runner.equal("local lagging A keeps optimistic B", localRace.state.currentTrack?.uri, trackB.uri)
        localGate.finish(with: .error)
        _ = await waitUntil { localRace.state.pendingCommands[.transport] == nil }
        runner.equal("local lagging A then rejection restores A", localRace.state.currentTrack?.uri, trackA.uri)
        runner.check("local lagging A then rejection does not record B", !localRace.history.entries.contains { $0.uri == trackB.uri })
        await localRace.shutdownForTermination()
    }
}
