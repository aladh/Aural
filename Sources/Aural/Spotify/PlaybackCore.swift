import Foundation
import AuralPlaybackCore

/// The complete Swift-facing boundary to Aural's embedded playback engine.
///
/// The application is native SwiftUI, and all catalog, authentication, state, and rendering
/// policy stays in Swift. The bundled Rust/librespot library is deliberately a leaf dependency:
/// only this file knows its C symbol names or result type.
nonisolated enum PlaybackCore {
    typealias Result = AuralPlaybackResult

    static func registerAudioDataCallback(_ callback: AudioDataCallback) {
        aural_playback_register_audio_data_callback(callback)
    }

    static func registerAudioControlCallback(_ callback: AudioControlCallback) {
        aural_playback_register_audio_control_callback(callback)
    }

    static func registerPlaybackStateCallback(_ callback: PlaybackStateCallback) {
        aural_playback_register_playback_state_callback(callback)
    }

    static func registerQueueCallback(_ callback: QueueCallback) {
        aural_playback_register_queue_callback(callback)
    }

    static func registerConnectionStateCallback(_ callback: ConnectionStateCallback) {
        aural_playback_register_connection_state_callback(callback)
    }

    static func registerDevicesCallback(_ callback: DevicesCallback) {
        aural_playback_register_devices_callback(callback)
    }

    static func authorizeStreaming(with accessToken: String) -> Int32 {
        accessToken.withCString { aural_playback_authorize_streaming($0) }
    }

    static func initialize() -> Result {
        aural_playback_init_player(nil)
    }

    static func play(uri: String, trackIndex: Int32 = -1) -> Result {
        uri.withCString { aural_playback_play_uri($0, trackIndex) }
    }

    static func play(tracks: [String]) -> Result {
        guard
            let data = try? JSONEncoder().encode(tracks),
            let json = String(data: data, encoding: .utf8)
        else { return .error }

        return json.withCString { aural_playback_play_tracks($0) }
    }

    static func pause() -> Result { aural_playback_pause() }
    static func resume() -> Result { aural_playback_resume() }
    static func next() -> Result { aural_playback_next() }
    static func previous() -> Result { aural_playback_previous() }
    static func seek(to milliseconds: UInt32) -> Result { aural_playback_seek(milliseconds) }
    static func setShuffle(_ enabled: Bool) -> Result { aural_playback_set_shuffle(enabled) }
    static func setRepeat(context: Bool) -> Result { aural_playback_set_repeat_context(context) }
    static func setRepeatTrack(_ enabled: Bool) -> Result { aural_playback_set_repeat_track(enabled) }
    static func positionMilliseconds() -> UInt32 { aural_playback_get_position_ms() }

    /// Appends a track, episode, or whole context to the play queue.
    static func addToQueue(uri: String) -> Result {
        uri.withCString { aural_playback_add_to_queue($0) }
    }

    /// Takes over playback from whatever Connect device is currently active.
    static func transferToLocal() -> Result { aural_playback_transfer_to_local() }

    /// Hands playback to another Spotify Connect device.
    static func transferPlayback(to deviceID: String) -> Result {
        deviceID.withCString { aural_playback_transfer_playback($0) }
    }

    /// The last queue the Connect cluster described, or nil before one has arrived.
    /// Same JSON shape the queue callback delivers.
    nonisolated static func queueSnapshotJSON() -> String? {
        guard let pointer = aural_playback_get_queue_snapshot() else { return nil }
        defer { aural_playback_free_string(pointer) }
        return String(cString: pointer)
    }

    static func configureHighQualityPlayback() {
        aural_playback_set_bitrate(2)
        aural_playback_set_gapless(true)
        aural_playback_set_initial_volume(UInt16.max)
    }

    static func shutdown() -> Result { aural_playback_shutdown() }
    static func cleanup() { aural_playback_cleanup() }
    static func clearStreamingCredentials() { aural_playback_clear_streaming_credentials() }

    /// Leaves Spotify Connect before system sleep, so this Mac disappears from other
    /// devices' pickers immediately. Unlike shutdown it does not block reconnection.
    nonisolated static func disconnect() -> Result { aural_playback_disconnect() }

    /// Rebuilds the streaming session after macOS wakes.
    ///
    /// The backend captures the playing track and its position before tearing down, then its
    /// reconnection loop restores them. Returns 0 when a reconnection was triggered, 1 when one
    /// was already running, and 2 when no session existed — every outcome is fine to ignore,
    /// because the backend also self-reports disconnections on its own.
    nonisolated static func forceReconnect() -> Int32 {
        aural_playback_force_reconnect()
    }

    /// A declined command is ordinary (for example Resume with no current context). Only
    /// backend lifecycle failures invalidate the connection and require reinitialization.
    static func requiresReconnect(after result: Result) -> Bool {
        result.rawValue == -2 || result.rawValue == -3
    }
}
