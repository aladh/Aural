//
//  PlaybackStore+EngineEvents.swift
//  Aural
//
//  Ordered engine event intake and metadata reconciliation.
//

import AuralDomain
import Foundation
import OSLog

extension PlaybackStore {
    /// Single ordered intake for every control callback from the embedded engine. Events from an
    /// obsolete engine generation or an older source revision are discarded before they can
    /// mutate presentation state.
    func receive(_ envelope: RustPlaybackEventEnvelope) {
        guard envelope.sequence > lastEngineEventSequence else { return }
        lastEngineEventSequence = envelope.sequence
        // Teardown must win before any ordered-source gate. Recording a revision here and then
        // bailing in `receive` would consume a snapshot the reducer never accepted.
        guard !isTearingDown else { return }

        switch envelope.event {
        case let .playback(state):
            receive(state, revision: state.revision, receivedAt: envelope.receivedAt)
        case let .queue(state):
            guard acceptsConnectQueueCallback(
                generation: state.sessionGeneration,
                revision: state.revision
            ) else { return }
            receive(state, revision: state.revision)
        case let .connection(state):
            receive(state, revision: state.revision, receivedAt: envelope.receivedAt)
        case let .devices(state):
            receive(
                state.devices,
                revision: state.revision,
                engineEpoch: state.sessionGeneration
            )
        }
    }

    /// MainActor dedupe for Connect queue *callbacks*. Does not adopt `engineGeneration`; that
    /// mirror moves only after a successful `reduce`.
    func acceptsConnectQueueCallback(generation: UInt64?, revision: UInt64?) -> Bool {
        guard !isTearingDown else { return false }
        if let generation {
            guard generation >= engineGeneration else { return false }
            if generation > engineGeneration {
                lastQueueRevision = 0
            }
        }
        if let revision {
            guard revision > lastQueueRevision else { return false }
            lastQueueRevision = revision
        }
        return true
    }

    func present(_ track: CatalogTrack) {
        setPresentation(
            track: CurrentTrack(
                uri: track.uri,
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL,
                duration: track.duration,
                metadataSource: .catalog
            ),
            timing: PlaybackTiming(position: 0, duration: track.duration, anchoredAt: environment.clock.now()),
            source: .user
        )
    }

    func receive(_ state: RustPlaybackState, revision: UInt64?, receivedAt: Date) {
        guard !isTearingDown else { return }
        let isInitialSnapshot = !hasReceivedPlaybackSnapshot
        let previousTrackURI = trackURI
        let snapshotIsPlaying = state.isPlaying && !(state.isPaused ?? false)
        let transport: PlaybackTransportState = (
            snapshotIsPlaying && !(isInitialSnapshot && isActiveDevice)
        ) ? .playing : (state.trackURI.isEmpty ? .stopped : .paused)
        let snapshotPosition = playbackSnapshotPosition(
            positionMilliseconds: state.positionMS,
            durationMilliseconds: state.durationMS,
            timestampMilliseconds: state.timestampMS,
            isPlaying: transport == .playing,
            now: receivedAt
        )
        let repeatSnapshot = RepeatMode(
            context: state.repeatContext ?? repeatMode.flags.context,
            track: state.repeatTrack ?? repeatMode.flags.track
        )
        let accepted = send(
            .enginePlayback(EnginePlaybackSnapshot(
                transport: transport,
                trackURI: state.trackURI.isEmpty ? nil : state.trackURI,
                timing: PlaybackTiming(
                    position: snapshotPosition,
                    duration: TimeInterval(max(0, state.durationMS)) / 1_000,
                    anchoredAt: receivedAt
                ),
                shuffle: state.shuffle,
                repeatMode: repeatSnapshot
            )),
            source: .enginePlayback,
            revision: revision,
            engineEpoch: state.sessionGeneration,
            receivedAt: receivedAt
        )
        guard accepted else { return }
        hasReceivedPlaybackSnapshot = true

        if !state.trackURI.isEmpty, state.trackURI != previousTrackURI {
            adoptTrackMetadata(for: state.trackURI, force: true)
        } else if state.trackURI.isEmpty {
            effects.cancel(.trackMetadata)
        }

        // A later cluster update can start Aural remotely. Count that transition, but never turn
        // the initial account snapshot into fresh listening history merely because the app opened.
        if !isInitialSnapshot,
           isActiveDevice,
           transport == .playing,
           !state.trackURI.isEmpty,
           state.trackURI != previousTrackURI
        {
            recordPlayed(state.trackURI)
        }
    }

