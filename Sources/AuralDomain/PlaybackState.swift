import Foundation

public enum PlaybackSessionPhase: Equatable, Sendable {
    case signedOut
    case authorizing
    case connecting
    case ready
    case recovering
    case failed(String)
}

public struct PlaybackDevice: Equatable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let isActive: Bool

    public init(id: String, name: String, type: String, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.isActive = isActive
    }
}

public enum PlaybackOwner: Equatable, Sendable {
    case none
    case local(PlaybackDevice)
    case remote(PlaybackDevice)
    case uncertain(PlaybackDevice?)
}

/// Resolves a connection callback without making metadata availability part of playback
/// ownership. A URI is sufficient evidence that playback exists; labels and artwork may arrive
/// later without changing where transport commands must be routed.
public func connectionPlaybackOwner(
    isLocalActive: Bool,
    localDeviceID: String?,
    localDeviceName: String,
    devices: [PlaybackDevice],
    currentTrackURI: String?,
    previousOwner: PlaybackOwner,
    lastRemoteDeviceID: String?
) -> PlaybackOwner {
    if isLocalActive {
        let local = devices.first { $0.id == localDeviceID }
            ?? PlaybackDevice(
                id: localDeviceID ?? "",
                name: localDeviceName,
                type: "computer",
                isActive: true
            )
        return .local(local)
    }
    if let remote = devices.first(where: { $0.isActive && $0.id != localDeviceID }) {
        return .remote(remote)
    }
    guard currentTrackURI?.isEmpty == false else { return .none }

    let candidate: PlaybackDevice? = switch previousOwner {
    case let .remote(device), let .uncertain(.some(device)):
        device
    default:
        lastRemoteDeviceID.flatMap { id in devices.first { $0.id == id } }
    }
    return .uncertain(candidate)
}

/// A cached queue snapshot may enrich the current track, but it never owns playback identity.
/// Returning nil for a mismatch prevents a pre-reconnect queue cache from replacing a newer
/// playback callback's track.
public func queueBootstrapMetadataURI(
    snapshotTrackURI: String?,
    currentTrackURI: String?
) -> String? {
    guard let snapshotTrackURI, !snapshotTrackURI.isEmpty,
          snapshotTrackURI == currentTrackURI else { return nil }
    return snapshotTrackURI
}

/// Process-lifetime gate shared by termination handling and command admission.
public struct PlaybackTerminationGate: Sendable {
    public private(set) var hasBegun = false

    public init() {}

    @discardableResult
    public mutating func begin() -> Bool {
        guard !hasBegun else { return false }
        hasBegun = true
        return true
    }

    public var allowsCommands: Bool { !hasBegun }
}

public enum PlaybackTransportState: Equatable, Sendable {
    case stopped
    case buffering
    case paused
    case playing
}

public enum MetadataProvenance: Int, Comparable, Sendable {
    case none = 0
    case catalog = 1
    case connect = 2
    case engine = 3

