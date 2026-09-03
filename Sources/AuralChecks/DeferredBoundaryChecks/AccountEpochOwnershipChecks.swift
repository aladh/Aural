import AuralDomain
import Foundation
@testable import AuralCore

private enum EpochOwnershipFailure: Error { case unavailable }

private final class EpochEngine: LocalPlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    func events() -> AsyncStream<RustPlaybackEventEnvelope> {
        AsyncStream { $0.finish() }
    }

    func count(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storage[name, default: 0]
    }

    private func record(_ name: String) {
        lock.lock(); storage[name, default: 0] += 1; lock.unlock()
    }

    func authorizeStreaming(with _: String) -> Int32 { record("authorize"); return 0 }
    func initialize() -> PlaybackEngineResult { record("initialize"); return .ok }
    func execute(_: LocalPlaybackOperation) -> PlaybackEngineResult { record("execute"); return .ok }
    func positionMilliseconds() -> UInt32 { 0 }
    func queueSnapshot() -> RustQueueState? { nil }
    func configureHighQualityPlayback() { record("configure") }
    func shutdown() -> PlaybackEngineResult { record("shutdown"); return .ok }
    func cleanup() { record("cleanup") }
    func clearStreamingCredentials() { record("clearCredentials") }
    func disconnect() -> PlaybackEngineResult { record("disconnect"); return .ok }
    func forceReconnect() -> Int32 { record("reconnect"); return 0 }
}

private final class EpochAccount: AccountSession, @unchecked Sendable {
    private let lock = NSLock()
    private var clearStorage = 0
    private var clearPark: CheckedContinuation<Void, Never>?
    var hasStoredGrant = true
    var parkClear = false

    var clearCount: Int {
        lock.lock(); defer { lock.unlock() }
        return clearStorage
    }

    var isClearParked: Bool {
        lock.lock(); defer { lock.unlock() }
        return clearPark != nil
    }

    func authorizeInteractively() async throws -> KeymasterTokens {
        KeymasterTokens(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            expiresAt: .distantFuture,
            username: "fixture-user"
        )
    }
    func hasGrant() async -> Bool { hasStoredGrant }
    func accessToken() async throws -> String { "fixture-access" }
    func adopt(_: KeymasterTokens) async throws {}
    func clear() async {
        if parkClear {
            await withCheckedContinuation { continuation in
                lock.withLock { clearPark = continuation }
            }
        }
        lock.withLock { clearStorage += 1 }
    }
    func completeClear() {
        lock.lock(); let continuation = clearPark; clearPark = nil; lock.unlock()
        continuation?.resume()
    }
    func revocations() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }
}

private final class EpochLifecycle: SystemLifecycleEvents, @unchecked Sendable {
    func events() -> AsyncStream<SystemLifecycleEvent> {
        AsyncStream { $0.finish() }
    }
}

private actor EpochPreferences: PlaybackPreferences {
    func shuffleEnabled() -> Bool { false }
    func setShuffleEnabled(_: Bool) {}
    func lastRemoteDeviceID() -> String? { nil }
    func setLastRemoteDeviceID(_: String?) {}
    func shuffleHistory() -> [String: TimeInterval] { [:] }
    func setShuffleHistory(_: [String: TimeInterval]) {}
}

private actor EpochRemote: RemotePlaybackClient {
    func send(_: SpotifyConnectCommand, from _: String, to _: String) async throws {}

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

private struct EpochAudio: AudioOutputPreparing { func prepareForPlayback() throws {} }
private struct EpochClock: PlaybackClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds _: TimeInterval) async throws {}
}
private struct EpochAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}
private struct EpochCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] {
        throw EpochOwnershipFailure.unavailable
    }
    func home() async throws -> PathfinderHome { throw EpochOwnershipFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw EpochOwnershipFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw EpochOwnershipFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw EpochOwnershipFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw EpochOwnershipFailure.unavailable }
    func profile() async throws -> PathfinderProfile { throw EpochOwnershipFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion { throw EpochOwnershipFailure.unavailable }
}

private actor EpochWebQueue: WebQueueClient {
    func queue() async throws -> [CatalogTrack] {
        throw URLError(.badServerResponse)
    }
}

private func epochEnvironment(
    engine: EpochEngine,
    account: EpochAccount
) -> PlaybackEnvironment {
    PlaybackEnvironment(
        remote: EpochRemote(),
        local: engine,
        webQueue: EpochWebQueue(),
        account: account,
        audioOutput: EpochAudio(),
        preferences: EpochPreferences(),
        lifecycle: EpochLifecycle(),
        clock: EpochClock(),
        catalog: EpochCatalog(),
        playlistMutations: UnavailablePlaylistMutations(),
        trackAttributes: EpochAttributes()
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

private func functionBody(_ source: String, named name: String) -> String? {
    guard let header = source.range(of: "func \(name)") else { return nil }
    guard let open = source[header.lowerBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = open
    while index < source.endIndex {
        switch source[index] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[open...index])
            }
        default: break
        }
        index = source.index(after: index)
    }
    return nil
}

