#ifndef AURAL_PLAYBACK_H
#define AURAL_PLAYBACK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Pointer parameters and return values are non-null by default within this
// region. The few that may be null are marked explicitly with `_Nullable`.
#pragma clang assume_nonnull begin

/// Frees a C string allocated by this library. Tolerates NULL (e.g. the result
/// of a function that returned NULL on error).
void aural_playback_free_string(char* _Nullable s);

// ============================================================================
// Error codes
// ============================================================================
//
// Command functions return an AuralPlaybackResult:
//   AuralPlaybackResultOk                   ( 0) = success
//   AuralPlaybackResultError                (-1) = general error
//   AuralPlaybackResultSessionDisconnected  (-2) = session disconnected, needs reinitialization
//                                             (call aural_playback_init_player with NULL)
//   AuralPlaybackResultSessionNotConnected  (-3) = session not connected (command rejected,
//                                             wait for session to connect)
//
// On AuralPlaybackResultSessionDisconnected, the Spirc channel has closed (e.g., due
// to idle timeout). Call aural_playback_init_player() with NULL so it reconnects from the
// credentials cached by aural_playback_authorize_streaming().
//
// On AuralPlaybackResultSessionNotConnected, the session is not yet connected. Wait
// for the connection-state callback before retrying the command.
typedef enum __attribute__((enum_extensibility(open))) AuralPlaybackResult : int32_t {
    AuralPlaybackResultOk = 0,
    AuralPlaybackResultError = -1,
    AuralPlaybackResultSessionDisconnected = -2,
    AuralPlaybackResultSessionNotConnected = -3,
} AuralPlaybackResult;

// ============================================================================
// Playback functions
// ============================================================================

/// Initializes the player.
/// Must be called before play/pause operations.
///
/// @param access_token A token minted with librespot's client id, or NULL to connect from
///                     the credentials cached by aural_playback_authorize_streaming(). NULL is the
///                     normal case: only the first init after a grant carries a token.
AuralPlaybackResult aural_playback_init_player(const char* _Nullable access_token);

/// Completes the one-time streaming authorization with a token Swift has already minted:
/// connects once and persists the credentials every later init connects from.
///
/// Swift owns the OAuth flow itself (see KeymasterAuth), because the same token also
/// authorizes pathfinder and spclient.
///
/// @param access_token A token minted with Spotify's desktop client id. Must not be NULL.
///
/// Returns:
///    0 = Authorized, credentials cached
///   -1 = Failed
///   -2 = Superseded by a logout; any credentials written were removed again
int32_t aural_playback_authorize_streaming(const char* _Nonnull access_token);

/// Removes the cached streaming credentials.
/// Call on logout, after the session teardown, so the next launch cannot connect the
/// account that just logged out. Removing credentials that are not there is not an error.
void aural_playback_clear_streaming_credentials(void);

/// Plays multiple tracks in sequence.
///
/// @param track_uris_json JSON array of track URIs as a C string
AuralPlaybackResult aural_playback_play_tracks(const char* track_uris_json);

/// Plays content by its Spotify URI or URL.
/// Supports albums, playlists, and artists (context URIs).
/// @param uri_or_url Spotify URI or URL (e.g., "spotify:album:xxx")
/// @param track_index Track index to start at (-1 = from beginning, 0+ = specific track)
AuralPlaybackResult aural_playback_play_uri(const char* uri_or_url, int32_t track_index);

/// Pauses playback.
AuralPlaybackResult aural_playback_pause(void);

/// Resumes playback: activate and `play()`. If no Playing event arrives, Swift issues
/// seek-capable load fallbacks via `aural_playback_load`. Reconnect rehydration still
/// loads from session globals inside the engine.
AuralPlaybackResult aural_playback_resume(void);

/// Loads a context or single track at `position_ms` and waits briefly for a Playing event.
/// Empty `track_hint` is a valid context hint. `uri` must be non-empty.
/// @param from_context true for a context URI, false for a single track URI.
AuralPlaybackResult aural_playback_load(
    const char* uri,
    const char* _Nullable track_hint,
    uint32_t position_ms,
    bool from_context
);

/// Shuts down the Spirc connection and sends goodbye to other devices.
/// Call this when the app is quitting to properly disconnect from Spotify Connect.
AuralPlaybackResult aural_playback_shutdown(void);

