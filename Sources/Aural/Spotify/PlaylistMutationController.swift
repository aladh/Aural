//
//  PlaylistMutationController.swift
//  Aural
//
//  Account-scoped playlist add/remove. Reads stay on CatalogProviding; this type
//  is the only catalog write owner for playlist occurrences.
//

import AuralDomain
import Foundation

@MainActor
@Observable
final class PlaylistMutationController {
    @ObservationIgnored private let mutations: any PlaylistMutating
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let feedback: TransientFeedbackPresenter
    @ObservationIgnored private let playlistStore: PlaylistStore
    @ObservationIgnored private let homeLibrary: HomeLibraryStore
    @ObservationIgnored private var requestScope: UInt64 = 0
    @ObservationIgnored private var mutationTask: Task<Void, Never>?

    init(
        mutations: any PlaylistMutating,
        session: CatalogSessionAvailability,
        feedback: TransientFeedbackPresenter,
        playlistStore: PlaylistStore,
        homeLibrary: HomeLibraryStore
    ) {
        self.mutations = mutations
        self.session = session
        self.feedback = feedback
        self.playlistStore = playlistStore
        self.homeLibrary = homeLibrary
    }

    var editableLibraryPlaylists: [CatalogItem] {
        PlaylistEditability.editablePlaylists(homeLibrary.playlists, profileURI: homeLibrary.profileURI)
    }

    func reset() {
        requestScope &+= 1
        mutationTask?.cancel()
        mutationTask = nil
    }

    func isLibraryPlaylistEditable(_ item: CatalogItem) -> Bool {
        PlaylistEditability.canJustifyEdit(
            playlistOwnerURI: item.ownerURI,
            profileURI: homeLibrary.profileURI
        )
    }

    func isOpenPlaylistEditable(_ item: CatalogItem) -> Bool {
        let ownerURI =
            playlistStore.loadedURI == item.uri
            ? (playlistStore.ownerURI ?? item.ownerURI)
            : item.ownerURI
        return PlaylistEditability.canJustifyEdit(
            playlistOwnerURI: ownerURI,
            profileURI: homeLibrary.profileURI
        )
    }

    func addTracks(_ tracks: [CatalogTrack], to playlist: CatalogItem) {
        let uris = PlaylistMutationSelection.addURIs(from: tracks)
        guard
            PlaylistMutationSelection.canAdd(
                isTargetEditable: isLibraryPlaylistEditable(playlist),
                uris: uris
            )
        else { return }
        guard session.isAvailable else {
            feedback.failure("Connect Spotify before changing playlists.")
            return
        }
        guard let playlistID = SpotifyURI.id(from: playlist.uri, kind: "playlist") else {
            feedback.failure("That playlist can’t be updated.")
            return
        }

        startMutation { identity in
            try await self.mutations.addToPlaylist(playlistId: playlistID, trackUris: uris)
            await self.finishSuccessfulWrite(
                identity,
                playlist: playlist,
                message: Self.addedMessage(count: uris.count, playlistTitle: playlist.title)
            )
        }
    }

    func removeOccurrences(selectedIDs: Set<String>, from playlist: CatalogItem) {
        guard isOpenPlaylistEditable(playlist) else { return }
        let selected = PlaylistMutationSelection.orderedTracks(
            selectedIDs: selectedIDs,
            in: playlistStore.tracks
        )
        let uids = PlaylistMutationSelection.occurrenceIDsForRemoval(from: selected)
        guard
            PlaylistMutationSelection.canRemove(
                isPlaylistEditable: true,
                occurrenceIDs: uids
            )
        else { return }
        guard session.isAvailable else {
            feedback.failure("Connect Spotify before changing playlists.")
            return
        }
        guard playlistStore.loadedURI == playlist.uri,
            let playlistID = SpotifyURI.id(from: playlist.uri, kind: "playlist")
        else {
            feedback.failure("That playlist can’t be updated.")
            return
        }

        startMutation { identity in
            try await self.mutations.removeFromPlaylist(playlistId: playlistID, uids: uids)
            await self.finishSuccessfulWrite(
                identity,
                playlist: playlist,
                message: Self.removedMessage(count: uids.count, playlistTitle: playlist.title)
            )
        }
    }

    private func startMutation(_ work: @escaping @MainActor (AccountScopedRequestIdentity) async throws -> Void) {
        requestScope &+= 1
        let requestID = requestScope
        let identity = session.requestIdentity(requestID: requestID)
        mutationTask?.cancel()
        mutationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if requestID == self.requestScope {
                    self.mutationTask = nil
                }
            }
            do {
                try await work(identity)
            } catch {
                guard self.isCurrent(identity) else { return }
                self.reportFailure(error)
            }
        }
    }

    private func finishSuccessfulWrite(
        _ identity: AccountScopedRequestIdentity,
        playlist: CatalogItem,
        message: String
    ) async {
        // A superseded or cancelled task may still observe a completed server write.
        // Refresh once for that write whenever the captured account/session is current.
        // requestID and Task.isCancelled are latest-intent gates, not session validity.
        guard sessionAllowsApply(identity) else { return }
        await reconcileIfOpen(playlist)
        guard sessionAllowsApply(identity) else { return }
        feedback.success(message)
    }

    private func reconcileIfOpen(_ playlist: CatalogItem) async {
        guard playlistStore.loadedURI == playlist.uri else { return }
        await playlistStore.load(playlist, force: true)
    }

    /// Account/session gate for applying a completed write. Does not use request identity
    /// or cooperative cancellation, so a superseded in-flight success can still refresh.
    private func sessionAllowsApply(_ identity: AccountScopedRequestIdentity) -> Bool {
        identity.accountEpoch == session.accountEpoch
            && identity.sessionRevision == session.snapshot.revision
            && session.isAvailable
    }

    private func isCurrent(_ identity: AccountScopedRequestIdentity) -> Bool {
        identity.isCurrent(
            requestID: requestScope,
            accountEpoch: session.accountEpoch,
            sessionRevision: session.snapshot.revision,
            isAvailable: session.isAvailable,
            isCancelled: Task.isCancelled
        )
    }

    private func reportFailure(_ error: Error) {
        if isCancellation(error) { return }
        if let apiError = error as? PartnerAPIError, case .mutationRejected = apiError {
            feedback.failure("Spotify couldn’t change that playlist.")
            return
        }
        feedback.failure("Couldn’t update that playlist.")
    }

    private static func addedMessage(count: Int, playlistTitle: String) -> String {
        if count == 1 {
            return "Added to \(playlistTitle)"
        }
        return "Added \(count) songs to \(playlistTitle)"
    }

    private static func removedMessage(count: Int, playlistTitle: String) -> String {
        if count == 1 {
            return "Removed from \(playlistTitle)"
        }
        return "Removed \(count) songs from \(playlistTitle)"
    }
}
