//
//  SearchStore.swift
//  Spotty
//
//  Query-scoped, independently published catalog search state.
//

import SpottyDomain
import Foundation

@MainActor
@Observable
final class SearchStore {
    enum Section: String, CaseIterable, Sendable {
        case tracks, albums, artists, playlists
    }

    private(set) var trackCollection = CatalogTrackCollection()
    var tracks: [CatalogTrack] { trackCollection.tracks }
    private(set) var albums: [CatalogItem] = []
    private(set) var artists: [CatalogItem] = []
    private(set) var playlists: [CatalogItem] = []
    private(set) var errors: [Section: String] = [:]
    private(set) var isSearching = false

    // Compatibility projections retained for the small boundary-check executable.
    var results: [CatalogTrack] { tracks }
    var error: String? {
        Section.allCases.lazy.compactMap { self.errors[$0] }.first
    }
    var failedSections: [Section] {
        Section.allCases.filter { self.errors[$0] != nil }
    }
    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }

    /// Delay before a view-driven query is admitted. Try Again calls `search`
    /// directly and must not wait this interval again.
    static let queryAdmissionDelay: TimeInterval = 0.3

    @ObservationIgnored private let provider: any CatalogProviding
    @ObservationIgnored private let metadata: CatalogMetadataRepository
    @ObservationIgnored private let session: CatalogSessionAvailability
    @ObservationIgnored private let clock: any PlaybackClock
    @ObservationIgnored private var requestScope: UInt64 = 0
    @ObservationIgnored private var debounceGeneration: UInt64 = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(
        provider: any CatalogProviding,
        metadata: CatalogMetadataRepository,
        session: CatalogSessionAvailability,
        clock: any PlaybackClock
    ) {
        self.provider = provider
        self.metadata = metadata
        self.session = session
        self.clock = clock
    }

    func reset() {
        invalidatePendingAdmission()
        requestScope &+= 1
        searchTask?.cancel()
        searchTask = nil
        clearResults()
        isSearching = false
    }

    /// Immediate admission for Try Again. Invalidates a pending debounce so a
    /// later timer cannot start a second fetch for a superseded query.
    func search(_ term: String) async {
        invalidatePendingAdmission()
        await performSearch(term.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// View-driven query path. Cancelled or superseded before the delay leaves
    /// committed results and `isSearching` unchanged.
    func scheduleSearch(_ term: String) async {
        invalidatePendingAdmission()
        let token = debounceGeneration
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheduled = session.snapshot
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(seconds: Self.queryAdmissionDelay)
            } catch {
                return
            }
            guard token == self.debounceGeneration, !Task.isCancelled else { return }
            guard self.session.snapshot == scheduled else { return }
            await self.performSearch(query)
        }
        debounceTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if token == debounceGeneration {
            debounceTask = nil
        }
    }

    private func invalidatePendingAdmission() {
        debounceGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func performSearch(_ query: String) async {
        requestScope &+= 1
        let requestID = requestScope
        searchTask?.cancel()
        guard session.isAvailable, !query.isEmpty else {
            clearResults()
            isSearching = false
            return
        }

        clearResults()
        isSearching = true
        let identity = session.requestIdentity(requestID: requestID)
        let task = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.loadTracks(query, identity: identity) }
                group.addTask { await self.loadAlbums(query, identity: identity) }
                group.addTask { await self.loadArtists(query, identity: identity) }
                group.addTask { await self.loadPlaylists(query, identity: identity) }
            }
        }
        searchTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if requestID == requestScope {
            isSearching = false
            searchTask = nil
        }
    }

    private func loadTracks(_ query: String, identity: AccountScopedRequestIdentity) async {
        await load(.tracks, identity: identity) {
            let values = try await provider.searchTracks(query, limit: 50).compactMap(CatalogMapping.searchTrack(from:))
            guard isCurrent(identity) else { return }
            trackCollection.replace(values)
            metadata.replaceTracks(values, from: .search)
            metadata.loadTrackAttributes(for: values)
        }
    }

    private func loadAlbums(_ query: String, identity: AccountScopedRequestIdentity) async {
        await load(.albums, identity: identity) {
            let values = try await provider.searchAlbums(query, limit: 30).compactMap(CatalogMapping.item(from:))
            guard isCurrent(identity) else { return }
            albums = values
            metadata.cacheItems(values, from: .search)
        }
    }

    private func loadArtists(_ query: String, identity: AccountScopedRequestIdentity) async {
        await load(.artists, identity: identity) {
            let values = try await provider.searchArtists(query, limit: 30).compactMap(CatalogMapping.item(from:))
            guard isCurrent(identity) else { return }
            artists = values
            metadata.cacheItems(values, from: .search)
        }
    }

    private func loadPlaylists(_ query: String, identity: AccountScopedRequestIdentity) async {
        await load(.playlists, identity: identity) {
            let values = try await provider.searchPlaylists(query, limit: 30).compactMap(CatalogMapping.item(from:))
            guard isCurrent(identity) else { return }
            playlists = values
            metadata.cacheItems(values, from: .search)
        }
    }

    private func load(
        _ section: Section,
        identity: AccountScopedRequestIdentity,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch CatalogProviderCapabilityError.unsupported {
        } catch {
            guard !isCancellation(error), isCurrent(identity) else { return }
            errors[section] = error.localizedDescription
        }
    }

    private func clearResults() {
        trackCollection.replace([])
        albums = []
        artists = []
        playlists = []
        errors = [:]
        metadata.replaceTracks([], from: .search)
        metadata.replaceItems([], from: .search)
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
}
