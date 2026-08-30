import AuralDomain

/// Narrow catalog-facing playback surface. Holds the scene-owned `PlaybackStore` so
/// constructing and passing this value does not snapshot playback facts or rebuild
/// action closures. Leaves observe by reading the computed facts they render and
/// call through to the same store methods.
struct CatalogPlaybackAccess: Equatable {
    private let player: PlaybackStore
    private let playerIdentity: ObjectIdentifier

    @MainActor
    init(player: PlaybackStore) {
        self.player = player
        self.playerIdentity = ObjectIdentifier(player)
    }

    @MainActor var isConnected: Bool { player.isConnected }
    @MainActor var accountEpoch: UInt64 { player.state.accountEpoch }
    @MainActor var canStartPlayback: Bool { player.canStartPlayback }
    @MainActor var hasCurrentTrack: Bool { player.hasCurrentTrack }
    @MainActor var currentTrackURI: String { player.trackURI }
    @MainActor var statusText: String { player.statusText }

    @MainActor
    func connect() {
        player.connect()
    }

    @MainActor
    func playURI(_ uri: String) {
        player.play(uri: uri)
    }

    @MainActor
    func playTrack(_ track: CatalogTrack) {
        player.play(track: track)
    }

    @MainActor
    func playPlaylist(_ item: CatalogItem) {
        player.playPlaylist(item)
    }

    @MainActor
    func addToQueue(_ uris: [String]) {
        player.addToQueue(uris: uris)
    }

    nonisolated static func == (lhs: CatalogPlaybackAccess, rhs: CatalogPlaybackAccess) -> Bool {
        lhs.playerIdentity == rhs.playerIdentity
    }
}
