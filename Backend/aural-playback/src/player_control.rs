use crate::*;

/// General command failure.
pub(crate) const ERROR_GENERAL: i32 = -1;
/// Closed command channel; the engine must be reinitialized.
pub(crate) const ERROR_NEEDS_REINIT: i32 = -2;
/// Session is not yet connected; the caller should wait for readiness.
pub(crate) const ERROR_NOT_CONNECTED: i32 = -3;

/// Returns 1 if the session is connected and ready for commands, 0 otherwise.
#[no_mangle]
pub extern "C" fn aural_playback_is_session_connected() -> i32 {
    ffi_query_i32("aural_playback_is_session_connected", || {
        i32::from(with_connection(|c| c.session_connected))
    })
}

/// Helper to check if session is connected. Returns ERROR_NOT_CONNECTED if not.
///
/// Also detects zombie sessions: the Session object may have been invalidated
/// (e.g. server closed the connection overnight) without the event listener
/// ever firing SessionDisconnected (because the Spirc task was idle).
/// When detected, updates state and triggers reconnection proactively.
pub(crate) fn require_session_connected() -> Result<(), i32> {
    if !with_connection(|c| c.session_connected) {
        debug!("Command rejected: session not connected");
        return Err(ERROR_NOT_CONNECTED);
    }

    let session_invalid = SESSION
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .is_none_or(|s| s.is_invalid());

    if session_invalid {
        debug!("Detected zombie session (is_connected=true but Session is invalid)");
        mark_disconnected("Session expired");
        spawn_reconnection_loop(RecoveryIntent::capture());
        return Err(ERROR_NOT_CONNECTED);
    }

    Ok(())
}

/// Plays multiple tracks in sequence.
/// Returns 0 on success, -1 on error.
///
/// # Parameters
/// - track_uris_json: JSON array of track URIs as a C string (e.g., "[\"spotify:track:xxx\", \"spotify:track:yyy\"]")
#[no_mangle]
pub extern "C" fn aural_playback_play_tracks(track_uris_json: *const c_char) -> i32 {
    ffi_command("aural_playback_play_tracks", || {
        debug!("aural_playback_play_tracks called");
        if let Err(e) = require_session_connected() {
            return e;
        }
        let Some(track_uris_str) = (unsafe { c_string_arg(track_uris_json) }) else {
            debug!("Play tracks error: track_uris_json is null or not valid UTF-8");
            return -1;
        };

        // Parse JSON array of track URIs
        let track_uris: Vec<String> = match serde_json::from_str(&track_uris_str) {
            Ok(uris) => uris,
            Err(_e) => {
                debug!("Play tracks error: failed to parse JSON: {:?}", _e);
                return -1;
            }
        };

        if track_uris.is_empty() {
            debug!("Play tracks error: empty track URIs array");
            return -1;
        }

        // Use Spirc.load() for proper Connect state sync
        let Some(spirc) = current_spirc("Play tracks") else {
            return -1;
        };

        // Ensure device is active before loading
        if let Err(e) = ensure_active_for_playback(&spirc) {
            return e;
        }

        let load_request = LoadRequest::from_tracks(
            track_uris,
            LoadRequestOptions {
                start_playing: true,
                seek_to: 0,
                ..Default::default()
            },
        );
        match spirc.load(load_request) {
            Ok(_) => {
                debug!("Spirc.load(tracks) succeeded");
                set_active_device(true);
                0
            }
            Err(_e) => {
                debug!("Play tracks error: Spirc.load() failed: {:?}", _e);
                -1
            }
        }
    })
}

