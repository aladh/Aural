#ifndef SPOTTY_PLAYBACK_H
#define SPOTTY_PLAYBACK_H

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
void spotty_playback_free_string(char* _Nullable s);

// ============================================================================
// Error codes
// ============================================================================
//
// Command functions return a SpottyPlaybackResult:
//   SpottyPlaybackResultOk                   ( 0) = success
//   SpottyPlaybackResultError                (-1) = general error
//   SpottyPlaybackResultSessionDisconnected  (-2) = session disconnected, needs reinitialization
//                                             (call spotty_playback_init_player with NULL)
//   SpottyPlaybackResultSessionNotConnected  (-3) = session not connected (command rejected,
//                                             wait for session to connect)
//
// On SpottyPlaybackResultSessionDisconnected, the Spirc channel has closed (e.g., due
// to idle timeout). Call spotty_playback_init_player() with NULL so it reconnects from the
// credentials cached by spotty_playback_authorize_streaming().
//
// On SpottyPlaybackResultSessionNotConnected, the session is not yet connected. Wait
// for the connection-state callback before retrying the command.
typedef enum __attribute__((enum_extensibility(open))) SpottyPlaybackResult : int32_t {
    SpottyPlaybackResultOk = 0,
    SpottyPlaybackResultError = -1,
    SpottyPlaybackResultSessionDisconnected = -2,
    SpottyPlaybackResultSessionNotConnected = -3,
} SpottyPlaybackResult;

// ============================================================================
// Playback functions
// ============================================================================

/// Initializes the player.
/// Must be called before play/pause operations.
///
/// @param access_token A token minted with librespot's client id, or NULL to connect from
///                     the credentials cached by spotty_playback_authorize_streaming(). NULL is the
///                     normal case: only the first init after a grant carries a token.
SpottyPlaybackResult spotty_playback_init_player(const char* _Nullable access_token);

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
int32_t spotty_playback_authorize_streaming(const char* _Nonnull access_token);

/// Removes the cached streaming credentials.
/// Call on logout, after the session teardown, so the next launch cannot connect the
/// account that just logged out. Removing credentials that are not there is not an error.
void spotty_playback_clear_streaming_credentials(void);

/// Plays multiple tracks in sequence.
///
/// @param track_uris_json JSON array of track URIs as a C string
SpottyPlaybackResult spotty_playback_play_tracks(const char* track_uris_json);

/// Plays content by its Spotify URI or URL.
/// Supports albums, playlists, and artists (context URIs).
/// @param uri_or_url Spotify URI or URL (e.g., "spotify:album:xxx")
/// @param track_index Track index to start at (-1 = from beginning, 0+ = specific track)
SpottyPlaybackResult spotty_playback_play_uri(const char* uri_or_url, int32_t track_index);

/// Pauses playback.
SpottyPlaybackResult spotty_playback_pause(void);

/// Resumes playback: activate and `play()`. If no Playing event arrives, Swift issues
/// seek-capable load fallbacks via `spotty_playback_load`. Reconnect rehydration issues the
/// same Swift targets while a connection snapshot reports `resume_pending`.
SpottyPlaybackResult spotty_playback_resume(void);

/// Loads a context or single track at `position_ms`.
/// `rehydrating_generation == 0` is a user-resume load: it waits briefly for a Playing event.
/// A nonzero value names the engine session generation being rehydrated after a reconnect:
/// the engine runs the load only if that generation is current and its `resume_pending`
/// window is still open, and returns 0 as soon as the load is queued (the window is the only
/// Playing wait). Otherwise it returns an ordinary failure without touching the session.
/// Empty `track_hint` is a valid context hint. `uri` must be non-empty.
/// @param from_context true for a context URI, false for a single track URI.
SpottyPlaybackResult spotty_playback_load(
    const char* uri,
    const char* _Nullable track_hint,
    uint32_t position_ms,
    bool from_context,
    uint64_t rehydrating_generation
);

/// Shuts down the Spirc connection and sends goodbye to other devices.
/// Call this when the app is quitting to properly disconnect from Spotify Connect.
SpottyPlaybackResult spotty_playback_shutdown(void);

