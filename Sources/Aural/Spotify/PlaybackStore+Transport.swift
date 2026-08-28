//
//  PlaybackStore+Transport.swift
//  Aural
//
//  Transport, playback options, and Spotify Connect device actions.
//

import AuralDomain
import Foundation
import OSLog

extension PlaybackStore {
    func play(uri: String) {
        submitPlay(uri: uri) { [weak self] accepted in
            if accepted { self?.recordPlayed(uri) }
        }
    }

    func play(track: CatalogTrack) {
        submitPlay(uri: track.uri, expectedTrack: currentTrack(from: track)) { [weak self] accepted in
            if accepted { self?.recordPlayed(track.uri) }
        }
    }

    func playPlaylist(_ item: CatalogItem) {
        let playlistTracks = catalog.playlistStore.tracks
        let orderedTracks = isShuffleEnabled ? fewerRepeatsOrder(playlistTracks) : playlistTracks
        let expectedTrack: CurrentTrack?
        if catalog.playlistStore.loadedURI == item.uri, let first = orderedTracks.first {
            expectedTrack = currentTrack(from: first)
        } else {
            expectedTrack = nil
        }

        if isShuffleEnabled, !orderedTracks.isEmpty {
            let trackURIs = orderedTracks.map(\.uri)
            performRoutedCommand(
                "Could not shuffle that playlist",
                kind: .transport,
                expecting: true,
                expectedTiming: expectedTrack.map { playTargetTiming(from: $0) },
                expectedTrack: expectedTrack,
                local: .playTracks(trackURIs),
                remote: .play(trackURIs: trackURIs)
            ) { [weak self] accepted in
                guard let self, accepted, let expectedTrack else { return }
                self.recordPlayed(expectedTrack.uri)
            }
            return
        }
        submitPlay(uri: item.uri, expectedTrack: expectedTrack) { [weak self] accepted in
            guard let self, accepted, let expectedTrack else { return }
            self.recordPlayed(expectedTrack.uri)
        }
    }