/// Disconnects from Spotify Connect without preventing future reconnection.
/// Use this before system sleep - the device disappears from Spotify immediately,
/// but forceReconnect() can still bring it back on wake.
/// Unlike shutdown(), this does NOT block auto-reconnect.
AuralPlaybackResult aural_playback_disconnect(void);

/// Cleans up all player state, allowing a fresh reinitialization.
/// Call this before aural_playback_init_player() when the session has disconnected.
/// This clears all static state (session, player, spirc, etc.)
void aural_playback_cleanup(void);

/// Returns the last position the Player reported, in milliseconds, or 0 if it has not
/// reported one. Deliberately not interpolated — Swift owns display interpolation, and
/// doing it on both sides made the two clocks disagree.
uint32_t aural_playback_get_position_ms(void);

/// Position saved at deactivation for resume-load, or 0 to use the live playhead.
uint32_t aural_playback_get_resume_position_ms(void);

/// Sticky resume-load context URI (`CURRENT_CONTEXT_URI`), or NULL if none.
/// Caller frees with `aural_playback_free_string`. Empty string is a present empty value.
char* _Nullable aural_playback_get_resume_context_uri(void);

/// Sticky resume-load track URI (`CURRENT_TRACK_URI`), or NULL if none.
/// Caller frees with `aural_playback_free_string`. Empty string is a valid context hint.
char* _Nullable aural_playback_get_resume_track_uri(void);

/// Callback function type for queue updates.
/// Receives a JSON string containing the queue state.
typedef void (*QueueCallback)(const char* queue_json);

/// Registers a callback to receive queue updates.
void aural_playback_register_queue_callback(QueueCallback callback);

/// Playback observation. `track_uri` and `context_uri` are valid only for the callback;
/// Swift must copy them before returning. NULL means missing. Flags are 0 or 1.
typedef struct AuralPlaybackSnapshot {
    uint64_t revision;
    uint64_t session_generation;
    int64_t position_ms;
    int64_t duration_ms;
    int64_t timestamp_ms;
    uint8_t is_playing;
    uint8_t is_paused;
    uint8_t shuffle;
    uint8_t repeat_track;
    uint8_t repeat_context;
    const char* _Nullable track_uri;
    const char* _Nullable context_uri;
} AuralPlaybackSnapshot;

/// Callback function type for playback state updates.
/// Receives a typed snapshot. String pointers are valid only for the callback.
typedef void (*PlaybackStateCallback)(const AuralPlaybackSnapshot* snapshot);

/// Registers a callback to receive playback state updates from Mercury/Spirc.
void aural_playback_register_playback_state_callback(PlaybackStateCallback callback);

/// Forces a reconnection to Spotify servers.
/// Use this after system wake to ensure a fresh connection before playback.
/// Returns:
///   0 = Reconnection triggered
///   1 = Reconnection already in progress
///   2 = No session initialized (nothing to reconnect)
int32_t aural_playback_force_reconnect(void);

/// Returns the last queue the Connect cluster described, as JSON, or NULL if no cluster
/// update has arrived yet. Caller owns the string and must free it with aural_playback_free_string.
/// Replaces the Web API's /me/player and /me/player/queue for Swift's bootstrap.
char* _Nullable aural_playback_get_queue_snapshot(void);

/// One cluster member. String pointers are valid only for the callback. NULL means missing.
typedef struct AuralProtocolDevice {
    const char* _Nullable id;
    const char* _Nullable name;
    const char* _Nullable device_type;
} AuralProtocolDevice;

/// Device-list observation. `active_device_id` and `devices` are valid only for the callback.
/// Swift must copy them before returning. NULL `devices` with count 0 is an empty list.
typedef struct AuralDevicesSnapshot {
    uint64_t revision;
    uint64_t session_generation;
    const char* _Nullable active_device_id;
    const AuralProtocolDevice* _Nullable devices;
    size_t device_count;
} AuralDevicesSnapshot;

/// Callback function type for Connect device-list updates.
typedef void (*DevicesCallback)(const AuralDevicesSnapshot* snapshot);

/// Registers a callback to receive the Connect device list from cluster updates.
/// Fires only when the list actually changes, not on every cluster tick.
void aural_playback_register_devices_callback(DevicesCallback callback);

/// Connection observation. `device_id` and `last_error` are valid only for the callback;
/// Swift must copy them before returning. NULL means missing. Flags are 0 or 1.
typedef struct AuralConnectionSnapshot {
    uint64_t revision;
    uint64_t session_generation;
    uint8_t session_connected;
    uint8_t spirc_ready;
    uint8_t is_active_device;
    const char* _Nullable device_id;
    const char* _Nullable last_error;
} AuralConnectionSnapshot;

