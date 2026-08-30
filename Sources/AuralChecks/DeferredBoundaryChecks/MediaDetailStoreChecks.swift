import AuralDomain
import Foundation
@testable import AuralCore

private enum MediaDetailCheckFailure: Error, Sendable {
    case unavailable
}

private actor RecordingAttributes: TrackAttributesProviding {
    private(set) var requestCount = 0
    private(set) var requestedURIs: [String] = []

    func attributes(for uris: [String]) async throws -> [String: TrackAttributes] {
        requestCount += 1
        requestedURIs.append(contentsOf: uris)
        return [:]
    }
}

private actor GatedAlbumCatalog: CatalogProviding {
    enum Outcome: Sendable {
        case album(PathfinderAlbumUnion)
        case failure(MediaDetailCheckFailure)
        case cancelled
        case urlCancelled
    }

    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private(set) var requestCount = 0

    func album(id _: String) async throws -> PathfinderAlbumUnion {
        requestCount += 1
        let outcome = await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        switch outcome {
        case let .album(album):
            return album
        case .failure:
            throw MediaDetailCheckFailure.unavailable
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
        throw MediaDetailCheckFailure.unavailable
    }
    func home() async throws -> PathfinderHome { throw MediaDetailCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw MediaDetailCheckFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw MediaDetailCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw MediaDetailCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] {
        throw MediaDetailCheckFailure.unavailable
    }
    func profile() async throws -> PathfinderProfile { throw MediaDetailCheckFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion {
        throw MediaDetailCheckFailure.unavailable
    }
    func artist(id _: String) async throws -> PathfinderArtistUnion {
        throw MediaDetailCheckFailure.unavailable
    }
    func artistDiscography(id _: String) async throws -> PathfinderArtistUnion {
        throw MediaDetailCheckFailure.unavailable
    }
}

private actor GatedArtistCatalog: CatalogProviding {
    enum Outcome: Sendable {
        case artist(PathfinderArtistUnion)
        case failure(MediaDetailCheckFailure)
        case cancelled
        case urlCancelled
    }

    private var overviewWaiters: [CheckedContinuation<Outcome, Never>] = []
    private var discographyWaiters: [CheckedContinuation<Outcome, Never>] = []
    private(set) var overviewRequestCount = 0
    private(set) var discographyRequestCount = 0

    func artist(id _: String) async throws -> PathfinderArtistUnion {
        overviewRequestCount += 1
        let outcome = await withCheckedContinuation { continuation in
            overviewWaiters.append(continuation)
        }
        return try result(from: outcome)
    }

    func artistDiscography(id _: String) async throws -> PathfinderArtistUnion {
        discographyRequestCount += 1
        let outcome = await withCheckedContinuation { continuation in
            discographyWaiters.append(continuation)
        }
        return try result(from: outcome)
    }

    func completeOverview(_ outcome: Outcome) {
        guard !overviewWaiters.isEmpty else { return }
        overviewWaiters.removeFirst().resume(returning: outcome)
    }

    func completeDiscography(_ outcome: Outcome) {
        guard !discographyWaiters.isEmpty else { return }
        discographyWaiters.removeFirst().resume(returning: outcome)
    }

    private func result(from outcome: Outcome) throws -> PathfinderArtistUnion {
        switch outcome {
        case let .artist(artist):
            return artist
        case .failure:
            throw MediaDetailCheckFailure.unavailable
        case .cancelled:
            throw CancellationError()
        case .urlCancelled:
            throw URLError(.cancelled)
        }
    }

    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] {
        throw MediaDetailCheckFailure.unavailable
    }
    func home() async throws -> PathfinderHome { throw MediaDetailCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] { throw MediaDetailCheckFailure.unavailable }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw MediaDetailCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw MediaDetailCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] {
        throw MediaDetailCheckFailure.unavailable
    }
    func profile() async throws -> PathfinderProfile { throw MediaDetailCheckFailure.unavailable }
    func playlist(id _: String) async throws -> PathfinderPlaylistUnion {
        throw MediaDetailCheckFailure.unavailable
    }
    func album(id _: String) async throws -> PathfinderAlbumUnion {
        throw MediaDetailCheckFailure.unavailable
    }
}

