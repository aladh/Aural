import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

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

private func spottySourceFile(_ relativePath: String) throws -> String {
    let checksDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repositoryRoot = checksDirectory.deletingLastPathComponent().deletingLastPathComponent()
    let url = repositoryRoot.appending(path: "Sources").appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func containsToken(_ source: String, _ token: String) -> Bool {
    source.contains(token)
}

@Suite("Transient Feedback")
struct TransientFeedbackTests {
    @Test
    @MainActor
    func testTransientFeedback() async {
        do {
            #expect(
                (AppDisplayName.resolve(info: ["CFBundleDisplayName": "Configured Name"])) == ("Configured Name"),
                "configured bundle display name drives the window title")
            #expect(
                (AppDisplayName.resolve(info: [:])) == ("Spotty"), "missing bundle display name falls back to Spotty")
            #expect(
                (AppDisplayName.resolve(info: ["CFBundleDisplayName": "  \n"])) == ("Spotty"),
                "blank bundle display name falls back to Spotty")
            #expect(
                (AppDisplayName.resolve(info: ["CFBundleDisplayName": 42])) == ("Spotty"),
                "non-string bundle display name falls back to Spotty")
        }

        do {
            let clock = UncooperativeParkedClock()
            let feedback = TransientFeedbackPresenter(clock: clock, duration: 4)

            feedback.success("Added to Queue")
            #expect((feedback.message?.kind) == (.success), "success kind")
            #expect((feedback.message?.text) == ("Added to Queue"), "success text")
            #expect((feedback.message == nil ? 0 : 1) == (1), "one message after success")

            feedback.informational("Queue is at the limit")
            #expect((feedback.message?.kind) == (.informational), "informational replaces success")
            #expect((feedback.message?.text) == ("Queue is at the limit"), "informational text")
            #expect((feedback.message == nil ? 0 : 1) == (1), "still one message after informational")

            feedback.failure("Could not add that track to the queue.")
            #expect((feedback.message?.kind) == (.failure), "failure replaces informational")
            #expect((feedback.message?.text) == ("Could not add that track to the queue."), "failure text")
            let visibleID = feedback.message?.id
            #expect((visibleID) != nil, "replacement has an identity")

            feedback.success("   ")
            #expect((feedback.message?.id) == (visibleID), "blank text does not replace")

            feedback.dismiss()
            #expect((feedback.message) == nil, "explicit dismiss clears the current message")
            clock.releaseAll()
            await yieldPasses()
            #expect((feedback.message) == nil, "released sleeps after dismiss stay empty")
        }

        do {
            let cooperative = CooperativeParkedClock()
            let cancelling = TransientFeedbackPresenter(clock: cooperative, duration: 4)
            cancelling.success("First")
            _ = await waitUntil { cooperative.waiterCount == 1 }
            let firstID = cancelling.message?.id
            cancelling.failure("Second")
            _ = await waitUntil { cooperative.waiterCount == 1 && cancelling.message?.text == "Second" }
            #expect((cancelling.message?.text) == ("Second"), "replacement is the only visible message")
            #expect((cancelling.message?.id != firstID) == true, "replacement is a new identity")
            #expect(
                (cancelling.message?.text) == ("Second"),
                "cancelling the previous dismissal leaves the replacement visible"
            )
            cancelling.dismiss()
            cooperative.releaseAll()

            let uncooperative = UncooperativeParkedClock()
            let stale = TransientFeedbackPresenter(clock: uncooperative, duration: 4)
            stale.success("Keep me")
            _ = await waitUntil { uncooperative.waiterCount == 1 }
            stale.failure("Replacement")
            _ = await waitUntil { uncooperative.waiterCount == 2 }
            #expect((stale.message?.text) == ("Replacement"), "replacement is showing before stale wake")
            let replacementID = stale.message?.id

            uncooperative.releaseNext()
            _ = await waitUntil { uncooperative.waiterCount == 1 }
            #expect((stale.message?.text) == ("Replacement"), "a stale dismissal cannot remove the replacement")
            #expect((stale.message?.id) == (replacementID), "replacement identity is unchanged")

            uncooperative.releaseNext()
            _ = await waitUntil { stale.message == nil }
            #expect((stale.message) == nil, "the current dismissal still expires the replacement")
        }

        do {
            let clock = UncooperativeParkedClock()
            let feedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let player = PlaybackStore(
                environment: feedbackEnvironment(clock: clock),
                feedback: feedback
            )
            #expect((player.feedback === feedback) == true, "the store keeps the composed presenter")

            player.addToQueue(uris: ["spotify:track:fixture"])
            #expect(
                (feedback.message?.text) == ("Connect Spotify before adding to the queue."),
                "disconnected add reports through the injected presenter")
            #expect((feedback.message?.kind) == (.failure), "disconnected add is a failure")
            #expect((player.transientCommandError) == nil, "disconnected add does not use playback notice")
            await player.endSession(clearGrant: false, finalPhase: .signedOut)
            #expect((feedback.message) == nil, "account teardown clears leftover mutation feedback")
            clock.releaseAll()
            await player.shutdownForTermination()
        }

        do {
            let clock = UncooperativeParkedClock()

            let localSuccessFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let localSuccess = PlaybackStore(
                environment: feedbackEnvironment(local: FeedbackLocalEngine(result: .ok), clock: clock),
                feedback: localSuccessFeedback
            )
            seedReady(localSuccess)
            localSuccess.addToQueue(uris: ["spotify:track:local-ok"])
            _ = await waitUntil { localSuccessFeedback.message?.kind == .success }
            #expect((localSuccessFeedback.message?.text) == ("Added to Queue"), "local add success")
            #expect((localSuccess.transientCommandError) == nil, "local add success is not a playback notice")
            await localSuccess.shutdownForTermination()

            let localFailureFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let localFailure = PlaybackStore(
                environment: feedbackEnvironment(local: FeedbackLocalEngine(result: .error), clock: clock),
                feedback: localFailureFeedback
            )
            seedReady(localFailure)
            localFailure.addToQueue(uris: ["spotify:track:local-fail"])
            _ = await waitUntil { localFailureFeedback.message?.kind == .failure }
            #expect(
                (localFailureFeedback.message?.text) == ("Could not add that track to the queue."), "local add failure")
            #expect((localFailure.transientCommandError) == nil, "local add failure is not a playback notice")
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
            joining.addToQueue(uris: ["spotify:track:joining"])
            #expect(
                (joiningFeedback.message?.text) == ("Spotty is still joining Spotify Connect."),
                "waiting for Connect identity is a mutation failure")
            #expect((joining.transientCommandError) == nil, "joining add is not a playback notice")
            await joining.shutdownForTermination()

            let remote = FeedbackRemoteClient(.succeed)
            let remoteSuccessFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let remoteSuccess = PlaybackStore(
                environment: feedbackEnvironment(remote: remote, clock: clock),
                feedback: remoteSuccessFeedback
            )
            seedRemoteOwner(remoteSuccess)
            remoteSuccess.addToQueue(uris: ["spotify:track:remote-ok"])
            _ = await waitUntil { remoteSuccessFeedback.message?.kind == .success }
            #expect((remoteSuccessFeedback.message?.text) == ("Added to Queue"), "remote add success")
            #expect((await remote.sendCount) == (1), "remote add still sends add_to_queue")
            #expect((remoteSuccess.transientCommandError) == nil, "remote add success is not a playback notice")
            await remoteSuccess.shutdownForTermination()

            let remoteFail = FeedbackRemoteClient(.fail)
            let remoteFailureFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let remoteFailure = PlaybackStore(
                environment: feedbackEnvironment(remote: remoteFail, clock: clock),
                feedback: remoteFailureFeedback
            )
            seedRemoteOwner(remoteFailure)
            remoteFailure.addToQueue(uris: ["spotify:track:remote-fail"])
            _ = await waitUntil { remoteFailureFeedback.message?.kind == .failure }
            #expect(
                (remoteFailureFeedback.message?.text) == ("Could not add that track to the queue."),
                "remote add failure")
            await remoteFailure.shutdownForTermination()

            let parkedRemote = FeedbackRemoteClient(.park)
            let cancelledFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let cancelled = PlaybackStore(
                environment: feedbackEnvironment(remote: parkedRemote, clock: clock),
                feedback: cancelledFeedback
            )
            seedRemoteOwner(cancelled)
            cancelled.addToQueue(uris: ["spotify:track:cancel"])
            #expect(
                (await waitUntil { await parkedRemote.sendCount == 1 }) == true,
                "cancelled add started the remote command")
            cancelled.effects.cancelAccountScoped()
            await parkedRemote.completePark(success: false)
            await yieldPasses()
            #expect((cancelledFeedback.message) == nil, "cancelled add reports no mutation feedback")
            await cancelled.shutdownForTermination()

            let staleRemote = FeedbackRemoteClient(.park)
            let staleFeedback = TransientFeedbackPresenter(clock: clock, duration: 4)
            let staleAccount = PlaybackStore(
                environment: feedbackEnvironment(remote: staleRemote, clock: clock),
                feedback: staleFeedback
            )
            seedRemoteOwner(staleAccount)
            staleAccount.addToQueue(uris: ["spotify:track:stale"])
            #expect(
                (await waitUntil { await staleRemote.sendCount == 1 }) == true,
                "stale-account add started the remote command")
            staleAccount.accountStore.advanceEpoch()
            await staleRemote.completePark(success: true)
            await yieldPasses()
            #expect((staleFeedback.message) == nil, "stale-account add reports no mutation feedback")
            await staleAccount.shutdownForTermination()

            clock.releaseAll()
        }

        do {
            do {
                do {
                    let banner = try spottySourceFile("Spotty/Views/TransientFeedbackBanner.swift")
                    let root = try spottySourceFile("Spotty/RootView.swift")
                    let app = try spottySourceFile("Spotty/SpottyApp.swift")
                    let queue = try spottySourceFile("Spotty/Spotify/PlaybackStore+Queue.swift")
                    let commands = try spottySourceFile("Spotty/Spotify/PlaybackStore+Commands.swift")
                    let presenter = try spottySourceFile("Spotty/TransientFeedback.swift")
                    let store = try spottySourceFile("Spotty/Spotify/PlaybackStore.swift")
                    let domain = try spottySourceFile("SpottyDomain/PlaybackState.swift")

                    #expect(
                        (containsToken(root, ".overlay(alignment: .bottom)")
                            && containsToken(root, "TransientFeedbackBanner(feedback: feedback)")
                            && containsToken(root, "NowPlayingBar(player: player, showsSidePanel: $showsSidePanel)"))
                            == true, "the banner is overlay-based at the root above the player")
                    #expect(
                        (containsToken(banner, ".allowsHitTesting(false)")
                            && !containsToken(root, ".allowsHitTesting(false)")) == true,
                        "the banner disables hit testing")
                    #expect(
                        (containsToken(banner, ".focusable(false)")
                            && containsToken(banner, ".accessibilityRespondsToUserInteraction(false)")) == true,
                        "the banner does not steal focus or user interaction")
                    #expect(
                        (containsToken(banner, "accessibilityReduceMotion")
                            && containsToken(banner, "reduceMotion ? nil")
                            && containsToken(banner, "reduceMotion ? .opacity")) == true,
                        "Reduce Motion controls presentation animation")
                    #expect(
                        (containsToken(banner, ".accessibilityLabel(spokenText(for: message))")
                            && containsToken(banner, "AccessibilityNotification.Announcement")) == true,
                        "VoiceOver uses a label and a native announcement")
                    #expect(
                        (!containsToken(banner, ".alert(")
                            && !containsToken(banner, ".sheet(")
                            && !containsToken(banner, ".popover(")
                            && !containsToken(banner, "Button(")
                            && !containsToken(presenter, "NotificationCenter")
                            && !containsToken(presenter, "[TransientFeedbackMessage]")) == true,
                        "the banner is not a modal, stack, or action control")
                    #expect(
                        (containsToken(app, "TransientFeedbackPresenter(clock: environment.clock)")
                            && containsToken(app, "PlaybackStore(environment: environment, feedback: feedback)")
                            && containsToken(
                                app, "RootView(player: player, catalog: player.catalog, feedback: feedback)"))
                            == true, "app composition injects one presenter into the store and root")
                    #expect(
                        (containsToken(store, "feedback: TransientFeedbackPresenter")
                            && !containsToken(store, "TransientFeedbackPresenter?")
                            && !containsToken(store, "?? TransientFeedbackPresenter")) == true,
                        "PlaybackStore requires the composed feedback owner")
                    #expect(
                        (containsToken(queue, "presentAddToQueueFeedback")
                            && containsToken(queue, "feedback.success")
                            && containsToken(queue, "feedback.informational")
                            && containsToken(queue, "feedback.failure(")
                            && !containsToken(queue, "showTransientCommandError")) == true,
                        "Add to Queue reports through the presenter, not playback notice")
                    #expect(
                        (containsToken(commands, "func showTransientCommandError")
                            && containsToken(commands, "setNotice(message)")) == true,
                        "transport command notices stay on the playback owner")
                    #expect(
                        (!containsToken(domain, "TransientFeedback")) == true,
                        "transient mutation feedback is not reducer-owned domain state")

                } catch {
                    Issue.record("\("banner, root, app, and queue sources are readable"): unexpected error \(error)")
                }
            }
        }
    }
}
