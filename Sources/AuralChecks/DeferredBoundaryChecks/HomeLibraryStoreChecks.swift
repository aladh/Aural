import AuralDomain
import Foundation
@testable import AuralCore

private enum HomeLibraryCheckFailure: Error, Sendable {
    case unavailable
}

private struct HomeLibraryCheckAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

private actor GatedPlaylistCatalog: CatalogProviding {
    enum Outcome: Sendable {
        case playlists([PathfinderPlaylist])
        case failure(HomeLibraryCheckFailure)
        case cancelled
        case urlCancelled
    }

    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private(set) var requestCount = 0

    func libraryPlaylists() async throws -> [PathfinderPlaylist] {
        requestCount += 1
        let outcome = await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        switch outcome {
        case let .playlists(items):
            return items
        case .failure:
            throw HomeLibraryCheckFailure.unavailable
        case .cancelled:
            throw CancellationError()
        case .urlCancelled:
            throw URLError(.cancelled)
        }
    }

    func completeNext(_ outcome: Outcome) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: outcome)
    }

    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] {
        throw HomeLibraryCheckFailure.unavailable
    }
    func home() async throws -> PathfinderHome { throw HomeLibraryCheckFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw HomeLibraryCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw HomeLibraryCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] {
        throw HomeLibraryCheckFailure.unavailable
    }
    func profile() async throws -> PathfinderProfile { throw HomeLibraryCheckFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion {
        throw HomeLibraryCheckFailure.unavailable
    }
}

private func decodePlaylist(_ json: String) throws -> PathfinderPlaylist {
    try JSONDecoder().decode(PathfinderPlaylist.self, from: Data(json.utf8))
}

private let firstPlaylistJSON = """
{"uri":"spotify:playlist:first","name":"First Mix","ownerV2":{"data":{"name":"Me","username":"me","uri":"spotify:user:me"}}}
"""
private let secondPlaylistJSON = """
{"uri":"spotify:playlist:second","name":"Second Mix","ownerV2":{"data":{"name":"Me","username":"me","uri":"spotify:user:me"}}}
"""

private func firstPlaylist() throws -> PathfinderPlaylist { try decodePlaylist(firstPlaylistJSON) }
private func secondPlaylist() throws -> PathfinderPlaylist { try decodePlaylist(secondPlaylistJSON) }

@MainActor
private func makeStore(
    provider: GatedPlaylistCatalog,
    session: CatalogSessionAvailability
) -> HomeLibraryStore {
    let metadata = CatalogMetadataRepository(
        attributesProvider: HomeLibraryCheckAttributes(),
        session: session
    )
    return HomeLibraryStore(provider: provider, metadata: metadata, session: session)
}

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
    var spins = 0
    while spins < 10_000 {
        if await condition() { return true }
        spins += 1
        await Task.yield()
    }
    return false
}

