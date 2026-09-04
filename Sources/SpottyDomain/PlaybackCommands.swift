import Foundation

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
    /// Requested shuffle value for a live options command. Repeat commands leave this nil.
    public let expectedShuffle: Bool?
    /// Exact pre-command shuffle captured at `commandStarted` for a live shuffle command.
    public let rollbackShuffle: Bool?
    /// Requested canonical repeat flags for a live options command. Shuffle commands leave this nil.
    public let expectedRepeatFlags: RepeatFlags?
    /// Exact pre-command raw repeat flags captured at `commandStarted` for a live repeat command.
    public let rollbackRepeatFlags: RepeatFlags?
    /// Requested remote-transfer owner. Transfer-to-this-Mac leaves this nil.
    public let expectedOwner: PlaybackOwner?
    /// Exact pre-command owner captured at `commandStarted` for a remote transfer.
    public let rollbackOwner: PlaybackOwner?
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
        expectedShuffle: Bool? = nil,
        rollbackShuffle: Bool? = nil,
        expectedRepeatFlags: RepeatFlags? = nil,
        rollbackRepeatFlags: RepeatFlags? = nil,
        expectedOwner: PlaybackOwner? = nil,
        rollbackOwner: PlaybackOwner? = nil,
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
        self.expectedShuffle = expectedShuffle
        self.rollbackShuffle = rollbackShuffle
        self.expectedRepeatFlags = expectedRepeatFlags
        self.rollbackRepeatFlags = rollbackRepeatFlags
        self.expectedOwner = expectedOwner
        self.rollbackOwner = rollbackOwner
        self.startedAt = startedAt
    }
}

/// How a known-target transport, shuffle, repeat, or remote-transfer command left `pendingCommands`
/// without `commandFinished`. Stored per command id so a later pause/resume cannot recycle
/// the nil catch-all. `commandFinished` consumes a matching entry (pending rollback or
/// consume-only) so the map does not grow for the process/session lifetime.
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