private func epochAdvancesBeforeConnectionCancel(in accountSource: String) -> Bool {
    guard let body = functionBody(accountSource, named: "invalidateAccountIdentity") else { return false }
    guard let advance = body.range(of: "advanceEpoch()") else { return false }
    guard let cancel = body.range(of: "staleTask?.cancel()") else { return false }
    return advance.lowerBound < cancel.lowerBound
}

private func playbackStoreWritableAccountEpochMutations(_ source: String) -> [String] {
    let assignment = try! NSRegularExpression(
        pattern: #"(?:self\.)?accountEpoch\s*(?:\+|&\+)?=(?!=)"#
    )
    return source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return nil }
        if trimmed.contains("@ObservationIgnored var accountEpoch") { return String(line) }
        let nsLine = trimmed as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard assignment.firstMatch(in: trimmed, range: range) != nil else { return nil }
        return String(line)
    }
}

@MainActor
func runAccountEpochOwnershipChecks(_ runner: CheckRunner) async {
    await runner.suite("AccountStore is the single writable account-epoch owner") {
        let engine = EpochEngine()
        let account = EpochAccount()
        let player = PlaybackStore(
            environment: epochEnvironment(engine: engine, account: account),
            feedback: TransientFeedbackPresenter(clock: EpochClock())
        )
        await player.restore()
        let start = player.accountStore.epoch
        runner.equal("restore keeps the initial account identity", start, 1)
        runner.equal("the store projection matches AccountStore", player.accountEpoch, start)
        runner.equal("reducer state starts on the same epoch", player.state.accountEpoch, start)

        await player.logout()
        let afterLogout = player.accountStore.epoch
        runner.equal("ordinary teardown advances AccountStore once", afterLogout, start + 1)
        runner.equal("PlaybackStore projects that exact epoch", player.accountEpoch, afterLogout)
        runner.equal("reducer state adopts that exact epoch", player.state.accountEpoch, afterLogout)
        runner.equal("catalog session observes that exact epoch", player.catalogSession.accountEpoch, afterLogout)
        runner.equal("QueueService reset uses that exact epoch", await player.queueService.accountEpoch, afterLogout)
        runner.equal("logout still shuts the engine down once", engine.count("shutdown"), 1)
        runner.equal("logout still clears the grant once", account.clearCount, 1)
    }

    await runner.suite("Coalesced teardown upgrades without a second epoch bump") {
        let engine = EpochEngine()
        let account = EpochAccount()
        account.parkClear = true
        let player = PlaybackStore(
            environment: epochEnvironment(engine: engine, account: account),
            feedback: TransientFeedbackPresenter(clock: EpochClock())
        )
        await player.restore()
        let start = player.accountStore.epoch

        let logout = Task { await player.logout() }
        runner.check("logout reaches grant clear", await waitUntil { account.isClearParked })
        let duringTeardown = player.accountStore.epoch
        runner.equal("the in-flight teardown already advanced AccountStore once", duringTeardown, start + 1)
        runner.equal("projection matches during the parked teardown", player.accountEpoch, duringTeardown)
        runner.equal("reducer already adopted the teardown epoch", player.state.accountEpoch, duringTeardown)
        runner.equal("catalog already observes the teardown epoch", player.catalogSession.accountEpoch, duringTeardown)
        runner.check(
            "QueueService already reset to the teardown epoch",
            await waitUntil { await player.queueService.accountEpoch == duringTeardown }
        )

        let upgrade = Task { await player.handleGrantRevocation() }
        for _ in 0..<20 { await Task.yield() }
        runner.equal(
            "an overlapping revocation does not advance the epoch again", player.accountStore.epoch, duringTeardown)
        runner.equal("projection is unchanged after the upgrade", player.accountEpoch, duringTeardown)
        runner.equal("reducer epoch is unchanged after the upgrade", player.state.accountEpoch, duringTeardown)

        account.completeClear()
        await logout.value
        await upgrade.value
        runner.equal("the completed coalesced teardown still advanced once", player.accountStore.epoch, start + 1)
        runner.equal("grant clear still happens once", account.clearCount, 1)
        runner.equal("engine shutdown still happens once", engine.count("shutdown"), 1)
    }

    await runner.suite("Process termination advances the epoch once through AccountStore") {
        let engine = EpochEngine()
        let account = EpochAccount()
        let player = PlaybackStore(
            environment: epochEnvironment(engine: engine, account: account),
            feedback: TransientFeedbackPresenter(clock: EpochClock())
        )
        await player.restore()
        let start = player.accountStore.epoch

        await player.shutdownForTermination()
        let afterStop = player.accountStore.epoch
        runner.equal("termination advances AccountStore once", afterStop, start + 1)
        runner.equal("PlaybackStore projects the termination epoch", player.accountEpoch, afterStop)
        runner.equal("reducer adopts the termination epoch", player.state.accountEpoch, afterStop)
        runner.equal("catalog observes the termination epoch", player.catalogSession.accountEpoch, afterStop)
        runner.equal("termination shuts the engine down once", engine.count("shutdown"), 1)
        runner.equal("termination does not clear the reusable grant", account.clearCount, 0)

        await player.shutdownForTermination()
        runner.equal("a second termination is idempotent and does not bump again", player.accountStore.epoch, afterStop)
        runner.equal("a second termination does not shut down again", engine.count("shutdown"), 1)
    }

    await runner.suite("Work stamped with the prior epoch stays inert") {
        let engine = EpochEngine()
        let account = EpochAccount()
        let player = PlaybackStore(
            environment: epochEnvironment(engine: engine, account: account),
            feedback: TransientFeedbackPresenter(clock: EpochClock())
        )
        await player.restore()
        _ = player.send(
            .presentation(
                PlaybackPresentationSnapshot(
                    currentTrack: CurrentTrack(uri: "spotify:track:prior", title: "Prior"),
                    transport: .paused,
                    timing: PlaybackTiming(anchoredAt: Date(timeIntervalSince1970: 1_800_000_000))
                )),
            source: .user
        )
        let prior = player.accountEpoch

        await player.logout()
        let current = player.accountStore.epoch
        runner.notEqual("logout replaced the prior identity", current, prior)

        let staleSession = player.send(.session(.ready), source: .account, accountEpoch: prior)
        let staleQueue = await player.queueService.acceptConnect(
            [QueueEntry(uri: "spotify:track:stale", provider: "connect", occurrence: 0)],
            accountEpoch: prior,
            sourceRevision: 1,
            contextURI: "spotify:track:stale"
        )
        runner.check("a reducer send stamped with the prior epoch is rejected", !staleSession)
        runner.nil_("QueueService rejects the prior epoch after reset", staleQueue)
        runner.nil_("prior-epoch work cannot revive signed-out presentation", player.state.currentTrack)
        runner.equal("signed-out session is unchanged", player.state.session, PlaybackSessionPhase.signedOut)
        runner.equal("inert work did not roll the epoch back", player.accountEpoch, current)
        runner.equal(
            "inert work did not drift the projection from AccountStore", player.accountEpoch, player.accountStore.epoch)
        runner.equal("inert work did not drift reducer state from AccountStore", player.state.accountEpoch, current)
    }

    runner.suite("PlaybackStore has no writable account-epoch increment or assignment") {
        runner.noThrow("PlaybackStore sources are readable") {
            let session = try auralSourceFile("Aural/Spotify/PlaybackStore+Session.swift")
            let store = try auralSourceFile("Aural/Spotify/PlaybackStore.swift")
            let commands = try auralSourceFile("Aural/Spotify/PlaybackStore+Commands.swift")
            let engineEvents = try auralSourceFile("Aural/Spotify/PlaybackStore+EngineEvents.swift")
            let history = try auralSourceFile("Aural/Spotify/PlaybackStore+History.swift")
            let queue = try auralSourceFile("Aural/Spotify/PlaybackStore+Queue.swift")
            let transport = try auralSourceFile("Aural/Spotify/PlaybackStore+Transport.swift")
            let projections = try auralSourceFile("Aural/Spotify/PlaybackStore+Projections.swift")
            let account = try auralSourceFile("Aural/Spotify/AccountStore.swift")
            let sources = [session, store, commands, engineEvents, history, queue, transport, projections]
            let mutations = sources.flatMap(playbackStoreWritableAccountEpochMutations)
            runner.equal("PlaybackStore files have no accountEpoch increment or assignment", mutations, [String]())
            runner.check(
                "PlaybackStore.accountEpoch is a read-only AccountStore projection",
                containsToken(store, "var accountEpoch: UInt64 { accountStore.epoch }")
                    && !containsToken(store, "@ObservationIgnored var accountEpoch")
            )
            runner.check(
                "teardown no longer resyncs a PlaybackStore mirror after AccountStore completes",
                !containsToken(session, "accountEpoch = accountStore.epoch")
            )
            runner.check(
                "AccountStore.advanceEpoch is the only epoch increment",
                account.components(separatedBy: "epoch &+= 1").count == 2
            )
            runner.check(
                "invalidateAccountIdentity advances the epoch before cancelling connection work",
                epochAdvancesBeforeConnectionCancel(in: account)
            )
        }
    }
}
