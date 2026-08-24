use super::*;

// Recovery must start from transport evidence, not from Connect activity. These cover
// the distinction that P0.1 was about: librespot emits the same deactivation event for
// an ordinary handoff and for an unexpected Spirc shutdown.

#[test]
fn deactivation_alone_does_not_recover() {
    // Another device took over. The session is fine — do not reconnect.
    assert!(!should_recover_after_deactivation(false, false));
}

#[test]
fn deactivation_with_dead_session_recovers() {
    // librespot calls handle_disconnect on unexpected Spirc shutdown; the cluster
    // listener can miss that while the dealer stream is still open.
    assert!(should_recover_after_deactivation(true, false));
}

#[test]
fn deactivation_during_teardown_never_recovers() {
    // Sleep and shutdown disconnect on purpose; recovering would fight them.
    assert!(!should_recover_after_deactivation(true, true));
    assert!(!should_recover_after_deactivation(false, true));
}

// A listener or loop belonging to a replaced session must not act. Before the rewrite
// this could not be expressed: one event listener survived across sessions, so its
// generation was rewritten in place and the staleness check compared two values that
// were always equal.

#[test]
fn a_superseded_listener_is_rejected() {
    // The replacement is installed while the old listener is still draining.
    assert!(!listener_may_act(3, 4));
}

#[test]
fn the_current_listener_acts() {
    assert!(listener_may_act(4, 4));
}

#[test]
fn a_reconnect_loop_abandons_after_its_generation_moves() {
    // A restart landed while the loop slept between attempts; rebuilding now would
    // replace a healthy new session with one built from a stale token.
    assert!(!reconnect_may_proceed(2, 3, false));
}

#[test]
fn a_reconnect_loop_abandons_during_teardown() {
    assert!(!reconnect_may_proceed(2, 2, true));
}

#[test]
fn a_reconnect_loop_does_not_abandon_because_of_its_own_rebuild() {
    // Regression: each attempt calls init_player_async, which bumps the generation
    // before it can fail. Comparing against the value captured at loop start made the
    // loop read its own rebuild as a foreign supersede and give up after one attempt,
    // killing the remaining nine backoff retries — and with the Player already torn
    // down by the preceding cleanup, playback stayed dead for the whole outage.
    let mut recovering = 2;
    let after_own_failed_attempt = 3; // init_player_async bumped it, then errored
    assert!(!reconnect_may_proceed(
        recovering,
        after_own_failed_attempt,
        false
    ));

    // Adopting the generation our own attempt produced is what keeps the loop alive.
    recovering = after_own_failed_attempt;
    assert!(reconnect_may_proceed(
        recovering,
        after_own_failed_attempt,
        false
    ));
}

#[test]
fn a_reconnect_loop_still_abandons_on_a_foreign_rebuild() {
    // Adopting our own bump must not blind the loop to someone else's.
    let recovering = 3; // adopted after our own attempt
    assert!(!reconnect_may_proceed(recovering, 4, false));
}

#[test]
fn a_reconnect_loop_proceeds_for_its_own_generation() {
    assert!(reconnect_may_proceed(2, 2, false));
}

// The periodic health check is the only thing watching while Aural is idle, so its
// trigger has to cover more than a session that reports itself invalid.

// Only local playback is rehydrated, and the intent has to be captured before the
// disconnect handling clears it.

#[test]
fn local_playback_is_resumed() {
    assert!(RecoveryIntent {
        was_playing: true,
        was_active: true
    }
    .should_resume());
}

#[test]
fn remote_playback_is_left_alone() {
    // Another device is still playing; taking over would steal it from the user.
    assert!(!RecoveryIntent {
        was_playing: true,
        was_active: false
    }
    .should_resume());
}

// The Stopped event cannot say why playback stopped, so a deactivation saves its own
// resume point rather than relying on the live position surviving.

#[test]
fn a_deactivation_resume_point_outranks_the_live_position() {
    // The live value is what Stopped reset it to on the way out.
    assert_eq!(resume_position(93606, 0), 93606);
}

#[test]
fn an_ordinary_resume_uses_the_live_position() {
    // Nothing saved: a pause and play that never went through a deactivation.
    assert_eq!(resume_position(0, 12087), 12087);
}

