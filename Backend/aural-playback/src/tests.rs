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
fn resume_load_plan_prefers_context_then_track_at_the_resume_position() {
    let plan = ResumeLoadPlan::capture(
        93606,
        0,
        Some("spotify:playlist:ctx".to_string()),
        Some("spotify:track:one".to_string()),
    );
    assert_eq!(
        plan.targets(),
        vec![
            ResumeLoadTarget::Context {
                uri: "spotify:playlist:ctx".to_string(),
                track_hint: Some("spotify:track:one".to_string()),
                position_ms: 93606,
            },
            ResumeLoadTarget::Track {
                uri: "spotify:track:one".to_string(),
                position_ms: 93606,
            },
        ]
    );
}

#[test]
fn resume_load_plan_skips_empty_context_and_empty_track_fallback() {
    let plan = ResumeLoadPlan::capture(0, 12087, Some(String::new()), Some(String::new()));
    assert_eq!(plan.position_ms, 12087);
    assert!(plan.context_uri.is_none());
    assert!(
        plan.targets().is_empty(),
        "empty context and empty track must not produce a load target"
    );
}

#[test]
fn resume_load_plan_with_only_a_track_loads_that_track() {
    let plan = ResumeLoadPlan::capture(0, 0, None, Some("spotify:track:solo".to_string()));
    assert_eq!(
        plan.targets(),
        vec![ResumeLoadTarget::Track {
            uri: "spotify:track:solo".to_string(),
            position_ms: 0,
        }]
    );
}

#[test]
fn load_at_position_rejects_an_empty_uri_before_session_checks() {
    assert_eq!(
        load_at_position(String::new(), None, 0, false),
        ERROR_GENERAL
    );
    assert_eq!(
        load_at_position(String::new(), Some("spotify:track:x".into()), 10, true),
        ERROR_GENERAL
    );
}

fn take_owned_c_string(ptr: *mut std::os::raw::c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let value = unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(str::to_owned);
    aural_playback_free_string(ptr);
    value
}

#[test]
fn resume_identity_exports_read_session_globals() {
    let _guard = lock_global_state();
    *CURRENT_CONTEXT_URI.lock().unwrap() = Some("spotify:playlist:ctx".into());
    *CURRENT_TRACK_URI.lock().unwrap() = Some("spotify:track:one".into());
    assert_eq!(
        take_owned_c_string(aural_playback_get_resume_context_uri()).as_deref(),
        Some("spotify:playlist:ctx")
    );
    assert_eq!(
        take_owned_c_string(aural_playback_get_resume_track_uri()).as_deref(),
        Some("spotify:track:one")
    );

    *CURRENT_TRACK_URI.lock().unwrap() = Some(String::new());
    assert_eq!(
        take_owned_c_string(aural_playback_get_resume_track_uri()).as_deref(),
        Some("")
    );

    *CURRENT_CONTEXT_URI.lock().unwrap() = None;
    *CURRENT_TRACK_URI.lock().unwrap() = None;
    assert_eq!(
        take_owned_c_string(aural_playback_get_resume_context_uri()),
        None
    );
    assert_eq!(
        take_owned_c_string(aural_playback_get_resume_track_uri()),
        None
    );
}

#[test]
fn resume_load_plan_keeps_an_empty_track_as_a_context_hint_only() {
    let plan = ResumeLoadPlan::capture(
        10,
        1,
        Some("spotify:album:ctx".to_string()),
        Some(String::new()),
    );
    assert_eq!(
        plan.targets(),
        vec![ResumeLoadTarget::Context {
            uri: "spotify:album:ctx".to_string(),
            track_hint: Some(String::new()),
            position_ms: 10,
        }]
    );
}