/// Plays content by its Spotify URI or URL.
/// Supports albums, playlists, and artists (context URIs).
/// @param uri_or_url Spotify URI or URL (e.g., "spotify:album:xxx")
/// @param track_index Track index to start at (-1 = from beginning, 0+ = specific track)
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn aural_playback_play_uri(uri_or_url: *const c_char, track_index: i32) -> i32 {
    ffi_command("aural_playback_play_uri", || {
        let Some(input_str) = (unsafe { c_string_arg(uri_or_url) }) else {
            debug!("Play error: uri_or_url is null or not valid UTF-8");
            return -1;
        };

        // Convert URL to URI if needed
        let uri_str = url_to_uri(&input_str);
        debug!(
            "aural_playback_play_uri called: uri={}, track_index={}",
            uri_str, track_index
        );

        if let Err(e) = require_session_connected() {
            return e;
        }

        // Use Spirc.load() with LoadRequest for proper Connect state sync
        let Some(spirc) = current_spirc("Play") else {
            return -1;
        };

        // Ensure device is active before loading
        if let Err(e) = ensure_active_for_playback(&spirc) {
            return e;
        }

        // Determine playing_track option based on track_index
        let playing_track = if track_index >= 0 {
            Some(PlayingTrack::Index(track_index as u32))
        } else {
            None
        };

        // Create LoadRequest - use from_context_uri for albums/playlists/artists,
        // from_tracks for single tracks (legacy behavior, prefer using radio for tracks)
        let load_request = if uri_str.starts_with("spotify:track:") {
            // Legacy single-track behavior - prefer using aural_playback_play_radio instead
            debug!("Spirc.load(LoadRequest::from_tracks([{}]))", uri_str);
            LoadRequest::from_tracks(
                vec![uri_str.clone()],
                LoadRequestOptions {
                    start_playing: true,
                    seek_to: 0,
                    ..Default::default()
                },
            )
        } else {
            // Context-based playback with optional starting track
            debug!(
                "Spirc.load(LoadRequest::from_context_uri({}, playing_track={:?}))",
                uri_str, playing_track
            );
            LoadRequest::from_context_uri(
                uri_str.clone(),
                LoadRequestOptions {
                    start_playing: true,
                    seek_to: 0,
                    playing_track,
                    ..Default::default()
                },
            )
        };

        match spirc.load(load_request) {
            Ok(_) => {
                debug!("Spirc.load() succeeded");
                IS_PLAYING.store(true, Ordering::SeqCst);
                set_active_device(true);
                0
            }
            Err(_e) => {
                debug!("Play error: Spirc.load() failed: {:?}", _e);
                -1
            }
        }
    })
}

/// Pauses playback.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn aural_playback_pause() -> i32 {
    ffi_command("aural_playback_pause", pause_playback)
}

/// Clears any buffered audio samples.
/// The Swift-side callback handles the flush synchronously before returning.
/// Note: aural_playback_disconnect() already handles this internally.
#[no_mangle]
pub extern "C" fn aural_playback_clear_audio_buffer() {
    ffi_void("aural_playback_clear_audio_buffer", || {
        debug!("aural_playback_clear_audio_buffer called");
        proxy_sink::ProxySink::clear_buffer();
    })
}

/// Resumes playback.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn aural_playback_resume() -> i32 {
    ffi_command("aural_playback_resume", resume_playback)
}

/// Stops playback completely.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn aural_playback_stop() -> i32 {
    ffi_command("aural_playback_stop", || {
        debug!("aural_playback_stop called");
        // Stops at the Player rather than through Spirc: this is a local teardown of
        // playback, not a Connect command.
        let player_guard = PLAYER.lock().unwrap_or_else(|e| e.into_inner());
        match player_guard.as_ref() {
            Some(player) => {
                player.stop();
                IS_PLAYING.store(false, Ordering::SeqCst);
                0
            }
            None => {
                debug!("Stop error: player not initialized");
                -1
            }
        }
    })
}