#[test]
fn a_queue_that_ran_out_resumes_from_the_start() {
    // `next` on the last track stops playback without deactivating, so nothing is
    // saved and Stopped has zeroed the live position. Pressing play must not restart
    // the track partway through.
    assert_eq!(resume_position(0, 0), 0);
}

#[test]
fn nothing_is_resumed_without_also_being_activated() {
    // `resume_via_load` requires an already-activated device: Spirc discards `Load`
    // while inactive, and the function no longer claims activity for itself. Its
    // reconnect caller gets that from `activate_after_connect`, which is a separate
    // argument to `init_player_async` — so pin the implication that keeps the two
    // consistent rather than leaving it to whoever next edits the call.
    for was_playing in [false, true] {
        for was_active in [false, true] {
            let intent = RecoveryIntent {
                was_playing,
                was_active,
            };
            assert!(!intent.should_resume() || intent.was_active);
        }
    }
}

#[test]
fn a_paused_local_player_is_not_resumed() {
    assert!(!RecoveryIntent {
        was_playing: false,
        was_active: true
    }
    .should_resume());
}

#[test]
fn health_check_recovers_a_dead_session() {
    assert!(health_check_should_recover(true, false, false, false));
}

#[test]
fn health_check_recovers_a_session_that_never_connected() {
    // Regression: Session::is_invalid is only set by shutdown(), so a session left
    // behind by a failed init reports valid forever. Before this, nothing retried —
    // the Swift watchdog used to paper over it by rebuilding every 120s, and removing
    // that watchdog exposed the gap at both startup and after a failed rebuild.
    assert!(health_check_should_recover(false, false, false, false));
}

#[test]
fn health_check_leaves_a_healthy_session_alone() {
    assert!(!health_check_should_recover(false, true, false, false));
}

#[test]
fn health_check_defers_to_a_running_reconnect() {
    // The loop is what fixes this; firing alongside it would just re-publish a
    // disconnected snapshot once a minute.
    assert!(!health_check_should_recover(true, false, true, false));
}

#[test]
fn health_check_stays_out_of_a_teardown() {
    assert!(!health_check_should_recover(true, false, false, true));
}

#[test]
fn only_the_current_cluster_listener_recovers() {
    assert!(should_recover_after_cluster_end(7, 7, false));
    // An older listener ending is the expected result of its session being replaced.
    assert!(!should_recover_after_cluster_end(6, 7, false));
    assert!(!should_recover_after_cluster_end(7, 7, true));
}

// Active-device state is derived from the cluster rather than inferred from whichever
// command ran last (P1.3).

#[test]
fn cluster_naming_us_makes_us_active() {
    assert!(is_active_in_cluster(
        "aural_playback_1234",
        Some("aural_playback_1234")
    ));
}

#[test]
fn cluster_naming_another_device_makes_us_inactive() {
    assert!(!is_active_in_cluster(
        "phone-abc",
        Some("aural_playback_1234")
    ));
}

#[test]
fn empty_active_device_clears_activity() {
    // "Nothing is playing anywhere" is a real state, not a missing value.
    assert!(!is_active_in_cluster("", Some("aural_playback_1234")));
}

#[test]
fn no_local_device_id_is_never_active() {
    assert!(!is_active_in_cluster("phone-abc", None));
    assert!(!is_active_in_cluster("", None));
}

// The streaming session connects from credentials cached on disk, so that every init
// after the one-time grant needs no token at all. See
// plans/streaming-auth-needs-a-first-party-client-id.md.

#[test]
fn credentials_cache_dir_is_absolute_and_app_scoped() {
    let dir = credentials_cache_dir();
    assert!(dir.is_absolute(), "cache dir must be absolute: {dir:?}");
    assert!(
        dir.ends_with("Aural/credentials"),
        "cache dir must be app-scoped: {dir:?}"
    );
}

#[test]
fn a_run_is_superseded_when_the_generation_moves() {
    // The grant writes credentials from inside Session::connect, so a logout landing
    // mid-connect must be detected afterwards — see AGENTS.md, a superseded run must
    // not write.
    assert!(!run_is_superseded(4, 4));
    assert!(run_is_superseded(4, 5));
    // A teardown that reset the counter is a supersession too, not a match.
    assert!(run_is_superseded(4, 0));
}