#[test]
fn playing_event_waits_observe_sequence_advances_and_timeouts() {
    let _guard = lock_global_state();
    let previous = PLAYING_EVENT_SEQ.fetch_add(1, Ordering::SeqCst);
    assert!(playing_event_advanced(previous));
    assert!(wait_for_playing_event(previous, Duration::ZERO));
    let current = PLAYING_EVENT_SEQ.load(Ordering::SeqCst);
    assert!(!playing_event_advanced(current));
    assert!(!wait_for_playing_event(current, Duration::ZERO));
    assert!(RUNTIME.block_on(wait_for_playing_event_async(previous, Duration::ZERO)));
    assert!(!RUNTIME.block_on(wait_for_playing_event_async(current, Duration::ZERO)));
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
    let dir = credentials_cache_dir().expect("this environment must expose an absolute HOME");
    assert!(dir.is_absolute(), "cache dir must be absolute: {dir:?}");
    assert!(
        dir.ends_with("Aural/credentials"),
        "cache dir must be app-scoped: {dir:?}"
    );
}

#[test]
fn credentials_cache_dir_uses_injected_home_without_tmp_fallback() {
    let dir = credentials_cache_dir_from_home(Some(std::path::Path::new(
        "/Users/tester/Library/Containers/app",
    )))
    .expect("absolute HOME is usable");
    assert_eq!(
        dir,
        std::path::PathBuf::from(
            "/Users/tester/Library/Containers/app/Library/Application Support/Aural/credentials"
        )
    );

    assert_eq!(
        credentials_cache_dir_from_home(None),
        Err(CredentialsCacheError::Missing)
    );
    assert_eq!(
        credentials_cache_dir_from_home(Some(std::path::Path::new(""))),
        Err(CredentialsCacheError::Missing)
    );
    assert_eq!(
        credentials_cache_dir_from_home(Some(std::path::Path::new("Library"))),
        Err(CredentialsCacheError::Relative)
    );
    for shared in [
        "/tmp",
        "/tmp/",
        "/tmp/aural",
        "/private/tmp",
        "/private/tmp/",
        "/private/tmp/aural",
        "/var/tmp",
        "/private/var/tmp",
        "/var/../tmp",
        "/Users/../tmp",
        "/foo/../private/tmp",
        "/private/./tmp",
    ] {
        assert_eq!(
            credentials_cache_dir_from_home(Some(std::path::Path::new(shared))),
            Err(CredentialsCacheError::SharedTemporary),
            "shared temporary HOME must fail closed: {shared}"
        );
    }
}

