import AuralDomain
import Foundation
import OSLog

typealias QueueSnapshotSource = PlaybackQueueSource
typealias QueueSnapshotCompleteness = PlaybackQueueCompleteness

nonisolated struct ProvenanceQueueSnapshot: Sendable {
    let accountEpoch: UInt64
    let revision: UInt64
    let source: QueueSnapshotSource
    let completeness: QueueSnapshotCompleteness
    let receivedAt: Date
    let contextURI: String?
    let entries: [QueueEntry]
    let tracks: [CatalogTrack]
}

/// Pure precedence policy. A lower-quality or older snapshot cannot erase a more authoritative
/// queue; metadata from either snapshot can still enrich the retained ordering.
nonisolated func mergeQueueSnapshots(
    current: ProvenanceQueueSnapshot?,
    incoming: ProvenanceQueueSnapshot
) -> ProvenanceQueueSnapshot {
    guard let current, current.accountEpoch == incoming.accountEpoch else { return incoming }
    let ordering = mergePlaybackQueueSnapshots(
        current: current.domainSnapshot,
        incoming: incoming.domainSnapshot
    )
    var retainedURIs = Set(ordering.entries.map(\.uri))
    if let contextURI = ordering.contextURI { retainedURIs.insert(contextURI) }
    let metadata = Dictionary(
        (current.tracks + incoming.tracks)
            .lazy
            .filter { retainedURIs.contains($0.uri) }
            .map { ($0.uri, $0) },
        uniquingKeysWith: { _, newer in newer }
    )
    return ProvenanceQueueSnapshot(
        accountEpoch: current.accountEpoch,
        revision: ordering.revision,
        source: ordering.source,
        completeness: ordering.completeness,
        receivedAt: ordering.receivedAt,
        contextURI: ordering.contextURI,
        entries: ordering.entries.enumerated().map { index, item in
            let preservedUID: String
            if !item.uid.isEmpty {
                preservedUID = item.uid
            } else if let current,
                      current.entries.indices.contains(index),
                      current.entries[index].uri == item.uri
            {
                preservedUID = current.entries[index].uid
            } else {
                preservedUID = ""
            }
            return QueueEntry(
                uri: item.uri,
                provider: item.provider,
                occurrence: queueOccurrence(item.id),
                uid: preservedUID
            )
        },
        tracks: Array(metadata.values)
    )
}

private extension ProvenanceQueueSnapshot {
    var domainSnapshot: PlaybackQueueSnapshot {
        PlaybackQueueSnapshot(
            entries: entries.map { PlaybackQueueItem($0) },
            source: source,
            completeness: completeness,
            revision: revision,
            receivedAt: receivedAt,
            contextURI: contextURI
        )
    }
}

private nonisolated func queueOccurrence(_ id: String) -> Int {
    id.split(separator: "-", maxSplits: 1).first.flatMap { Int($0) } ?? 0
}

