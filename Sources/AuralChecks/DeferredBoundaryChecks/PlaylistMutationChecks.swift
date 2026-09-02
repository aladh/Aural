import AuralDomain
import Foundation
@testable import AuralCore

private enum PlaylistMutationCheckFailure: Error {
    case unavailable
}

private struct MutationCheckAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

/// Parks until cancelled so a presented message stays visible for assertions.
private final class HoldingClock: PlaybackClock, @unchecked Sendable {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }

    func sleep(seconds _: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

private actor ScriptedPlaylistServices: CatalogProviding, PlaylistMutating {
    var profile = PathfinderProfile(username: "me", name: "Me", uri: "spotify:user:me", avatar: nil)
    var library: [PathfinderPlaylist] = []
    var playlistsByID: [String: PathfinderPlaylistUnion] = [:]
    var playlistLoadCount = 0
    var libraryLoadCount = 0
    var addCalls: [(playlistId: String, uris: [String])] = []
    var removeCalls: [(playlistId: String, uids: [String])] = []
    var addError: (any Error)?
    var removeError: (any Error)?
    var playlistError: (any Error)?
    var parkPlaylistLoads = false
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var playlistWaiters: [CheckedContinuation<Void, any Error>] = []

    var isParked: Bool { !waiters.isEmpty }
    var parkedCount: Int { waiters.count }
    var isPlaylistLoadParked: Bool { !playlistWaiters.isEmpty }

    func hasParkedAdds(_ count: Int) -> Bool {
        addCalls.count == count && waiters.count == count
    }

    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] {
        throw PlaylistMutationCheckFailure.unavailable
    }
    func home() async throws -> PathfinderHome { throw PlaylistMutationCheckFailure.unavailable }
    func libraryPlaylists() async throws -> [PathfinderPlaylist] {
        libraryLoadCount += 1
        return library
    }
    func libraryAlbums() async throws -> [PathfinderAlbum] { throw PlaylistMutationCheckFailure.unavailable }
    func libraryArtists() async throws -> [PathfinderArtist] { throw PlaylistMutationCheckFailure.unavailable }
    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] { throw PlaylistMutationCheckFailure.unavailable }
    func profile() async throws -> PathfinderProfile { profile }
    func playlist(id: String) async throws -> PathfinderPlaylistUnion {
        playlistLoadCount += 1
        if parkPlaylistLoads {
            try await parkPlaylistLoad()
        }
        if let playlistError { throw playlistError }
        guard let playlist = playlistsByID[id] else { throw PlaylistMutationCheckFailure.unavailable }
        return playlist
    }

    func addToPlaylist(playlistId: String, trackUris: [String]) async throws {
        addCalls.append((playlistId, trackUris))
        if let addError { throw addError }
        try await park()
    }

    func removeFromPlaylist(playlistId: String, uids: [String]) async throws {
        removeCalls.append((playlistId, uids))
        if let removeError { throw removeError }
        try await park()
    }

    func completePark() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func failPark() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(throwing: CancellationError())
    }

    func completePlaylistPark() {
        guard !playlistWaiters.isEmpty else { return }
        playlistWaiters.removeFirst().resume()
    }

    func failPlaylistPark() {
        guard !playlistWaiters.isEmpty else { return }
        playlistWaiters.removeFirst().resume(throwing: CancellationError())
    }

    func setAddError(_ error: (any Error)?) { addError = error }
    func setRemoveError(_ error: (any Error)?) { removeError = error }
    func setPlaylistError(_ error: (any Error)?) { playlistError = error }
    func setParkPlaylistLoads(_ enabled: Bool) { parkPlaylistLoads = enabled }
    func setLibrary(_ items: [PathfinderPlaylist]) { library = items }
    func setPlaylist(_ playlist: PathfinderPlaylistUnion) {
        if let id = playlist.id {
            playlistsByID[id] = playlist
        }
    }

    private func park() async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func parkPlaylistLoad() async throws {
        try await withCheckedThrowingContinuation { continuation in
            playlistWaiters.append(continuation)
        }
    }
}

private func decodePlaylist(_ json: String) throws -> PathfinderPlaylist {
    try JSONDecoder().decode(PathfinderPlaylist.self, from: Data(json.utf8))
}

private func decodePlaylistUnion(_ json: String) throws -> PathfinderPlaylistUnion {
    try JSONDecoder().decode(PathfinderPlaylistUnion.self, from: Data(json.utf8))
}

private let ownedLibraryJSON = """
    {"uri":"spotify:playlist:owned","name":"Owned Mix","ownerV2":{"data":{"name":"Me","username":"me","uri":"spotify:user:me"}}}
    """