private func decodeAlbum(_ json: String) throws -> PathfinderAlbumUnion {
    let response = try JSONDecoder().decode(PathfinderAlbumResponse.self, from: Data(json.utf8))
    guard let album = response.data?.albumUnion else {
        throw MediaDetailCheckFailure.unavailable
    }
    return album
}

private func decodeArtist(_ json: String) throws -> PathfinderArtistUnion {
    let response = try JSONDecoder().decode(PathfinderArtistResponse.self, from: Data(json.utf8))
    guard let artist = response.data?.artistUnion else {
        throw MediaDetailCheckFailure.unavailable
    }
    return artist
}

private let firstAlbumJSON = """
{"data":{"albumUnion":{"uri":"spotify:album:first","name":"First Album","type":"ALBUM","date":{"isoString":"2024-01-02T00:00:00Z"},"coverArt":{"sources":[]},"artists":{"items":[]},"tracksV2":{"items":[{"track":{"uri":"spotify:track:first","name":"First Track","trackNumber":1,"discNumber":1,"duration":{"totalMilliseconds":120000},"artists":{"items":[]}}}],"totalCount":1}}}}
"""
private let secondAlbumJSON = """
{"data":{"albumUnion":{"uri":"spotify:album:second","name":"Second Album","type":"ALBUM","date":{"isoString":"2025-03-04T00:00:00Z"},"coverArt":{"sources":[]},"artists":{"items":[]},"tracksV2":{"items":[{"track":{"uri":"spotify:track:second","name":"Second Track","trackNumber":1,"discNumber":1,"duration":{"totalMilliseconds":90000},"artists":{"items":[]}}}],"totalCount":1}}}}
"""
private let firstArtistJSON = """
{"data":{"artistUnion":{"uri":"spotify:artist:first","id":"first","profile":{"name":"First Artist"},"visuals":{"avatarImage":{"sources":[]}},"discography":{"all":{"items":[{"releases":{"items":[{"uri":"spotify:album:first-release","id":"first-release","name":"First Release","type":"ALBUM","date":{"year":2024},"coverArt":{"sources":[]},"tracks":{"totalCount":1}}]}}],"totalCount":1}}}}}
"""
private let secondArtistJSON = """
{"data":{"artistUnion":{"uri":"spotify:artist:second","id":"second","profile":{"name":"Second Artist"},"visuals":{"avatarImage":{"sources":[]}},"discography":{"all":{"items":[{"releases":{"items":[{"uri":"spotify:album:second-release","id":"second-release","name":"Second Release","type":"ALBUM","date":{"year":2025},"coverArt":{"sources":[]},"tracks":{"totalCount":1}}]}}],"totalCount":1}}}}}
"""
private func firstAlbum() throws -> PathfinderAlbumUnion { try decodeAlbum(firstAlbumJSON) }
private func secondAlbum() throws -> PathfinderAlbumUnion { try decodeAlbum(secondAlbumJSON) }
private func firstArtist() throws -> PathfinderArtistUnion { try decodeArtist(firstArtistJSON) }
private func secondArtist() throws -> PathfinderArtistUnion { try decodeArtist(secondArtistJSON) }

private func albumItem(_ id: String, uri: String? = nil) -> CatalogItem {
    CatalogItem(
        id: id,
        uri: uri ?? "spotify:album:\(id)",
        title: id,
        subtitle: "",
        artworkURL: nil,
        kind: .album
    )
}

private func artistItem(_ id: String, uri: String? = nil) -> CatalogItem {
    CatalogItem(
        id: id,
        uri: uri ?? "spotify:artist:\(id)",
        title: id,
        subtitle: "",
        artworkURL: nil,
        kind: .artist
    )
}

@MainActor
private func makeAlbumStore(
    provider: GatedAlbumCatalog,
    session: CatalogSessionAvailability,
    attributes: RecordingAttributes = RecordingAttributes()
) -> (AlbumDetailStore, CatalogMetadataRepository) {
    let metadata = CatalogMetadataRepository(attributesProvider: attributes, session: session)
    return (AlbumDetailStore(provider: provider, metadata: metadata, session: session), metadata)
}