/// Shuts down the Spirc connection and sends goodbye to other devices.
/// Call this when the app is quitting to properly disconnect from Spotify Connect.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn aural_playback_shutdown() -> i32 {
    ffi_command("aural_playback_shutdown", || {
        debug!("aural_playback_shutdown called");
        // Prevent reconnection attempts during intentional shutdown
        SHUTTING_DOWN.store(true, Ordering::SeqCst);

        // The account is going away, so any streaming grant still waiting on a browser no longer
        // belongs to anyone. Only here — not in cleanup, which runs on every ordinary rebuild.
        LOGOUT_GENERATION.fetch_add(1, Ordering::SeqCst);

        // Publish the truth now rather than waiting for the listeners to notice the channel
        // close. A snapshot still claiming a connected session and a ready Spirc after an
        // intentional shutdown is what lets Swift adopt the dead session as a healthy one — on
        // logout that meant the next login skipped initialization and kept a closed Spirc.
        // Notified outside the lock: the callback re-enters Swift.
        with_connection(|c| {
            c.spirc_ready = false;
            c.session_connected = false;
            c.session_connection_id = None;
            c.connected_since_ms = 0;
            c.last_error = Some("Shutdown requested".to_string());
        });
        notify_connection_state_change();

        spirc_command("Shutdown", |spirc| spirc.shutdown())
    })
}

/// Disconnects from Spotify Connect without preventing future reconnection.
/// Use this before system sleep - the device disappears from Spotify immediately,
/// but forceReconnect() can still bring it back on wake.
/// Unlike shutdown(), this does NOT set SHUTTING_DOWN, so auto-reconnect still works.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn aural_playback_disconnect() -> i32 {
    ffi_command("aural_playback_disconnect", || {
        debug!("aural_playback_disconnect called - disconnecting for sleep");
        // Set sleeping flag to prevent auto-reconnect when cluster listener ends
        SLEEPING.store(true, Ordering::SeqCst);

        let Some(spirc) = current_spirc("Disconnect") else {
            return -1;
        };

        // First pause playback to stop producing new audio
        let _ = spirc.pause();
        debug!("aural_playback_disconnect: paused playback");

        // Clear the audio buffer synchronously to flush any remaining samples.
        // This must complete before we return, otherwise stale audio plays on wake — and it
        // blocks, which is the second reason `current_spirc` hands out a clone rather than a
        // guard.
        proxy_sink::ProxySink::clear_buffer();
        debug!("aural_playback_disconnect: audio buffer cleared");

        // Now shutdown Spirc (disconnect from Spotify Connect)
        match spirc.shutdown() {
            Ok(()) => {
                debug!("aural_playback_disconnect: spirc shutdown complete");
                0
            }
            Err(e) => spirc_error("Disconnect", &e),
        }
    })
}

/// Cleans up all player state, allowing a fresh reinitialization.
/// Call this before aural_playback_init_player() when the session has disconnected.
/// This clears all static state (session, player, spirc, etc.)
#[no_mangle]
pub extern "C" fn aural_playback_cleanup() {
    ffi_void("aural_playback_cleanup", || {
        debug!("aural_playback_cleanup called - clearing all state");

        // Invalidate the current generation first, so anything already in flight — most
        // importantly a reconnect loop sleeping between attempts — sees that what it was
        // recovering no longer exists and abandons instead of rebuilding over the teardown.
        // This bump is *before* waiting on the lifecycle lock so an in-flight commit can
        // observe supersession while it still holds that lock.
        let invalidated = SESSION_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
        debug!(
            "aural_playback_cleanup invalidated generation, now {}",
            invalidated
        );

        match block_on_export(async {
            with_lifecycle_lock(async {
                let _store = enter_store_section();
                cleanup_player_globals();
            })
            .await;
        }) {
            Ok(()) => {}
            Err(_) => {
                // Nested `block_on` cannot take `LIFECYCLE`. Unlocked writes would race an
                // in-flight build. Generation is already invalidated above; Swift does not
                // call cleanup from a Tokio worker.
                debug!("aural_playback_cleanup: refusing nested-runtime cleanup");
            }
        }
    })
}

