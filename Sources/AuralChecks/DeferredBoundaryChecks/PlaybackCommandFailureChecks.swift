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

private enum FixtureRemoteFailure: Error {
    case boom
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
}