private let foreignLibraryJSON = """
    {"uri":"spotify:playlist:foreign","name":"Foreign Mix","ownerV2":{"data":{"name":"Them","username":"them","uri":"spotify:user:them"}}}
    """
private let ownedContentsJSON = """
    {"uri":"spotify:playlist:owned","name":"Owned Mix","description":null,"ownerV2":{"data":{"username":"me","name":"Me","uri":"spotify:user:me"}},"content":{"totalCount":2,"items":[{"uid":"uid-a","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}},{"uid":"uid-b","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}}]}}
    """
private let ownedAfterRemovalJSON = """
    {"uri":"spotify:playlist:owned","name":"Owned Mix","description":null,"ownerV2":{"data":{"username":"me","name":"Me","uri":"spotify:user:me"}},"content":{"totalCount":1,"items":[{"uid":"uid-b","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}}]}}
    """
private let ownedAfterAddJSON = """
    {"uri":"spotify:playlist:owned","name":"Owned Mix","description":null,"ownerV2":{"data":{"username":"me","name":"Me","uri":"spotify:user:me"}},"content":{"totalCount":3,"items":[{"uid":"uid-a","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}},{"uid":"uid-b","itemV2":{"data":{"uri":"spotify:track:dup","name":"Dup","trackDuration":{"totalMilliseconds":1000}}}},{"uid":"uid-c","itemV2":{"data":{"uri":"spotify:track:new","name":"New","trackDuration":{"totalMilliseconds":1000}}}}]}}
    """
private let foreignContentsJSON = """
    {"uri":"spotify:playlist:foreign","name":"Foreign Mix","description":null,"ownerV2":{"data":{"username":"them","name":"Them","uri":"spotify:user:them"}},"content":{"totalCount":1,"items":[{"uid":"uid-f","itemV2":{"data":{"uri":"spotify:track:other","name":"Other","trackDuration":{"totalMilliseconds":1000}}}}]}}
    """

@MainActor
private func makeCatalog(
    services: ScriptedPlaylistServices,
    session: CatalogSessionAvailability,
    feedback: TransientFeedbackPresenter
) -> CatalogStore {
    CatalogStore(
        provider: services,
        attributesProvider: MutationCheckAttributes(),
        playlistMutations: services,
        session: session,
        clock: SystemPlaybackClock(),
        feedback: feedback
    )
}

@MainActor
private func yieldPasses(_ count: Int = 200) async {
    for _ in 0..<count {
        await Task.yield()
    }
}

