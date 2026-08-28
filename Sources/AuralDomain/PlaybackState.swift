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

/// Single owner-resolution policy for connection callbacks and device snapshots.
/// Metadata availability is not ownership: a URI is sufficient evidence that playback exists,
/// so labels and artwork may arrive later without changing where transport commands route.
/// `lastRemoteDeviceID` is immutable event context, never read from store preferences here.
/// A matching remembered remote remains an uncertain candidate so paused Connect playback stays
/// remote-routable; a missing, stale, or local identity fallback stays `uncertain(nil)` and
/// never becomes local.
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
        devices.first { $0.id == device.id } ?? device
    default:
        lastRemoteDeviceID.flatMap { id in
            guard id != localDeviceID else { return nil }
            return devices.first { $0.id == id }
        }
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
    /// Independent Connect/FFI switches. `repeatMode` is the display collapse
    /// (`track` wins when both are true); planning uses this pair so a live
    /// both-true snapshot is not forgotten as `context: false`.
    public var repeatFlags: RepeatFlags

    public init(
        shuffle: Bool = false,
        repeatMode: RepeatMode = .off,
        repeatFlags: RepeatFlags? = nil
    ) {
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.repeatFlags = repeatFlags ?? repeatMode.flags
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
    public let repeatFlags: RepeatFlags?

    public init(
        transport: PlaybackTransportState,
        trackURI: String?,
        timing: PlaybackTiming,
        shuffle: Bool? = nil,
        repeatMode: RepeatMode? = nil,
        repeatFlags: RepeatFlags? = nil
    ) {
        self.transport = transport
        self.trackURI = trackURI
        self.timing = timing
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.repeatFlags = repeatFlags
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
    public let uid: String

    public init(id: String, uri: String, provider: String, uid: String = "") {
        self.id = id
        self.uri = uri
        self.provider = provider
        self.uid = uid
    }

    public init(_ entry: QueueEntry) {
        self.init(id: entry.id, uri: entry.uri, provider: entry.provider, uid: entry.uid)
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
    /// Remembered remote device stamped by the store at event intake. The reducer uses this
    /// only as payload; it does not read preferences.
    public var lastRemoteDeviceID: String?

    public init(
        devices: [PlaybackDevice] = [],
        localDeviceID: String? = nil,
        revision: UInt64 = 0,
        lastRemoteDeviceID: String? = nil
    ) {
        self.devices = devices
        self.localDeviceID = localDeviceID
        self.revision = revision
        self.lastRemoteDeviceID = lastRemoteDeviceID
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
    public let expectedTiming: PlaybackTiming?
    public let rollbackTiming: PlaybackTiming?
    /// Concrete play target when the caller already knows the track to present.
    public let expectedTrack: CurrentTrack?
    /// Exact presentation captured at `commandStarted` for a known play target.
    public let rollbackPresentation: PlaybackPresentationSnapshot?
    public let startedAt: Date

    public init(
        id: UUID,
        kind: PlaybackCommandKind,
        expectedTransport: PlaybackTransportState?,
        rollbackTransport: PlaybackTransportState? = nil,
        expectedTiming: PlaybackTiming? = nil,
        rollbackTiming: PlaybackTiming? = nil,
        expectedTrack: CurrentTrack? = nil,
        rollbackPresentation: PlaybackPresentationSnapshot? = nil,
        startedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.expectedTransport = expectedTransport
        self.rollbackTransport = rollbackTransport
        self.expectedTiming = expectedTiming
        self.rollbackTiming = rollbackTiming
        self.expectedTrack = expectedTrack
        self.rollbackPresentation = rollbackPresentation
        self.startedAt = startedAt
    }
}

/// How a known-target transport command left `pendingCommands` without `commandFinished`.
/// Stored per command id so a later pause/resume cannot recycle the nil catch-all.
public enum PlaybackTransportCommandResolution: Equatable, Sendable {
    case confirmed
    case superseded
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
    public var transportCommandResolutions: [UUID: PlaybackTransportCommandResolution]

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
        sourceRevisions: [PlaybackEventSource: UInt64] = [:],
        transportCommandResolutions: [UUID: PlaybackTransportCommandResolution] = [:]
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
        self.transportCommandResolutions = transportCommandResolutions
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
            reconcileTransport(transport, incomingTrackURI: nil, in: &candidate)
        case let .enginePlayback(snapshot):
            let incomingURI = playbackTrackURI(snapshot.trackURI)
            if shouldHoldOptimisticPlayTarget(incomingURI: incomingURI, in: candidate) {
                applyEnginePlaybackOptions(snapshot, in: &candidate)
            } else {
                supersedeOptimisticPlayTargetIfNeeded(incomingURI: incomingURI, in: &candidate)
                let previousURI = candidate.currentTrack?.uri
                reconcileSeekTiming(snapshot.timing, incomingTrackURI: incomingURI, in: &candidate)
                if let uri = incomingURI {
                    if candidate.currentTrack?.uri != uri {
                        candidate.currentTrack = CurrentTrack(uri: uri)
                    }
                } else {
                    candidate.currentTrack = nil
                }
                adoptOwnerAfterTrackURIChange(
                    previousURI: previousURI,
                    incomingURI: incomingURI,
                    in: &candidate
                )
                applyEnginePlaybackOptions(snapshot, in: &candidate)
                reconcileTransport(
                    candidate.currentTrack == nil ? .stopped : snapshot.transport,
                    incomingTrackURI: incomingURI,
                    in: &candidate
                )
            }
        case let .engineConnection(snapshot):
            if let session = snapshot.session { candidate.session = session }
            candidate.owner = snapshot.owner
            candidate.devices.localDeviceID = snapshot.localDeviceID
        case let .presentation(presentation):
            let incomingURI = playbackTrackURI(presentation.currentTrack?.uri)
            if !shouldHoldOptimisticPlayTarget(incomingURI: incomingURI, in: candidate) {
                supersedeOptimisticPlayTargetIfNeeded(incomingURI: incomingURI, in: &candidate)
                reconcileSeekTiming(
                    presentation.timing,
                    incomingTrackURI: presentation.currentTrack?.uri,
                    in: &candidate
                )
                candidate.currentTrack = presentation.currentTrack
                reconcileTransport(
                    presentation.transport,
                    incomingTrackURI: incomingURI,
                    in: &candidate
                )
            }
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
            let incomingURI = playbackTrackURI(track?.uri)
            if shouldHoldOptimisticPlayTarget(incomingURI: incomingURI, in: candidate) {
                break
            }
            supersedeOptimisticPlayTargetIfNeeded(incomingURI: incomingURI, in: &candidate)
            let previousURI = candidate.currentTrack?.uri
            if candidate.pendingCommands[.seek] != nil,
               incomingURI == nil || playbackTrackURI(candidate.currentTrack?.uri) != incomingURI
            {
                candidate.pendingCommands[.seek] = nil
            }
            candidate.currentTrack = track
            adoptOwnerAfterTrackURIChange(
                previousURI: previousURI,
                incomingURI: incomingURI,
                in: &candidate
            )
            if track == nil {
                candidate.transport = .stopped
                candidate.timing = PlaybackTiming(anchoredAt: envelope.receivedAt)
            }
        case let .timing(position, duration, anchoredAt):
            reconcileSeekTiming(
                PlaybackTiming(
                    position: max(0, position),
                    duration: max(0, duration),
                    anchoredAt: anchoredAt
                ),
                incomingTrackURI: candidate.currentTrack?.uri,
                in: &candidate
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
            applyConnectionPlaybackOwner(&candidate)
        case let .commandStarted(command):
            // Capture current presentation before applying the caller's target. The store must
            // not mutate transport, timing, or track first, or rollback records the optimistic values.
            // Do not clear other commands' resolutions: a later pause must not recycle the
            // already-reconciled-success path for a superseded play.
            let prepared = PendingPlaybackCommand(
                id: command.id,
                kind: command.kind,
                expectedTransport: command.expectedTransport,
                rollbackTransport: command.rollbackTransport ?? (
                    command.expectedTransport == nil && command.expectedTrack == nil ? nil : candidate.transport
                ),
                expectedTiming: command.expectedTiming,
                rollbackTiming: command.rollbackTiming ?? (
                    command.expectedTiming == nil && command.expectedTrack == nil ? nil : candidate.timing
                ),
                expectedTrack: command.expectedTrack,
                rollbackPresentation: command.rollbackPresentation ?? (
                    command.expectedTrack == nil ? nil : PlaybackPresentationSnapshot(
                        currentTrack: candidate.currentTrack,
                        transport: candidate.transport,
                        timing: candidate.timing
                    )
                ),
                startedAt: command.startedAt
            )
            candidate.pendingCommands[command.kind] = prepared
            if let expectedTrack = command.expectedTrack {
                if playbackTrackURI(candidate.currentTrack?.uri) != playbackTrackURI(expectedTrack.uri) {
                    candidate.pendingCommands[.seek] = nil
                }
                candidate.currentTrack = expectedTrack
            }
            if let expected = command.expectedTransport {
                candidate.transport = expected
            }
            if let expected = command.expectedTiming {
                candidate.timing = expected
            }
        case let .commandFinished(id, accepted, notice):
            guard let pair = candidate.pendingCommands.first(where: { $0.value.id == id }) else {
                return false
            }
            candidate.pendingCommands[pair.key] = nil
            if !accepted {
                if let rollback = pair.value.rollbackPresentation {
                    candidate.currentTrack = rollback.currentTrack
                    candidate.transport = rollback.transport
                    candidate.timing = rollback.timing
                } else {
                    if let rollback = pair.value.rollbackTransport {
                        candidate.transport = rollback
                    }
                    if let rollback = pair.value.rollbackTiming {
                        candidate.timing = rollback
                    }
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
            candidate.transportCommandResolutions = [:]
            candidate.devices.revision = 0
        }

        if let revision {
            let previous = candidate.sourceRevisions[source] ?? 0
            guard revision > previous else { return nil }
        }

        return candidate
    }

    private static func reconcileTransport(
        _ transport: PlaybackTransportState,
        incomingTrackURI: String?,
        in state: inout PlaybackState
    ) {
        if let pending = state.pendingCommands[.transport],
           let targetURI = playbackTrackURI(pending.expectedTrack?.uri)
        {
            let incoming = playbackTrackURI(incomingTrackURI)
            if incoming != targetURI {
                state.transport = pending.expectedTransport ?? transport
                return
            }
            if let expected = pending.expectedTransport, transport != expected {
                state.transport = expected
            } else {
                state.transport = transport
                if pending.expectedTransport == nil || pending.expectedTransport == transport {
                    state.transportCommandResolutions[pending.id] = .confirmed
                    state.pendingCommands[.transport] = nil
                }
            }
            return
        }
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

    /// Lagging snapshots of the pre-command track must not confirm or replace a known play target.
    private static func shouldHoldOptimisticPlayTarget(
        incomingURI: String?,
        in state: PlaybackState
    ) -> Bool {
        guard let pending = state.pendingCommands[.transport],
              let targetURI = playbackTrackURI(pending.expectedTrack?.uri)
        else { return false }
        let incoming = playbackTrackURI(incomingURI)
        let rollbackURI = playbackTrackURI(pending.rollbackPresentation?.currentTrack?.uri)
        return incoming != nil && incoming != targetURI && incoming == rollbackURI
    }

    private static func supersedeOptimisticPlayTargetIfNeeded(
        incomingURI: String?,
        in state: inout PlaybackState
    ) {
        guard let pending = state.pendingCommands[.transport],
              let targetURI = playbackTrackURI(pending.expectedTrack?.uri)
        else { return }
        let incoming = playbackTrackURI(incomingURI)
        let rollbackURI = playbackTrackURI(pending.rollbackPresentation?.currentTrack?.uri)
        if incoming == targetURI { return }
        if incoming != nil, incoming == rollbackURI { return }
        state.pendingCommands[.transport] = nil
        state.transportCommandResolutions[pending.id] = .superseded
    }

    private static func applyEnginePlaybackOptions(
        _ snapshot: EnginePlaybackSnapshot,
        in candidate: inout PlaybackState
    ) {
        if let shuffle = snapshot.shuffle { candidate.options.shuffle = shuffle }
        if snapshot.repeatMode != nil || snapshot.repeatFlags != nil {
            let flags = snapshot.repeatFlags
                ?? snapshot.repeatMode?.flags
                ?? candidate.options.repeatFlags
            candidate.options.repeatFlags = flags
            candidate.options.repeatMode = snapshot.repeatMode
                ?? RepeatMode(context: flags.context, track: flags.track)
        }
    }

    /// Holds optimistic seek timing until an incoming sample is at the expected millisecond
    /// position on the same track. A different track or empty URI supersedes the old seek and
    /// adopts the incoming timing so rollback cannot attach the previous track's position.
    private static func reconcileSeekTiming(
        _ timing: PlaybackTiming,
        incomingTrackURI: String?,
        in state: inout PlaybackState
    ) {
        let incomingURI = playbackTrackURI(incomingTrackURI)
        if state.pendingCommands[.seek] != nil,
           incomingURI == nil || playbackTrackURI(state.currentTrack?.uri) != incomingURI
        {
            state.pendingCommands[.seek] = nil
            state.timing = timing
            return
        }
        if let pending = state.pendingCommands[.seek],
           let expected = pending.expectedTiming,
           !matchesExpectedSeekPosition(timing, expected)
        {
            state.timing = expected
        } else {
            state.timing = timing
            if let pending = state.pendingCommands[.seek],
               let expected = pending.expectedTiming,
               matchesExpectedSeekPosition(timing, expected)
            {
                state.pendingCommands[.seek] = nil
            }
        }
    }

    private static func applyConnectionPlaybackOwner(_ candidate: inout PlaybackState) {
        let devices = candidate.devices
        let isLocalActive = devices.devices.contains {
            $0.isActive && $0.id == devices.localDeviceID
        }
        candidate.owner = connectionPlaybackOwner(
            isLocalActive: isLocalActive,
            localDeviceID: devices.localDeviceID,
            localDeviceName: devices.devices.first { $0.id == devices.localDeviceID }?.name ?? "",
            devices: devices.devices,
            currentTrackURI: candidate.currentTrack?.uri,
            previousOwner: candidate.owner,
            lastRemoteDeviceID: devices.lastRemoteDeviceID
        )
    }

    /// Cluster delivery notifies devices before player state, so the first no-active snapshot
    /// often has no URI yet and resolves to `.none`. When a URI later appears or clears, reuse
    /// the stamped last-remote context instead of leaving `.none` locally routable.
    /// Connection-authoritative `.local` / `.remote` / identified `.uncertain` owners stay put
    /// until a devices snapshot re-resolves them.
    private static func adoptOwnerAfterTrackURIChange(
        previousURI: String?,
        incomingURI: String?,
        in candidate: inout PlaybackState
    ) {
        let previous = playbackTrackURI(previousURI)
        let incoming = playbackTrackURI(incomingURI)
        guard previous != incoming else { return }
        if incoming == nil {
            if case .uncertain = candidate.owner {
                applyConnectionPlaybackOwner(&candidate)
            }
            return
        }
        guard previous == nil else { return }
        switch candidate.owner {
        case .none, .uncertain(nil):
            applyConnectionPlaybackOwner(&candidate)
        default:
            break
        }
    }

    private static func playbackTrackURI(_ uri: String?) -> String? {
        uri.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func matchesExpectedSeekPosition(
        _ actual: PlaybackTiming,
        _ expected: PlaybackTiming
    ) -> Bool {
        Int((actual.position * 1_000).rounded()) == Int((expected.position * 1_000).rounded())
    }

}

/// The one queue-ordering precedence policy used by both the reducer and live queue service.
/// Complete Connect occurrence order is authoritative for a playback context. Web API and
/// catalog metadata may enrich labels, but they must not reorder or replace that list, and
/// they must not copy their revision or receivedAt onto the Connect ordering snapshot.
public func mergePlaybackQueueSnapshots(
    current: PlaybackQueueSnapshot,
    incoming: PlaybackQueueSnapshot
) -> PlaybackQueueSnapshot {
    if current.contextURI != incoming.contextURI {
        return incoming.receivedAt >= current.receivedAt ? incoming : current
    }
    if let preserved = preservingConnectOccurrenceOrder(current: current, incoming: incoming) {
        return preserved
    }
    if incoming.source > current.source { return incoming }
    if incoming.source < current.source { return current }
    if incoming.revision > current.revision { return incoming }
    if incoming.revision < current.revision { return current }
    return incoming.completeness >= current.completeness ? incoming : current
}

/// Same-context Web snapshots may ride along for metadata elsewhere. They do not become
/// the occurrence list, and they do not share a revision/receivedAt clock with Connect.
private func preservingConnectOccurrenceOrder(
    current: PlaybackQueueSnapshot,
    incoming: PlaybackQueueSnapshot
) -> PlaybackQueueSnapshot? {
    let currentConnect = current.source == .connect && current.completeness == .complete
    let incomingConnect = incoming.source == .connect && incoming.completeness == .complete
    if currentConnect, incoming.source == .webAPI {
        return current
    }
    if incomingConnect, current.source == .webAPI {
        return incoming
    }
    return nil
}
