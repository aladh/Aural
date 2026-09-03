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
            guard
                acceptsConnectQueueCallback(
                    generation: state.sessionGeneration,
                    revision: state.revision
                )
            else { return }
            receive(state, revision: state.revision, engineEpoch: state.sessionGeneration)
        case let .connection(state):
            receive(state, revision: state.revision, receivedAt: envelope.receivedAt)
        case let .devices(state):
            receive(
                ConnectDeviceProjection.devices(
                    from: state.devices,
                    activeDeviceID: state.activeDeviceID
                ),
                revision: state.revision,
                engineEpoch: state.sessionGeneration
            )
        }
    }

    /// MainActor dedupe for Connect queue *callbacks*. Records generation and revision together
    /// and does not adopt `engineGeneration`.
    func acceptsConnectQueueCallback(generation: UInt64?, revision: UInt64?) -> Bool {
        guard !isTearingDown else { return false }
        return connectQueueCallback.accept(
            generation: generation,
            revision: revision,
            engineEpoch: engineGeneration
        )
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
        let transport: PlaybackTransportState =
            (snapshotIsPlaying && !(isInitialSnapshot && isActiveDevice))
            ? .playing : (state.trackURI.isEmpty ? .stopped : .paused)
        let snapshotPosition = playbackSnapshotPosition(
            positionMilliseconds: state.positionMS,
            durationMilliseconds: state.durationMS,
            timestampMilliseconds: state.timestampMS,
            isPlaying: transport == .playing,
            now: receivedAt
        )
        let flags = RepeatFlags(
            context: state.repeatContext ?? self.state.options.repeatFlags.context,
            track: state.repeatTrack ?? self.state.options.repeatFlags.track
        )
        let repeatSnapshot = RepeatMode(context: flags.context, track: flags.track)
        let accepted = send(
            .enginePlayback(
                EnginePlaybackSnapshot(
                    transport: transport,
                    trackURI: state.trackURI.isEmpty ? nil : state.trackURI,
                    timing: PlaybackTiming(
                        position: snapshotPosition,
                        duration: TimeInterval(max(0, state.durationMS)) / 1_000,
                        anchoredAt: receivedAt
                    ),
                    shuffle: state.shuffle,
                    repeatMode: repeatSnapshot,
                    repeatFlags: flags
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
        mayAdoptPlaybackIdentity: Bool = true,
        accountEpoch capturedAccountEpoch: UInt64? = nil,
        engineEpoch capturedEngineEpoch: UInt64? = nil
    ) {
        guard !isTearingDown else { return }
        let protocolNext = (state.protocolNextTracks ?? []).map { $0.domainTrack() }
        let protocolPrev = (state.protocolPrevTracks ?? []).map { $0.domainTrack() }
        let entries = QueueProtocolProjection.upcomingEntries(from: protocolNext)
        let epoch = capturedAccountEpoch ?? accountEpoch
        // Stamp from the payload generation. `engineGeneration` is only a fallback when the
        // snapshot omitted `sessionGeneration`; it must not override a newer decoded epoch.
        let engineEpoch = capturedEngineEpoch ?? state.sessionGeneration ?? engineGeneration
        effects.replace(
            .connectQueueAccept,
            with: Task { [weak self] in
                guard let self else { return }
                let accepted = await self.queueService.acceptConnect(
                    entries,
                    accountEpoch: epoch,
                    sourceRevision: revision,
                    contextURI: state.track?.uri ?? self.trackURI,
                    provisional: state.track == nil && entries.isEmpty,
                    engineEpoch: engineEpoch,
                    protocolNext: protocolNext,
                    protocolPrev: protocolPrev,
                    queueRevision: state.queueRevision ?? "",
                    disallowSetQueue: state.disallowSetQueue ?? false,
                    disallowRemovingFromNextTracks: state.disallowRemovingFromNextTracks ?? false
                )
                guard !Task.isCancelled, !self.isTearingDown else { return }
                guard self.accountEpoch == epoch, self.engineGeneration <= engineEpoch else { return }
                guard let accepted else { return }
                let previousOrdering = self.state.queue.entries.map(\.uri)
                self.queueMutation = accepted.mutation
                guard self.apply(accepted.snapshot, engineEpoch: engineEpoch) else { return }
                if self.state.queue.entries.map(\.uri) != previousOrdering {
                    self.queueInspectorOrderingVersion &+= 1
                }
            })

        guard let track = state.track, QueueProtocolProjection.isPlayableTrackURI(track.uri) else {
            return
        }
        if !mayAdoptPlaybackIdentity {
            guard
                queueBootstrapMetadataURI(
                    snapshotTrackURI: track.uri,
                    currentTrackURI: self.state.currentTrack?.uri
                ) != nil
            else { return }
        }

        let changedTrack = track.uri != trackURI
        let name = track.name ?? ""
        let artist = track.artist ?? ""
        let imageURL = track.imageURL ?? ""
        let durationMS = track.durationMS ?? 0

        if !name.isEmpty || !artist.isEmpty || !imageURL.isEmpty {
            // A check fixture or older snapshot supplied labels; production Connect
            // queue rows do not. Catalog enrichment is the live metadata owner.
            let trackDuration =
                durationMS > 0
                ? TimeInterval(durationMS) / 1_000
                : duration
            let current = CurrentTrack(
                uri: track.uri,
                title: name.isEmpty ? nil : name,
                artist: artist.isEmpty ? nil : artist,
                artworkURL: imageURL.isEmpty ? nil : URL(string: imageURL),
                duration: trackDuration,
                metadataSource: .engine
            )
            let accepted = setPresentation(
                track: current,
                timing: PlaybackTiming(
                    position: changedTrack ? 0 : position,
                    duration: trackDuration,
                    anchoredAt: environment.clock.now()
                ),
                source: .engineQueue,
                accountEpoch: epoch,
                engineEpoch: engineEpoch
            )
            if accepted {
                history.applyMetadata(
                    uri: track.uri,
                    title: name,
                    artist: artist,
                    artworkURL: imageURL.isEmpty ? nil : URL(string: imageURL)
                )
            }
        } else if changedTrack || !hasCurrentTrackMetadata {
            // Cluster updates deliberately ship uris without names; resolve against
            // whatever the catalog already loaded so the bar never stays blank.
            if changedTrack {
                let accepted = setPresentation(
                    track: CurrentTrack(uri: track.uri),
                    timing: PlaybackTiming(anchoredAt: environment.clock.now()),
                    source: .engineQueue,
                    accountEpoch: epoch,
                    engineEpoch: engineEpoch
                )
                guard accepted else { return }
            }
            adoptTrackMetadata(
                for: track.uri,
                accountEpoch: epoch,
                engineEpoch: engineEpoch
            )
        }
    }

    /// Fills the now-playing fields for an adopted uri from what the catalog already holds.
    ///
    /// The backend ships playback-state and queue updates **without names on purpose** —
    /// resolving them was the old Web API's job. Until a resolver exists again, the loaded
    /// catalog is the source: without this, any start that bypasses a track row (grid cards,
    /// remote starts, cold context plays) plays audio into a bar that still reads
    /// "Nothing playing" and never flips its transport.
    private func adoptTrackMetadata(
        for uri: String,
        force: Bool = false,
        accountEpoch: UInt64? = nil,
        engineEpoch: UInt64? = nil
    ) {
        if !force, hasCurrentTrackMetadata { return }

        if let track = catalog.metadata.knownTrack(for: uri) {
            let accepted = setTrackMetadata(
                uri: uri,
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL,
                duration: track.duration > 0 ? track.duration : duration,
                provenance: .catalog,
                accountEpoch: accountEpoch,
                engineEpoch: engineEpoch
            )
            guard accepted else { return }
            effects.cancel(.trackMetadata)
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
        let accepted = setTrackMetadata(
            uri: uri,
            title: nil,
            artist: nil,
            artworkURL: nil,
            duration: duration,
            provenance: .none,
            accountEpoch: accountEpoch,
            engineEpoch: engineEpoch
        )
        guard accepted else { return }
        resolveTrackMetadata(for: uri, accountEpoch: accountEpoch, engineEpoch: engineEpoch)
    }

    private func resolveTrackMetadata(
        for uri: String,
        accountEpoch: UInt64? = nil,
        engineEpoch: UInt64? = nil
    ) {
        let epoch = accountEpoch ?? self.accountEpoch
        let capturedEngineEpoch = engineEpoch ?? engineGeneration
        effects.replace(
            .trackMetadata,
            with: Task { [weak self] in
                do {
                    guard let self else { return }
                    let metadata = try await self.coordinator.metadata(for: uri)
                    guard !Task.isCancelled, !self.isTearingDown else { return }
                    let accepted = self.setTrackMetadata(
                        uri: uri,
                        title: metadata.title,
                        artist: metadata.artist,
                        artworkURL: metadata.artworkURL,
                        duration: metadata.duration > 0 ? metadata.duration : self.duration,
                        provenance: .connect,
                        accountEpoch: epoch,
                        engineEpoch: capturedEngineEpoch
                    )
                    guard accepted else { return }
                    self.history.applyMetadata(
                        uri: uri,
                        title: metadata.title,
                        artist: metadata.artist,
                        artworkURL: metadata.artworkURL
                    )
                } catch {
                    guard !Task.isCancelled, self?.isTearingDown == false else { return }
                    debugLog(
                        "SpotifyConnectAPI", "Track metadata resolution failed: \(String(describing: type(of: error)))")
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
            revision: revision,
            lastRemoteDeviceID: lastRemoteDeviceID
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
            .engineConnection(
                EngineConnectionSnapshot(
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