private func fixtureTrack(id: String, uri: String) -> CatalogTrack {
    CatalogTrack(
        id: id,
        uri: uri,
        title: id,
        artist: "Artist",
        album: "Album",
        duration: 1,
        artworkURL: nil,
        addedAt: nil
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
func runPlaylistMutationChecks(_ runner: CheckRunner) async {
    runner.suite("Ownership metadata mapping") {
        runner.noThrow("library and detail playlist JSON decode") {
            let owned = try decodePlaylist(ownedLibraryJSON)
            let mapped = CatalogMapping.item(from: owned)
            runner.equal("library playlist keeps owner URI", mapped?.ownerURI, "spotify:user:me")
            runner.equal("library playlist keeps the owner subtitle", mapped?.subtitle, "Me")

            let foreign = try decodePlaylist(foreignLibraryJSON)
            runner.equal(
                "foreign playlist owner is preserved",
                CatalogMapping.item(from: foreign)?.ownerURI,
                "spotify:user:them"
            )

            let union = try decodePlaylistUnion(ownedContentsJSON)
            runner.equal(
                "open playlist owner URI is mapped from ownerV2",
                CatalogMapping.ownerURI(from: union),
                "spotify:user:me"
            )
            let tracks = union.content?.items?.compactMap(CatalogMapping.playlistTrack(from:)) ?? []
            runner.equal(
                "playlist rows use occurrence UIDs as CatalogTrack.id",
                tracks.map(\.id),
                ["uid-a", "uid-b"]
            )
            runner.equal(
                "duplicate rows keep the same track URI",
                tracks.map(\.uri),
                ["spotify:track:dup", "spotify:track:dup"]
            )
        }
    }

    await runner.suite("Editable library targets and batch add") {
        let services = ScriptedPlaylistServices()
        do {
            try await services.setLibrary([
                decodePlaylist(ownedLibraryJSON),
                decodePlaylist(foreignLibraryJSON),
            ])
            try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
        } catch {
            runner.check("owned library fixtures decode", false)
            return
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HoldingClock(), duration: 4)
        let catalog = makeCatalog(services: services, session: session, feedback: feedback)

        await catalog.homeLibrary.loadProfile()
        await catalog.homeLibrary.loadPlaylists()
        runner.equal("profile URI is retained for write advertising", catalog.homeLibrary.profileURI, "spotify:user:me")
        runner.equal(
            "only owned library playlists are editable targets",
            catalog.playlistMutations.editableLibraryPlaylists.map(\.uri),
            ["spotify:playlist:owned"]
        )

        let owned = catalog.homeLibrary.playlists.first { $0.uri == "spotify:playlist:owned" }
        runner.notNil("owned playlist is in the library", owned)
        guard let owned else {
            feedback.dismiss()
            return
        }
        await catalog.playlistStore.load(owned)
        let playlistLoadsBeforeAdd = await services.playlistLoadCount
        let duplicateURI = "spotify:track:dup"
        catalog.playlistMutations.addTracks(
            [
                fixtureTrack(id: "row-1", uri: duplicateURI),
                fixtureTrack(id: "row-2", uri: duplicateURI),
            ],
            to: owned
        )
        _ = await waitUntil { await services.isParked }
        let addCall = await services.addCalls.first
        runner.equal("add uses the playlist id, not the URI", addCall?.playlistId, "owned")
        runner.equal("one mutation carries every selected URI", addCall?.uris, [duplicateURI, duplicateURI])

        do {
            try await services.setPlaylist(decodePlaylistUnion(ownedAfterAddJSON))
        } catch {
            runner.check("post-add playlist fixture decodes", false)
        }
        await services.completePark()
        _ = await waitUntil {
            catalog.playlistStore.tracks.map(\.id) == ["uid-a", "uid-b", "uid-c"]
                && feedback.message?.kind == .success
                && feedback.message?.text == "Added 2 songs to Owned Mix"
        }
        runner.equal(
            "successful add refreshes the open playlist",
            catalog.playlistStore.tracks.map(\.id),
            ["uid-a", "uid-b", "uid-c"]
        )
        runner.equal("successful add reports through the shared presenter", feedback.message?.kind, .success)
        runner.equal("successful add names the playlist", feedback.message?.text, "Added 2 songs to Owned Mix")
        runner.equal(
            "reconcile reloads only the open playlist", await services.playlistLoadCount, playlistLoadsBeforeAdd + 1)
        runner.equal("library list is not reloaded after add", await services.libraryLoadCount, 1)
        feedback.dismiss()
    }

    await runner.suite("Occurrence-safe removal, reconciliation, and read-only refusal") {
        let services = ScriptedPlaylistServices()
        do {
            try await services.setLibrary([decodePlaylist(ownedLibraryJSON)])
            try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
        } catch {
            runner.check("removal fixtures decode", false)
            return
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HoldingClock(), duration: 4)
        let catalog = makeCatalog(services: services, session: session, feedback: feedback)
        await catalog.homeLibrary.loadProfile()
        await catalog.homeLibrary.loadPlaylists()
        let owned = catalog.homeLibrary.playlists[0]
        await catalog.playlistStore.load(owned)
        runner.equal(
            "open playlist loads both duplicate occurrences", catalog.playlistStore.tracks.map(\.id),
            ["uid-a", "uid-b"])
        runner.check(
            "owned open playlist is editable after load",
            catalog.playlistMutations.isOpenPlaylistEditable(owned)
        )

        let foreignPlaylist: CatalogItem?
        do {
            foreignPlaylist = CatalogMapping.item(from: try decodePlaylist(foreignLibraryJSON))
        } catch {
            foreignPlaylist = nil
            runner.check("foreign playlist fixture decodes", false)
        }
        if let foreignPlaylist {
            runner.check(
                "a foreign playlist is not an editable library target",
                !catalog.playlistMutations.isLibraryPlaylistEditable(foreignPlaylist)
            )
            catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-a"], from: foreignPlaylist)
        }
        runner.equal("read-only playlists do not start a removal", await services.removeCalls.count, 0)

        catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-a", "uid-a"], from: owned)
        _ = await waitUntil { await services.isParked }
        let removal = await services.removeCalls.first
        runner.equal("removal is one batched request", await services.removeCalls.count, 1)
        runner.equal("removal uses the selected Pathfinder UID", removal?.uids, ["uid-a"])
        runner.check(
            "removal does not send the duplicated track URI", removal?.uids.contains("spotify:track:dup") == false)

        do {
            try await services.setPlaylist(decodePlaylistUnion(ownedAfterRemovalJSON))
        } catch {
            runner.check("post-remove playlist fixture decodes", false)
        }
        await services.completePark()
        _ = await waitUntil {
            catalog.playlistStore.tracks.map(\.id) == ["uid-b"]
                && feedback.message?.text == "Removed from Owned Mix"
        }
        runner.equal("success refreshes only the open playlist", catalog.playlistStore.tracks.map(\.id), ["uid-b"])
        runner.equal("selection-stable remaining occurrence is uid-b", catalog.playlistStore.tracks.first?.id, "uid-b")
        runner.equal(
            "successful remove reports through the presenter", feedback.message?.text, "Removed from Owned Mix")
        runner.equal("library is not fully reloaded after remove", await services.libraryLoadCount, 1)
        feedback.dismiss()
    }

    await runner.suite("Permission rejection, cancellation, and stale session") {
        let services = ScriptedPlaylistServices()
        do {
            try await services.setLibrary([decodePlaylist(ownedLibraryJSON)])
            try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
        } catch {
            runner.check("rejection fixtures decode", false)
            return
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HoldingClock(), duration: 4)
        let catalog = makeCatalog(services: services, session: session, feedback: feedback)
        await catalog.homeLibrary.loadProfile()
        await catalog.homeLibrary.loadPlaylists()
        let owned = catalog.homeLibrary.playlists[0]
        await catalog.playlistStore.load(owned)
        let loadedIDs = catalog.playlistStore.tracks.map(\.id)

        await services.setAddError(PartnerAPIError.mutationRejected("addToPlaylist"))
        catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:new")], to: owned)
        _ = await waitUntil { feedback.message?.kind == .failure }
        runner.equal(
            "typed rejection is a privacy-safe failure",
            feedback.message?.text,
            "Spotify couldn’t change that playlist."
        )
        runner.equal("rejection leaves the open playlist untouched", catalog.playlistStore.tracks.map(\.id), loadedIDs)
        runner.check(
            "rejection text does not include Spotify identifiers", feedback.message?.text.contains("spotify:") == false)

        await services.setAddError(nil)
        catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:new")], to: owned)
        _ = await waitUntil { await services.isParked }
        catalog.playlistMutations.reset()
        await services.failPark()
        await yieldPasses()
        runner.equal(
            "cancelled mutation does not replace the rejection message with success", feedback.message?.kind, .failure)
        runner.equal("cancelled mutation leaves tracks unchanged", catalog.playlistStore.tracks.map(\.id), loadedIDs)

        catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:stale")], to: owned)
        _ = await waitUntil { await services.isParked }
        session.update(accountEpoch: 2, isAvailable: true)
        await services.completePark()
        await yieldPasses()
        runner.equal("stale-account success does not present mutation feedback", feedback.message?.kind, .failure)
        runner.equal(
            "stale-account success does not apply playlist rows", catalog.playlistStore.tracks.map(\.id), loadedIDs)

        session.update(accountEpoch: 2, isAvailable: false)
        catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:offline")], to: owned)
        runner.equal(
            "unavailable session reports a connect failure",
            feedback.message?.text,
            "Connect Spotify before changing playlists."
        )
        runner.equal("unavailable session does not send another write", await services.addCalls.count, 3)
        feedback.dismiss()
    }

    await runner.suite("Overlapping mutations reconcile each completed write") {
        let services = ScriptedPlaylistServices()
        do {
            try await services.setLibrary([decodePlaylist(ownedLibraryJSON)])
            try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
        } catch {
            runner.check("overlapping fixtures decode", false)
            return
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HoldingClock(), duration: 4)
        let catalog = makeCatalog(services: services, session: session, feedback: feedback)
        await catalog.homeLibrary.loadProfile()
        await catalog.homeLibrary.loadPlaylists()
        let owned = catalog.homeLibrary.playlists[0]
        await catalog.playlistStore.load(owned)
        let loadsBefore = await services.playlistLoadCount

        catalog.playlistMutations.addTracks(
            [fixtureTrack(id: "row-1", uri: "spotify:track:first")],
            to: owned
        )
        _ = await waitUntil { await services.parkedCount == 1 }
        catalog.playlistMutations.addTracks(
            [fixtureTrack(id: "row-2", uri: "spotify:track:second")],
            to: owned
        )
        _ = await waitUntil { await services.hasParkedAdds(2) }
        let sentAdds = await services.addCalls
        runner.equal("both overlapping writes are sent", sentAdds.count, 2)
        runner.equal(
            "first overlapping write keeps its batch",
            sentAdds.map(\.uris),
            [["spotify:track:first"], ["spotify:track:second"]]
        )

        do {
            try await services.setPlaylist(decodePlaylistUnion(ownedAfterAddJSON))
        } catch {
            runner.check("overlapping post-add fixture decodes", false)
        }
        await services.completePark()
        _ = await waitUntil { await services.playlistLoadCount == loadsBefore + 1 }
        await services.completePark()
        _ = await waitUntil {
            await services.playlistLoadCount == loadsBefore + 2
                && feedback.message?.kind == .success
                && catalog.playlistStore.tracks.map(\.id) == ["uid-a", "uid-b", "uid-c"]
        }
        runner.equal(
            "each completed overlapping write reloads the open playlist once",
            await services.playlistLoadCount,
            loadsBefore + 2
        )
        runner.equal(
            "later overlapping success reports through the presenter",
            feedback.message?.kind,
            .success
        )
        runner.check(
            "stale account/session still blocked overlapping apply",
            catalog.playlistStore.tracks.map(\.id) == ["uid-a", "uid-b", "uid-c"]
        )
        feedback.dismiss()
    }

    await runner.suite("Committed add keeps success when forced reload fails") {
        let services = ScriptedPlaylistServices()
        do {
            try await services.setLibrary([decodePlaylist(ownedLibraryJSON)])
            try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
        } catch {
            runner.check("add-reload fixtures decode", false)
            return
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HoldingClock(), duration: 4)
        let catalog = makeCatalog(services: services, session: session, feedback: feedback)
        await catalog.homeLibrary.loadProfile()
        await catalog.homeLibrary.loadPlaylists()
        let owned = catalog.homeLibrary.playlists[0]
        await catalog.playlistStore.load(owned)
        let loadedIDs = catalog.playlistStore.tracks.map(\.id)
        let loadsBefore = await services.playlistLoadCount
        runner.equal("open playlist has nonempty rows before add", loadedIDs, ["uid-a", "uid-b"])

        catalog.playlistMutations.addTracks(
            [fixtureTrack(id: "row", uri: "spotify:track:new")],
            to: owned
        )
        _ = await waitUntil { await services.isParked }
        await services.setPlaylistError(PlaylistMutationCheckFailure.unavailable)
        await services.completePark()
        _ = await waitUntil {
            catalog.playlistStore.error != nil
                && feedback.message?.kind == .success
                && feedback.message?.text == "Added to Owned Mix"
        }
        runner.equal("committed add still reports mutation success", feedback.message?.kind, .success)
        runner.equal("committed add still names the playlist", feedback.message?.text, "Added to Owned Mix")
        runner.equal(
            "failed reload keeps the previous nonempty rows",
            catalog.playlistStore.tracks.map(\.id),
            loadedIDs
        )
        runner.notNil("failed reload records a refresh error beside those rows", catalog.playlistStore.error)
        runner.equal("failed reload does not send another add", await services.addCalls.count, 1)
        runner.equal("forced reconcile attempted one playlist read", await services.playlistLoadCount, loadsBefore + 1)

        await catalog.playlistStore.load(owned, force: true)
        runner.notNil("retry failure keeps the stale-refresh error", catalog.playlistStore.error)
        runner.equal(
            "retry failure still keeps the previous rows",
            catalog.playlistStore.tracks.map(\.id),
            loadedIDs
        )
        runner.equal("retry does not repeat the add", await services.addCalls.count, 1)
        runner.equal(
            "retry failure loads the open playlist once more",
            await services.playlistLoadCount,
            loadsBefore + 2
        )

        await services.setPlaylistError(nil)
        do {
            try await services.setPlaylist(decodePlaylistUnion(ownedAfterAddJSON))
        } catch {
            runner.check("retry-success playlist fixture decodes", false)
        }
        await catalog.playlistStore.load(owned, force: true)
        runner.nil_("successful retry clears the stale-refresh error", catalog.playlistStore.error)
        runner.equal(
            "successful retry replaces rows with the authoritative playlist",
            catalog.playlistStore.tracks.map(\.id),
            ["uid-a", "uid-b", "uid-c"]
        )
        runner.equal("successful retry still does not repeat the add", await services.addCalls.count, 1)
        runner.equal("success toast is unchanged by retry", feedback.message?.kind, .success)
        feedback.dismiss()
    }

    await runner.suite("Committed remove keeps success when forced reload fails") {
        let services = ScriptedPlaylistServices()
        do {
            try await services.setLibrary([decodePlaylist(ownedLibraryJSON)])
            try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
        } catch {
            runner.check("remove-reload fixtures decode", false)
            return
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HoldingClock(), duration: 4)
        let catalog = makeCatalog(services: services, session: session, feedback: feedback)
        await catalog.homeLibrary.loadProfile()
        await catalog.homeLibrary.loadPlaylists()
        let owned = catalog.homeLibrary.playlists[0]
        await catalog.playlistStore.load(owned)
        let loadedIDs = catalog.playlistStore.tracks.map(\.id)

        catalog.playlistMutations.removeOccurrences(selectedIDs: ["uid-a"], from: owned)
        _ = await waitUntil { await services.isParked }
        await services.setPlaylistError(PlaylistMutationCheckFailure.unavailable)
        await services.completePark()
        _ = await waitUntil {
            catalog.playlistStore.error != nil
                && feedback.message?.text == "Removed from Owned Mix"
        }
        runner.equal("committed remove still reports mutation success", feedback.message?.kind, .success)
        runner.equal(
            "failed remove reload keeps previous nonempty rows",
            catalog.playlistStore.tracks.map(\.id),
            loadedIDs
        )
        runner.notNil("failed remove reload records a refresh error", catalog.playlistStore.error)
        runner.equal("failed remove reload does not send another removal", await services.removeCalls.count, 1)
        feedback.dismiss()
    }

    await runner.suite("Stale refresh warning survives cancellation and stale identity") {
        let services = ScriptedPlaylistServices()
        do {
            try await services.setLibrary([
                decodePlaylist(ownedLibraryJSON),
                decodePlaylist(foreignLibraryJSON),
            ])
            try await services.setPlaylist(decodePlaylistUnion(ownedContentsJSON))
        } catch {
            runner.check("stale-refresh fixtures decode", false)
            return
        }
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HoldingClock(), duration: 4)
        let catalog = makeCatalog(services: services, session: session, feedback: feedback)
        await catalog.homeLibrary.loadProfile()
        await catalog.homeLibrary.loadPlaylists()
        let owned = catalog.homeLibrary.playlists.first { $0.uri == "spotify:playlist:owned" }
        runner.notNil("owned playlist is in the library for stale-refresh checks", owned)
        guard let owned else {
            feedback.dismiss()
            return
        }
        await catalog.playlistStore.load(owned)
        let loadedIDs = catalog.playlistStore.tracks.map(\.id)

        catalog.playlistMutations.addTracks(
            [fixtureTrack(id: "row", uri: "spotify:track:new")],
            to: owned
        )
        _ = await waitUntil { await services.isParked }
        await services.setPlaylistError(PlaylistMutationCheckFailure.unavailable)
        await services.completePark()
        _ = await waitUntil { catalog.playlistStore.error != nil }
        runner.notNil("reconciliation failure plants the stale-refresh error", catalog.playlistStore.error)

        await services.setParkPlaylistLoads(true)
        let cancelledRetry = Task { await catalog.playlistStore.load(owned, force: true) }
        _ = await waitUntil { await services.isPlaylistLoadParked }
        runner.notNil("force reload start keeps the stale-refresh error", catalog.playlistStore.error)
        cancelledRetry.cancel()
        await services.failPlaylistPark()
        await cancelledRetry.value
        runner.notNil("cancelled retry does not clear the stale-refresh error", catalog.playlistStore.error)
        runner.equal("cancelled retry keeps previous rows", catalog.playlistStore.tracks.map(\.id), loadedIDs)
        runner.equal("cancelled retry does not repeat the add", await services.addCalls.count, 1)

        do {
            try await services.setPlaylist(decodePlaylistUnion(ownedAfterAddJSON))
        } catch {
            runner.check("stale-identity playlist fixture decodes", false)
        }
        await services.setPlaylistError(nil)
        let staleRetry = Task { await catalog.playlistStore.load(owned, force: true) }
        _ = await waitUntil { await services.isPlaylistLoadParked }
        session.update(accountEpoch: 2, isAvailable: true)
        await services.completePlaylistPark()
        await staleRetry.value
        runner.notNil("stale-account retry does not clear the stale-refresh error", catalog.playlistStore.error)
        runner.equal("stale-account retry does not apply newer rows", catalog.playlistStore.tracks.map(\.id), loadedIDs)
        runner.equal("stale-account retry does not repeat the add", await services.addCalls.count, 1)

        await services.setParkPlaylistLoads(false)
        let foreign = catalog.homeLibrary.playlists.first { $0.uri == "spotify:playlist:foreign" }
        runner.notNil("foreign playlist is in the library for switch coverage", foreign)
        if let foreign {
            do {
                try await services.setPlaylist(decodePlaylistUnion(foreignContentsJSON))
            } catch {
                runner.check("foreign playlist fixture decodes", false)
            }
            await catalog.playlistStore.load(foreign)
            runner.nil_("switching playlists clears the previous stale-refresh error", catalog.playlistStore.error)
            runner.equal(
                "switching playlists loads the new playlist rows",
                catalog.playlistStore.tracks.map(\.id),
                ["uid-f"]
            )
        }
        runner.equal("playlist switch does not send another add", await services.addCalls.count, 1)
        feedback.dismiss()
    }

    runner.suite("Playlist track collection version") {
        let services = ScriptedPlaylistServices()
        let session = CatalogSessionAvailability(accountEpoch: 1, isAvailable: true)
        let feedback = TransientFeedbackPresenter(clock: HoldingClock())
        let catalog = makeCatalog(services: services, session: session, feedback: feedback)
        let first = fixtureTrack(id: "uid-a", uri: "spotify:track:a")
        let second = fixtureTrack(id: "uid-b", uri: "spotify:track:b")
        catalog.playlistStore.replaceLoadedPlaylist(uri: "spotify:playlist:owned", tracks: [first, second])
        let loadedVersion = catalog.playlistStore.trackCollection.version
        catalog.playlistStore.replaceLoadedPlaylist(
            uri: "spotify:playlist:owned",
            tracks: [first, fixtureTrack(id: "uid-mid", uri: "spotify:track:mid")]
        )
        runner.equal("replacement keeps the same row count", catalog.playlistStore.tracks.count, 2)
        runner.check(
            "same-count middle replacement mints a new version",
            catalog.playlistStore.trackCollection.version != loadedVersion
        )
        runner.equal(
            "authoritative rows follow the replacement identity",
            catalog.playlistStore.tracks.map(\.id),
            ["uid-a", "uid-mid"]
        )
    }

    runner.suite("Playlist mutation UI contract and drag prototype") {
        runner.noThrow("playlist mutation sources are readable") {
            let table = try auralSourceFile("Aural/Views/SharedComponents.swift")
            let providing = try auralSourceFile("Aural/Spotify/CatalogProviding.swift")
            let mutating = try auralSourceFile("Aural/Spotify/PlaylistMutating.swift")
            let controller = try auralSourceFile("Aural/Spotify/PlaylistMutationController.swift")
            let playlistStore = try auralSourceFile("Aural/Spotify/PlaylistStore.swift")
            let searchStore = try auralSourceFile("Aural/Spotify/SearchStore.swift")
            let albumStore = try auralSourceFile("Aural/Spotify/MediaDetailStores.swift")
            let homeLibrary = try auralSourceFile("Aural/Spotify/HomeLibraryStore.swift")
            let collectionType = try auralSourceFile("AuralDomain/CatalogTrackCollection.swift")
            let displayCache = try auralSourceFile("AuralDomain/TrackTableDisplayCache.swift")
            let playlistDetail = try auralSourceFile("Aural/Views/PlaylistDetailView.swift")
            let mediaDetail = try auralSourceFile("Aural/Views/MediaDetailViews.swift")
            let libraryViews = try auralSourceFile("Aural/Views/LibraryViews.swift")
            let root = try auralSourceFile("Aural/RootView.swift")
            let contractURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "docs/product-and-acceptance-contract.md")
            let contract = try String(contentsOf: contractURL, encoding: .utf8)

            runner.check(
                "CatalogProviding stays a read-only catalog surface",
                !containsToken(providing, "func addToPlaylist")
                    && !containsToken(providing, "func removeFromPlaylist")
                    && !containsToken(providing, "func moveInPlaylist")
                    && containsToken(mutating, "protocol PlaylistMutating")
            )
            runner.check(
                "TrackTable uses multi-selection and a native Add to Playlist menu",
                containsToken(table, "Set<CatalogTrack.ID>")
                    && containsToken(table, "Menu(\"Add to Playlist\")")
                    && containsToken(table, "onDeleteCommand")
                    && containsToken(table, "Remove from Playlist")
            )
            runner.check(
                "TrackTable projects rows from a collection version instead of comparing tracks",
                containsToken(table, "TrackTableDisplayCache")
                    && containsToken(table, "CatalogTrackCollection")
                    && containsToken(table, "onChange(of: displayInputs")
                    && containsToken(table, "tracks.version")
                    && !containsToken(table, "onChange(of: tracks")
                    && !containsToken(table, "displayedTracks")
                    && !containsToken(table, "updateDisplayedTracks")
            )
            runner.check(
                "every TrackTable owner passes a CatalogTrackCollection",
                containsToken(playlistDetail, "tracks: store.trackCollection")
                    && containsToken(mediaDetail, "tracks: store.trackCollection")
                    && containsToken(libraryViews, "tracks: store.trackCollection")
                    && containsToken(root, "tracks: catalog.homeLibrary.likedTrackCollection")
            )
            runner.check(
                "catalog track lists replace through CatalogTrackCollection",
                containsToken(playlistStore, "trackCollection.replace")
                    && containsToken(searchStore, "trackCollection.replace")
                    && containsToken(albumStore, "trackCollection.replace")
                    && containsToken(homeLibrary, "likedTrackCollection.replace")
                    && !containsToken(playlistStore, "replaceCatalogTracks")
                    && !containsToken(searchStore, "replaceCatalogTracks")
                    && !containsToken(albumStore, "replaceCatalogTracks")
                    && !containsToken(homeLibrary, "replaceCatalogTracks")
            )
            runner.check(
                "PlaylistStore does not keep a second sorted copy",
                !containsToken(playlistStore, "sortedTracks")
                    && !containsToken(playlistStore, "dateSort")
                    && !containsToken(playlistStore, "resortTracks")
            )
            runner.check(
                "CatalogTrackCollection versions assignments instead of injected identity",
                containsToken(collectionType, "public init(tracks: [CatalogTrack] = [])")
                    && containsToken(collectionType, "version = UUID()")
                    && !containsToken(collectionType, "init(id:")
                    && !containsToken(collectionType, "revision")
                    && !containsToken(collectionType, ": Equatable")
            )
            runner.check(
                "TrackTableDisplayCache does not Equatable-compare cached rows",
                !containsToken(displayCache, ": Equatable")
            )
            runner.check(
                "Remove from Playlist and Delete pass only occurrence UIDs",
                containsToken(table, "PlaylistMutationSelection.occurrenceIDsForRemoval(from: selectedTracks)")
                    && !containsToken(table, "removeOccurrences(Array(selectedIDs))")
            )
            runner.check(
                "read-only tables do not register delete unless removal is offered",
                containsToken(table, "onDeleteCommandIfAvailable(playlistActions?.canRemoveOccurrences == true)")
            )
            runner.check(
                "mutations report through the composed TransientFeedbackPresenter",
                containsToken(controller, "feedback.success")
                    && containsToken(controller, "feedback.failure")
                    && !containsToken(controller, "NotificationCenter")
                    && !containsToken(controller, "Timer(")
            )
            runner.check(
                "reload failure is not turned into mutation failure or extra feedback",
                containsToken(controller, "await playlistStore.load(playlist, force: true)")
                    && !containsToken(controller, "playlistStore.error")
                    && containsToken(controller, "feedback.success(message)")
            )
            runner.check(
                "force reloads keep a same-playlist error until a current load succeeds",
                containsToken(playlistStore, "else if !force")
                    && containsToken(playlistStore, "error = nil")
                    && containsToken(playlistStore, "cancelled or superseded retry cannot hide stale rows")
            )
            runner.check(
                "nonempty playlist rows show a persistent stale-refresh warning with Retry",
                containsToken(playlistDetail, "Couldn't refresh this playlist. The songs shown may be out of date.")
                    && containsToken(playlistDetail, "Button(\"Retry\")")
                    && containsToken(playlistDetail, "await store.load(item, force: true)")
                    && containsToken(playlistDetail, "staleRefreshWarning")
                    && !containsToken(playlistDetail, "addTracks")
                    && !containsToken(playlistDetail, "removeOccurrences")
            )
            runner.check(
                "the product contract distinguishes mutation success from a stale playlist refresh",
                containsToken(contract, "Write failure, cancellation, and stale account/session results")
                    && containsToken(contract, "A committed write stays successful if that refresh fails")
                    && containsToken(contract, "Retry reloads rows without")
            )
            runner.check(
                "drag-to-playlist is omitted from table and playlist mutation UI",
                !containsToken(table, ".draggable(")
                    && !containsToken(table, ".dropDestination(")
                    && !containsToken(table, "onDrop(")
                    && !containsToken(controller, ".draggable(")
            )
            runner.check(
                "the product contract records the drag prototype decision",
                containsToken(contract, "Dragging selected tracks onto playlist rows is omitted")
                    && containsToken(contract, "SwiftUI Table")
            )
        }
    }
}
