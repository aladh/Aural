import Foundation

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
