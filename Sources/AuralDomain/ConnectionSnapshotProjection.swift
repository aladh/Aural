import Foundation

/// App-facing connection session from engine session flags.
///
/// The engine reports connected/ready/error observations. Local display name is Swift-owned.
public enum ConnectionSnapshotProjection: Sendable {
    /// Empty wire IDs are missing, not a distinct device.
    public static func resolvedDeviceID(wire: String?, fallback: String?) -> String? {
        if let wire, !wire.isEmpty { return wire }
        return fallback
    }

    public static func sessionPhase(
        connected: Bool,
        spircReady: Bool,
        lastError: String?
    ) -> PlaybackSessionPhase? {
        if connected, spircReady { return .ready }
        if let lastError, !lastError.isEmpty { return .failed(lastError) }
        return nil
    }
}