#[cfg(unix)]
#[test]
fn credentials_cache_dir_is_created_private() {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("aural-creds-mode-{}-private", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    ensure_private_credentials_dir(&dir).expect("create private cache dir");
    let mode = std::fs::metadata(&dir)
        .expect("cache dir metadata")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(
        mode, 0o700,
        "credential cache must not be group- or world-accessible"
    );
    let _ = std::fs::remove_dir_all(&dir);
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

fn lock_global_state() -> std::sync::MutexGuard<'static, ()> {
    lock_lifecycle_test_globals()
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

/// Compile-time ABI contract. The release archive is also checked with `nm`; these assignments
/// make signature drift fail in the fast Rust test suite before reaching the linker check.
///
/// [`exported_c_functions_enter_through_the_panic_barrier`] extends this with a source-level
/// check that every `extern "C"` body starts at a panic-barrier helper, so a new symbol cannot
/// skip the boundary by being added only here.
#[test]
fn exported_c_function_signatures_are_stable() {
    let _: extern "C" fn(*mut c_char) = aural_playback_free_string;
    let _: extern "C" fn() = aural_playback_clear_streaming_credentials;
    let _: extern "C" fn() = aural_playback_cleanup;
    let _: [extern "C" fn() -> *mut c_char; 3] = [
        aural_playback_get_queue_snapshot,
        aural_playback_get_resume_context_uri,
        aural_playback_get_resume_track_uri,
    ];

    let _: [extern "C" fn() -> i32; 8] = [
        aural_playback_force_reconnect,
        aural_playback_pause,
        aural_playback_resume,
        aural_playback_shutdown,
        aural_playback_disconnect,
        aural_playback_next,
        aural_playback_previous,
        aural_playback_transfer_to_local,
    ];

    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_authorize_streaming;
    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_init_player;
    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_play_tracks;
    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_transfer_playback;
    let _: extern "C" fn(*const c_char) -> i32 = aural_playback_add_to_queue;
    let _: extern "C" fn(*const c_char, i32) -> i32 = aural_playback_play_uri;
    let _: extern "C" fn(*const c_char, *const c_char, u32, bool) -> i32 = aural_playback_load;
    let _: extern "C" fn(u32) -> i32 = aural_playback_seek;
    let _: extern "C" fn() -> u32 = aural_playback_get_position_ms;
    let _: extern "C" fn() -> u32 = aural_playback_get_resume_position_ms;
    let _: extern "C" fn(u8) = aural_playback_set_bitrate;
    let _: extern "C" fn(u16) = aural_playback_set_initial_volume;
    let _: extern "C" fn(bool) -> i32 = aural_playback_set_shuffle;
    let _: extern "C" fn(bool) -> i32 = aural_playback_set_repeat_context;
    let _: extern "C" fn(bool) -> i32 = aural_playback_set_repeat_track;
    let _: extern "C" fn(bool) = aural_playback_set_gapless;

    let _: extern "C" fn(extern "C" fn(*const c_char)) = aural_playback_register_queue_callback;
    let _: extern "C" fn(extern "C" fn(*const c_char)) =
        aural_playback_register_playback_state_callback;
    let _: extern "C" fn(extern "C" fn(*const c_char)) = aural_playback_register_devices_callback;
    let _: extern "C" fn(extern "C" fn(*const c_char)) =
        aural_playback_register_connection_state_callback;
    let _: extern "C" fn(extern "C" fn(*const f32, usize)) =
        aural_playback_register_audio_data_callback;
    let _: extern "C" fn(extern "C" fn(u8)) = aural_playback_register_audio_control_callback;
}

#[test]
fn ffi_command_panic_returns_general_error() {
    assert_eq!(
        ffi_command("test_command", || panic!("token-payload-must-not-abort")),
        ERROR_GENERAL
    );
}

#[test]
fn ffi_query_panic_returns_conservative_zero_or_false() {
    assert_eq!(
        ffi_query_i32("test_flag", || panic!("token-payload-must-not-abort")),
        0
    );
    assert_eq!(
        ffi_query_u32("test_u32", || panic!("token-payload-must-not-abort")),
        0
    );
    assert_eq!(
        ffi_query_u8("test_u8", || panic!("token-payload-must-not-abort")),
        0
    );
    assert!(!ffi_query_bool("test_bool", || panic!(
        "token-payload-must-not-abort"
    )));
}

#[test]
fn ffi_owned_string_panic_returns_null() {
    let ptr = ffi_owned_string("test_string", || panic!("token-payload-must-not-abort"));
    assert!(ptr.is_null());
}

#[test]
fn ffi_void_panic_is_a_noop() {
    ffi_void("test_void", || panic!("token-payload-must-not-abort"));
}

#[test]
fn ffi_helpers_return_the_work_value_when_they_do_not_panic() {
    assert_eq!(ffi_command("ok_command", || 7), 7);
    assert_eq!(ffi_query_i32("ok_flag", || 1), 1);
    assert_eq!(ffi_query_u32("ok_u32", || 42), 42);
    assert_eq!(ffi_query_u8("ok_u8", || 2), 2);
    assert!(ffi_query_bool("ok_bool", || true));
    assert!(ffi_owned_string("ok_string", std::ptr::null_mut).is_null());
    let mut completed = false;
    ffi_void("ok_void", || completed = true);
    assert!(completed);
}

#[test]
fn block_on_export_runs_on_a_non_runtime_thread() {
    assert_eq!(block_on_export(async { 9u8 }), Ok(9));
}

#[test]
fn block_on_export_refuses_a_tokio_owned_thread() {
    let refused = RUNTIME.block_on(async { block_on_export(async { 0i32 }) });
    assert_eq!(refused, Err(ERROR_GENERAL));
}

#[test]
fn init_player_nested_runtime_does_not_clear_teardown_flags() {
    let _guard = lock_global_state();
    aural_playback_cleanup();
    SHUTTING_DOWN.store(true, Ordering::SeqCst);
    SLEEPING.store(true, Ordering::SeqCst);

    let code = RUNTIME.block_on(async { aural_playback_init_player(std::ptr::null()) });

    assert_eq!(code, ERROR_GENERAL);
    assert!(
        SHUTTING_DOWN.load(Ordering::SeqCst),
        "nested init must not cancel an in-flight shutdown"
    );
    assert!(
        SLEEPING.load(Ordering::SeqCst),
        "nested init must not cancel sleep"
    );

    SHUTTING_DOWN.store(false, Ordering::SeqCst);
    SLEEPING.store(false, Ordering::SeqCst);
}

const FFI_PANIC_BARRIERS: &[&str] = &[
    "ffi_command",
    "ffi_query_i32",
    "ffi_query_u32",
    "ffi_query_u8",
    "ffi_query_bool",
    "ffi_owned_string",
    "ffi_void",
];

/// Structural ABI companion to [`exported_c_function_signatures_are_stable`].
///
/// Walks Rust sources rather than line numbers: every `pub extern "C"` export must enter
/// through a named panic-barrier helper, and only `runtime.rs` may call `RUNTIME.block_on`.
#[test]
fn exported_c_functions_enter_through_the_panic_barrier() {
    let src_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut exports = Vec::new();
    for entry in std::fs::read_dir(&src_dir).expect("src dir") {
        let path = entry.expect("dir entry").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        let source = std::fs::read_to_string(&path).expect("read rust source");
        let file_name = path.file_name().and_then(|name| name.to_str());
        let is_test_module = file_name == Some("tests.rs")
            || file_name.is_some_and(|name| name.ends_with("_tests.rs"));
        if file_name != Some("runtime.rs") && !is_test_module {
            assert!(
                !source.contains("RUNTIME.block_on"),
                "{} must call block_on_export rather than RUNTIME.block_on",
                path.display()
            );
        }
        exports.extend(exported_c_functions(&source));
    }

    exports.sort_by(|a, b| a.0.cmp(&b.0));
    assert!(
        !exports.is_empty(),
        "expected to find exported C functions in aural-playback sources"
    );
    for (name, barrier) in &exports {
        assert!(
            FFI_PANIC_BARRIERS.contains(&barrier.as_str()),
            "{name} enters through {barrier}, which is not a panic-barrier helper"
        );
    }
}

/// `Spirc::load` Ok is queued, not playing. `resume_playback` trusts `IS_PLAYING` for its
/// early return, so a queued `play_uri` / `play_tracks` load must not store true.
/// Production code (excluding `tests.rs` / `*_tests.rs` and `#[cfg(test)]` modules) may
/// write `IS_PLAYING=true` only from the `PlayerEvent::Playing` arm.
#[test]
fn only_a_playing_event_stores_is_playing_true() {
    let src_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files_with_true_store = Vec::new();
    let mut playing_arm_stores_true = false;
    for entry in std::fs::read_dir(&src_dir).expect("src dir") {
        let path = entry.expect("dir entry").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        let file_name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default();
        if file_name == "tests.rs" || file_name.ends_with("_tests.rs") {
            continue;
        }
        let source = std::fs::read_to_string(&path).expect("read rust source");
        let production = strip_cfg_test_modules(&source);
        if code_contains(&production, "IS_PLAYING.store(true") {
            files_with_true_store.push(file_name.to_string());
        }
        if file_name == "player_event_pump.rs" {
            playing_arm_stores_true = code_contains(
                &match_arm_body(&production, "PlayerEvent::Playing"),
                "IS_PLAYING.store(true",
            );
        }
    }
    files_with_true_store.sort();
    assert_eq!(
        files_with_true_store,
        vec!["player_event_pump.rs".to_string()],
        "queued play commands must not store IS_PLAYING=true"
    );
    assert!(
        playing_arm_stores_true,
        "PlayerEvent::Playing must remain the authoritative IS_PLAYING=true write"
    );
}

fn strip_cfg_test_modules(source: &str) -> String {
    let bytes = source.as_bytes();
    let marker = "#[cfg(test)]";
    let mut out = String::new();
    let mut search_from = 0;
    while let Some(rel) = source[search_from..].find(marker) {
        let attr_start = search_from + rel;
        out.push_str(&source[search_from..attr_start]);
        let after_attr = attr_start + marker.len();
        let ident = skip_ws_and_comments(bytes, after_attr);
        if source[ident..].starts_with("mod ") {
            let name_start = ident + 4;
            let name_end = source[name_start..]
                .find(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                .map(|idx| name_start + idx)
                .unwrap_or(source.len());
            let after_name = skip_ws_and_comments(bytes, name_end);
            if after_name < bytes.len() && bytes[after_name] == b'{' {
                search_from = matching_brace(bytes, after_name) + 1;
                continue;
            }
            if after_name < bytes.len() && bytes[after_name] == b';' {
                search_from = after_name + 1;
                continue;
            }
        }
        out.push_str(marker);
        search_from = after_attr;
    }
    out.push_str(&source[search_from..]);
    out
}

#[test]
fn strip_cfg_test_modules_keeps_production_after_a_test_module() {
    let source = concat!(
        "fn before() {}\n",
        "#[cfg(test)]\n",
        "mod tests {\n",
        "    IS_PLAYING.store(true, Ordering::SeqCst);\n",
        "}\n",
        "fn after() { IS_PLAYING.store(true, Ordering::SeqCst); }\n",
    );
    let stripped = strip_cfg_test_modules(source);
    assert!(
        !code_contains(&stripped, "mod tests"),
        "the test module body must be omitted"
    );
    assert!(
        code_contains(&stripped, "fn after"),
        "production after a test module must still be scanned"
    );
    assert!(code_contains(&stripped, "IS_PLAYING.store(true"));
}

fn code_contains(source: &str, needle: &str) -> bool {
    let bytes = source.as_bytes();
    let needle = needle.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match scan_code_byte(bytes, i) {
            Scan::Skip(next) => i = next,
            Scan::Byte(_, next) => {
                if bytes[i..].starts_with(needle) {
                    return true;
                }
                i = next;
            }
        }
    }
    false
}

fn match_arm_body(source: &str, pattern: &str) -> String {
    let start = source
        .find(pattern)
        .unwrap_or_else(|| panic!("missing {pattern}"));
    let bytes = source.as_bytes();
    let arrow = start
        + source[start..]
            .find("=>")
            .unwrap_or_else(|| panic!("{pattern} is not a match arm"));
    let brace = next_unquoted(bytes, arrow + 2, b'{')
        .unwrap_or_else(|| panic!("{pattern} arm has no body"));
    let end = matching_brace(bytes, brace);
    source[brace + 1..end].to_string()
}

fn matching_brace(bytes: &[u8], open: usize) -> usize {
    let mut depth = 0usize;
    let mut i = open;
    while i < bytes.len() {
        match scan_code_byte(bytes, i) {
            Scan::Skip(next) => i = next,
            Scan::Byte(b, next) => {
                if b == b'{' {
                    depth += 1;
                } else if b == b'}' {
                    depth -= 1;
                    if depth == 0 {
                        return i;
                    }
                }
                i = next;
            }
        }
    }
    panic!("unbalanced brace")
}

fn exported_c_functions(source: &str) -> Vec<(String, String)> {
    let bytes = source.as_bytes();
    let needle = b"pub extern \"C\" fn ";
    let mut found = Vec::new();
    let mut search_from = 0;
    while let Some(rel) = source[search_from..].find("pub extern \"C\" fn ") {
        let start = search_from + rel;
        let name_start = start + needle.len();
        let name_end = source[name_start..]
            .find(|c: char| !c.is_ascii_alphanumeric() && c != '_')
            .map(|idx| name_start + idx)
            .unwrap_or(source.len());
        let name = source[name_start..name_end].to_string();
        let brace = match next_unquoted(bytes, name_end, b'{') {
            Some(idx) => idx,
            None => panic!("export {name} has no function body"),
        };
        let first = first_identifier_in_block(bytes, brace + 1);
        found.push((name, first));
        search_from = brace + 1;
    }
    found
}

fn next_unquoted(bytes: &[u8], from: usize, target: u8) -> Option<usize> {
    let mut i = from;
    while i < bytes.len() {
        match scan_code_byte(bytes, i) {
            Scan::Skip(next) => i = next,
            Scan::Byte(b, next) => {
                if b == target {
                    return Some(i);
                }
                i = next;
            }
        }
    }
    None
}

fn first_identifier_in_block(bytes: &[u8], from: usize) -> String {
    let i = skip_ws_and_comments(bytes, from);
    if i >= bytes.len() {
        panic!("function body ended before a call");
    }
    match bytes[i] {
        b'a'..=b'z' | b'A'..=b'Z' | b'_' => {
            let start = i;
            let mut end = i + 1;
            while end < bytes.len() && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_') {
                end += 1;
            }
            std::str::from_utf8(&bytes[start..end])
                .expect("identifier")
                .to_string()
        }
        _ => panic!(
            "function body must start with a panic-barrier helper call, found {:?}",
            bytes[i] as char
        ),
    }
}

fn skip_ws_and_comments(bytes: &[u8], mut i: usize) -> usize {
    loop {
        while i < bytes.len() && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'/' {
            i += 2;
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'*' {
            i += 2;
            while i + 1 < bytes.len() && !(bytes[i] == b'*' && bytes[i + 1] == b'/') {
                i += 1;
            }
            i = i.saturating_add(2).min(bytes.len());
            continue;
        }
        return i;
    }
}

enum Scan {
    Skip(usize),
    Byte(u8, usize),
}

fn scan_code_byte(bytes: &[u8], i: usize) -> Scan {
    if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'/' {
        let mut j = i + 2;
        while j < bytes.len() && bytes[j] != b'\n' {
            j += 1;
        }
        return Scan::Skip(j);
    }
    if i + 1 < bytes.len() && bytes[i] == b'/' && bytes[i + 1] == b'*' {
        let mut j = i + 2;
        while j + 1 < bytes.len() && !(bytes[j] == b'*' && bytes[j + 1] == b'/') {
            j += 1;
        }
        return Scan::Skip(j.saturating_add(2).min(bytes.len()));
    }
    if bytes[i] == b'"' {
        return Scan::Skip(skip_quoted(bytes, i, b'"'));
    }
    if bytes[i] == b'\'' {
        return Scan::Skip(skip_quoted(bytes, i, b'\''));
    }
    Scan::Byte(bytes[i], i + 1)
}

fn skip_quoted(bytes: &[u8], start: usize, quote: u8) -> usize {
    let mut i = start + 1;
    let mut escape = false;
    while i < bytes.len() {
        let b = bytes[i];
        if escape {
            escape = false;
        } else if b == b'\\' {
            escape = true;
        } else if b == quote {
            return i + 1;
        }
        i += 1;
    }
    bytes.len()
}
