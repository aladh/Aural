import AuralDomain

/// Narrow catalog-facing playback surface. Holds the scene-owned `PlaybackStore` so
/// constructing and passing this value does not snapshot playback facts or rebuild
/// action closures. Leaves observe by reading the computed facts they render and
/// call through to the same store methods.
@MainActor
struct CatalogPlaybackAccess {
    private let player: PlaybackStore

    init(player: PlaybackStore) {
        self.player = player
    }

    var isConnected: Bool { player.isConnected }
    var accountEpoch: UInt64 { player.state.accountEpoch }
    var canStartPlayback: Bool { player.canStartPlayback }
    var hasCurrentTrack: Bool { player.hasCurrentTrack }
    var currentTrackURI: String { player.trackURI }
    var statusText: String { player.statusText }

    func connect() {
        player.connect()
    }

    func playURI(_ uri: String) {
        player.play(uri: uri)
    }

    func playTrack(_ track: CatalogTrack) {
        player.play(track: track)
    }

    func playPlaylist(_ item: CatalogItem) {
        player.playPlaylist(item)
    }

    func addToQueue(_ uris: [String]) {
        player.addToQueue(uris: uris)
    }
}