@MainActor
func runHomeLibraryStoreChecks(_ runner: CheckRunner) async {
    let first: PathfinderPlaylist
    let second: PathfinderPlaylist
    do {
        first = try firstPlaylist()
        second = try secondPlaylist()
    } catch {
        runner.check("synthetic playlist fixtures decode", false)
        return
    }

    await runner.suite("Home library non-force join") {
        let provider = GatedPlaylistCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makeStore(provider: provider, session: session)

        let firstLoad = Task { await store.loadPlaylists() }
        runner.check(
            "the first playlist request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        let follower = Task { await store.loadPlaylists() }
        await Task.yield()
        runner.equal("a duplicate current-section request joins the in-flight work", await provider.requestCount, 1)
        runner.check("the joined section stays loading", store.isLoading(.playlists))

        await provider.completeNext(.playlists([first]))
        await firstLoad.value
        await follower.value

        runner.equal("joined consumers publish one result", store.playlists.map(\.uri), ["spotify:playlist:first"])
        runner.check("the joined section is loaded once", store.loadedSections.contains(.playlists))
        runner.check("joined loading finishes", !store.isLoading(.playlists))
        runner.nil_("join does not surface an error", store.error(for: .playlists))
    }

    await runner.suite("Home library force supersession") {
        let provider = GatedPlaylistCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makeStore(provider: provider, session: session)

        let stale = Task { await store.loadPlaylists() }
        runner.check(
            "the superseded request parks",
            await waitUntil { await provider.requestCount == 1 }
        )

        let forced = Task { await store.loadPlaylists(force: true) }
        runner.check(
            "force starts a new section request instead of joining",
            await waitUntil { await provider.requestCount == 2 }
        )
        runner.check("the newest flight owns loading", store.isLoading(.playlists))
        runner.nil_("force clears the previous section error slot", store.error(for: .playlists))

        await provider.completeNext(.playlists([first]))
        await stale.value
        runner.check("a stale success leaves the new request loading", store.isLoading(.playlists))
        runner.check("a stale success does not mark the section loaded", !store.loadedSections.contains(.playlists))
        runner.equal("a stale success does not publish", store.playlists.map(\.uri), [])
        runner.nil_("a stale success does not surface an error", store.error(for: .playlists))

        let joiner = Task { await store.loadPlaylists() }
        for _ in 0..<32 { await Task.yield() }
        runner.equal(
            "the old request cannot clear the new request's in-flight task",
            await provider.requestCount,
            2
        )

        await provider.completeNext(.playlists([second]))
        await forced.value
        await joiner.value

        runner.equal(
            "only the current forced request publishes",
            store.playlists.map(\.uri),
            ["spotify:playlist:second"]
        )
        runner.check("the newest flight marks the section loaded", store.loadedSections.contains(.playlists))
        runner.check("the newest flight clears loading", !store.isLoading(.playlists))
    }

    await runner.suite("Home library non-force joins an in-flight forced refresh") {
        let provider = GatedPlaylistCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makeStore(provider: provider, session: session)

        let initial = Task { await store.loadPlaylists() }
        runner.check(
            "the initial playlist request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        await provider.completeNext(.playlists([first]))
        await initial.value
        runner.equal("the section is loaded before the forced refresh", store.playlists.map(\.uri), ["spotify:playlist:first"])

        let forced = Task { await store.loadPlaylists(force: true) }
        runner.check(
            "force refreshes an already-loaded section",
            await waitUntil { await provider.requestCount == 2 }
        )
        let follower = Task { await store.loadPlaylists() }
        for _ in 0..<32 { await Task.yield() }
        runner.equal(
            "a non-forced caller joins the in-flight forced refresh",
            await provider.requestCount,
            2
        )
        runner.check("the forced refresh keeps loading while the follower waits", store.isLoading(.playlists))

        await provider.completeNext(.playlists([second]))
        await forced.value
        await follower.value
        runner.equal(
            "joined callers observe the forced refresh",
            store.playlists.map(\.uri),
            ["spotify:playlist:second"]
        )
        runner.check("the joined forced refresh finishes loading", !store.isLoading(.playlists))
    }

    await runner.suite("Home library stale failure and cancellation stay inert") {
        let provider = GatedPlaylistCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makeStore(provider: provider, session: session)

        let stale = Task { await store.loadPlaylists() }
        runner.check(
            "the failing request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        let forced = Task { await store.loadPlaylists(force: true) }
        runner.check(
            "force supersedes the failing request",
            await waitUntil { await provider.requestCount == 2 }
        )

        await provider.completeNext(.failure(.unavailable))
        await stale.value
        runner.check("a stale failure leaves the new request loading", store.isLoading(.playlists))
        runner.nil_("a stale failure does not surface an error", store.error(for: .playlists))

        await provider.completeNext(.urlCancelled)
        await forced.value
        runner.check("cancellation does not mark the section loaded", !store.loadedSections.contains(.playlists))
        runner.check("cancellation clears only the cancelled flight's loading", !store.isLoading(.playlists))
        runner.nil_("cancellation does not surface a user-facing error", store.error(for: .playlists))
        runner.equal("cancellation does not publish playlists", store.playlists.map(\.uri), [])
    }

    await runner.suite("Home library account and session change") {
        let provider = GatedPlaylistCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makeStore(provider: provider, session: session)

        let staleEpoch = Task { await store.loadPlaylists() }
        runner.check(
            "the pre-epoch request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        session.update(accountEpoch: 2, isAvailable: true)
        await provider.completeNext(.playlists([first]))
        await staleEpoch.value
        runner.equal("an older account epoch cannot publish", store.playlists.map(\.uri), [])
        runner.check("an older account epoch cannot mark the section loaded", !store.loadedSections.contains(.playlists))

        let staleRevision = Task { await store.loadPlaylists() }
        runner.check(
            "the pre-reconnect request parks",
            await waitUntil { await provider.requestCount == 2 }
        )
        session.update(accountEpoch: 2, isAvailable: false)
        session.update(accountEpoch: 2, isAvailable: true)
        await provider.completeNext(.playlists([first]))
        await staleRevision.value
        runner.equal("a pre-reconnect result cannot publish", store.playlists.map(\.uri), [])

        let current = Task { await store.loadPlaylists() }
        runner.check(
            "a new session starts a distinct request",
            await waitUntil { await provider.requestCount == 3 }
        )
        await provider.completeNext(.playlists([second]))
        await current.value
        runner.equal(
            "the current session publishes",
            store.playlists.map(\.uri),
            ["spotify:playlist:second"]
        )
        runner.check("the current session marks the section loaded", store.loadedSections.contains(.playlists))
    }

    await runner.suite("Home library reset and teardown") {
        let provider = GatedPlaylistCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makeStore(provider: provider, session: session)

        let inflight = Task { await store.loadPlaylists() }
        runner.check(
            "the torn-down request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        runner.check("teardown starts from a loading section", store.isLoading(.playlists))

        store.reset()
        runner.check("reset clears loading", !store.isLoading)
        runner.check("reset clears loaded sections", store.loadedSections.isEmpty)
        runner.equal("reset clears playlists", store.playlists.map(\.uri), [])
        runner.nil_("reset clears section errors", store.error(for: .playlists))

        await provider.completeNext(.playlists([first]))
        await inflight.value
        runner.equal("a torn-down success cannot publish", store.playlists.map(\.uri), [])
        runner.check("a torn-down success cannot restore loading", !store.isLoading)
        runner.check("a torn-down success cannot mark the section loaded", store.loadedSections.isEmpty)
        runner.nil_("a torn-down success cannot surface an error", store.error(for: .playlists))
    }
}