/// Clears engine globals and session-scoped playback identity.
///
/// Callers that write these stores must already hold the lifecycle lock.
pub(crate) fn cleanup_player_globals() {
    // Signal event listener to stop
    if let Some(tx) = PLAYER_EVENT_TX
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take()
    {
        let _ = tx.send(());
    }

    // Shutdown Spirc first - this terminates the spirc_task and closes the dealer
    shutdown_spirc("aural_playback_cleanup");

    // Now clear Spirc reference
    *SPIRC.lock().unwrap_or_else(|e| e.into_inner()) = None;
    // Clear player (see do_reconnect_cleanup for why Swift is told first)
    proxy_sink::ProxySink::notify_player_gone();
    *PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // Clear mixer
    *MIXER.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // Clear session
    *SESSION.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // Reset state flags
    IS_PLAYING.store(false, Ordering::SeqCst);
    set_active_device(false);
    SHUFFLE_STATE.store(false, Ordering::SeqCst);
    REPEAT_TRACK_STATE.store(false, Ordering::SeqCst);
    REPEAT_CONTEXT_STATE.store(false, Ordering::SeqCst);
    POSITION_MS.store(0, Ordering::SeqCst);
    // Belongs to the session being torn down. Surviving a logout would let a resume seek to
    // an offset from the previous lifecycle, or another account's playback.
    RESUME_POSITION_MS.store(0, Ordering::SeqCst);
    // What that offset is an offset *into*, and the same argument applies with more at stake.
    // `resume_via_load` loads `CURRENT_CONTEXT_URI` with `CURRENT_TRACK_URI` as its track
    // hint, and nothing after a login rewrites them until playback establishes something new:
    // `update_current_context_uri` ignores empty values, and `set_current_track_uri` only runs
    // from player events. So pressing play as a freshly logged-in account reaches an activated
    // Spirc with no queue, `play()` produces no `Playing` event, and the fallback loads the
    // previous account's context — with its position, if this line's neighbour above had not
    // already been cleared. Reachable through the ordinary control path: with nobody active,
    // `sendTransportCommand` takes the Web API 404 and falls back to `aural_playback_resume`.
    //
    // Only a full cleanup clears them. The wake and reconnect paths run
    // `do_reconnect_cleanup`, which deliberately leaves playback state alone so the
    // rehydrating load has something to reload; this function runs on logout and on an
    // explicit rebuild, after which Rust has no track or context loaded — which is what Swift
    // already assumes when `performInitialization` nils its own `currentTrackUri`.
    *CURRENT_TRACK_URI.lock().unwrap_or_else(|e| e.into_inner()) = None;
    *CURRENT_CONTEXT_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = None;
    LAST_VOLUME.store(0, Ordering::SeqCst);
    LAST_ACTIVE_DEVICE_ID
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();

    // The cluster describes an account, so both of these belong to the session being torn
    // down. `aural_playback_get_queue_snapshot` is what the queue bootstrap reads on a cold start,
    // and its whole guard rests on nil meaning "no cluster update has arrived" — a surviving
    // snapshot makes that read as "this is the queue", and a freshly logged-in account gets
    // the previous one's. The device list is a dedup cache, so a stale entry would suppress
    // the first update after a login as unchanged.
    *LAST_QUEUE_JSON.lock().unwrap_or_else(|e| e.into_inner()) = None;
    LAST_DEVICES_JSON
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();

    // Reset the connection snapshot: not ready, not connected, no device ID.
    // reconnect_attempt is deliberately preserved - it drives exponential backoff and
    // is only reset on a successful connect (in the SessionConnected handler).
    with_connection(|c| {
        c.spirc_ready = false;
        c.session_connected = false;
        c.session_connection_id = None;
        c.device_id = None;
        c.connected_since_ms = 0;
    });

    // Notify connection state change
    notify_connection_state_change();

    debug!("aural_playback_cleanup complete - ready for reinitialization");
}

/// Returns 1 if currently playing, 0 otherwise.
#[no_mangle]
pub extern "C" fn aural_playback_is_playing() -> i32 {
    ffi_query_i32("aural_playback_is_playing", || {
        i32::from(IS_PLAYING.load(Ordering::SeqCst))
    })
}

/// Returns 1 if this device is the active Spotify Connect device, 0 otherwise.
/// When not active, playback controls should use Web API instead of Spirc.
#[no_mangle]
pub extern "C" fn aural_playback_is_active_device() -> i32 {
    ffi_query_i32("aural_playback_is_active_device", || {
        i32::from(is_active_device())
    })
}