/// Serialises the tests that drive the real FFI entry points. Everything else here is a
/// pure predicate and needs no lock, but these mutate process-wide generation counters
/// and the suite runs in parallel.
static GLOBAL_STATE: Mutex<()> = Mutex::new(());

fn lock_global_state() -> std::sync::MutexGuard<'static, ()> {
    GLOBAL_STATE.lock().unwrap_or_else(|e| e.into_inner())
}

#[test]
fn routine_cleanup_does_not_supersede_a_grant() {
    let _guard = lock_global_state();
    // A grant waits on a human in a browser, which is long enough for an ordinary play,
    // retry or wake to rebuild the player underneath it. Those bump SESSION_GENERATION;
    // if the grant watched that counter it would report itself superseded and delete the
    // credentials it had just written.
    let before = LOGOUT_GENERATION.load(Ordering::SeqCst);
    let session_before = SESSION_GENERATION.load(Ordering::SeqCst);

    aural_playback_cleanup();

    assert_ne!(
        SESSION_GENERATION.load(Ordering::SeqCst),
        session_before,
        "cleanup is expected to move the session generation"
    );
    assert_eq!(
        LOGOUT_GENERATION.load(Ordering::SeqCst),
        before,
        "cleanup must not invalidate a streaming grant"
    );
}

#[test]
fn shutdown_supersedes_a_grant() {
    let _guard = lock_global_state();

    // Logout and app termination both go through here, and both mean the account this
    // grant belongs to is gone.
    let before = LOGOUT_GENERATION.load(Ordering::SeqCst);

    let _ = aural_playback_shutdown();

    assert!(run_is_superseded(
        before,
        LOGOUT_GENERATION.load(Ordering::SeqCst)
    ));

    // Leave the flag as the rest of the suite expects; init clears it in the app.
    SHUTTING_DOWN.store(false, Ordering::SeqCst);
}

