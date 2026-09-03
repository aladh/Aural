import AuralDomain
import Foundation
@testable import AuralCore

private final class FeedbackLocalEngine: LocalPlaybackEngine, @unchecked Sendable {
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
    func queueSnapshot() -> RustQueueState? { nil }
    func configureHighQualityPlayback() {}
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() {}
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }
}

private enum FeedbackRemoteFailure: Error { case boom }

private actor FeedbackRemoteClient: RemotePlaybackClient {
    enum Behavior: Sendable {
        case succeed
        case fail
        case park
    }

    private let behavior: Behavior
    private var parked: CheckedContinuation<Void, Error>?
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
            throw FeedbackRemoteFailure.boom
        case .park:
            try await withCheckedThrowingContinuation { parked = $0 }
        }
    }

    func completePark(success: Bool) {
        if success {
            parked?.resume()
        } else {
            parked?.resume(throwing: FeedbackRemoteFailure.boom)
        }
        parked = nil
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

private actor IdleFeedbackWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
    }
}

private final class IdleFeedbackAccount: AccountSession, @unchecked Sendable {
    func authorizeInteractively() async throws -> KeymasterTokens { throw CancellationError() }
    func hasGrant() async -> Bool { false }
    func accessToken() async throws -> String { "fixture-access" }
    func adopt(_: KeymasterTokens) async throws {}
    func clear() async {}
    func revocations() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

private final class IdleFeedbackLifecycle: SystemLifecycleEvents, @unchecked Sendable {
    func events() -> AsyncStream<SystemLifecycleEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor IdleFeedbackPreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private struct IdleFeedbackAudio: AudioOutputPreparing { func prepareForPlayback() throws {} }

private struct IdleFeedbackAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

private enum FeedbackCheckFailure: Error { case unavailable }

private struct IdleFeedbackCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] {
        throw FeedbackCheckFailure.unavailable
    }
    func home() async throws -> PathfinderHome { throw FeedbackCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw FeedbackCheckFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw FeedbackCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw FeedbackCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw FeedbackCheckFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw FeedbackCheckFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw FeedbackCheckFailure.unavailable }
}

/// Sleeps until `releaseNext()` or `releaseAll()`. Does not consult Task cancellation, so a
/// replaced message can still prove token-guarded stale dismissal.
private final class UncooperativeParkedClock: PlaybackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }

    func sleep(seconds _: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters.append(continuation)
            lock.unlock()
        }
    }

    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func releaseNext() {
        lock.lock()
        let next = waiters.isEmpty ? nil : waiters.removeFirst()
        lock.unlock()
        next?.resume()
    }

    func releaseAll() {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private func feedbackEnvironment(
    local: any LocalPlaybackEngine = FeedbackLocalEngine(),
    remote: any RemotePlaybackClient = FeedbackRemoteClient(.succeed),
    clock: any PlaybackClock
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: remote,
        local: local,
        webQueue: IdleFeedbackWebQueue(),
        account: IdleFeedbackAccount(),
        audioOutput: IdleFeedbackAudio(),
        preferences: IdleFeedbackPreferences(),
        lifecycle: IdleFeedbackLifecycle(),
        clock: clock,
        catalog: IdleFeedbackCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: IdleFeedbackAttributes()
    )
}