/// Returns the last position reported by the Player.
///
/// Swift owns display interpolation. Interpolating here as well used to add up to five
/// seconds after Player events stopped, while reconnect rehydration correctly resumed from
/// this raw position. The two clocks therefore produced an exact five-second snap backwards.
pub(crate) fn current_position_ms() -> u32 {
    POSITION_MS.load(Ordering::SeqCst)
}

#[no_mangle]
pub extern "C" fn aural_playback_get_position_ms() -> u32 {
    ffi_query_u32("aural_playback_get_position_ms", current_position_ms)
}

/// Skips to the next track in the queue.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn aural_playback_next() -> i32 {
    ffi_command("aural_playback_next", || {
        debug!("aural_playback_next called");
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Next", |spirc| spirc.next())
    })
}

/// Skips to the previous track in the queue.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn aural_playback_previous() -> i32 {
    ffi_command("aural_playback_previous", || {
        debug!("aural_playback_previous called");
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Previous", |spirc| spirc.prev())
    })
}

/// Seeks to the given position in milliseconds.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn aural_playback_seek(position_ms: u32) -> i32 {
    ffi_command("aural_playback_seek", || {
        debug!("aural_playback_seek called: {}ms", position_ms);
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Seek", |spirc| spirc.set_position_ms(position_ms))
    })
}

/// Async core of radio playback. Safe to call from both sync (via block_on) and async contexts.
pub(crate) async fn play_radio_async(uri_str: &str) -> i32 {
    if let Err(e) = require_session_connected() {
        return e;
    }

    let session = {
        let guard = SESSION.lock().unwrap_or_else(|e| e.into_inner());
        match guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                debug!("Play radio error: session not initialized");
                return -1;
            }
        }
    };

    // Resolve the radio playlist URI
    let playlist_uri: Result<String, String> = async {
        let spotify_uri = parse_spotify_uri(uri_str)?;

        let response = session
            .spclient()
            .get_radio_for_track(&spotify_uri)
            .await
            .map_err(|e| format!("Failed to get radio: {:?}", e))?;

        let json: serde_json::Value = serde_json::from_slice(&response)
            .map_err(|e| format!("Failed to parse radio response: {:?}", e))?;

        // The API returns a playlist URI in mediaItems
        // Format: { "mediaItems": [{ "uri": "spotify:playlist:xxx" }] }
        json.get("mediaItems")
            .and_then(|items| items.as_array())
            .and_then(|items| items.first())
            .and_then(|item| item.get("uri"))
            .and_then(|u| u.as_str())
            .filter(|uri| uri.starts_with("spotify:playlist:"))
            .map(|s| s.to_string())
            .ok_or_else(|| "No radio playlist found in response".to_string())
    }
    .await;

    let playlist_uri = match playlist_uri {
        Ok(uri) => uri,
        Err(_e) => {
            debug!("Play radio error: {}", _e);
            return -1;
        }
    };

    let current_track_uri = CURRENT_TRACK_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    let seek_to = if current_track_uri.as_deref() == Some(uri_str) {
        current_position_ms()
    } else {
        0
    };

    debug!("Loading radio playlist: {} at {}ms", playlist_uri, seek_to);

    let Some(spirc) = current_spirc("Play radio") else {
        return -1;
    };

    if let Err(e) = ensure_active_for_playback(&spirc) {
        return e;
    }

    let load_request = LoadRequest::from_context_uri(
        playlist_uri.clone(),
        LoadRequestOptions {
            start_playing: true,
            seek_to,
            playing_track: Some(PlayingTrack::Uri(uri_str.to_string())),
            ..Default::default()
        },
    );
    match spirc.load(load_request) {
        Ok(_) => {
            set_active_device(true);
            0
        }
        Err(_e) => {
            debug!("Play radio error: {:?}", _e);
            -1
        }
    }
}

/// Plays radio for a seed track.
/// Gets the radio playlist URI and loads it directly via Spirc.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn aural_playback_play_radio(track_uri: *const c_char) -> i32 {
    ffi_command("aural_playback_play_radio", || {
        let Some(uri_str) = (unsafe { c_string_arg(track_uri) }) else {
            debug!("Play radio error: track_uri is null or not valid UTF-8");
            return -1;
        };

        debug!("aural_playback_play_radio called: {}", uri_str);

        match block_on_export(play_radio_async(&uri_str)) {
            Ok(code) | Err(code) => code,
        }
    })
}