#[test]
fn clearing_credentials_removes_the_directory() {
    // Deliberately parameterised: cargo test runs unsandboxed, so exercising this
    // against credentials_cache_dir() would delete the real credentials on this machine
    // every time the suite ran.
    let dir = std::env::temp_dir().join(format!("aural-creds-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create cache dir");
    std::fs::write(dir.join("credentials.json"), b"{}").expect("write credentials");
    assert!(dir.exists());

    clear_credentials_at(&dir);

    assert!(!dir.exists(), "logout must not leave credentials behind");
}

#[test]
fn clearing_credentials_that_are_not_there_is_fine() {
    // Logging out without ever having authorized streaming is ordinary, not an error.
    let dir = std::env::temp_dir().join(format!("aural-absent-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);

    clear_credentials_at(&dir);

    assert!(!dir.exists());
}

#[test]
fn control_snapshot_stamps_are_monotonic_and_session_scoped() {
    let _guard = lock_global_state();
    let expected_generation = SESSION_GENERATION.load(Ordering::SeqCst);

    let first = stamped_snapshot(|stamp| stamp);
    let second = stamped_snapshot(|stamp| stamp);

    assert_eq!(second.revision, first.revision + 1);
    assert_eq!(first.session_generation, expected_generation);
    assert_eq!(second.session_generation, expected_generation);
}

#[test]
fn playback_snapshot_json_keeps_legacy_fields_and_adds_ordering() {
    let json = serde_json::to_value(PlaybackStateUpdate {
        revision: 12,
        session_generation: 4,
        is_playing: true,
        is_paused: false,
        track_uri: "spotify:track:test".to_string(),
        position_ms: 1_250,
        duration_ms: 180_000,
        shuffle: true,
        repeat_track: false,
        repeat_context: true,
        timestamp_ms: 99,
    })
    .expect("serialize playback snapshot");

    assert_eq!(json["revision"], 12);
    assert_eq!(json["session_generation"], 4);
    assert_eq!(json["is_playing"], true);
    assert_eq!(json["is_paused"], false);
    assert_eq!(json["track_uri"], "spotify:track:test");
    assert_eq!(json["position_ms"], 1_250);
    assert_eq!(json["duration_ms"], 180_000);
    assert_eq!(json["shuffle"], true);
    assert_eq!(json["repeat_track"], false);
    assert_eq!(json["repeat_context"], true);
    assert_eq!(json["timestamp_ms"], 99);
}

#[test]
fn queue_snapshot_json_keeps_legacy_fields_and_adds_ordering() {
    let json = serde_json::to_value(QueueState {
        revision: 13,
        session_generation: 4,
        track: None,
        next_tracks: Vec::new(),
        prev_tracks: Vec::new(),
    })
    .expect("serialize queue snapshot");

    assert_eq!(json["revision"], 13);
    assert_eq!(json["session_generation"], 4);
    assert!(json["track"].is_null());
    assert_eq!(json["next_tracks"], serde_json::json!([]));
    assert_eq!(json["prev_tracks"], serde_json::json!([]));
}

#[test]
fn devices_snapshot_wraps_legacy_devices_with_ordering() {
    let json = serde_json::to_value(DevicesState {
        revision: 15,
        session_generation: 6,
        devices: vec![ConnectDeviceInfo {
            id: "speaker-1".to_string(),
            name: "Living Room".to_string(),
            device_type: "SPEAKER".to_string(),
            is_active: true,
            is_private_session: false,
            is_restricted: false,
            volume_percent: Some(42),
            disable_volume: true,
        }],
    })
    .expect("serialize devices snapshot");

    assert_eq!(json["revision"], 15);
    assert_eq!(json["session_generation"], 6);
    assert_eq!(json["devices"].as_array().map(Vec::len), Some(1));

    let device = &json["devices"][0];
    assert_eq!(device["id"], "speaker-1");
    assert_eq!(device["name"], "Living Room");
    assert_eq!(device["type"], "SPEAKER");
    assert_eq!(device["is_active"], true);
    assert_eq!(device["is_private_session"], false);
    assert_eq!(device["is_restricted"], false);
    assert_eq!(device["volume_percent"], 42);
    assert_eq!(device["disable_volume"], true);
}

fn provided_track(uri: &str, provider: &str) -> ProvidedTrack {
    ProvidedTrack {
        uri: uri.to_string(),
        provider: provider.to_string(),
        ..Default::default()
    }
}

#[test]
fn queue_conversion_preserves_identity_and_provider_only() {
    let item = to_queue_item(&provided_track("spotify:track:abc", "queue"));

    assert_eq!(item.uri, "spotify:track:abc");
    assert_eq!(item.provider, "queue");
    assert!(item.name.is_empty());
    assert!(item.artist.is_empty());
    assert!(item.image_url.is_empty());
    assert!(item.album_name.is_empty());
    assert_eq!(item.duration_ms, 0);
}

#[test]
fn queue_conversion_stops_at_delimiter_and_filters_non_tracks() {
    let tracks = vec![
        provided_track("spotify:episode:ignored", "context"),
        provided_track("spotify:track:first", "queue"),
        provided_track("spotify:delimiter", "delimiter"),
        provided_track("spotify:track:autoplay-hidden", "autoplay"),
    ];

    let items = collect_queue_items(&tracks, "next");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].uri, "spotify:track:first");
    assert_eq!(items[0].provider, "queue");
}

#[test]
fn connection_snapshot_json_keeps_legacy_fields_and_adds_generation() {
    let json = serde_json::to_value(ConnectionStateInfo {
        revision: 14,
        session_generation: 5,
        session_connected: true,
        session_connection_id: Some("connection".to_string()),
        spirc_ready: true,
        device_id: Some("device".to_string()),
        device_name: "Aural".to_string(),
        reconnect_attempt: 0,
        last_error: None,
        connected_since_ms: Some(100),
        is_active_device: false,
    })
    .expect("serialize connection snapshot");

    assert_eq!(json["revision"], 14);
    assert_eq!(json["session_generation"], 5);
    assert_eq!(json["session_connected"], true);
    assert_eq!(json["session_connection_id"], "connection");
    assert_eq!(json["spirc_ready"], true);
    assert_eq!(json["device_id"], "device");
    assert_eq!(json["device_name"], "Aural");
    assert_eq!(json["reconnect_attempt"], 0);
    assert!(json["last_error"].is_null());
    assert_eq!(json["connected_since_ms"], 100);
    assert_eq!(json["is_active_device"], false);
}

/// Compile-time ABI contract. The release archive is also checked with `nm`; these assignments
/// make signature drift fail in the fast Rust test suite before reaching the linker check.
#[test]
fn exported_c_function_signatures_are_stable() {
    let _: extern "C" fn(*mut c_char) = aural_playback_free_string;
    let _: extern "C" fn() = aural_playback_clear_streaming_credentials;
    let _: extern "C" fn() = aural_playback_clear_audio_buffer;
    let _: extern "C" fn() = aural_playback_cleanup;
    let _: extern "C" fn() -> *mut c_char = aural_playback_last_grant_account;
    let _: extern "C" fn() -> *mut c_char = aural_playback_get_connection_state;
    let _: extern "C" fn() -> *mut c_char = aural_playback_get_queue_snapshot;

    let _: [extern "C" fn() -> i32; 13] = [
        aural_playback_force_reconnect,
        aural_playback_is_session_connected,
        aural_playback_pause,
        aural_playback_resume,
        aural_playback_stop,
        aural_playback_shutdown,
        aural_playback_disconnect,
        aural_playback_is_playing,
        aural_playback_is_active_device,
        aural_playback_next,
        aural_playback_previous,
        aural_playback_transfer_to_local,
        aural_playback_is_spirc_ready,
    ];

    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_authorize_streaming;
    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_init_player;
    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_play_tracks;
    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_play_radio;
    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_transfer_playback;
    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_add_to_queue;
    let _: extern "C" fn(*const c_char, i32) -> i32 = aural_playback_play_uri;
    let _: extern "C" fn(u32) -> i32 = aural_playback_seek;
    let _: extern "C" fn() -> u32 = aural_playback_get_position_ms;
    let _: extern "C" fn(u16) -> i32 = aural_playback_set_volume;
    let _: extern "C" fn(u8) = aural_playback_set_bitrate;
    let _: extern "C" fn() -> u8 = aural_playback_get_bitrate;
    let _: extern "C" fn(u16) = aural_playback_set_initial_volume;
    let _: extern "C" fn(bool) -> i32 = aural_playback_set_shuffle;
    let _: extern "C" fn(bool) -> i32 = aural_playback_set_repeat_context;
    let _: extern "C" fn(bool) -> i32 = aural_playback_set_repeat_track;
    let _: extern "C" fn(bool) = aural_playback_set_gapless;
    let _: extern "C" fn() -> bool = aural_playback_get_gapless;

    let _: extern "C" fn(extern "C" fn(*const c_char)) = aural_playback_register_queue_callback;
    let _: extern "C" fn(extern "C" fn(*const c_char)) =
        aural_playback_register_playback_state_callback;
    let _: extern "C" fn(extern "C" fn(*const c_char)) = aural_playback_register_loading_callback;
    let _: extern "C" fn(extern "C" fn(*const c_char)) =
        aural_playback_register_session_client_changed_callback;
    let _: extern "C" fn(extern "C" fn(*const c_char)) = aural_playback_register_set_queue_callback;
    let _: extern "C" fn(extern "C" fn(*const c_char)) =
        aural_playback_register_active_device_callback;
    let _: extern "C" fn(extern "C" fn(*const c_char)) = aural_playback_register_devices_callback;
    let _: extern "C" fn(extern "C" fn(*const c_char)) =
        aural_playback_register_connection_state_callback;
    let _: extern "C" fn(extern "C" fn(u16)) = aural_playback_register_volume_callback;
    let _: extern "C" fn(extern "C" fn()) = aural_playback_register_became_inactive_callback;
    let _: extern "C" fn(extern "C" fn()) = aural_playback_register_became_active_callback;
    let _: extern "C" fn(extern "C" fn(*const f32, usize)) =
        aural_playback_register_audio_data_callback;
    let _: extern "C" fn(extern "C" fn(u8)) = aural_playback_register_audio_control_callback;
}