/// Disconnects from Spotify Connect without preventing future reconnection.
/// Use this before system sleep - the device disappears from Spotify immediately,
/// but forceReconnect() can still bring it back on wake.
/// Unlike shutdown(), this does NOT block auto-reconnect.
SpottyPlaybackResult spotty_playback_disconnect(void);

/// Cleans up all player state, allowing a fresh reinitialization.
/// Call this before spotty_playback_init_player() when the session has disconnected.
/// This clears all static state (session, player, spirc, etc.)
void spotty_playback_cleanup(void);

/// Returns the last position the Player reported, in milliseconds, or 0 if it has not
/// reported one. Deliberately not interpolated — Swift owns display interpolation, and
/// doing it on both sides made the two clocks disagree.
uint32_t spotty_playback_get_position_ms(void);

/// Position saved at deactivation for resume-load, or 0 to use the live playhead.
uint32_t spotty_playback_get_resume_position_ms(void);

/// Sticky resume-load context URI (`CURRENT_CONTEXT_URI`), or NULL if none.
/// Caller frees with `spotty_playback_free_string`. Empty string is a present empty value.
char* _Nullable spotty_playback_get_resume_context_uri(void);

/// Sticky resume-load track URI (`CURRENT_TRACK_URI`), or NULL if none.
/// Caller frees with `spotty_playback_free_string`. Empty string is a valid context hint.
char* _Nullable spotty_playback_get_resume_track_uri(void);

/// One Connect metadata pair. Pointers are valid only for the callback or until
/// `spotty_playback_free_queue_snapshot`. NULL means missing; outbound empty strings and
/// strings containing an interior NUL are also delivered as NULL.
typedef struct SpottyStringPair {
    const char* _Nullable key;
    const char* _Nullable value;
} SpottyStringPair;

/// One restriction key with its reason list.
typedef struct SpottyRestriction {
    const char* _Nullable key;
    const char* _Nullable const* _Nullable reasons;
    size_t reason_count;
} SpottyRestriction;

/// Unfiltered Connect queue row. String and nested pointers are valid only for the
/// callback or until `spotty_playback_free_queue_snapshot`. NULL means missing; outbound empty
/// strings and strings containing an interior NUL are also delivered as NULL.
typedef struct SpottyProtocolQueueTrack {
    const char* _Nullable uri;
    const char* _Nullable uid;
    const char* _Nullable provider;
    const SpottyStringPair* _Nullable metadata;
    size_t metadata_count;
    const char* _Nullable const* _Nullable removed;
    size_t removed_count;
    const char* _Nullable const* _Nullable blocked;
    size_t blocked_count;
    const SpottyRestriction* _Nullable restrictions;
    size_t restriction_count;
    const char* _Nullable album_uri;
    const char* _Nullable const* _Nullable disallow_reasons;
    size_t disallow_reason_count;
    const char* _Nullable artist_uri;
} SpottyProtocolQueueTrack;

/// Queue observation. Pointers are valid only for the callback or until
/// `spotty_playback_free_queue_snapshot`. NULL `next_tracks`/`prev_tracks` with count 0
/// is an empty list. A missing current track is three NULL track fields. Outbound empty strings
/// and strings containing an interior NUL are delivered as NULL.
typedef struct SpottyQueueSnapshot {
    uint64_t revision;
    uint64_t session_generation;
    const char* _Nullable track_uri;
    const char* _Nullable track_provider;
    const char* _Nullable track_uid;
    const SpottyProtocolQueueTrack* _Nullable next_tracks;
    size_t next_count;
    const SpottyProtocolQueueTrack* _Nullable prev_tracks;
    size_t prev_count;
    const char* _Nullable queue_revision;
    uint8_t disallow_set_queue;
    uint8_t disallow_removing_from_next_tracks;
} SpottyQueueSnapshot;

/// Callback function type for queue updates.
/// Receives a typed snapshot. Pointers are valid only for the callback.
typedef void (*QueueCallback)(const SpottyQueueSnapshot* snapshot);

/// Registers a callback to receive queue updates from cluster snapshots.
void spotty_playback_register_queue_callback(QueueCallback callback);

