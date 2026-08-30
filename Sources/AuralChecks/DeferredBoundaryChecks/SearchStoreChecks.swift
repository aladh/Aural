import AuralDomain
import Foundation
@testable import AuralCore

private enum SearchStoreCheckFailure: Error, Sendable {
    case unavailable
}

private struct SearchCheckAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

private actor GatedSearchCatalog: CatalogProviding {
    enum Outcome: Sendable {
        case tracks([PathfinderTrack])
        case failure
        case cancelled
    }

    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private(set) var trackQueries: [String] = []

    var requestCount: Int { trackQueries.count }

    func searchTracks(_ term: String, limit _: Int) async throws -> [PathfinderTrack] {
        trackQueries.append(term)
        let outcome = await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        switch outcome {
        case let .tracks(items):
            return items
        case .failure:
            throw SearchStoreCheckFailure.unavailable
        case .cancelled:
            throw CancellationError()
        }
    }

    func completeNext(_ outcome: Outcome) {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: outcome)
    }

    func home() async throws -> PathfinderHome { throw SearchStoreCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw SearchStoreCheckFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw SearchStoreCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw SearchStoreCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] {
        throw SearchStoreCheckFailure.unavailable
    }
    func profile() async throws -> PathfinderProfile { throw SearchStoreCheckFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion {
        throw SearchStoreCheckFailure.unavailable
    }
}

/// Sleeps until `releaseAll()`, and throws `CancellationError` if the waiting task is cancelled.
private final class CooperativeParkedClock: PlaybackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSleeps: [TimeInterval] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }

    var requestedSleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSleeps
    }

    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        lock.lock()
        recordedSleeps.append(seconds)
        lock.unlock()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    func releaseAll() {
        lock.lock()
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }
}

private func decodeTrack(_ json: String) throws -> PathfinderTrack {
    try JSONDecoder().decode(PathfinderTrack.self, from: Data(json.utf8))
}

private let firstTrackJSON = """
{"uri":"spotify:track:first","name":"First Track","albumOfTrack":{"name":"First Album"},"artists":{"items":[{"profile":{"name":"First Artist"}}]},"duration":{"totalMilliseconds":1000}}
"""
private let secondTrackJSON = """
{"uri":"spotify:track:second","name":"Second Track","albumOfTrack":{"name":"Second Album"},"artists":{"items":[{"profile":{"name":"Second Artist"}}]},"duration":{"totalMilliseconds":2000}}
"""

@MainActor
private func makeStore(
    provider: GatedSearchCatalog,
    session: CatalogSessionAvailability,
    clock: any PlaybackClock
) -> SearchStore {
    let metadata = CatalogMetadataRepository(
        attributesProvider: SearchCheckAttributes(),
        session: session
    )
    return SearchStore(provider: provider, metadata: metadata, session: session, clock: clock)
}

