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
        let previous = playbackPresentation
        present(track)
        submitPlay(uri: track.uri) { [weak self] accepted in
            guard let self else { return }
            if accepted {
                self.recordPlayed(track.uri)
            } else {
                self.restorePlaybackPresentation(previous)
            }
        }
    }

    func playPlaylist(_ item: CatalogItem) {
        let playlistTracks = catalog.playlistStore.tracks
        let orderedTracks = isShuffleEnabled ? fewerRepeatsOrder(playlistTracks) : playlistTracks
        let previous = playbackPresentation
        var presentedTrack: CatalogTrack?
        if catalog.playlistStore.loadedURI == item.uri, let first = orderedTracks.first {
            present(first)
            presentedTrack = first
        }

        if isShuffleEnabled, !orderedTracks.isEmpty {
            let trackURIs = orderedTracks.map(\.uri)
            performRoutedCommand(
                "Could not shuffle that playlist",
                kind: .transport,
                expecting: true,
                local: .playTracks(trackURIs),
                remote: .play(trackURIs: trackURIs)
            ) { [weak self] accepted in
                guard let self else { return }
                if accepted {
                    self.setTransport(.playing, anchoredAt: self.environment.clock.now())
                    if let presentedTrack { self.recordPlayed(presentedTrack.uri) }
                } else {
                    self.restorePlaybackPresentation(previous)
                }
            }
            return
        }
        submitPlay(uri: item.uri) { [weak self] accepted in
            guard let self else { return }
            if accepted {
                if let presentedTrack { self.recordPlayed(presentedTrack.uri) }
            } else {
                self.restorePlaybackPresentation(previous)
            }
        }
    }

    private func submitPlay(
        uri: String,
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
            local: .playURI(value),
            remote: .play(uri: value)
        ) { [weak self] accepted in
            if accepted {
                guard let self else { return }
                self.setTransport(.playing, anchoredAt: self.environment.clock.now())
            }
            completion(accepted)
        }
    }

    private var playbackPresentation: PlaybackPresentationSnapshot {
        PlaybackPresentationSnapshot(
            currentTrack: state.currentTrack,
            transport: state.transport,
            timing: state.timing
        )
    }

    private func restorePlaybackPresentation(_ presentation: PlaybackPresentationSnapshot) {
        send(.presentation(presentation), source: .command)
    }

    func toggleShuffle() {
        let previous = isShuffleEnabled
        let enabled = !isShuffleEnabled
        setShuffleEnabled(enabled)
        Task { await environment.preferences.setShuffleEnabled(enabled) }

        // Spotify Connect only exposes an on/off command. Keep other clients in sync when
        // there is a live context; playlist starts in Aural use the local freshness ordering.
        if isActiveDevice || activeRemoteDevice != nil {
            performRoutedCommand(
                "Could not update shuffle",
                kind: .options,
                local: .shuffle(enabled),
                remote: .shuffle(enabled)
            ) { [weak self] accepted in
                guard let self, !accepted else { return }
                self.setShuffleEnabled(previous)
                Task { await self.environment.preferences.setShuffleEnabled(previous) }
            }
        }
    }

    func togglePlayback() {
        guard canTogglePlayback else { return }
        let previousIsPlaying = isPlaying
        let targetIsPlaying = !isPlaying
        if targetIsPlaying {
            // A paused anchor may be arbitrarily old; resume interpolation from now.
            setTiming(position: position, anchoredAt: environment.clock.now())
        } else {
            // Freeze the smooth UI clock before the optimistic state change stops it. The local
            // player can provide an exact position; a remote device is represented by this clock.
            if isActiveDevice {
                refreshPosition()
            } else {
                setTiming(position: displayedPosition(at: environment.clock.now()))
            }
        }
        setTransport(targetIsPlaying ? .playing : .paused)

        let failure = targetIsPlaying ? "Resume was rejected" : "Pause was rejected"
        performRoutedCommand(
            failure,
            kind: .transport,
            expecting: targetIsPlaying,
            local: targetIsPlaying ? .resume : .pause,
            remote: targetIsPlaying ? .resume : .pause
        ) { [weak self] accepted in
            guard let self else { return }
            if accepted {
                self.refreshPosition()
            } else {
                self.setTransport(previousIsPlaying ? .playing : .paused)
            }
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
        setTiming(position: TimeInterval(milliseconds) / 1_000)
        performRoutedCommand(
            "Seek was rejected",
            kind: .seek,
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