/// Callback function type for connection state change notifications.
typedef void (*ConnectionStateCallback)(const AuralConnectionSnapshot* snapshot);

/// Registers a callback to receive connection state change notifications.
/// Called whenever the connection state changes (connect, disconnect, error, etc.).
void aural_playback_register_connection_state_callback(ConnectionStateCallback callback);

// ============================================================================
// Audio output callbacks
// ============================================================================

/// Audio playback control event, delivered to AudioControlCallback.
typedef enum __attribute__((enum_extensibility(open))) AuralPlaybackAudioControlEvent : uint8_t {
    AuralPlaybackAudioControlEventStop = 0,
    AuralPlaybackAudioControlEventStart = 1,
    AuralPlaybackAudioControlEventClear = 2,
} AuralPlaybackAudioControlEvent;

/// Callback function type for receiving raw PCM audio data.
/// Audio format: 44100 Hz, 2 channels (stereo), Float32, interleaved.
/// Called from a background thread - must be thread-safe.
///
/// @param samples Pointer to interleaved f32 samples
/// @param sample_count Number of f32 values (frames * 2 for stereo)
typedef void (*AudioDataCallback)(const float* _Nullable samples, size_t sample_count);

/// Callback function type for audio control events (start/stop/clear).
/// Called from a background thread - must be thread-safe.
typedef void (*AudioControlCallback)(AuralPlaybackAudioControlEvent event);

/// Registers a callback to receive raw PCM audio data from the decoder.
/// The callback is called for each decoded audio chunk (~4096 samples).
void aural_playback_register_audio_data_callback(AudioDataCallback callback);

/// Registers a callback for audio playback control events (start/stop/clear).
void aural_playback_register_audio_control_callback(AudioControlCallback callback);

/// Skips to the next track in the queue.
AuralPlaybackResult aural_playback_next(void);

/// Skips to the previous track in the queue.
AuralPlaybackResult aural_playback_previous(void);

/// Seeks to the given position in milliseconds.
AuralPlaybackResult aural_playback_seek(uint32_t position_ms);

/// Sets shuffle mode for the current playback context.
///
/// @param enabled true to enable shuffle, false to disable it
AuralPlaybackResult aural_playback_set_shuffle(bool enabled);

/// Repeats the current playback context (repeat the whole queue).
AuralPlaybackResult aural_playback_set_repeat_context(bool enabled);

/// Repeats the current track (repeat one).
AuralPlaybackResult aural_playback_set_repeat_track(bool enabled);

/// Transfers playback from another device to this local player.
/// Uses the native Spotify Connect protocol via Spirc.
AuralPlaybackResult aural_playback_transfer_to_local(void);

/// Transfers playback from this local player to another device.
/// Uses the native Spotify Connect protocol via SpClient.
///
/// @param to_device_id The target device ID to transfer playback to
AuralPlaybackResult aural_playback_transfer_playback(const char* to_device_id);

/// Adds a URI to the Connect queue.
///
/// The shipped command forwards the string to Spirc as a single Spotify URI.
/// Track URIs are the path Aural uses; this export does not resolve episodes, shows,
/// or context URIs into a list of tracks.
///
/// @param uri Spotify URI (e.g., "spotify:track:xxx")
AuralPlaybackResult aural_playback_add_to_queue(const char* uri);

// ============================================================================
// Playback settings (take effect on next player initialization)
// ============================================================================

/// Sets the streaming bitrate.
/// 0 = 96 kbps, 1 = 160 kbps (default), 2 = 320 kbps
/// Note: Takes effect on next player initialization.
///
/// @param bitrate Bitrate level (0, 1, or 2)
void aural_playback_set_bitrate(uint8_t bitrate);

/// Sets gapless playback (true = enabled, false = disabled).
/// Enabled by default. Takes effect on next player initialization.
///
/// @param enabled Whether gapless playback is enabled
void aural_playback_set_gapless(bool enabled);

/// Sets the initial volume (0-65535) used when registering with Spotify Connect.
/// Must be called before aural_playback_init_player() to take effect.
///
/// @param volume Initial volume level (0 = muted, 65535 = max)
void aural_playback_set_initial_volume(uint16_t volume);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif // AURAL_PLAYBACK_H