    func receive(
        _ state: RustQueueState,
        revision: UInt64?,
        mayAdoptPlaybackIdentity: Bool = true
    ) {
        guard !isTearingDown else { return }
        let nextTracks = state.nextTracks ?? []
        let entries = nextTracks.enumerated().map { index, item in
            QueueEntry(uri: item.uri, provider: item.provider, occurrence: index)
        }
        let epoch = accountEpoch
        Task { [weak self] in
            guard let self,
                  let snapshot = await self.queueService.acceptConnect(
                    entries,
                    accountEpoch: epoch,
                    sourceRevision: revision,
                    contextURI: state.track?.uri ?? self.trackURI,
                    provisional: state.track == nil && entries.isEmpty
                  ), self.accountEpoch == epoch
            else { return }
            self.apply(snapshot)
        }

        guard let track = state.track else { return }
        if !mayAdoptPlaybackIdentity {
            guard queueBootstrapMetadataURI(
                snapshotTrackURI: track.uri,
                currentTrackURI: self.state.currentTrack?.uri
            ) != nil else { return }
        }

        let changedTrack = track.uri != trackURI

        if !track.name.isEmpty || !track.artist.isEmpty || !track.imageURL.isEmpty {
            // The backend supplied real metadata for this track.
            let trackDuration = track.durationMS > 0
                ? TimeInterval(track.durationMS) / 1_000
                : duration
            let current = CurrentTrack(
                uri: track.uri,
                title: track.name.isEmpty ? nil : track.name,
                artist: track.artist.isEmpty ? nil : track.artist,
                artworkURL: track.imageURL.isEmpty ? nil : URL(string: track.imageURL),
                duration: trackDuration,
                metadataSource: .engine
            )
            setPresentation(
                track: current,
                timing: PlaybackTiming(
                    position: changedTrack ? 0 : position,
                    duration: trackDuration,
                    anchoredAt: environment.clock.now()
                ),
                source: .engineQueue
            )
            history.applyMetadata(
                uri: track.uri,
                title: track.name,
                artist: track.artist,
                artworkURL: URL(string: track.imageURL)
            )
        } else if changedTrack || !hasCurrentTrackMetadata {
            // Cluster updates deliberately ship uris without names; resolve against
            // whatever the catalog already loaded so the bar never stays blank.
            if changedTrack {
                setPresentation(
                    track: CurrentTrack(uri: track.uri),
                    timing: PlaybackTiming(anchoredAt: environment.clock.now()),
                    source: .engineQueue
                )
            }
            adoptTrackMetadata(for: track.uri)
        }
    }

    /// Fills the now-playing fields for an adopted uri from what the catalog already holds.
    ///
    /// The backend ships playback-state and queue updates **without names on purpose** —
    /// resolving them was the old Web API's job. Until a resolver exists again, the loaded
    /// catalog is the source: without this, any start that bypasses a track row (grid cards,
    /// remote starts, cold context plays) plays audio into a bar that still reads
    /// "Nothing playing" and never flips its transport.
    private func adoptTrackMetadata(for uri: String, force: Bool = false) {
        if !force, hasCurrentTrackMetadata { return }

        if let track = catalog.metadata.knownTrack(for: uri) {
            effects.cancel(.trackMetadata)
            setTrackMetadata(
                uri: uri,
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL,
                duration: track.duration > 0 ? track.duration : duration,
                provenance: .catalog
            )
            history.applyMetadata(
                uri: uri,
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL
            )
            return
        }

        // A URI is not metadata. Keep the transport context internally, but leave the UI in its
        // neutral state until either the queue callback or a loaded catalog supplies real names.
        setTrackMetadata(
            uri: uri,
            title: nil,
            artist: nil,
            artworkURL: nil,
            duration: duration,
            provenance: .none
        )
        resolveTrackMetadata(for: uri)
    }