/// Playback observation. `track_uri` and `context_uri` are valid only for the callback;
/// Swift must copy them before returning. NULL means missing; outbound empty strings and
/// strings containing an interior NUL are also delivered as NULL. Flags are 0 or 1.
/// `is_active_device` is the protocol active-member fact captured with this observation;
/// it is independent of the arrival order of the connection callback.
typedef struct SpottyPlaybackSnapshot {
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
    uint8_t is_active_device;
    const char* _Nullable track_uri;
    const char* _Nullable context_uri;
} SpottyPlaybackSnapshot;

/// Callback function type for playback state updates.
/// Receives a typed snapshot. String pointers are valid only for the callback.
typedef void (*PlaybackStateCallback)(const SpottyPlaybackSnapshot* snapshot);

/// Registers a callback to receive playback state updates from Mercury/Spirc.
void spotty_playback_register_playback_state_callback(PlaybackStateCallback callback);

/// Forces a reconnection to Spotify servers.
/// Use this after system wake to ensure a fresh connection before playback.
/// Returns:
///   0 = Reconnection triggered
///   1 = Reconnection already in progress
///   2 = No session initialized (nothing to reconnect)
int32_t spotty_playback_force_reconnect(void);

/// Returns the last queue the Connect cluster described, or NULL if no cluster update has
/// arrived yet. Caller must copy strings before calling `spotty_playback_free_queue_snapshot`.
/// Replaces the Web API's /me/player and /me/player/queue for Swift's bootstrap.
SpottyQueueSnapshot* _Nullable spotty_playback_get_queue_snapshot(void);

/// Frees a queue snapshot allocated by `spotty_playback_get_queue_snapshot`. Tolerates NULL.
void spotty_playback_free_queue_snapshot(SpottyQueueSnapshot* _Nullable snapshot);

/// One cluster member. String pointers are valid only for the callback. NULL means missing;
/// outbound empty strings and strings containing an interior NUL are also delivered as NULL.
typedef struct SpottyProtocolDevice {
    const char* _Nullable id;
    const char* _Nullable name;
    const char* _Nullable device_type;
} SpottyProtocolDevice;

/// Device-list observation. `active_device_id` and `devices` are valid only for the callback.
/// Swift must copy them before returning. NULL `devices` with count 0 is an empty list.
typedef struct SpottyDevicesSnapshot {
    uint64_t revision;
    uint64_t session_generation;
    const char* _Nullable active_device_id;
    const SpottyProtocolDevice* _Nullable devices;
    size_t device_count;
} SpottyDevicesSnapshot;

/// Callback function type for Connect device-list updates.
typedef void (*DevicesCallback)(const SpottyDevicesSnapshot* snapshot);

/// Registers a callback to receive the Connect device list from cluster updates.
/// Fires only when the list actually changes, not on every cluster tick.
void spotty_playback_register_devices_callback(DevicesCallback callback);

/// Connection observation. `device_id` and `last_error` are valid only for the callback;
/// Swift must copy them before returning. NULL means missing; outbound empty strings and
/// strings containing an interior NUL are also delivered as NULL. Flags are 0 or 1.
/// `credentials_rejected` is a typed, definitive streaming-credential rejection. It takes
/// precedence over generic reconnect errors; it does not revoke the independent Keymaster grant.
/// `resume_pending` is set only inside a reconnect's rehydration window: the session is
/// connected and activated but `spirc_ready` is deliberately still 0, and Swift should
/// issue its resume-load targets through `spotty_playback_load` now. Readiness is published
/// once a Playing event lands, a load reports a dead Spirc, or the window times out.
typedef struct SpottyConnectionSnapshot {
    uint64_t revision;
    uint64_t session_generation;
    uint8_t session_connected;
    uint8_t spirc_ready;
    uint8_t is_active_device;
    uint8_t resume_pending;
    uint8_t credentials_rejected;
    const char* _Nullable device_id;
    const char* _Nullable last_error;
} SpottyConnectionSnapshot;

/// Callback function type for connection state change notifications.
typedef void (*ConnectionStateCallback)(const SpottyConnectionSnapshot* snapshot);

/// Registers a callback to receive connection state change notifications.
/// Called whenever the connection state changes (connect, disconnect, error, etc.).
void spotty_playback_register_connection_state_callback(ConnectionStateCallback callback);

// ============================================================================
// Audio output callbacks
// ============================================================================

