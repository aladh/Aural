import AuralDomain

/// Narrow immutable projection used by catalog views. It exposes only the playback facts and
/// actions those views need, keeping the app-owned PlaybackStore at the scene composition edge.
struct CatalogPlaybackAccess {
    let isConnected: Bool
    let accountEpoch: UInt64
    let canStartPlayback: Bool
    let hasCurrentTrack: Bool
    let currentTrackURI: String
    let statusText: String
    let connect: @MainActor () -> Void
    let playURI: @MainActor (String) -> Void
    let playTrack: @MainActor (CatalogTrack) -> Void
    let playPlaylist: @MainActor (CatalogItem) -> Void
    let addToQueue: @MainActor (String) -> Void

    @MainActor
    init(player: PlaybackStore) {
        isConnected = player.isConnected
        accountEpoch = player.state.accountEpoch
        canStartPlayback = player.canStartPlayback
        hasCurrentTrack = player.hasCurrentTrack
        currentTrackURI = player.trackURI
        statusText = player.statusText
        connect = { [weak player] in player?.connect() }
        playURI = { [weak player] uri in player?.play(uri: uri) }
        playTrack = { [weak player] track in player?.play(track: track) }
        playPlaylist = { [weak player] item in player?.playPlaylist(item) }
        addToQueue = { [weak player] uri in player?.addToQueue(uri: uri) }
    }
}