@MainActor
private func commitImmediateSearch(
    _ store: SearchStore,
    provider: GatedSearchCatalog,
    query: String,
    tracks: [PathfinderTrack]
) async -> Bool {
    let task = Task { await store.search(query) }
    guard await waitUntil({ await provider.requestCount == 1 }) else { return false }
    await provider.completeNext(.tracks(tracks))
    await task.value
    return true
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
func runSearchStoreChecks(_ runner: CheckRunner) async {
    let first: PathfinderTrack
    let second: PathfinderTrack
    do {
        first = try decodeTrack(firstTrackJSON)
        second = try decodeTrack(secondTrackJSON)
    } catch {
        runner.check("synthetic search fixtures decode", false)
        return
    }

    await runner.suite("Search debounce pre-deadline cancellation") {
        let provider = GatedSearchCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let clock = CooperativeParkedClock()
        let store = makeStore(provider: provider, session: session, clock: clock)

        runner.check(
            "seeded results commit immediately",
            await commitImmediateSearch(store, provider: provider, query: "alpha", tracks: [first])
        )
        runner.equal("committed tracks stay visible before a later query is admitted", store.tracks.map(\.uri), [
            "spotify:track:first",
        ])
        runner.check("seeded search is not left searching", !store.isSearching)

        let pending = Task { await store.scheduleSearch("beta") }
        runner.check(
            "the debounce clock parks before admission",
            await waitUntil { clock.waiterCount == 1 }
        )
        runner.equal(
            "debounce asks for the catalog admission delay",
            clock.requestedSleeps,
            [SearchStore.queryAdmissionDelay]
        )
        runner.check("debounce does not publish isSearching before admission", !store.isSearching)
        runner.equal("debounce does not start a catalog fetch before admission", await provider.requestCount, 1)
        runner.equal(
            "committed results survive a query that has not been admitted",
            store.tracks.map(\.uri),
            ["spotify:track:first"]
        )

        pending.cancel()
        await pending.value
        runner.equal("cancelled debounce never starts a fetch", await provider.requestCount, 1)
        runner.equal(
            "cancelled debounce leaves committed results",
            store.tracks.map(\.uri),
            ["spotify:track:first"]
        )
        runner.check("cancelled debounce does not publish isSearching", !store.isSearching)
        runner.equal("cancelled debounce leaves no clock waiter", clock.waiterCount, 0)
    }

    await runner.suite("Search debounce exact admission") {
        let provider = GatedSearchCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let clock = CooperativeParkedClock()
        let store = makeStore(provider: provider, session: session, clock: clock)

        let pending = Task { await store.scheduleSearch("  beta  ") }
        runner.check(
            "admission waits on the injected clock",
            await waitUntil { clock.waiterCount == 1 }
        )
        runner.check("exact admission has not fetched yet", await provider.requestCount == 0)
        runner.check("exact admission has not published isSearching yet", !store.isSearching)

        clock.releaseAll()
        runner.check(
            "exact admission starts the trimmed query",
            await waitUntil { await provider.trackQueries == ["beta"] }
        )
        runner.check("admitted search publishes isSearching", store.isSearching)
        await provider.completeNext(.tracks([second]))
        await pending.value
        runner.equal("admitted search publishes the current query", store.tracks.map(\.uri), [
            "spotify:track:second",
        ])
        runner.check("admitted search clears isSearching", !store.isSearching)
        runner.equal("admitted search leaves no clock waiter", clock.waiterCount, 0)
    }

    await runner.suite("Search debounce rapid query supersession") {
        let provider = GatedSearchCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let clock = CooperativeParkedClock()
        let store = makeStore(provider: provider, session: session, clock: clock)

        let firstQuery = Task { await store.scheduleSearch("alpha") }
        runner.check(
            "the first query parks on the clock",
            await waitUntil { clock.waiterCount == 1 }
        )
        let secondQuery = Task { await store.scheduleSearch("beta") }
        runner.check(
            "the newer query replaces the parked timer",
            await waitUntil { clock.waiterCount == 1 && clock.requestedSleeps.count == 2 }
        )
        await firstQuery.value
        runner.equal("the superseded timer never fetched", await provider.requestCount, 0)

        clock.releaseAll()
        runner.check(
            "only the latest query is admitted",
            await waitUntil { await provider.trackQueries == ["beta"] }
        )
        await provider.completeNext(.tracks([second]))
        await secondQuery.value
        runner.equal("supersession publishes the latest query", store.tracks.map(\.uri), [
            "spotify:track:second",
        ])
        runner.equal("supersession fetches once", await provider.requestCount, 1)
    }

    await runner.suite("Search debounce reset disconnect and stale identity") {
        let provider = GatedSearchCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let clock = CooperativeParkedClock()
        let store = makeStore(provider: provider, session: session, clock: clock)

        runner.check(
            "reset fixture commits",
            await commitImmediateSearch(store, provider: provider, query: "alpha", tracks: [first])
        )

        let resetPending = Task { await store.scheduleSearch("beta") }
        runner.check(
            "reset parks the later query",
            await waitUntil { clock.waiterCount == 1 }
        )
        store.reset()
        runner.check("reset clears committed results immediately", store.isEmpty)
        clock.releaseAll()
        await resetPending.value
        runner.equal("reset prevents the parked timer from fetching", await provider.requestCount, 1)
        runner.check("reset leaves the store empty", store.isEmpty)

        let disconnectPending = Task { await store.scheduleSearch("gamma") }
        runner.check(
            "disconnect parks before session change",
            await waitUntil { clock.waiterCount == 1 }
        )
        session.update(accountEpoch: 1, isAvailable: false)
        clock.releaseAll()
        await disconnectPending.value
        runner.equal("a session change refuses the parked timer", await provider.requestCount, 1)
        runner.check("a refused timer does not publish isSearching", !store.isSearching)

        session.update(accountEpoch: 2, isAvailable: true)
        let stale = Task { await store.search("delta") }
        runner.check(
            "stale identity parks the fetch",
            await waitUntil { await provider.requestCount == 2 }
        )
        session.update(accountEpoch: 3, isAvailable: true)
        await provider.completeNext(.tracks([second]))
        await stale.value
        runner.check("a stale success does not publish", store.isEmpty)
        runner.check("a stale success is not left searching", !store.isSearching)
    }

    await runner.suite("Search immediate retry skips debounce") {
        let provider = GatedSearchCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let clock = CooperativeParkedClock()
        let store = makeStore(provider: provider, session: session, clock: clock)

        let scheduled = Task { await store.scheduleSearch("retry") }
        runner.check(
            "retry parks the view-driven timer",
            await waitUntil { clock.waiterCount == 1 }
        )

        let retry = Task { await store.search("retry") }
        runner.check(
            "Try Again fetches without waiting for the clock",
            await waitUntil { await provider.trackQueries == ["retry"] }
        )
        runner.equal("immediate retry uses one sleep from the cancelled timer", clock.requestedSleeps, [
            SearchStore.queryAdmissionDelay,
        ])
        await provider.completeNext(.tracks([first]))
        await retry.value
        runner.equal("immediate retry publishes", store.tracks.map(\.uri), ["spotify:track:first"])

        clock.releaseAll()
        await scheduled.value
        runner.equal("a later timer does not fetch after Try Again", await provider.requestCount, 1)
        runner.equal("a later timer does not replace retry results", store.tracks.map(\.uri), [
            "spotify:track:first",
        ])
    }

    await runner.suite("Search debounce empty query") {
        let provider = GatedSearchCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let clock = CooperativeParkedClock()
        let store = makeStore(provider: provider, session: session, clock: clock)

        runner.check(
            "empty-query fixture commits",
            await commitImmediateSearch(store, provider: provider, query: "alpha", tracks: [first])
        )

        let cancelledEmpty = Task { await store.scheduleSearch("   ") }
        runner.check(
            "empty query parks before admission",
            await waitUntil { clock.waiterCount == 1 }
        )
        cancelledEmpty.cancel()
        await cancelledEmpty.value
        runner.equal(
            "cancelled empty query leaves committed results",
            store.tracks.map(\.uri),
            ["spotify:track:first"]
        )
        runner.equal("cancelled empty query does not fetch", await provider.requestCount, 1)

        let admittedEmpty = Task { await store.scheduleSearch("\n\t") }
        runner.check(
            "admitted empty query parks",
            await waitUntil { clock.waiterCount == 1 }
        )
        clock.releaseAll()
        await admittedEmpty.value
        runner.check("admitted empty query clears committed results", store.isEmpty)
        runner.equal("admitted empty query does not fetch", await provider.requestCount, 1)
        runner.check("admitted empty query is not left searching", !store.isSearching)
    }

    runner.suite("Search debounce ownership contract") {
        runner.noThrow("search debounce sources are readable") {
            let store = try auralSourceFile("Aural/Spotify/SearchStore.swift")
            let catalog = try auralSourceFile("Aural/Spotify/CatalogStore.swift")
            let playback = try auralSourceFile("Aural/Spotify/PlaybackStore.swift")
            let views = try auralSourceFile("Aural/Views/LibraryViews.swift")

            runner.check(
                "SearchStore owns delayed admission on the injected clock",
                containsToken(store, "clock.sleep(seconds: Self.queryAdmissionDelay)")
                    && containsToken(store, "func scheduleSearch")
                    && !containsToken(store, "Task.sleep")
            )
            runner.check(
                "SearchView keeps searchable and task identity without raw sleep",
                containsToken(views, ".searchable(text: $searchText")
                    && containsToken(views, ".task(id: SearchLoadIdentity(")
                    && containsToken(views, "await store.scheduleSearch(searchText)")
                    && !containsToken(views, "Task.sleep")
            )
            runner.check(
                "Try Again still admits immediately",
                containsToken(views, "Task { await store.search(searchText) }")
            )
            runner.check(
                "CatalogStore forwards the environment clock into SearchStore",
                containsToken(catalog, "clock: any PlaybackClock")
                    && containsToken(catalog, "clock: clock")
                    && containsToken(playback, "clock: environment.clock")
            )
        }
    }
}
