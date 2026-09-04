import Foundation
import Testing
import SpottyDomain
@testable import SpottyCore

@Suite("Credential Rejection")
struct CredentialRejectionTests {
    @Test @MainActor
    func testAcceptedRejectionPreservesGrantAndOffersExplicitReauthorization() async {
        let engine = CredentialRejectionEngine()
        let account = CredentialRejectionAccount()
        let environment = CredentialRejectionEnvironment.make(account: account, engine: engine)
        let player = PlaybackStore(
            environment: environment,
            feedback: TransientFeedbackPresenter(clock: environment.clock)
        )

        player.receive(
            RustConnectionState(
                revision: 1,
                sessionGeneration: 0,
                sessionConnected: false,
                spircReady: false,
                isActiveDevice: true,
                resumePending: true,
                lastError: "private upstream detail",
                deviceID: "local",
                credentialsRejected: true
            ),
            revision: 1,
            receivedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(
            (player.statusText) == (ConnectionSnapshotProjection.credentialsRejectedMessage),
            "credential rejection projects stable actionable text"
        )
        #expect((player.requiresReauthentication) == true, "accepted rejection enables reauthorization")
        #expect((account.clearCount) == (0), "credential rejection does not clear the Keymaster grant")

        let rejection = player.effects.settlement(of: .credentialRejection)
        #expect((rejection != nil) == true, "accepted rejection owns its teardown effect")
        await rejection?.wait()
        #expect((engine.clearStreamingCredentialsCount) == (1), "only streaming credentials are cleared")
        #expect((account.clearCount) == (0), "teardown preserves the independent account grant")
        #expect(
            (player.phase) == (.failed(ConnectionSnapshotProjection.credentialsRejectedMessage)),
            "teardown keeps the actionable rejection phase"
        )
        #expect((engine.executeCount) == (0), "credential rejection does not issue reconnect rehydration")

        let stale = RustConnectionState(
            revision: 2,
            sessionGeneration: 0,
            sessionConnected: true,
            spircReady: true,
            isActiveDevice: true,
            resumePending: false,
            lastError: nil,
            deviceID: "local",
            credentialsRejected: true
        )
        player.receive(stale, revision: stale.revision, receivedAt: Date(timeIntervalSince1970: 2))
        #expect(
            (engine.clearStreamingCredentialsCount) == (1),
            "an old-generation rejection cannot repeat credential cleanup"
        )

        let initializeBeforeRestore = engine.initializeCount
        await player.restore()
        #expect((account.authorizeCount) == (0), "restore keeps the rejected grant from opening a browser")
        #expect(
            (engine.initializeCount) == (initializeBeforeRestore),
            "restore with a rejection marker does not retry the known-rejected streaming credential"
        )

        let playback = CatalogPlaybackAccess(player: player)
        #expect((playback.connectionActionTitle) == ("Sign In Again"), "the action names reauthorization")
        playback.connect()
        #expect(
            (await waitUntil { player.phase == .ready }) == true,
            "the explicit sign-in action completes a fresh account workflow"
        )
        #expect((account.authorizeCount) == (1), "the reauthorization action opens the interactive flow")
        #expect((player.requiresReauthentication) == false, "a successful fresh grant clears the marker")
    }
}

private enum CredentialRejectionTestFailure: Error {
    case unavailable
}

private final class CredentialRejectionEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var clearStreamingCredentialsStorage = 0
    private var executeStorage = 0
    private var initializeStorage = 0

    var clearStreamingCredentialsCount: Int { lock.withLock { clearStreamingCredentialsStorage } }
    var executeCount: Int { lock.withLock { executeStorage } }
    var initializeCount: Int { lock.withLock { initializeStorage } }

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func authorizeStreaming(with _: String) -> Int32 { 0 }
    func initialize() -> PlaybackEngineResult {
        lock.withLock { initializeStorage += 1 }
        return .ok
    }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult {
        lock.withLock { executeStorage += 1 }
        return .ok
    }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? { nil }
    func configureHighQualityPlayback() {}
    func shutdown() -> PlaybackEngineResult { .ok }
    func cleanup() {}
    func clearStreamingCredentials() { lock.withLock { clearStreamingCredentialsStorage += 1 } }
    func disconnect() -> PlaybackEngineResult { .ok }
    func forceReconnect() -> Int32 { 0 }
}

private final class CredentialRejectionAccount: AccountSession, @unchecked Sendable {
    private let lock = NSLock()
    private var clearStorage = 0
    private var authorizeStorage = 0

    var clearCount: Int { lock.withLock { clearStorage } }
    var authorizeCount: Int { lock.withLock { authorizeStorage } }

    func authorizeInteractively() async throws -> KeymasterTokens {
        lock.withLock { authorizeStorage += 1 }
        return KeymasterTokens(
            accessToken: "reauthorized-access",
            refreshToken: "reauthorized-refresh",
            expiresAt: .distantFuture,
            username: "listener"
        )
    }
    func hasGrant() async -> Bool { true }
    func grantState() async -> KeymasterGrantState { .available }
    func accessToken() async throws -> String { "existing-access" }
    func adopt(_: KeymasterTokens) async throws {}
    func clear() async { lock.withLock { clearStorage += 1 } }
    func revocations() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private struct CredentialRejectionRemote: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}
    func trackMetadata(for uri: String) async throws -> SpotifyConnectTrackMetadata {
        SpotifyConnectTrackMetadata(uri: uri, title: "Track", artist: "Artist", artworkURL: nil, duration: 180)
    }
}

private struct CredentialRejectionWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] { [] }
}

private struct CredentialRejectionAudio: AudioOutputPreparing {
    func prepareForPlayback() throws {}
}

private actor CredentialRejectionPreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private struct CredentialRejectionLifecycle: SystemLifecycleEvents {
    func events() -> AsyncStream<SystemLifecycleEvent> { AsyncStream { $0.finish() } }
}

private struct CredentialRejectionClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {}
}

private struct CredentialRejectionCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] {
        throw CredentialRejectionTestFailure.unavailable
    }
    func home() async throws -> PathfinderHome { throw CredentialRejectionTestFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] {
        throw CredentialRejectionTestFailure.unavailable
    }
    func libraryAlbums() async throws -> [PathfinderAlbum] {
        throw CredentialRejectionTestFailure.unavailable
    }
    func libraryArtists() async throws -> [PathfinderArtist] {
        throw CredentialRejectionTestFailure.unavailable
    }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] {
        throw CredentialRejectionTestFailure.unavailable
    }
    func profile() async throws -> PathfinderProfile { throw CredentialRejectionTestFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion {
        throw CredentialRejectionTestFailure.unavailable
    }
}

private struct CredentialRejectionAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

private enum CredentialRejectionEnvironment {
    static func make(
        account: any AccountSession,
        engine: any LocalPlaybackEngine
    ) -> PlaybackEnvironment {
        PlaybackEnvironment(
            remote: CredentialRejectionRemote(),
            local: engine,
            webQueue: CredentialRejectionWebQueue(),
            account: account,
            audioOutput: CredentialRejectionAudio(),
            preferences: CredentialRejectionPreferences(),
            lifecycle: CredentialRejectionLifecycle(),
            clock: CredentialRejectionClock(),
            catalog: CredentialRejectionCatalog(),
            playlistMutations: UnavailablePlaylistMutations(),
            trackAttributes: CredentialRejectionAttributes()
        )
    }
}