    public static func < (lhs: MetadataProvenance, rhs: MetadataProvenance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct CurrentTrack: Equatable, Sendable {
    public var uri: String
    public var title: String?
    public var artist: String?
    public var artworkURL: URL?
    public var duration: TimeInterval
    public var metadataSource: MetadataProvenance

    public init(
        uri: String,
        title: String? = nil,
        artist: String? = nil,
        artworkURL: URL? = nil,
        duration: TimeInterval = 0,
        metadataSource: MetadataProvenance = .none
    ) {
        self.uri = uri
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration
        self.metadataSource = metadataSource
    }
}

public struct PlaybackTiming: Equatable, Sendable {
    public var position: TimeInterval
    public var duration: TimeInterval
    public var anchoredAt: Date

    public init(position: TimeInterval = 0, duration: TimeInterval = 0, anchoredAt: Date = Date()) {
        self.position = position
        self.duration = duration
        self.anchoredAt = anchoredAt
    }
}

/// A complete user-visible playback presentation. Optimistic starts, rollbacks, and restoration
/// enter the reducer as one value so observers never see a title from one track paired with the
/// transport or timing of another.
public struct PlaybackPresentationSnapshot: Equatable, Sendable {
    public var currentTrack: CurrentTrack?
    public var transport: PlaybackTransportState
    public var timing: PlaybackTiming

    public init(
        currentTrack: CurrentTrack?,
        transport: PlaybackTransportState,
        timing: PlaybackTiming
    ) {
        self.currentTrack = currentTrack
        self.transport = currentTrack == nil ? .stopped : transport
        self.timing = currentTrack == nil ? PlaybackTiming(anchoredAt: timing.anchoredAt) : timing
    }
}

/// Metadata enrichment is scoped to a URI and replaces all display fields atomically. A stale
/// response for a track that is no longer current is rejected by the reducer.
public struct PlaybackTrackMetadata: Equatable, Sendable {
    public let uri: String
    public let title: String?
    public let artist: String?
    public let artworkURL: URL?
    public let duration: TimeInterval
    public let source: MetadataProvenance

    public init(
        uri: String,
        title: String?,
        artist: String?,
        artworkURL: URL?,
        duration: TimeInterval,
        source: MetadataProvenance
    ) {
        self.uri = uri
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = max(0, duration)
        self.source = source
    }
}

public struct PlaybackOptions: Equatable, Sendable {
    public var shuffle: Bool
    public var repeatMode: RepeatMode

    public init(shuffle: Bool = false, repeatMode: RepeatMode = .off) {
        self.shuffle = shuffle
        self.repeatMode = repeatMode
    }
}

/// One authoritative engine playback sample. Keeping its transport, identity, timing, and
/// options together prevents the UI from observing combinations that never existed upstream.
public struct EnginePlaybackSnapshot: Equatable, Sendable {
    public let transport: PlaybackTransportState
    public let trackURI: String?
    public let timing: PlaybackTiming
    public let shuffle: Bool?
    public let repeatMode: RepeatMode?

    public init(
        transport: PlaybackTransportState,
        trackURI: String?,
        timing: PlaybackTiming,
        shuffle: Bool? = nil,
        repeatMode: RepeatMode? = nil
    ) {
        self.transport = transport
        self.trackURI = trackURI
        self.timing = timing
        self.shuffle = shuffle
        self.repeatMode = repeatMode
    }
}

/// One connection callback reduced atomically with the device identity it describes.
public struct EngineConnectionSnapshot: Equatable, Sendable {
    public let session: PlaybackSessionPhase?
    public let owner: PlaybackOwner
    public let localDeviceID: String?

    public init(
        session: PlaybackSessionPhase?,
        owner: PlaybackOwner,
        localDeviceID: String?
    ) {
        self.session = session
        self.owner = owner
        self.localDeviceID = localDeviceID
    }
}

public struct PlaybackQueueItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let uri: String
    public let provider: String

    public init(id: String, uri: String, provider: String) {
        self.id = id
        self.uri = uri
        self.provider = provider
    }
}

public enum PlaybackQueueSource: Int, Comparable, Sendable {
    case none = 0
    case provisional = 1
    case connect = 2
    case webAPI = 3