actor QueueService {
    private enum WebCapability {
        case unknown
        case available
        case unavailable
    }

    private let webQueue: any WebQueueClient
    private let metadata: TrackMetadataService
    private let clock: any PlaybackClock
    private var accountEpoch: UInt64 = 0
    private var revision: UInt64 = 0
    private var lastConnectSourceRevision: UInt64 = 0
    private var contextURI: String?
    private var webCapability = WebCapability.unknown
    private var webRetryNotBefore: Date?
    private var snapshot: ProvenanceQueueSnapshot?
    private var mutation: QueueMutationSnapshot?

    init(
        webQueue: any WebQueueClient,
        metadata: TrackMetadataService,
        clock: any PlaybackClock = SystemPlaybackClock()
    ) {
        self.webQueue = webQueue
        self.metadata = metadata
        self.clock = clock
    }

    func reset(accountEpoch: UInt64) async {
        self.accountEpoch = accountEpoch
        revision = 0
        lastConnectSourceRevision = 0
        contextURI = nil
        webCapability = .unknown
        webRetryNotBefore = nil
        snapshot = nil
        mutation = nil
        await metadata.reset()
    }

    func mutationSnapshot() -> QueueMutationSnapshot? { mutation }

    func acceptConnect(
        _ entries: [QueueEntry],
        accountEpoch requestedEpoch: UInt64,
        sourceRevision: UInt64? = nil,
        contextURI incomingContextURI: String?,
        provisional: Bool = false,
        engineEpoch: UInt64 = 0,
        protocolNext: [QueueProtocolTrack] = [],
        protocolPrev: [QueueProtocolTrack] = [],
        queueRevision: String = "",
        disallowSetQueue: Bool = false,
        disallowRemovingFromNextTracks: Bool = false
    ) -> ProvenanceQueueSnapshot? {
        guard requestedEpoch == accountEpoch else { return nil }
        if let sourceRevision {
            guard sourceRevision > lastConnectSourceRevision else { return snapshot }
            lastConnectSourceRevision = sourceRevision
            revision = max(revision, sourceRevision)
        } else {
            revision &+= 1
        }
        contextURI = incomingContextURI
        let incoming = ProvenanceQueueSnapshot(
            accountEpoch: accountEpoch,
            revision: revision,
            source: provisional ? .provisional : .connect,
            completeness: entries.isEmpty && provisional ? .partial : .complete,
            receivedAt: clock.now(),
            contextURI: incomingContextURI,
            entries: entries,
            tracks: []
        )
        snapshot = mergeQueueSnapshots(current: snapshot, incoming: incoming)
        mutation = QueueMutationSnapshot(
            accountEpoch: accountEpoch,
            engineEpoch: engineEpoch,
            sourceRevision: sourceRevision ?? revision,
            source: provisional ? .provisional : .connect,
            completeness: protocolNext.isEmpty && !entries.isEmpty ? .partial : (provisional ? .partial : .complete),
            provisional: provisional,
            next: protocolNext,
            prev: protocolPrev,
            queueRevision: queueRevision,
            disallowSetQueue: disallowSetQueue,
            disallowRemovingFromNextTracks: disallowRemovingFromNextTracks
        )
        return snapshot
    }

    func refresh(
        fallbackEntries: [QueueEntry],
        cachedTracks: [CatalogTrack] = [],
        currentTrackURI: String?,
        accountEpoch requestedEpoch: UInt64,
        onUpdate: @escaping @MainActor @Sendable (ProvenanceQueueSnapshot) async -> Void = { _ in }
    ) async -> ProvenanceQueueSnapshot? {
        let interval = AuralLog.queueSignposter.beginInterval("Queue refresh")
        defer { AuralLog.queueSignposter.endInterval("Queue refresh", interval) }
        guard requestedEpoch == accountEpoch else { return nil }
        contextURI = currentTrackURI
        let requestedContext = currentTrackURI

        if shouldRequestWebQueue {
            do {
                let tracks = try await webQueue.queue()
                guard requestedEpoch == accountEpoch, requestedContext == contextURI else { return nil }
                webCapability = .available
                webRetryNotBefore = nil
                revision &+= 1
                let incoming = ProvenanceQueueSnapshot(
                    accountEpoch: accountEpoch,
                    revision: revision,
                    source: .webAPI,
                    completeness: .complete,
                    receivedAt: clock.now(),
                    contextURI: requestedContext,
                    entries: tracks.enumerated().map {
                        QueueEntry(uri: $0.element.uri, provider: "web-api", occurrence: $0.offset)
                    },
                    tracks: tracks
                )
                snapshot = mergeQueueSnapshots(current: snapshot, incoming: incoming)
                AuralLog.queue.info(
                    "Queue refreshed from Web API; entries=\(tracks.count, privacy: .public); epoch=\(requestedEpoch, privacy: .public)"
                )
                if let snapshot { await onUpdate(snapshot) }
                return snapshot
            } catch let error as SpotifyWebPlayerAPIError {
                let status = error.statusCode
                if [401, 403].contains(status ?? 0) {
                    webCapability = .unavailable
                } else if status == 429 {
                    // The desktop-client grant is commonly rate-limited at this documented Web
                    // endpoint. Fall back immediately, then avoid hammering it every time the
                    // inspector opens; a new account resets the cooldown.
                    webRetryNotBefore = clock.now().addingTimeInterval(5 * 60)
                }
                debugLog(
                    "QueueService",
                    "Web queue unavailable; HTTP=\(status.map(String.init) ?? "unknown"); using Connect fallback"
                )
            } catch {
                debugLog(
                    "QueueService",
                    "Web queue unavailable; error=\(String(describing: type(of: error))); using Connect fallback"
                )
            }
        }

        let wantedURIs = uniqueTrackURIs(in: fallbackEntries)
        let wantedSet = Set(wantedURIs)
        var hydrated = Dictionary(
            cachedTracks.lazy.filter { wantedSet.contains($0.uri) }.map { ($0.uri, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        guard let initial = updateFallbackSnapshot(
            entries: fallbackEntries,
            tracks: Array(hydrated.values),
            wantedCount: wantedURIs.count,
            requestedEpoch: requestedEpoch,
            requestedContext: requestedContext
        ) else { return nil }
        AuralLog.queue.info(
            "Queue fallback started; entries=\(fallbackEntries.count, privacy: .public); cached=\(hydrated.count, privacy: .public); epoch=\(requestedEpoch, privacy: .public)"
        )
        await onUpdate(initial)

        let missing = wantedURIs.filter { hydrated[$0] == nil }
        guard !missing.isEmpty else { return snapshot }
        let hydrationInterval = AuralLog.queueSignposter.beginInterval("Queue metadata hydration")
        defer { AuralLog.queueSignposter.endInterval("Queue metadata hydration", hydrationInterval) }
        let maximumConcurrentRequests = 8
        await withTaskGroup(of: SpotifyConnectTrackMetadata?.self) { group in
            var iterator = missing.makeIterator()
            for _ in 0 ..< min(maximumConcurrentRequests, missing.count) {
                guard let uri = iterator.next() else { break }
                group.addTask { [metadata] in try? await metadata.metadata(for: uri) }
            }

            while let value = await group.next() {
                guard !Task.isCancelled,
                      requestedEpoch == accountEpoch,
                      requestedContext == contextURI
                else {
                    group.cancelAll()
                    return
                }
                if let value {
                    hydrated[value.uri] = Self.catalogTrack(from: value)
                    if let update = updateFallbackSnapshot(
                        entries: fallbackEntries,
                        tracks: Array(hydrated.values),
                        wantedCount: wantedURIs.count,
                        requestedEpoch: requestedEpoch,
                        requestedContext: requestedContext
                    ) {
                        await onUpdate(update)
                    }
                }
                if let uri = iterator.next() {
                    group.addTask { [metadata] in try? await metadata.metadata(for: uri) }
                }
            }
        }
        AuralLog.queue.info(
            "Queue fallback finished; hydrated=\(hydrated.count, privacy: .public)/\(wantedURIs.count, privacy: .public); epoch=\(requestedEpoch, privacy: .public)"
        )
        return snapshot
    }

    private func uniqueTrackURIs(in entries: [QueueEntry]) -> [String] {
        var seen: Set<String> = []
        return entries.compactMap { entry in
            guard entry.uri.hasPrefix("spotify:track:"), seen.insert(entry.uri).inserted else {
                return nil
            }
            return entry.uri
        }
    }

    private func updateFallbackSnapshot(
        entries: [QueueEntry],
        tracks: [CatalogTrack],
        wantedCount: Int,
        requestedEpoch: UInt64,
        requestedContext: String?
    ) -> ProvenanceQueueSnapshot? {
        guard requestedEpoch == accountEpoch, requestedContext == contextURI else { return nil }
        revision &+= 1
        let incoming = ProvenanceQueueSnapshot(
            accountEpoch: accountEpoch,
            revision: revision,
            source: .connect,
            completeness: tracks.count == wantedCount ? .complete : .partial,
            receivedAt: clock.now(),
            contextURI: requestedContext,
            entries: entries,
            tracks: tracks
        )
        snapshot = mergeQueueSnapshots(current: snapshot, incoming: incoming)
        return snapshot
    }

    private static func catalogTrack(from metadata: SpotifyConnectTrackMetadata) -> CatalogTrack {
        CatalogTrack(
            id: metadata.uri,
            uri: metadata.uri,
            title: metadata.title,
            artist: metadata.artist,
            album: "",
            duration: metadata.duration,
            artworkURL: metadata.artworkURL,
            addedAt: nil
        )
    }

    private var shouldRequestWebQueue: Bool {
        guard webCapability != .unavailable else { return false }
        guard let webRetryNotBefore else { return true }
        return clock.now() >= webRetryNotBefore
    }
}
