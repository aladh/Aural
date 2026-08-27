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
    private var parked: CheckedContinuation<Void, any Error>?

    var isParked: Bool { parked != nil }

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
        parked?.resume()
        parked = nil
    }

    func setAddError(_ error: (any Error)?) { addError = error }
    func setRemoveError(_ error: (any Error)?) { removeError = error }
    func setLibrary(_ items: [PathfinderPlaylist]) { library = items }
    func setPlaylist(_ playlist: PathfinderPlaylistUnion) {
        if let id = playlist.id {
            playlistsByID[id] = playlist
        }
    }

    private func park() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                parked = continuation
            }
        } onCancel: {
            Task { await self.failPark() }
        }
    }

    private func failPark() {
        parked?.resume(throwing: CancellationError())
        parked = nil
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
        feedback: feedback
    )
}

@MainActor
private func yieldPasses(_ count: Int = 200) async {
    for _ in 0..<count {
        await Task.yield()
    }
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
        runner.equal("reconcile reloads only the open playlist", await services.playlistLoadCount, playlistLoadsBeforeAdd + 1)
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
        runner.equal("open playlist loads both duplicate occurrences", catalog.playlistStore.tracks.map(\.id), ["uid-a", "uid-b"])
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
        runner.check("removal does not send the duplicated track URI", removal?.uids.contains("spotify:track:dup") == false)

        do {
            try await services.setPlaylist(decodePlaylistUnion(ownedAfterRemovalJSON))
        } catch {
            runner.check("post-remove playlist fixture decodes", false)
        }
        await services.completePark()
        _ = await waitUntil { catalog.playlistStore.tracks.map(\.id) == ["uid-b"] }
        runner.equal("success refreshes only the open playlist", catalog.playlistStore.tracks.map(\.id), ["uid-b"])
        runner.equal("selection-stable remaining occurrence is uid-b", catalog.playlistStore.tracks.first?.id, "uid-b")
        runner.equal("successful remove reports through the presenter", feedback.message?.text, "Removed from Owned Mix")
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
        runner.check("rejection text does not include Spotify identifiers", feedback.message?.text.contains("spotify:") == false)

        await services.setAddError(nil)
        catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:new")], to: owned)
        _ = await waitUntil { await services.isParked }
        catalog.playlistMutations.reset()
        await yieldPasses()
        runner.equal("cancelled mutation does not replace the rejection message with success", feedback.message?.kind, .failure)
        runner.equal("cancelled mutation leaves tracks unchanged", catalog.playlistStore.tracks.map(\.id), loadedIDs)

        catalog.playlistMutations.addTracks([fixtureTrack(id: "row", uri: "spotify:track:stale")], to: owned)
        _ = await waitUntil { await services.isParked }
        session.update(accountEpoch: 2, isAvailable: true)
        await services.completePark()
        await yieldPasses()
        runner.equal("stale-account success does not present mutation feedback", feedback.message?.kind, .failure)
        runner.equal("stale-account success does not apply playlist rows", catalog.playlistStore.tracks.map(\.id), loadedIDs)

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

    runner.suite("Playlist mutation UI contract and drag prototype") {
        runner.noThrow("playlist mutation sources are readable") {
            let table = try auralSourceFile("Aural/Views/SharedComponents.swift")
            let providing = try auralSourceFile("Aural/Spotify/CatalogProviding.swift")
            let mutating = try auralSourceFile("Aural/Spotify/PlaylistMutating.swift")
            let controller = try auralSourceFile("Aural/Spotify/PlaylistMutationController.swift")
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
