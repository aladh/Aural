//
//  PlaybackStore+Queue.swift
//  Aural
//
//  Queue commands, refresh, and provenance-aware presentation.
//

import AuralDomain
import Foundation
import OSLog

extension PlaybackStore {
    // MARK: - Queue panel

    /// Appends a track to the play queue, as the official client's context menu does.
    ///
    /// Deliberately not routed through `performCommand`: queue adds are independent of
    /// transport state, and serializing them behind the pending flag would silently
    /// drop a second quick add.
    func addToQueue(uri: String) {
        guard canStartPlayback else {
            showTransientCommandError("Connect Spotify before adding to the queue.")
            return
        }

        switch commandRoute {
        case .waitingForLocalIdentity:
            showTransientCommandError("Aural is still joining Spotify Connect.")
            return
        case let .remote(from, to):
            let effectID = PlaybackEffectID.queueCommand(UUID())
            let epoch = accountEpoch
            effects.replace(effectID, with: Task { [weak self] in
                defer { self?.effects.complete(effectID) }
                do {
                    guard let self else { return }
                    try await self.coordinator.performRemote(.addToQueue(uri), from: from, to: to)
                    guard !Task.isCancelled, self.accountEpoch == epoch, self.isConnected else { return }
                } catch {
                    guard let self, !Task.isCancelled, self.accountEpoch == epoch, self.isConnected else { return }
                    self.showTransientCommandError("Could not add that track to the queue.")
                }
            })
            return
        case .local:
            break
        }

        let effectID = PlaybackEffectID.queueCommand(UUID())
        let epoch = accountEpoch
        effects.replace(effectID, with: Task { [weak self] in
            defer { self?.effects.complete(effectID) }
            guard let self else { return }
            let result = await self.coordinator.performLocal(.addToQueue(uri))
            guard !Task.isCancelled, self.accountEpoch == epoch, self.isConnected else { return }
            if !result.isOK {
                self.showTransientCommandError("Could not add that track to the queue.")
            }
        })
    }

    /// Pulls the backend's last-known queue so the panel opens with content even
    /// before the next cluster update streams in.
    func refreshQueueSnapshot() {
        let epoch = accountEpoch
        effects.replace(.queueSnapshot, with: Task { [weak self] in
            guard let self,
                  let json = await self.coordinator.queueSnapshotJSON(),
                  !Task.isCancelled,
                  self.accountEpoch == epoch,
                  self.isConnected,
                  let data = json.data(using: .utf8),
                  let state = try? JSONDecoder().decode(RustQueueState.self, from: data)
            else { return }
            guard self.acceptsEngineEvent(
                generation: state.sessionGeneration,
                revision: state.revision,
                source: .engineQueue
            ) else { return }
            self.receive(state, revision: state.revision, mayAdoptPlaybackIdentity: false)
        })
    }

    /// Refreshes the cross-device queue without changing playback.
    ///
    /// The documented Web API response is preferred because it carries both exact ordering and
    /// metadata. Spotify currently rate-limits its desktop client grant at api.spotify.com, so a
    /// failed attempt falls back to the already-synchronized Connect queue and hydrates its uris
    /// through spclient in small batches.
    func refreshQueue() {
        guard isConnected else { return }
        refreshQueueSnapshot()
        catalog.metadata.retainTracks(from: .queue, for: Set(queueNextEntries.map(\.uri) + [trackURI]))
        let cachedTracks = queueNextEntries.compactMap { catalog.metadata.knownTrack(for: $0.uri) }
        effects.replace(.queueRefresh, with: Task { [weak self] in
            guard let self else { return }
            let epoch = self.accountEpoch
            guard let snapshot = await self.queueService.refresh(
                fallbackEntries: self.queueNextEntries,
                cachedTracks: cachedTracks,
                currentTrackURI: self.trackURI.isEmpty ? nil : self.trackURI,
                accountEpoch: epoch,
                onUpdate: { [weak self] update in
                    guard let self, !Task.isCancelled,
                          self.isConnected, self.accountEpoch == epoch else { return }
                    self.apply(update)
                }
            ), !Task.isCancelled, self.isConnected, self.accountEpoch == epoch else { return }
            self.apply(snapshot)
        })
    }

    func cancelQueueRefresh() {
        effects.cancel(.queueRefresh)
        effects.cancel(.queueSnapshot)
    }

    func apply(_ snapshot: ProvenanceQueueSnapshot) {
        var retainedURIs = Set(snapshot.entries.map(\.uri))
        if let contextURI = snapshot.contextURI { retainedURIs.insert(contextURI) }
        catalog.metadata.retainTracks(from: .queue, for: retainedURIs)
        send(
            .queue(PlaybackQueueSnapshot(
                entries: snapshot.entries.map {
                    PlaybackQueueItem(id: $0.id, uri: $0.uri, provider: $0.provider)
                },
                source: snapshot.source,
                completeness: snapshot.completeness,
                revision: snapshot.revision,
                receivedAt: snapshot.receivedAt,
                contextURI: snapshot.contextURI
            )),
            source: .engineQueue,
            revision: snapshot.revision,
            receivedAt: snapshot.receivedAt
        )
        catalog.metadata.replaceTracks(snapshot.tracks, from: .queue)
    }

}