@MainActor
private func makeArtistStore(
    provider: GatedArtistCatalog,
    session: CatalogSessionAvailability
) -> ArtistDetailStore {
    ArtistDetailStore(provider: provider, session: session)
}

@MainActor
private func waitUntilArtistPair(
    _ provider: GatedArtistCatalog,
    overview: Int,
    discography: Int
) async -> Bool {
    await waitUntil {
        let overviewCount = await provider.overviewRequestCount
        let discographyCount = await provider.discographyRequestCount
        return overviewCount == overview && discographyCount == discography
    }
}

@MainActor
private struct AlbumLoadProbe {
    let task: Task<Void, Never>
    let hasEntered: () -> Bool
    let hasFinished: () -> Bool
}

@MainActor
private func startJoiningAlbumLoad(_ store: AlbumDetailStore, item: CatalogItem) -> AlbumLoadProbe {
    var entered = false
    var finished = false
    let task = Task { @MainActor in
        entered = true
        await store.load(item)
        finished = true
    }
    return AlbumLoadProbe(
        task: task,
        hasEntered: { entered },
        hasFinished: { finished }
    )
}

@MainActor
private struct ArtistLoadProbe {
    let task: Task<Void, Never>
    let hasEntered: () -> Bool
    let hasFinished: () -> Bool
}

@MainActor
private func startJoiningArtistLoad(_ store: ArtistDetailStore, item: CatalogItem) -> ArtistLoadProbe {
    var entered = false
    var finished = false
    let task = Task { @MainActor in
        entered = true
        await store.load(item)
        finished = true
    }
    return ArtistLoadProbe(
        task: task,
        hasEntered: { entered },
        hasFinished: { finished }
    )
}