    private func resolveTrackMetadata(for uri: String) {
        let epoch = accountEpoch
        effects.replace(.trackMetadata, with: Task { [weak self] in
            do {
                guard let self else { return }
                let metadata = try await self.coordinator.metadata(for: uri)
                guard !Task.isCancelled, self.accountEpoch == epoch,
                      self.isConnected, self.trackURI == uri else { return }
                self.setTrackMetadata(
                    uri: uri,
                    title: metadata.title,
                    artist: metadata.artist,
                    artworkURL: metadata.artworkURL,
                    duration: metadata.duration > 0 ? metadata.duration : self.duration,
                    provenance: .connect
                )
                self.history.applyMetadata(
                    uri: uri,
                    title: metadata.title,
                    artist: metadata.artist,
                    artworkURL: metadata.artworkURL
                )
            } catch {
                guard !Task.isCancelled, self?.accountEpoch == epoch else { return }
                debugLog("SpotifyConnectAPI", "Track metadata resolution failed: \(String(describing: type(of: error)))")
            }
        })
    }

    func receive(_ devices: [ConnectDevice], revision: UInt64, engineEpoch: UInt64) {
        guard !isTearingDown else { return }
        let snapshot = PlaybackDeviceSnapshot(
            devices: devices.map {
                PlaybackDevice(id: $0.id, name: $0.name, type: $0.type, isActive: $0.isActive)
            },
            localDeviceID: localDeviceID,
            revision: revision
        )
        let accepted = send(
            .devices(snapshot),
            source: .engineDevices,
            revision: revision,
            engineEpoch: engineEpoch
        )
        guard accepted else { return }
        if let remote = devices.first(where: { $0.isActive && $0.id != localDeviceID }) {
            lastRemoteDeviceID = remote.id
            Task { await environment.preferences.setLastRemoteDeviceID(remote.id) }
        }
    }

    func receive(_ state: RustConnectionState, revision: UInt64?, receivedAt: Date) {
        guard !isTearingDown else { return }
        let resolvedLocalID = state.deviceID.flatMap { $0.isEmpty ? nil : $0 } ?? localDeviceID
        let resolvedDeviceName: String
        if let name = state.deviceName, !name.isEmpty {
            resolvedDeviceName = name
        } else {
            resolvedDeviceName = thisDeviceName
        }
        let owner = connectionPlaybackOwner(
            isLocalActive: state.isActiveDevice,
            localDeviceID: resolvedLocalID,
            localDeviceName: resolvedDeviceName,
            devices: self.state.devices.devices,
            currentTrackURI: self.state.currentTrack?.uri,
            previousOwner: self.state.owner,
            lastRemoteDeviceID: lastRemoteDeviceID
        )
        let session: PlaybackSessionPhase?
        if state.sessionConnected, state.spircReady {
            session = .ready
        } else if let error = state.lastError, !error.isEmpty {
            session = .failed(error)
        } else {
            session = nil
        }
        let accepted = send(
            .engineConnection(EngineConnectionSnapshot(
                session: session,
                owner: owner,
                localDeviceID: resolvedLocalID
            )),
            source: .engineConnection,
            revision: revision,
            engineEpoch: state.sessionGeneration,
            receivedAt: receivedAt
        )
        guard accepted else { return }
        thisDeviceName = resolvedDeviceName
        accountStore.receiveEngineConnection(
            connected: state.sessionConnected,
            ready: state.spircReady,
            error: state.lastError
        )
    }

}