    private func submitPlay(
        uri: String,
        expectedTrack: CurrentTrack? = nil,
        completion: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        let value = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            completion(false)
            return
        }
        performRoutedCommand(
            "Could not play that Spotify URI",
            expecting: true,
            expectedTiming: expectedTrack.map { playTargetTiming(from: $0) },
            expectedTrack: expectedTrack,
            local: .playURI(value),
            remote: .play(uri: value),
            completion: completion
        )
    }

    private func currentTrack(from track: CatalogTrack) -> CurrentTrack {
        CurrentTrack(
            uri: track.uri,
            title: track.title,
            artist: track.artist,
            artworkURL: track.artworkURL,
            duration: track.duration,
            metadataSource: .catalog
        )
    }

    private func playTargetTiming(from track: CurrentTrack) -> PlaybackTiming {
        PlaybackTiming(position: 0, duration: track.duration, anchoredAt: environment.clock.now())
    }

    func toggleShuffle() {
        let enabled = !isShuffleEnabled
        // Spotify Connect only exposes an on/off command. Keep other clients in sync when
        // there is a live context; playlist starts in Aural use the local freshness ordering.
        if isActiveDevice || activeRemoteDevice != nil {
            performRoutedCommand(
                "Could not update shuffle",
                kind: .options,
                expectedShuffle: enabled,
                local: .shuffle(enabled),
                remote: .shuffle(enabled)
            ) { [weak self] accepted in
                guard let self, accepted else { return }
                Task { await self.environment.preferences.setShuffleEnabled(self.isShuffleEnabled) }
            }
            return
        }
        setShuffleEnabled(enabled)
        Task { await environment.preferences.setShuffleEnabled(enabled) }
    }

    func togglePlayback() {
        guard canTogglePlayback else { return }
        let targetIsPlaying = !isPlaying
        let now = environment.clock.now()
        let expectedTiming: PlaybackTiming
        if targetIsPlaying {
            // A paused anchor may be arbitrarily old; resume interpolation from now.
            expectedTiming = PlaybackTiming(position: position, duration: duration, anchoredAt: now)
        } else {
            // Freeze the smooth UI clock in the same event that applies paused transport. The
            // local player can still refresh an exact position as a follow-up; a remote device
            // is represented by this clock.
            if isActiveDevice {
                refreshPosition()
            }
            expectedTiming = PlaybackTiming(
                position: displayedPosition(at: now),
                duration: duration,
                anchoredAt: now
            )
        }

        let failure = targetIsPlaying ? "Resume was rejected" : "Pause was rejected"
        performRoutedCommand(
            failure,
            kind: .transport,
            expecting: targetIsPlaying,
            expectedTiming: expectedTiming,
            local: targetIsPlaying ? .resume : .pause,
            remote: targetIsPlaying ? .resume : .pause
        ) { [weak self] accepted in
            guard let self, accepted else { return }
            self.refreshPosition()
        }
    }

    func next() {
        performRoutedCommand(
            "Next was rejected",
            kind: .navigation,
            local: .next,
            remote: .next
        )
    }

    func previous() {
        performRoutedCommand(
            "Previous was rejected",
            kind: .navigation,
            local: .previous,
            remote: .previous
        )
    }

    func seek(to fraction: Double) {
        let milliseconds = UInt32(max(0, min(1, fraction)) * duration * 1_000)
        let now = environment.clock.now()
        performRoutedCommand(
            "Seek was rejected",
            kind: .seek,
            expectedTiming: PlaybackTiming(
                position: TimeInterval(milliseconds) / 1_000,
                duration: duration,
                anchoredAt: now
            ),
            local: .seek(milliseconds),
            remote: .seek(to: Int(milliseconds))
        )
    }

    func refreshPosition() {
        guard isConnected, showsPauseControl, isActiveDevice else { return }
        let epoch = accountEpoch
        let capturedEngineEpoch = engineGeneration
        effects.replace(.positionRefresh, with: Task { [weak self] in
            guard let self else { return }
            let position = await self.coordinator.positionMilliseconds()
            guard !Task.isCancelled, !self.isTearingDown, self.isConnected else { return }
            _ = self.setTiming(
                position: TimeInterval(position) / 1_000,
                accountEpoch: epoch,
                engineEpoch: capturedEngineEpoch
            )
        })
    }

    // MARK: - Repeat

    /// Cycles off → repeat queue → repeat track → off, like Spotify's transport.
    func cycleRepeat() {
        guard canStartPlayback else { return }
        let previousMode = repeatMode
        let previousFlags = state.options.repeatFlags
        let nextMode = previousMode.next
        let nextFlags = nextMode.flags
        setRepeat(mode: nextMode, flags: nextFlags)
        let plan = RepeatTransitionPlan.planning(from: previousFlags, to: nextFlags)
        let enginePlaybackRevision = state.sourceRevisions[.enginePlayback]
        performRoutedOperation(
            "Could not update repeat",
            kind: .options,
            local: .repeatOptions(plan),
            remote: { api, from, to in
                try await RepeatTransitionApplication.applyRemote(plan) { mutation in
                    try await api.send(.repeatMutation(mutation), from: from, to: to)
                }
            }
        ) { [weak self] accepted in
            guard let self, !accepted else { return }
            let disposition = reconcileRepeatCommandFailure(
                visibleMode: self.repeatMode,
                visibleFlags: self.state.options.repeatFlags,
                previousMode: previousMode,
                previousFlags: previousFlags,
                targetMode: nextMode,
                targetFlags: nextFlags,
                enginePlaybackRevisionChanged:
                    self.state.sourceRevisions[.enginePlayback] != enginePlaybackRevision
            )
            if disposition == .restorePrevious {
                self.setRepeat(mode: previousMode, flags: previousFlags)
            }
        }
    }

    // MARK: - Spotify Connect devices

    /// Hands playback to another Connect device. Selecting this Mac transfers back here.
    func transferPlayback(to device: ConnectDevice) {
        guard canStartPlayback else { return }
        guard device.isActive == false, device.id != activeRemoteDevice?.id else { return }
        if device.id == localDeviceID {
            performCommand(
                "Could not move playback to this Mac",
                operation: .transferToLocal,
                kind: .transfer
            )
            return
        }
        let previousOwner = state.owner
        send(
            .owner(.uncertain(PlaybackDevice(
                id: device.id,
                name: device.name,
                type: device.type,
                isActive: false
            ))),
            source: .command
        )
        performCommand(
            "Could not move playback to \(device.name)",
            operation: .transferToDevice(device.id),
            kind: .transfer
        ) { [weak self] accepted in
            if accepted {
                self?.showTransientCommandError("Playing on \(device.name)")
            } else {
                self?.send(.owner(previousOwner), source: .command)
            }
        }
    }

}