@MainActor
func runMediaDetailStoreChecks(_ runner: CheckRunner) async {
    let firstAlbumValue: PathfinderAlbumUnion
    let secondAlbumValue: PathfinderAlbumUnion
    let firstArtistValue: PathfinderArtistUnion
    let secondArtistValue: PathfinderArtistUnion
    do {
        firstAlbumValue = try firstAlbum()
        secondAlbumValue = try secondAlbum()
        firstArtistValue = try firstArtist()
        secondArtistValue = try secondArtist()
    } catch {
        runner.check("synthetic media-detail fixtures decode", false)
        return
    }

    let firstAlbumItem = albumItem("first")
    let secondAlbumItem = albumItem("second")
    let firstArtistItem = artistItem("first")
    let secondArtistItem = artistItem("second")

    await runner.suite("Media detail same-selection join") {
        let provider = GatedAlbumCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let (store, _) = makeAlbumStore(provider: provider, session: session)

        let firstLoad = Task { await store.load(firstAlbumItem) }
        runner.check(
            "the first album request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        let follower = startJoiningAlbumLoad(store, item: firstAlbumItem)
        runner.check(
            "the duplicate caller entered load",
            await waitUntil { follower.hasEntered() }
        )
        runner.equal("a duplicate current-selection request joins the in-flight work", await provider.requestCount, 1)
        runner.check("the joined album stays loading", store.isLoading)
        runner.check("the duplicate caller is still waiting on the in-flight request", !follower.hasFinished())
        runner.equal("join does not clear the current selection", store.item?.uri, "spotify:album:first")

        await provider.completeNext(.album(firstAlbumValue))
        await firstLoad.value
        await follower.task.value
        runner.check("the duplicate caller finishes after the in-flight request", follower.hasFinished())
        runner.equal("joined consumers publish one album", store.tracks.map(\.uri), ["spotify:track:first"])
        runner.equal("joined consumers publish the release date", store.releaseDate, "2024-01-02")
        runner.check("joined loading finishes", !store.isLoading)
        runner.nil_("join does not surface an error", store.error)

        await store.load(firstAlbumItem)
        runner.equal("a completed same-session album is not fetched again", await provider.requestCount, 1)
    }

    await runner.suite("Media detail join claim survives owner cancel") {
        let provider = GatedAlbumCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let (store, _) = makeAlbumStore(provider: provider, session: session)

        let owner = Task { await store.load(firstAlbumItem) }
        runner.check(
            "the owner album request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        let joiner = startJoiningAlbumLoad(store, item: firstAlbumItem)
        runner.check(
            "the joiner entered load",
            await waitUntil { joiner.hasEntered() }
        )
        runner.equal("the joiner claimed the in-flight request", await provider.requestCount, 1)
        runner.check("the joiner is waiting on the claimed flight", !joiner.hasFinished())

        owner.cancel()
        runner.equal(
            "owner cancel does not start a second provider request after a join claim",
            await provider.requestCount,
            1
        )
        runner.check("the joiner remains on the live flight after owner cancel", !joiner.hasFinished())

        await provider.completeNext(.album(firstAlbumValue))
        await joiner.task.value
        await owner.value
        runner.check("the joiner finishes after the claimed flight", joiner.hasFinished())
        runner.equal("the joiner receives the in-flight result", store.tracks.map(\.uri), ["spotify:track:first"])
        runner.check("claimed-flight loading finishes", !store.isLoading)
        runner.nil_("claimed-flight success does not surface an error", store.error)
    }

    await runner.suite("Media detail cancelled owner does not join") {
        let provider = GatedAlbumCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let (store, _) = makeAlbumStore(provider: provider, session: session)

        let owner = Task { await store.load(firstAlbumItem) }
        runner.check(
            "the owner album request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        owner.cancel()
        // Drain last-claim release so this admission observes no live flight.
        for _ in 0..<16 { await Task.yield() }
        let reload = Task { await store.load(firstAlbumItem) }
        runner.check(
            "reloading the same URI after owner cancellation starts a new provider request",
            await waitUntil { await provider.requestCount == 2 }
        )
        runner.check("the replacement flight owns loading", store.isLoading)

        await provider.completeNext(.cancelled)
        await owner.value
        runner.check("the cancelled owner does not publish", store.tracks.isEmpty)
        runner.nil_("the cancelled owner does not surface an error", store.error)

        await provider.completeNext(.album(firstAlbumValue))
        await reload.value
        runner.equal("the replacement flight publishes", store.tracks.map(\.uri), ["spotify:track:first"])
        runner.check("the replacement flight clears loading", !store.isLoading)
    }

    await runner.suite("Media detail selection supersession and late finish") {
        let provider = GatedAlbumCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let (store, _) = makeAlbumStore(provider: provider, session: session)

        let stale = Task { await store.load(firstAlbumItem) }
        runner.check(
            "the superseded album request parks",
            await waitUntil { await provider.requestCount == 1 }
        )

        let current = Task { await store.load(secondAlbumItem) }
        runner.check(
            "a different selection starts a new request instead of joining",
            await waitUntil { await provider.requestCount == 2 }
        )
        runner.check("the newest flight owns loading", store.isLoading)
        runner.equal("the newest selection is presented immediately", store.item?.uri, "spotify:album:second")
        runner.equal("a new selection clears the previous tracks", store.tracks.map(\.uri), [])
        runner.nil_("a new selection clears the previous error", store.error)

        await provider.completeNext(.album(firstAlbumValue))
        await stale.value
        runner.check("a stale success leaves the new request loading", store.isLoading)
        runner.equal("a stale success does not publish tracks", store.tracks.map(\.uri), [])
        runner.equal("a stale success does not publish a release date", store.releaseDate, "")
        runner.nil_("a stale success does not surface an error", store.error)

        let joiner = startJoiningAlbumLoad(store, item: secondAlbumItem)
        runner.check(
            "the later same-selection caller entered load",
            await waitUntil { joiner.hasEntered() }
        )
        runner.equal(
            "the old request cannot clear the new request's in-flight task",
            await provider.requestCount,
            2
        )
        runner.check("a later same-selection caller is still waiting on the newest flight", !joiner.hasFinished())

        await provider.completeNext(.album(secondAlbumValue))
        await current.value
        await joiner.task.value
        runner.check("the later same-selection caller finishes with the newest flight", joiner.hasFinished())
        runner.equal("only the current selection publishes", store.tracks.map(\.uri), ["spotify:track:second"])
        runner.equal("only the current selection publishes a release date", store.releaseDate, "2025-03-04")
        runner.check("the newest flight clears loading", !store.isLoading)
    }

    await runner.suite("Media detail stale failure and cancellation stay inert") {
        let provider = GatedAlbumCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let (store, _) = makeAlbumStore(provider: provider, session: session)

        let stale = Task { await store.load(firstAlbumItem) }
        runner.check(
            "the failing album request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        let current = Task { await store.load(secondAlbumItem) }
        runner.check(
            "a different selection supersedes the failing request",
            await waitUntil { await provider.requestCount == 2 }
        )

        await provider.completeNext(.failure(.unavailable))
        await stale.value
        runner.check("a stale failure leaves the new request loading", store.isLoading)
        runner.nil_("a stale failure does not surface an error", store.error)

        await provider.completeNext(.urlCancelled)
        await current.value
        runner.check("cancellation clears only the cancelled flight's loading", !store.isLoading)
        runner.nil_("cancellation does not surface a user-facing error", store.error)
        runner.equal("cancellation does not publish tracks", store.tracks.map(\.uri), [])
    }

    await runner.suite("Media detail session supersession") {
        let provider = GatedAlbumCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let (store, _) = makeAlbumStore(provider: provider, session: session)

        let staleEpoch = Task { await store.load(firstAlbumItem) }
        runner.check(
            "the pre-epoch album request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        session.update(accountEpoch: 2, isAvailable: true)
        await provider.completeNext(.album(firstAlbumValue))
        await staleEpoch.value
        runner.equal("an older account epoch cannot publish tracks", store.tracks.map(\.uri), [])
        runner.equal("an older account epoch cannot publish a release date", store.releaseDate, "")

        let staleRevision = Task { await store.load(firstAlbumItem) }
        runner.check(
            "the pre-reconnect album request parks",
            await waitUntil { await provider.requestCount == 2 }
        )
        session.update(accountEpoch: 2, isAvailable: false)
        session.update(accountEpoch: 2, isAvailable: true)
        await provider.completeNext(.album(firstAlbumValue))
        await staleRevision.value
        runner.equal("a pre-reconnect album result cannot publish", store.tracks.map(\.uri), [])

        let current = Task { await store.load(firstAlbumItem) }
        runner.check(
            "a new catalog session starts a distinct album request",
            await waitUntil { await provider.requestCount == 3 }
        )
        await provider.completeNext(.album(secondAlbumValue))
        await current.value
        runner.equal("the current session publishes album tracks", store.tracks.map(\.uri), ["spotify:track:second"])

        session.update(accountEpoch: 3, isAvailable: true)
        let afterEpoch = Task { await store.load(firstAlbumItem) }
        runner.check(
            "a later account epoch reloads a previously loaded album",
            await waitUntil { await provider.requestCount == 4 }
        )
        await provider.completeNext(.album(firstAlbumValue))
        await afterEpoch.value
        runner.equal("the later account epoch publishes album tracks", store.tracks.map(\.uri), ["spotify:track:first"])
    }

    await runner.suite("Media detail reset and teardown") {
        let provider = GatedAlbumCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let (store, _) = makeAlbumStore(provider: provider, session: session)

        let inflight = Task { await store.load(firstAlbumItem) }
        runner.check(
            "the torn-down album request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        runner.check("teardown starts from a loading album", store.isLoading)

        store.reset()
        runner.check("reset clears album loading", !store.isLoading)
        runner.nil_("reset clears the current album", store.item)
        runner.equal("reset clears album tracks", store.tracks.map(\.uri), [])
        runner.equal("reset clears the release date", store.releaseDate, "")
        runner.nil_("reset clears album errors", store.error)

        await provider.completeNext(.album(firstAlbumValue))
        await inflight.value
        runner.equal("a torn-down album success cannot publish tracks", store.tracks.map(\.uri), [])
        runner.equal("a torn-down album success cannot restore a release date", store.releaseDate, "")
        runner.check("a torn-down album success cannot restore loading", !store.isLoading)
        runner.nil_("a torn-down album success cannot surface an error", store.error)
        runner.nil_("a torn-down album success cannot restore the selection", store.item)
    }

    await runner.suite("Media detail invalid URI") {
        let albumProvider = GatedAlbumCatalog()
        let artistProvider = GatedArtistCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let (albumStore, _) = makeAlbumStore(provider: albumProvider, session: session)
        let artistStore = makeArtistStore(provider: artistProvider, session: session)
        let invalidAlbum = albumItem("bad", uri: "not-an-album-uri")
        let invalidArtist = artistItem("bad", uri: "spotify:track:not-an-artist")
        let wrongKind = artistItem("first", uri: "spotify:album:first")

        await albumStore.load(invalidAlbum)
        runner.equal("an invalid album URI does not call the provider", await albumProvider.requestCount, 0)
        runner.equal(
            "an invalid album URI surfaces a stable error",
            albumStore.error,
            "Spotify returned an invalid album address."
        )
        runner.check("an invalid album URI does not stay loading", !albumStore.isLoading)
        runner.equal("an invalid album URI still presents the selection", albumStore.item?.uri, "not-an-album-uri")

        await albumStore.load(invalidAlbum)
        runner.equal("retrying an invalid album URI still does not call the provider", await albumProvider.requestCount, 0)

        await albumStore.load(wrongKind)
        runner.equal("a non-album selection is ignored", await albumProvider.requestCount, 0)
        runner.equal("a non-album selection leaves the invalid album state", albumStore.item?.uri, "not-an-album-uri")

        await artistStore.load(invalidArtist)
        runner.equal("an invalid artist URI does not call overview", await artistProvider.overviewRequestCount, 0)
        runner.equal("an invalid artist URI does not call discography", await artistProvider.discographyRequestCount, 0)
        runner.equal(
            "an invalid artist URI surfaces a stable error",
            artistStore.error,
            "Spotify returned an invalid artist address."
        )
        runner.check("an invalid artist URI does not stay loading", !artistStore.isLoading)
    }

    await runner.suite("Album metadata side effects") {
        let provider = GatedAlbumCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let attributes = RecordingAttributes()
        let (store, metadata) = makeAlbumStore(provider: provider, session: session, attributes: attributes)

        let stale = Task { await store.load(firstAlbumItem) }
        runner.check(
            "the stale metadata request parks",
            await waitUntil { await provider.requestCount == 1 }
        )
        let current = Task { await store.load(secondAlbumItem) }
        runner.check(
            "the current album metadata request parks",
            await waitUntil { await provider.requestCount == 2 }
        )

        await provider.completeNext(.album(firstAlbumValue))
        await stale.value
        runner.nil_("a stale album success does not cache tracks", metadata.knownTrack(for: "spotify:track:first"))
        runner.equal("a stale album success does not start attribute enrichment", await attributes.requestCount, 0)

        await provider.completeNext(.album(secondAlbumValue))
        await current.value
        runner.equal(
            "the current album publishes metadata",
            metadata.knownTrack(for: "spotify:track:second")?.title,
            "Second Track"
        )
        runner.nil_("the current album does not keep stale album metadata", metadata.knownTrack(for: "spotify:track:first"))
        runner.check(
            "the current album starts attribute enrichment",
            await waitUntil { await attributes.requestCount == 1 }
        )
        runner.equal("attribute enrichment uses the current album tracks", await attributes.requestedURIs, ["spotify:track:second"])
    }

    await runner.suite("Artist same-selection join and parallel completion") {
        let provider = GatedArtistCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makeArtistStore(provider: provider, session: session)

        let firstLoad = Task { await store.load(firstArtistItem) }
        runner.check(
            "artist overview and discography both park",
            await waitUntilArtistPair(provider, overview: 1, discography: 1)
        )
        let follower = startJoiningArtistLoad(store, item: firstArtistItem)
        runner.check(
            "the duplicate artist caller entered load",
            await waitUntil { follower.hasEntered() }
        )
        runner.equal("duplicate artist overview is not requested", await provider.overviewRequestCount, 1)
        runner.equal("duplicate artist discography is not requested", await provider.discographyRequestCount, 1)
        runner.check("the artist stays loading until both fetches finish", store.isLoading)
        runner.check("the duplicate artist caller is still waiting", !follower.hasFinished())
        runner.equal("partial artist completion does not publish yet", store.releases.map(\.uri), [])

        await provider.completeOverview(.artist(firstArtistValue))
        for _ in 0..<32 { await Task.yield() }
        runner.check("overview alone does not finish loading", store.isLoading)
        runner.equal("overview alone does not publish releases", store.releases.map(\.uri), [])
        runner.check("overview alone does not finish the joined caller", !follower.hasFinished())

        await provider.completeDiscography(.artist(firstArtistValue))
        await firstLoad.value
        await follower.task.value
        runner.check("the duplicate artist caller finishes after both fetches", follower.hasFinished())
        runner.equal(
            "artist mapping uses the profile name after both fetches complete",
            store.releases.map(\.uri),
            ["spotify:album:first-release"]
        )
        runner.equal("artist mapping uses the profile as the release subtitle", store.releases.first?.subtitle, "First Artist")
        runner.check("parallel artist loading finishes once", !store.isLoading)

        await store.load(firstArtistItem)
        runner.equal("a completed same-session artist is not fetched again", await provider.overviewRequestCount, 1)
        runner.equal("a completed same-session discography is not fetched again", await provider.discographyRequestCount, 1)
    }

    await runner.suite("Artist selection supersession stays inert") {
        let provider = GatedArtistCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makeArtistStore(provider: provider, session: session)

        let stale = Task { await store.load(firstArtistItem) }
        runner.check(
            "the superseded artist pair parks",
            await waitUntilArtistPair(provider, overview: 1, discography: 1)
        )
        let current = Task { await store.load(secondArtistItem) }
        runner.check(
            "a different artist starts a new parallel pair",
            await waitUntilArtistPair(provider, overview: 2, discography: 2)
        )
        runner.equal("the newest artist is presented immediately", store.item?.uri, "spotify:artist:second")
        runner.equal("a new artist clears previous releases", store.releases.map(\.uri), [])

        await provider.completeOverview(.artist(firstArtistValue))
        await provider.completeDiscography(.artist(firstArtistValue))
        await stale.value
        runner.check("a stale artist pair leaves the new request loading", store.isLoading)
        runner.equal("a stale artist pair does not publish", store.releases.map(\.uri), [])

        await provider.completeOverview(.artist(secondArtistValue))
        await provider.completeDiscography(.artist(secondArtistValue))
        await current.value
        runner.equal(
            "only the current artist publishes",
            store.releases.map(\.uri),
            ["spotify:album:second-release"]
        )
        runner.equal("the current artist profile names the releases", store.releases.first?.subtitle, "Second Artist")
        runner.check("the current artist clears loading", !store.isLoading)
    }

    await runner.suite("Artist reset invalidates outstanding work") {
        let provider = GatedArtistCatalog()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let store = makeArtistStore(provider: provider, session: session)

        let inflight = Task { await store.load(firstArtistItem) }
        runner.check(
            "the torn-down artist pair parks",
            await waitUntilArtistPair(provider, overview: 1, discography: 1)
        )
        store.reset()
        runner.check("reset clears artist loading", !store.isLoading)
        runner.nil_("reset clears the current artist", store.item)
        runner.equal("reset clears releases", store.releases.map(\.uri), [])

        await provider.completeOverview(.artist(firstArtistValue))
        await provider.completeDiscography(.artist(firstArtistValue))
        await inflight.value
        runner.equal("a torn-down artist success cannot publish", store.releases.map(\.uri), [])
        runner.check("a torn-down artist success cannot restore loading", !store.isLoading)
        runner.nil_("a torn-down artist success cannot restore the selection", store.item)
    }
}
