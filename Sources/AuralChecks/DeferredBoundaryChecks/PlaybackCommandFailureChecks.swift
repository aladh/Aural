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
        lock.lock()
        defer { lock.unlock() }
        return storedAuthorizeCount
    }

    func authorizeInteractively() async throws -> KeymasterTokens {
        lock.lock()
        storedAuthorizeCount += 1
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

private let commandWaitNanoseconds: UInt64 = 2_000_000_000

private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { @MainActor in
            while await !condition() {
                if Task.isCancelled { return false }
                await Task.yield()
            }
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: commandWaitNanoseconds)
            return false
        }
        let finished = await group.next() ?? false
        group.cancelAll()
        return finished
    }
}

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
        trackAttributes: IdleAttributes()
    )
}

@MainActor
func runPlaybackCommandFailureChecks(_ runner: CheckRunner) async {
    runner.suite("Playback command failure mapping") {
        runner.equal(
            "local success is a typed success",
            PlaybackCommandFailure.from(engineResult: .ok),
            .success(())
        )
        runner.equal(
            "engine error -1 is rejected",
            PlaybackCommandFailure.from(engineResult: PlaybackEngineResult(rawValue: -1)),
            .failure(.rejected)
        )
        runner.equal(
            "session disconnected is reconnect-required",
            PlaybackCommandFailure.from(engineResult: PlaybackEngineResult(rawValue: -2)),
            .failure(.reconnectRequired)
        )
        runner.equal(
            "session not connected is reconnect-required",
            PlaybackCommandFailure.from(engineResult: PlaybackEngineResult(rawValue: -3)),
            .failure(.reconnectRequired)
        )
        runner.equal(
            "an unrecognized engine code is unavailable",
            PlaybackCommandFailure.from(engineResult: PlaybackEngineResult(rawValue: -99)),
            .failure(.unavailable)
        )
        runner.equal(
            "rejected notices keep the action string",
            PlaybackCommandPresentation.noticeMessage(for: .rejected, action: "Pause was rejected"),
            "Pause was rejected"
        )
        runner.equal(
            "remote rejection notices keep the action string",
            PlaybackCommandPresentation.noticeMessage(for: .remoteRejected, action: "Pause was rejected"),
            "Pause was rejected"
        )
    }

    await runner.suite("Coordinator local command outcomes") {
        let successCoordinator = PlaybackCoordinator(
            local: ScriptedLocalEngine(result: .ok),
            remote: ScriptedRemoteClient(.succeed)
        )
        if let success = await localCommandOutcome(successCoordinator, runner, label: "local success") {
            runner.equal("local success", success, .success(()))
        }

        let rejectedCoordinator = PlaybackCoordinator(
            local: ScriptedLocalEngine(result: PlaybackEngineResult(rawValue: -1)),
            remote: ScriptedRemoteClient(.succeed)
        )
        if let rejected = await localCommandOutcome(rejectedCoordinator, runner, label: "local rejection") {
            runner.equal("local rejection", rejected, .failure(.rejected))
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
            runner.equal("local reconnect-required", reconnect, .failure(.reconnectRequired))
        }
    }

    await runner.suite("Coordinator remote command outcomes") {
        let success = try? await PlaybackCoordinator(
            local: ScriptedLocalEngine(result: .ok),
            remote: ScriptedRemoteClient(.succeed)
        ).performRemoteCommand { remote in
            try await remote.send(.pause, from: "from", to: "to")
        }
        runner.equal("remote success", success, Optional.some(.success(())))

        let rejected = try? await PlaybackCoordinator(
            local: ScriptedLocalEngine(result: .ok),
            remote: ScriptedRemoteClient(.fail)
        ).performRemoteCommand { remote in
            try await remote.send(.pause, from: "from", to: "to")
        }
        runner.equal("remote rejection", rejected, Optional.some(.failure(.remoteRejected)))

        let coordinator = PlaybackCoordinator(
            local: ScriptedLocalEngine(result: .ok),
            remote: ScriptedRemoteClient(.sleepUntilCancelled)
        )
        let cancelled = Task {
            try await coordinator.performRemoteCommand { remote in
                try await remote.send(.pause, from: "from", to: "to")
            }
        }
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

        func runLocal(_ result: PlaybackEngineResult, account: IdleAccount = IdleAccount()) async -> (
            completions: [Bool],
            notice: String?,
            authorizeCount: Int,
            player: PlaybackStore
        ) {
            let player = PlaybackStore(
                environment: commandEnvironment(
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

        let rejected = await runLocal(PlaybackEngineResult(rawValue: -1))
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

        func prepareRemoteStore(remote: ScriptedRemoteClient) -> PlaybackStore {
            let player = PlaybackStore(
                environment: commandEnvironment(
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
