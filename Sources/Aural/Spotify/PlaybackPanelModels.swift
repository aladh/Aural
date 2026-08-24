//
//  PlaybackPanelModels.swift
//  Aural
//

import AuralDomain
import Foundation

typealias RepeatMode = AuralDomain.RepeatMode
typealias RepeatFlags = AuralDomain.RepeatFlags
typealias QueueEntry = AuralDomain.QueueEntry
typealias ConnectDevice = AuralDomain.ConnectDevice
typealias ConnectCommandRoute = AuralDomain.ConnectCommandRoute
typealias HistoryEntry = AuralDomain.HistoryEntry
typealias PlaybackHistory = AuralDomain.PlaybackHistory

func interpolatedPlaybackPosition(
    anchor: TimeInterval,
    anchoredAt: Date,
    now: Date,
    isPlaying: Bool,
    duration: TimeInterval
) -> TimeInterval {
    AuralDomain.interpolatedPlaybackPosition(
        anchor: anchor,
        anchoredAt: anchoredAt,
        now: now,
        isPlaying: isPlaying,
        duration: duration
    )
}

func playbackSnapshotPosition(
    positionMilliseconds: Int64,
    durationMilliseconds: Int64,
    timestampMilliseconds: Int64?,
    isPlaying: Bool,
    now: Date = Date()
) -> TimeInterval {
    AuralDomain.playbackSnapshotPosition(
        positionMilliseconds: positionMilliseconds,
        durationMilliseconds: durationMilliseconds,
        timestampMilliseconds: timestampMilliseconds,
        isPlaying: isPlaying,
        now: now
    )
}

func connectCommandRoute(
    isLocalActive: Bool,
    localDeviceID: String?,
    devices: [ConnectDevice],
    fallbackRemoteDeviceID: String? = nil
) -> ConnectCommandRoute {
    AuralDomain.connectCommandRoute(
        isLocalActive: isLocalActive,
        localDeviceID: localDeviceID,
        devices: devices,
        fallbackRemoteDeviceID: fallbackRemoteDeviceID
    )
}

/// The in-memory recently-played list shown in the panel's History tab.
/// Session-scoped by design: nothing about history needs to outlive the app.
@MainActor
@Observable
final class PlaybackHistoryStore {
    private(set) var entries: [HistoryEntry] = []

    func notePlayed(uri: String, title: String, artist: String, artworkURL: URL?) {
        guard uri.hasPrefix("spotify:track:") else { return }
        entries = PlaybackHistory.updated(
            entries,
            afterPlaying: uri,
            title: title.isEmpty ? fallbackTitle(for: uri) : title,
            artist: artist,
            artworkURLString: artworkURL?.absoluteString,
            playedAt: Date()
        )
    }

    func applyMetadata(uri: String, title: String, artist: String, artworkURL: URL?) {
        entries = PlaybackHistory.withMetadata(
            entries,
            for: uri,
            title: title,
            artist: artist,
            artworkURLString: artworkURL?.absoluteString
        )
    }

    func reset() {
        entries = []
    }

    private func fallbackTitle(for uri: String) -> String {
        uri.split(separator: ":").last.map(String.init) ?? uri
    }
}
