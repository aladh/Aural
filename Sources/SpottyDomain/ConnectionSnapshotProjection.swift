import Foundation

/// App-facing connection session from engine session flags.
///
/// The engine reports connected/ready/error observations. Local display name is Swift-owned.
public enum ConnectionSnapshotProjection: Sendable {
    /// Stable presentation for the typed credential outcome. The upstream error is retained as
    /// a flag for account policy, never interpolated into user-facing text.
    public static let credentialsRejectedMessage = "Your Spotify session expired. Sign in again."

    /// Stable fallback for a connection error whose private upstream details are not suitable
    /// for the UI. The engine may retain a diagnostic category for logs, but this projection only
    /// exposes actionable, privacy-safe presentation.
    public static let connectionFailedMessage = "Spotify connection failed. Try again."

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
        sessionPhase(
            connected: connected,
            spircReady: spircReady,
            credentialsRejected: false,
            lastError: lastError
        )
    }

    public static func sessionPhase(
        connected: Bool,
        spircReady: Bool,
        credentialsRejected: Bool,
        lastError: String?
    ) -> PlaybackSessionPhase? {
        if credentialsRejected {
            return .failed(credentialsRejectedMessage)
        }
        if connected, spircReady { return .ready }
        if let lastError, !lastError.isEmpty { return .failed(connectionFailedMessage) }
        return nil
    }
}