/// Sets the playback volume (0-65535).
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn aural_playback_set_volume(volume: u16) -> i32 {
    ffi_command("aural_playback_set_volume", || {
        debug!("aural_playback_set_volume called: {}", volume);
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Set volume", |spirc| spirc.set_volume(volume))
    })
}

/// Sets shuffle mode on the current playback context.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn aural_playback_set_shuffle(enabled: bool) -> i32 {
    ffi_command("aural_playback_set_shuffle", || {
        debug!("aural_playback_set_shuffle called: {}", enabled);
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Set shuffle", |spirc| spirc.shuffle(enabled))
    })
}

/// Sets repeat-context on the current playback context (repeat the queue).
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn aural_playback_set_repeat_context(enabled: bool) -> i32 {
    ffi_command("aural_playback_set_repeat_context", || {
        debug!("aural_playback_set_repeat_context called: {}", enabled);
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Set repeat context", |spirc| spirc.repeat(enabled))
    })
}

/// Sets repeat-track (repeat one) on the current playback context.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn aural_playback_set_repeat_track(enabled: bool) -> i32 {
    ffi_command("aural_playback_set_repeat_track", || {
        debug!("aural_playback_set_repeat_track called: {}", enabled);
        if let Err(e) = require_session_connected() {
            return e;
        }
        spirc_command("Set repeat track", |spirc| spirc.repeat_track(enabled))
    })
}

/// Sets the streaming bitrate.
/// 0 = 96 kbps, 1 = 160 kbps (default), 2 = 320 kbps
/// Note: Takes effect on next player initialization (restart playback to apply).
#[no_mangle]
pub extern "C" fn aural_playback_set_bitrate(bitrate: u8) {
    ffi_void("aural_playback_set_bitrate", || {
        let value = bitrate.min(2); // Clamp to valid range
        let old_value = BITRATE_SETTING.swap(value, Ordering::SeqCst);
        if old_value != value {
            let _kbps = match value {
                0 => 96,
                2 => 320,
                _ => 160,
            };
            debug!(
                "Bitrate changed to {}kbps (restart playback to apply)",
                _kbps
            );
        }
    })
}

/// Gets the current bitrate setting.
/// 0 = 96 kbps, 1 = 160 kbps, 2 = 320 kbps
#[no_mangle]
pub extern "C" fn aural_playback_get_bitrate() -> u8 {
    ffi_query_u8("aural_playback_get_bitrate", || {
        BITRATE_SETTING.load(Ordering::SeqCst)
    })
}

/// Sets gapless playback (true = enabled, false = disabled).
/// Enabled by default. Takes effect on next player initialization (restart playback to apply).
#[no_mangle]
pub extern "C" fn aural_playback_set_gapless(enabled: bool) {
    ffi_void("aural_playback_set_gapless", || {
        let old_value = GAPLESS_SETTING.swap(enabled, Ordering::SeqCst);
        if old_value != enabled {
            debug!(
                "Gapless playback changed to {} (restart playback to apply)",
                enabled
            );
        }
    })
}

/// Gets the current gapless playback setting.
#[no_mangle]
pub extern "C" fn aural_playback_get_gapless() -> bool {
    ffi_query_bool("aural_playback_get_gapless", || {
        GAPLESS_SETTING.load(Ordering::SeqCst)
    })
}

/// Sets the initial volume (0-65535) used when registering with Spotify Connect.
/// Must be called before aural_playback_init_player() to take effect.
#[no_mangle]
pub extern "C" fn aural_playback_set_initial_volume(volume: u16) {
    ffi_void("aural_playback_set_initial_volume", || {
        INITIAL_VOLUME_SETTING.store(volume, Ordering::SeqCst);
    })
}

