//
//  PlaybackStore+History.swift
//  Aural
//
//  Playback history and fewer-repeats ordering.
//

import AuralDomain
import Foundation
import OSLog

extension PlaybackStore {
    func recordPlayed(_ uri: String) {
        guard !uri.isEmpty else { return }
        let playedAt = environment.clock.now()
        let now = playedAt.timeIntervalSince1970
        var history = playbackHistory()
        history[uri] = now
        history = ShufflePolicy.pruned(history, now: now)

        shuffleHistoryCache = history
        Task { await environment.preferences.setShuffleHistory(history) }

        let track = catalog.metadata.knownTrack(for: uri)
        let info = catalog.metadata.displayInfo(for: uri)
        self.history.notePlayed(
            uri: uri,
            title: track?.title ?? info.title,
            artist: track?.artist ?? info.artist,
            artworkURL: track?.artworkURL,
            playedAt: playedAt
        )
    }

    func playbackHistory() -> [String: TimeInterval] {
        shuffleHistoryCache
    }

    func fewerRepeatsOrder(_ tracks: [CatalogTrack]) -> [CatalogTrack] {
        guard tracks.count > 1 else { return tracks }
        var generator = SystemRandomNumberGenerator()
        let order = ShufflePolicy.order(
            count: tracks.count,
            uri: { tracks[$0].uri },
            history: playbackHistory(),
            now: environment.clock.now().timeIntervalSince1970,
            generator: &generator
        )
        return order.map { tracks[$0] }
    }
}