@MainActor
private func yieldPasses(_ count: Int = 200) async {
    for _ in 0..<count {
        await Task.yield()
    }
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
func runTransientFeedbackChecks(_ runner: CheckRunner) async {
    await runner.suite("Transient feedback kinds, replacement, and dismissal") {
        let clock = UncooperativeParkedClock()
        let feedback = TransientFeedbackPresenter(clock: clock, duration: 4)

        feedback.success("Added to Queue")
        runner.equal("success kind", feedback.message?.kind, .success)
        runner.equal("success text", feedback.message?.text, "Added to Queue")
        runner.equal("one message after success", feedback.message == nil ? 0 : 1, 1)

        feedback.informational("Queue is at the limit")
        runner.equal("informational replaces success", feedback.message?.kind, .informational)
        runner.equal("informational text", feedback.message?.text, "Queue is at the limit")
        runner.equal("still one message after informational", feedback.message == nil ? 0 : 1, 1)

        feedback.failure("Could not add that track to the queue.")
        runner.equal("failure replaces informational", feedback.message?.kind, .failure)
        runner.equal("failure text", feedback.message?.text, "Could not add that track to the queue.")
        let visibleID = feedback.message?.id
        runner.notNil("replacement has an identity", visibleID)

        feedback.success("   ")
        runner.equal("blank text does not replace", feedback.message?.id, visibleID)

        feedback.dismiss()
        runner.nil_("explicit dismiss clears the current message", feedback.message)
        clock.releaseAll()
        await yieldPasses()
        runner.nil_("released sleeps after dismiss stay empty", feedback.message)
    }

    await runner.suite("Transient feedback cancellation and stale dismissal") {
        let cooperative = CooperativeParkedClock()
        let cancelling = TransientFeedbackPresenter(clock: cooperative, duration: 4)
        cancelling.success("First")
        _ = await waitUntil { cooperative.waiterCount == 1 }
        let firstID = cancelling.message?.id
        cancelling.failure("Second")
        _ = await waitUntil { cooperative.waiterCount == 1 && cancelling.message?.text == "Second" }
        runner.equal("replacement is the only visible message", cancelling.message?.text, "Second")
        runner.check("replacement is a new identity", cancelling.message?.id != firstID)
        runner.equal(
            "cancelling the previous dismissal leaves the replacement visible",
            cancelling.message?.text,
            "Second"
        )
        cancelling.dismiss()
        cooperative.releaseAll()

        let uncooperative = UncooperativeParkedClock()
        let stale = TransientFeedbackPresenter(clock: uncooperative, duration: 4)
        stale.success("Keep me")
        _ = await waitUntil { uncooperative.waiterCount == 1 }
        stale.failure("Replacement")
        _ = await waitUntil { uncooperative.waiterCount == 2 }
        runner.equal("replacement is showing before stale wake", stale.message?.text, "Replacement")
        let replacementID = stale.message?.id

        uncooperative.releaseNext()
        _ = await waitUntil { uncooperative.waiterCount == 1 }
        runner.equal(
            "a stale dismissal cannot remove the replacement",
            stale.message?.text,
            "Replacement"
        )
        runner.equal("replacement identity is unchanged", stale.message?.id, replacementID)

        uncooperative.releaseNext()
        _ = await waitUntil { stale.message == nil }
        runner.nil_("the current dismissal still expires the replacement", stale.message)
    }

    await runner.suite("Feature injection of transient feedback") {
        let clock = UncooperativeParkedClock()
        let feedback = TransientFeedbackPresenter(clock: clock, duration: 4)
        let player = PlaybackStore(
            environment: feedbackEnvironment(clock: clock),
            feedback: feedback
        )
        runner.check("the store keeps the composed presenter", player.feedback === feedback)

        player.addToQueue(uri: "spotify:track:fixture")
        runner.equal(
            "disconnected add reports through the injected presenter",
            feedback.message?.text,
            "Connect Spotify before adding to the queue."
        )
        runner.equal("disconnected add is a failure", feedback.message?.kind, .failure)
        runner.nil_("disconnected add does not use playback notice", player.transientCommandError)
        await player.endSession(clearGrant: false, finalPhase: .signedOut)
        runner.nil_("account teardown clears leftover mutation feedback", feedback.message)
        clock.releaseAll()
        await player.shutdownForTermination()
    }

    await runner.suite("Add to Queue mutation feedback") {
        let clock = UncooperativeParkedClock()

        let localSuccessFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
        let localSuccess = PlaybackStore(
            environment: feedbackEnvironment(local: FeedbackLocalEngine(result: .ok), clock: clock),
            feedback: localSuccessFeedback
        )
        seedReady(localSuccess)
        localSuccess.addToQueue(uri: "spotify:track:local-ok")
        _ = await waitUntil { localSuccessFeedback.message?.kind == .success }
        runner.equal("local add success", localSuccessFeedback.message?.text, "Added to Queue")
        runner.nil_("local add success is not a playback notice", localSuccess.transientCommandError)
        await localSuccess.shutdownForTermination()

        let localFailureFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
        let localFailure = PlaybackStore(
            environment: feedbackEnvironment(local: FeedbackLocalEngine(result: .error), clock: clock),
            feedback: localFailureFeedback
        )
        seedReady(localFailure)
        localFailure.addToQueue(uri: "spotify:track:local-fail")
        _ = await waitUntil { localFailureFeedback.message?.kind == .failure }
        runner.equal(
            "local add failure",
            localFailureFeedback.message?.text,
            "Could not add that track to the queue."
        )
        runner.nil_("local add failure is not a playback notice", localFailure.transientCommandError)
        await localFailure.shutdownForTermination()

        let joiningFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
        let joining = PlaybackStore(
            environment: feedbackEnvironment(clock: clock),
            feedback: joiningFeedback
        )
        seedReady(joining)
        _ = joining.send(
            .owner(.remote(PlaybackDevice(id: "speaker", name: "Speaker", type: "speaker", isActive: true))),
            source: .command
        )
        joining.addToQueue(uri: "spotify:track:joining")
        runner.equal(
            "waiting for Connect identity is a mutation failure",
            joiningFeedback.message?.text,
            "Aural is still joining Spotify Connect."
        )
        runner.nil_("joining add is not a playback notice", joining.transientCommandError)
        await joining.shutdownForTermination()

        let remote = FeedbackRemoteClient(.succeed)
        let remoteSuccessFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
        let remoteSuccess = PlaybackStore(
            environment: feedbackEnvironment(remote: remote, clock: clock),
            feedback: remoteSuccessFeedback
        )
        seedRemoteOwner(remoteSuccess)
        remoteSuccess.addToQueue(uri: "spotify:track:remote-ok")
        _ = await waitUntil { remoteSuccessFeedback.message?.kind == .success }
        runner.equal("remote add success", remoteSuccessFeedback.message?.text, "Added to Queue")
        runner.equal("remote add still sends add_to_queue", await remote.sendCount, 1)
        runner.nil_("remote add success is not a playback notice", remoteSuccess.transientCommandError)
        await remoteSuccess.shutdownForTermination()

        let remoteFail = FeedbackRemoteClient(.fail)
        let remoteFailureFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
        let remoteFailure = PlaybackStore(
            environment: feedbackEnvironment(remote: remoteFail, clock: clock),
            feedback: remoteFailureFeedback
        )
        seedRemoteOwner(remoteFailure)
        remoteFailure.addToQueue(uri: "spotify:track:remote-fail")
        _ = await waitUntil { remoteFailureFeedback.message?.kind == .failure }
        runner.equal(
            "remote add failure",
            remoteFailureFeedback.message?.text,
            "Could not add that track to the queue."
        )
        await remoteFailure.shutdownForTermination()

        let parkedRemote = FeedbackRemoteClient(.park)
        let cancelledFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
        let cancelled = PlaybackStore(
            environment: feedbackEnvironment(remote: parkedRemote, clock: clock),
            feedback: cancelledFeedback
        )
        seedRemoteOwner(cancelled)
        cancelled.addToQueue(uri: "spotify:track:cancel")
        runner.check(
            "cancelled add started the remote command",
            await waitUntil { await parkedRemote.sendCount == 1 }
        )
        cancelled.effects.cancelAccountScoped()
        await parkedRemote.completePark(success: false)
        await yieldPasses()
        runner.nil_("cancelled add reports no mutation feedback", cancelledFeedback.message)
        await cancelled.shutdownForTermination()

        let staleRemote = FeedbackRemoteClient(.park)
        let staleFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
        let staleAccount = PlaybackStore(
            environment: feedbackEnvironment(remote: staleRemote, clock: clock),
            feedback: staleFeedback
        )
        seedRemoteOwner(staleAccount)
        staleAccount.addToQueue(uri: "spotify:track:stale")
        runner.check(
            "stale-account add started the remote command",
            await waitUntil { await staleRemote.sendCount == 1 }
        )
        staleAccount.accountStore.advanceEpoch()
        await staleRemote.completePark(success: true)
        await yieldPasses()
        runner.nil_("stale-account add reports no mutation feedback", staleFeedback.message)
        await staleAccount.shutdownForTermination()

        clock.releaseAll()
    }

    runner.suite("Transient feedback banner overlay contract") {
        runner.noThrow("banner, root, app, and queue sources are readable") {
            let banner = try auralSourceFile("Aural/Views/TransientFeedbackBanner.swift")
            let root = try auralSourceFile("Aural/RootView.swift")
            let app = try auralSourceFile("Aural/AuralApp.swift")
            let queue = try auralSourceFile("Aural/Spotify/PlaybackStore+Queue.swift")
            let commands = try auralSourceFile("Aural/Spotify/PlaybackStore+Commands.swift")
            let presenter = try auralSourceFile("Aural/TransientFeedback.swift")
            let store = try auralSourceFile("Aural/Spotify/PlaybackStore.swift")
            let domain = try auralSourceFile("AuralDomain/PlaybackState.swift")

            runner.check(
                "the banner is overlay-based at the root above the player",
                containsToken(root, ".overlay(alignment: .bottom)")
                    && containsToken(root, "TransientFeedbackBanner(feedback: feedback)")
                    && containsToken(root, "NowPlayingBar(player: player, showsSidePanel: $showsSidePanel)")
            )
            runner.check(
                "the banner disables hit testing",
                containsToken(banner, ".allowsHitTesting(false)")
                    && !containsToken(root, ".allowsHitTesting(false)")
            )
            runner.check(
                "the banner does not steal focus or user interaction",
                containsToken(banner, ".focusable(false)")
                    && containsToken(banner, ".accessibilityRespondsToUserInteraction(false)")
            )
            runner.check(
                "Reduce Motion controls presentation animation",
                containsToken(banner, "accessibilityReduceMotion")
                    && containsToken(banner, "reduceMotion ? nil")
                    && containsToken(banner, "reduceMotion ? .opacity")
            )
            runner.check(
                "VoiceOver uses a label and a native announcement",
                containsToken(banner, ".accessibilityLabel(spokenText(for: message))")
                    && containsToken(banner, "AccessibilityNotification.Announcement")
            )
            runner.check(
                "the banner is not a modal, stack, or action control",
                !containsToken(banner, ".alert(")
                    && !containsToken(banner, ".sheet(")
                    && !containsToken(banner, ".popover(")
                    && !containsToken(banner, "Button(")
                    && !containsToken(presenter, "NotificationCenter")
                    && !containsToken(presenter, "[TransientFeedbackMessage]")
            )
            runner.check(
                "app composition injects one presenter into the store and root",
                containsToken(app, "TransientFeedbackPresenter(clock: environment.clock)")
                    && containsToken(app, "PlaybackStore(environment: environment, feedback: feedback)")
                    && containsToken(app, "RootView(player: player, catalog: player.catalog, feedback: feedback)")
            )
            runner.check(
                "PlaybackStore requires the composed feedback owner",
                containsToken(store, "feedback: TransientFeedbackPresenter")
                    && !containsToken(store, "TransientFeedbackPresenter?")
                    && !containsToken(store, "?? TransientFeedbackPresenter")
            )
            runner.check(
                "Add to Queue reports through the presenter, not playback notice",
                containsToken(queue, "presentAddToQueueFeedback")
                    && containsToken(queue, "feedback.success")
                    && containsToken(queue, "feedback.informational")
                    && containsToken(queue, "feedback.failure(")
                    && !containsToken(queue, "showTransientCommandError")
            )
            runner.check(
                "transport command notices stay on the playback owner",
                containsToken(commands, "func showTransientCommandError")
                    && containsToken(commands, "setNotice(message)")
            )
            runner.check(
                "transient mutation feedback is not reducer-owned domain state",
                !containsToken(domain, "TransientFeedback")
            )
        }
    }
}