/// Transfers playback from another device to this local player.
/// Uses the native Spotify Connect protocol via Spirc.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn aural_playback_transfer_to_local() -> i32 {
    ffi_command("aural_playback_transfer_to_local", || {
        debug!("aural_playback_transfer_to_local called");
        if let Err(e) = require_session_connected() {
            return e;
        }
        // Pass None to transfer from whatever device is currently playing
        spirc_command("Transfer", |spirc| spirc.transfer(None))
    })
}

/// Transfers playback from this local player to another device.
/// Uses the native Spotify Connect protocol via SpClient.
/// Returns 0 on success, -1 on error.
///
/// # Parameters
/// - to_device_id: The target device ID to transfer playback to
#[no_mangle]
pub extern "C" fn aural_playback_transfer_playback(to_device_id: *const c_char) -> i32 {
    ffi_command("aural_playback_transfer_playback", || {
        let Some(to_device_str) = (unsafe { c_string_arg(to_device_id) }) else {
            debug!("Transfer playback error: to_device_id is null or not valid UTF-8");
            return -1;
        };

        debug!("aural_playback_transfer_playback called: {}", to_device_str);

        if let Err(e) = require_session_connected() {
            return e;
        }

        let session_guard = SESSION.lock().unwrap_or_else(|e| e.into_inner());
        let session = match session_guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                debug!("Transfer playback error: session not initialized");
                return -1;
            }
        };
        drop(session_guard);

        // Deliberately our own device ID, not the cluster's active device. The endpoint is
        // POST /connect-state/v1/connect/transfer/from/{from}/to/{to}, and the backend derives
        // the source from the session rather than validating this segment: librespot itself
        // passes its own ID for *both* sides in the transfer-to-local path, in the branch that
        // only runs while it is not the active device (Spirc::handle_command, SpircCommand::
        // Transfer). Verified by hand too — Aural -> iPhone -> a Connect speaker chains
        // fine, each hop sourced from an already-inactive Aural.
        //
        // So passing the cluster's active device here would trade a value that is always known
        // for one that lags the dealer websocket by a few hundred milliseconds, and buy nothing.
        let from_device_id = match current_device_id() {
            Some(id) => id,
            None => {
                debug!("Transfer playback error: device ID not initialized");
                return -1;
            }
        };

        let result: Result<(), String> = match block_on_export(async {
            session
                .spclient()
                .transfer(&from_device_id, &to_device_str, None)
                .await
                .map_err(|e| format!("Transfer failed: {:?}", e))?;
            Ok(())
        }) {
            Ok(result) => result,
            Err(code) => return code,
        };

        match result {
            Ok(_) => {
                // Pause local playback after successful transfer
                let player_guard = PLAYER.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(player) = player_guard.as_ref() {
                    player.pause();
                }
                IS_PLAYING.store(false, Ordering::SeqCst);
                set_active_device(false);
                0
            }
            Err(_e) => {
                debug!("Transfer playback error: {}", _e);
                -1
            }
        }
    })
}

/// Returns 1 if Spirc is initialized and connected to Spotify Connect, 0 otherwise.
#[no_mangle]
pub extern "C" fn aural_playback_is_spirc_ready() -> i32 {
    ffi_query_i32("aural_playback_is_spirc_ready", || {
        i32::from(with_connection(|c| c.spirc_ready))
    })
}

/// Adds an item to the queue.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn aural_playback_add_to_queue(uri: *const c_char) -> i32 {
    ffi_command("aural_playback_add_to_queue", || {
        let Some(uri_str) = (unsafe { c_string_arg(uri) }) else {
            debug!("Add to queue error: uri is null or not valid UTF-8");
            return -1;
        };

        debug!("[Aural] aural_playback_add_to_queue called: {}", uri_str);

        if let Err(e) = require_session_connected() {
            return e;
        }

        // Parse string to SpotifyUri
        let spotify_uri = match parse_spotify_uri(&uri_str) {
            Ok(uri) => uri,
            Err(e) => {
                debug!("Add to queue error: {}", e);
                return -1;
            }
        };

        spirc_command("Add to queue", |spirc| spirc.add_to_queue(spotify_uri))
    })
}