/// Audio playback control event, delivered to AudioControlCallback.
typedef enum __attribute__((enum_extensibility(open))) SpottyPlaybackAudioControlEvent : uint8_t {
    SpottyPlaybackAudioControlEventStop = 0,
    SpottyPlaybackAudioControlEventStart = 1,
    SpottyPlaybackAudioControlEventClear = 2,
} SpottyPlaybackAudioControlEvent;

/// Callback function type for receiving raw PCM audio data.
/// Audio format: 44100 Hz, 2 channels (stereo), Float32, interleaved.
/// Called from a background thread - must be thread-safe.
///
/// @param samples Pointer to interleaved f32 samples
/// @param sample_count Number of f32 values (frames * 2 for stereo)
typedef void (*AudioDataCallback)(const float* _Nullable samples, size_t sample_count);

/// Callback function type for audio control events (start/stop/clear).
/// Called from a background thread - must be thread-safe.
typedef void (*AudioControlCallback)(SpottyPlaybackAudioControlEvent event);

/// Registers a callback to receive raw PCM audio data from the decoder.
/// The callback is called for each decoded audio chunk (~4096 samples).
void spotty_playback_register_audio_data_callback(AudioDataCallback callback);

/// Registers a callback for audio playback control events (start/stop/clear).
void spotty_playback_register_audio_control_callback(AudioControlCallback callback);

// ============================================================================
/// Skips to the next track in the queue.
SpottyPlaybackResult spotty_playback_next(void);

/// Skips to the previous track in the queue.
SpottyPlaybackResult spotty_playback_previous(void);

/// Seeks to the given position in milliseconds.
SpottyPlaybackResult spotty_playback_seek(uint32_t position_ms);

/// Sets shuffle mode for the current playback context.
///
/// @param enabled true to enable shuffle, false to disable it
SpottyPlaybackResult spotty_playback_set_shuffle(bool enabled);

/// Repeats the current playback context (repeat the whole queue).
SpottyPlaybackResult spotty_playback_set_repeat_context(bool enabled);

/// Repeats the current track (repeat one).
SpottyPlaybackResult spotty_playback_set_repeat_track(bool enabled);

/// Transfers playback from another device to this local player.
/// Uses the native Spotify Connect protocol via Spirc.
SpottyPlaybackResult spotty_playback_transfer_to_local(void);

/// Transfers playback from this local player to another device.
/// Uses the native Spotify Connect protocol via SpClient.
///
/// @param to_device_id The target device ID to transfer playback to
SpottyPlaybackResult spotty_playback_transfer_playback(const char* to_device_id);

/// Adds a URI to the Connect queue.
///
/// The shipped command forwards the string to Spirc as a single Spotify URI.
/// Track URIs are the path Spotty uses; this export does not resolve episodes, shows,
/// or context URIs into a list of tracks.
///
/// @param uri Spotify URI (e.g., "spotify:track:xxx")
SpottyPlaybackResult spotty_playback_add_to_queue(const char* uri);

// ============================================================================
// Playback settings (take effect on next player initialization)
// ============================================================================

/// Sets the streaming bitrate.
/// 0 = 96 kbps, 1 = 160 kbps (default), 2 = 320 kbps
/// Note: Takes effect on next player initialization.
///
/// @param bitrate Bitrate level (0, 1, or 2)
void spotty_playback_set_bitrate(uint8_t bitrate);

/// Sets gapless playback (true = enabled, false = disabled).
/// Enabled by default. Takes effect on next player initialization.
///
/// @param enabled Whether gapless playback is enabled
void spotty_playback_set_gapless(bool enabled);

/// Sets the initial volume (0-65535) used when registering with Spotify Connect.
/// Must be called before spotty_playback_init_player() to take effect.
///
/// @param volume Initial volume level (0 = muted, 65535 = max)
void spotty_playback_set_initial_volume(uint16_t volume);

/// Sets the user-facing device name advertised to Spotify Connect.
/// Must be called before spotty_playback_init_player() to take effect.
/// The string is copied during this call.
///
/// @param device_name Non-empty UTF-8 display name
void spotty_playback_set_device_name(const char* device_name);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif // SPOTTY_PLAYBACK_H