    public static func < (lhs: PlaybackQueueSource, rhs: PlaybackQueueSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum PlaybackQueueCompleteness: Int, Comparable, Sendable {
    case metadataOnly = 0
    case partial = 1
    case complete = 2

    public static func < (lhs: PlaybackQueueCompleteness, rhs: PlaybackQueueCompleteness) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct PlaybackQueueSnapshot: Equatable, Sendable {
    public var entries: [PlaybackQueueItem]
    public var source: PlaybackQueueSource
    public var completeness: PlaybackQueueCompleteness
    public var revision: UInt64
    public var receivedAt: Date
    public var contextURI: String?

    public init(
        entries: [PlaybackQueueItem] = [],
        source: PlaybackQueueSource = .none,
        completeness: PlaybackQueueCompleteness = .partial,
        revision: UInt64 = 0,
        receivedAt: Date = .distantPast,
        contextURI: String? = nil
    ) {
        self.entries = entries
        self.source = source
        self.completeness = completeness
        self.revision = revision
        self.receivedAt = receivedAt
        self.contextURI = contextURI
    }
}

public struct PlaybackDeviceSnapshot: Equatable, Sendable {
    public var devices: [PlaybackDevice]
    public var localDeviceID: String?
    public var revision: UInt64

    public init(devices: [PlaybackDevice] = [], localDeviceID: String? = nil, revision: UInt64 = 0) {
        self.devices = devices
        self.localDeviceID = localDeviceID
        self.revision = revision
    }
}

public enum PlaybackCommandKind: Hashable, Sendable {
    case transport
    case navigation
    case seek
    case options
    case transfer
    case queue
}

public struct PendingPlaybackCommand: Equatable, Sendable {
    public let id: UUID
    public let kind: PlaybackCommandKind
    public let expectedTransport: PlaybackTransportState?
    public let rollbackTransport: PlaybackTransportState?
    public let startedAt: Date

    public init(
        id: UUID,
        kind: PlaybackCommandKind,
        expectedTransport: PlaybackTransportState?,
        rollbackTransport: PlaybackTransportState? = nil,
        startedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.expectedTransport = expectedTransport
        self.rollbackTransport = rollbackTransport
        self.startedAt = startedAt
    }
}

public struct PlaybackNotice: Equatable, Sendable {
    public let id: UUID
    public let message: String

    public init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}

public enum PlaybackEventSource: Hashable, Sendable {
    case account
    case engineConnection
    case enginePlayback
    case engineQueue
    case engineDevices
    case command
    case metadata
    case user
}

public struct PlaybackEventEnvelope: Sendable {
    public let accountEpoch: UInt64
    public let engineEpoch: UInt64
    public let source: PlaybackEventSource
    public let revision: UInt64?
    public let receivedAt: Date
    public let event: PlaybackEvent

    public init(
        accountEpoch: UInt64,
        engineEpoch: UInt64,
        source: PlaybackEventSource,
        revision: UInt64? = nil,
        receivedAt: Date = Date(),
        event: PlaybackEvent
    ) {
        self.accountEpoch = accountEpoch
        self.engineEpoch = engineEpoch
        self.source = source
        self.revision = revision
        self.receivedAt = receivedAt
        self.event = event
    }
}

public enum PlaybackEvent: Sendable {
    case reset(session: PlaybackSessionPhase)
    case session(PlaybackSessionPhase)
    case owner(PlaybackOwner)
    case transport(PlaybackTransportState)
    case enginePlayback(EnginePlaybackSnapshot)
    case engineConnection(EngineConnectionSnapshot)
    case presentation(PlaybackPresentationSnapshot)
    case trackMetadata(PlaybackTrackMetadata)
    case currentTrack(CurrentTrack?)
    case timing(position: TimeInterval, duration: TimeInterval, anchoredAt: Date)
    case options(PlaybackOptions)
    case queue(PlaybackQueueSnapshot)
    case devices(PlaybackDeviceSnapshot)
    case commandStarted(PendingPlaybackCommand)
    case commandFinished(id: UUID, accepted: Bool, notice: PlaybackNotice?)
    case notice(PlaybackNotice?)
}

public struct PlaybackState: Equatable, Sendable {
    public var accountEpoch: UInt64
    public var engineEpoch: UInt64
    public var session: PlaybackSessionPhase
    public var owner: PlaybackOwner
    public var transport: PlaybackTransportState
    public var currentTrack: CurrentTrack?
    public var timing: PlaybackTiming
    public var options: PlaybackOptions
    public var queue: PlaybackQueueSnapshot
    public var devices: PlaybackDeviceSnapshot
    public var pendingCommands: [PlaybackCommandKind: PendingPlaybackCommand]
    public var notice: PlaybackNotice?
    public var sourceRevisions: [PlaybackEventSource: UInt64]

    public init(
        accountEpoch: UInt64 = 0,
        engineEpoch: UInt64 = 0,
        session: PlaybackSessionPhase = .signedOut,
        owner: PlaybackOwner = .none,
        transport: PlaybackTransportState = .stopped,
        currentTrack: CurrentTrack? = nil,
        timing: PlaybackTiming = PlaybackTiming(),
        options: PlaybackOptions = PlaybackOptions(),
        queue: PlaybackQueueSnapshot = PlaybackQueueSnapshot(),
        devices: PlaybackDeviceSnapshot = PlaybackDeviceSnapshot(),
        pendingCommands: [PlaybackCommandKind: PendingPlaybackCommand] = [:],
        notice: PlaybackNotice? = nil,
        sourceRevisions: [PlaybackEventSource: UInt64] = [:]
    ) {
        self.accountEpoch = accountEpoch
        self.engineEpoch = engineEpoch
        self.session = session
        self.owner = owner
        self.transport = transport
        self.currentTrack = currentTrack
        self.timing = timing
        self.options = options
        self.queue = queue
        self.devices = devices
        self.pendingCommands = pendingCommands
        self.notice = notice
        self.sourceRevisions = sourceRevisions
    }
}

public enum PlaybackReducer {
    /// Query-only epoch and ordered-source revision gates. A `true` result does not record the
    /// revision; only a successful `reduce` may mutate `PlaybackState`.
    public static func accepts(
        _ state: PlaybackState,
        accountEpoch: UInt64,
        engineEpoch: UInt64,
        source: PlaybackEventSource,
        revision: UInt64?
    ) -> Bool {
        adopting(
            state,
            accountEpoch: accountEpoch,
            engineEpoch: engineEpoch,
            source: source,
            revision: revision
        ) != nil
    }

    @discardableResult
    public static func reduce(
        _ state: inout PlaybackState,
        envelope: PlaybackEventEnvelope
    ) -> Bool {
        // Reduce into a candidate so a rejected event is genuinely inert. In particular, an
        // unknown command acknowledgement must not consume its source revision and prevent the
        // matching acknowledgement from arriving later.
        guard var candidate = adopting(
            state,
            accountEpoch: envelope.accountEpoch,
            engineEpoch: envelope.engineEpoch,
            source: envelope.source,
            revision: envelope.revision
        ) else { return false }

        switch envelope.event {
        case let .reset(session):
            candidate = PlaybackState(
                accountEpoch: envelope.accountEpoch,
                engineEpoch: envelope.engineEpoch,
                session: session
            )
        case let .session(session):
            candidate.session = session
        case let .owner(owner):
            candidate.owner = owner
        case let .transport(transport):
            reconcileTransport(transport, in: &candidate)
        case let .enginePlayback(snapshot):
            if let uri = snapshot.trackURI, !uri.isEmpty {
                if candidate.currentTrack?.uri != uri {
                    candidate.currentTrack = CurrentTrack(uri: uri)
                }
            } else {
                candidate.currentTrack = nil
            }
            candidate.timing = snapshot.timing
            if let shuffle = snapshot.shuffle { candidate.options.shuffle = shuffle }
            if let repeatMode = snapshot.repeatMode { candidate.options.repeatMode = repeatMode }
            reconcileTransport(candidate.currentTrack == nil ? .stopped : snapshot.transport, in: &candidate)
        case let .engineConnection(snapshot):
            if let session = snapshot.session { candidate.session = session }
            candidate.owner = snapshot.owner
            candidate.devices.localDeviceID = snapshot.localDeviceID
        case let .presentation(presentation):
            candidate.currentTrack = presentation.currentTrack
            candidate.timing = presentation.timing
            reconcileTransport(presentation.transport, in: &candidate)
        case let .trackMetadata(metadata):
            guard var track = candidate.currentTrack, track.uri == metadata.uri else { return false }
            track.title = metadata.title
            track.artist = metadata.artist
            track.artworkURL = metadata.artworkURL
            track.duration = metadata.duration
            track.metadataSource = metadata.source
            candidate.currentTrack = track
            if metadata.duration > 0 {
                candidate.timing.duration = metadata.duration
            }
        case let .currentTrack(track):
            candidate.currentTrack = track
            if track == nil {
                candidate.transport = .stopped
                candidate.timing = PlaybackTiming(anchoredAt: envelope.receivedAt)
            }
        case let .timing(position, duration, anchoredAt):
            candidate.timing = PlaybackTiming(
                position: max(0, position),
                duration: max(0, duration),
                anchoredAt: anchoredAt
            )
        case let .options(options):
            candidate.options = options
        case let .queue(incoming):
            candidate.queue = mergePlaybackQueueSnapshots(
                current: candidate.queue,
                incoming: incoming
            )
        case let .devices(devices):
            guard devices.revision >= candidate.devices.revision else { return false }
            candidate.devices = devices
            if let active = devices.devices.first(where: \.isActive) {
                candidate.owner = active.id == devices.localDeviceID ? .local(active) : .remote(active)
            } else if candidate.currentTrack == nil {
                candidate.owner = .none
            } else {
                let previousCandidate: PlaybackDevice? = switch candidate.owner {
                case let .remote(device), let .uncertain(.some(device)): device
                default: nil
                }
                let refreshed = previousCandidate.flatMap { prior in
                    devices.devices.first { $0.id == prior.id }
                } ?? previousCandidate
                candidate.owner = .uncertain(refreshed)
            }
        case let .commandStarted(command):
            let prepared = PendingPlaybackCommand(
                id: command.id,
                kind: command.kind,
                expectedTransport: command.expectedTransport,
                rollbackTransport: command.rollbackTransport ?? (
                    command.expectedTransport == nil ? nil : candidate.transport
                ),
                startedAt: command.startedAt
            )
            candidate.pendingCommands[command.kind] = prepared
            if let expected = command.expectedTransport {
                candidate.transport = expected
            }
        case let .commandFinished(id, accepted, notice):
            guard let pair = candidate.pendingCommands.first(where: { $0.value.id == id }) else {
                return false
            }
            candidate.pendingCommands[pair.key] = nil
            if !accepted {
                if pair.key == .transport, let rollback = pair.value.rollbackTransport {
                    candidate.transport = rollback
                }
                candidate.notice = notice
            }
        case let .notice(notice):
            candidate.notice = notice
        }

        // Record a revision only after the event itself was accepted. Reset creates a fresh
        // snapshot, so doing this last also preserves reset as a barrier against queued events.
        if let revision = envelope.revision {
            candidate.sourceRevisions[envelope.source] = revision
        }
        state = candidate
        return true
    }

    /// Account epoch, engine epoch, and per-source revision gates shared by `accepts` and `reduce`.
    /// The returned candidate has not yet recorded `envelope.revision`.
    private static func adopting(
        _ state: PlaybackState,
        accountEpoch: UInt64,
        engineEpoch: UInt64,
        source: PlaybackEventSource,
        revision: UInt64?
    ) -> PlaybackState? {
        var candidate = state

        guard accountEpoch >= candidate.accountEpoch else { return nil }
        if accountEpoch > candidate.accountEpoch {
            candidate = PlaybackState(
                accountEpoch: accountEpoch,
                engineEpoch: engineEpoch,
                session: .signedOut
            )
        }

        guard engineEpoch >= candidate.engineEpoch else { return nil }
        if engineEpoch > candidate.engineEpoch {
            candidate.engineEpoch = engineEpoch
            candidate.sourceRevisions = [:]
            candidate.pendingCommands = [:]
        }

        if let revision {
            let previous = candidate.sourceRevisions[source] ?? 0
            guard revision > previous else { return nil }
        }

        return candidate
    }

    private static func reconcileTransport(
        _ transport: PlaybackTransportState,
        in state: inout PlaybackState
    ) {
        if let pending = state.pendingCommands[.transport],
           let expected = pending.expectedTransport,
           transport != expected
        {
            state.transport = expected
        } else {
            state.transport = transport
            if state.pendingCommands[.transport]?.expectedTransport == transport {
                state.pendingCommands[.transport] = nil
            }
        }
    }

}

/// The one queue-ordering precedence policy used by both the reducer and live queue service.
/// Metadata enrichment is deliberately separate: it may improve labels but cannot reorder uris.
public func mergePlaybackQueueSnapshots(
    current: PlaybackQueueSnapshot,
    incoming: PlaybackQueueSnapshot
) -> PlaybackQueueSnapshot {
    if current.contextURI != incoming.contextURI {
        return incoming.receivedAt >= current.receivedAt ? incoming : current
    }
    if incoming.source > current.source { return incoming }
    if incoming.source < current.source { return current }
    if incoming.revision > current.revision { return incoming }
    if incoming.revision < current.revision { return current }
    return incoming.completeness >= current.completeness ? incoming : current
}
