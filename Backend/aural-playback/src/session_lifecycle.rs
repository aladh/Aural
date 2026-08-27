use crate::*;

/// Whether the run that started at `started_generation` has been superseded.
pub(crate) fn run_is_superseded(started_generation: u64, current_generation: u64) -> bool {
    started_generation != current_generation
}

/// Where librespot persists the AP credentials produced by the streaming grant.
///
/// Under the sandbox `HOME` is already the app container, so this stays inside it.
pub(crate) fn credentials_cache_dir() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    std::path::Path::new(&home)
        .join("Library")
        .join("Application Support")
        .join("Aural")
        .join("credentials")
}

/// Removes cached credentials from `dir`, treating "not there" as success.
///
/// Takes the directory rather than reading `credentials_cache_dir()` so it can be tested
/// against a temporary one: `cargo test` runs unsandboxed, where that path resolves to the
/// developer's real credentials.
pub(crate) fn clear_credentials_at(dir: &std::path::Path) {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => debug!("Cleared streaming credentials"),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => debug!("Could not remove streaming credentials: {}", e),
    }
}

/// Removes the cached streaming credentials. Called on logout, after the session teardown,
/// so that the next launch cannot connect the account that just logged out.
#[no_mangle]
pub extern "C" fn aural_playback_clear_streaming_credentials() {
    ffi_void("aural_playback_clear_streaming_credentials", || {
        clear_credentials_at(&credentials_cache_dir());
    })
}

/// The Spotify account id the last successful streaming grant authenticated as, or null.
/// Free with `aural_playback_free_string`.
#[no_mangle]
pub extern "C" fn aural_playback_last_grant_account() -> *mut c_char {
    ffi_owned_string("aural_playback_last_grant_account", || {
        let account = LAST_GRANT_ACCOUNT
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        account.map_or(std::ptr::null_mut(), into_owned_c_string)
    })
}

/// Completes the one-time streaming authorization with a token Swift has already minted:
/// connects once, and lets librespot persist the AP credentials every later init uses.
///
/// Returns 0 on success, -1 on failure, -2 if the run was superseded.
///
/// Swift owns the OAuth flow itself — see `KeymasterAuth` and
/// `plans/single-grant-partner-api.md`. The token has to exist there anyway, because the same
/// one authorizes pathfinder and spclient, and a token minted here would have been dropped on
/// the floor after this call. What stays here is what only librespot can do: the AP connect
/// and the credential cache.
///
/// The token must be minted with Spotify's own desktop client id. One minted with the user's
/// dashboard client id authenticates with the AP but is rejected by login5, which is what took
/// playback down entirely; see `plans/streaming-auth-needs-a-first-party-client-id.md`.
#[no_mangle]
pub extern "C" fn aural_playback_authorize_streaming(access_token: *const c_char) -> i32 {
    ffi_command("aural_playback_authorize_streaming", || {
        let started_generation = LOGOUT_GENERATION.load(Ordering::SeqCst);

        let token = match unsafe { c_string_arg(access_token) } {
            Some(t) if !t.is_empty() => t,
            _ => {
                debug!("Streaming authorization error: no access token");
                return -1;
            }
        };
        debug!("Streaming authorization: token received, connecting");

        // Connect once so librespot writes the AP credentials into the cache. Every init after
        // this connects from that cache with no token at all.
        let result = match block_on_export(async {
            let device_id = format!("aural_{}", std::process::id());
            let (session, credentials) = create_session(&device_id, Some(&token))?;
            session
                .connect(credentials, true)
                .await
                .map_err(|e| format!("Connect failed: {:?}", e))?;
            // Recorded before shutdown: this is the account the browser was signed into, which
            // Swift compares against the Web API account before accepting the grant.
            *LAST_GRANT_ACCOUNT.lock().unwrap_or_else(|e| e.into_inner()) =
                Some(session.username().to_string());
            session.shutdown();
            Ok::<(), String>(())
        }) {
            Ok(result) => result,
            Err(code) => return code,
        };

        if let Err(e) = result {
            debug!("Streaming authorization connect error: {}", e);
            return -1;
        }

        // Rechecked *after* the write, not before: librespot persists from inside
        // Session::connect, so a logout landing mid-connect would wipe the cache and this run
        // would then recreate it behind logout's back. Against LOGOUT_GENERATION, not the
        // session one: an ordinary rebuild during the browser wait is not a supersession.
        if run_is_superseded(started_generation, LOGOUT_GENERATION.load(Ordering::SeqCst)) {
            debug!("Streaming authorization superseded; removing the credentials it wrote");
            clear_credentials_at(&credentials_cache_dir());
            return -2;
        }

        debug!("Streaming authorization complete");
        0
    })
}

/// Creates a new (unconnected) Session with the given device ID.
///
/// `access_token` is `Some` only for the first connect after the streaming grant. Every later
/// init passes `None` and connects from the credentials librespot cached then — which is the
/// point of the cache: no token, no refresh, no round-trip before connecting.
///
/// The token must be one minted with librespot's own client id. A Web API token minted with
/// the user's dashboard client id authenticates with the AP but is rejected by login5, which
/// is what took playback down entirely; see
/// `plans/streaming-auth-needs-a-first-party-client-id.md`.
pub(crate) fn create_session(
    device_id: &str,
    access_token: Option<&str>,
) -> Result<(Session, librespot_core::authentication::Credentials), String> {
    let session_config = SessionConfig {
        device_id: device_id.to_string(),
        ..Default::default()
    };
    let cache = Cache::new(Some(credentials_cache_dir()), None, None, None)
        .map_err(|e| format!("Cache error: {}", e))?;

    // Prefer a freshly granted token; otherwise reuse what the last grant cached. Resolved
    // here rather than at the call site so every caller gets the same rule.
    let credentials = match access_token {
        Some(token) => librespot_core::authentication::Credentials::with_access_token(token),
        None => cache
            .credentials()
            .ok_or_else(|| "No streaming credentials: authorization required".to_string())?,
    };

    let session = Session::new(session_config, Some(cache));
    Ok((session, credentials))
}

/// How often to check whether the current session needs recovery.
pub(crate) const SESSION_HEALTH_CHECK_INTERVAL: Duration = Duration::from_secs(60);

/// Watches for a session that is unusable while no other recovery owner is active.
///
/// Every other recovery trigger needs something to happen: the cluster listener only acts
/// when its stream *closes*, and librespot's dealer retries internally so the stream can
/// stay open for minutes past a dead session; the zombie check in
/// `require_session_connected` only runs when a command is issued. While Aural is the
/// active device something trips one of those quickly. While it is *not* active, nothing
/// may. The same check also covers a partial initialization that stored a Session but never
/// reached the connected-and-Spirc-ready state. In either case it starts the normal
/// reconnect loop unless that loop or an intentional teardown already owns the lifecycle.
///
/// Cost is one sleeping task per generation, waking once a minute to read a few flags
/// (`Session::is_invalid` is a lock read of a `bool`). It exits when its generation is
/// superseded, so it dies with the session it belongs to rather than accumulating.
pub(crate) fn spawn_session_health_check(generation: u64) {
    RUNTIME.spawn(async move {
        loop {
            tokio::time::sleep(SESSION_HEALTH_CHECK_INTERVAL).await;

            // Superseded: whatever replaced our session brought its own check.
            if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
                return;
            }

            // Sleep and shutdown invalidate the session on purpose.
            if teardown_in_progress() {
                continue;
            }

            let session_invalid = SESSION
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .is_some_and(|s| s.is_invalid());

            if health_check_should_recover(
                session_invalid,
                with_connection(|c| c.session_connected),
                RECONNECTING.load(Ordering::SeqCst),
                teardown_in_progress(),
            ) {
                debug!(
                    "Session health check: session {} needs recovery (invalid={})",
                    generation, session_invalid
                );
                let intent = RecoveryIntent::capture();
                mark_disconnected("Session unusable");
                spawn_reconnection_loop(intent);
                // Recovery owns it from here; the rebuild spawns the next check.
                return;
            }
        }
    });
}

/// Spawns the reconnection loop task.
/// Uses exponential backoff and rebuilds from the cached streaming credentials.
pub(crate) fn spawn_reconnection_loop(intent: RecoveryIntent) {
    // Check if already reconnecting
    if RECONNECTING.swap(true, Ordering::SeqCst) {
        debug!(
            "[WAKE +{}ms] Reconnection already in progress, skipping",
            elapsed_since_wake_ms()
        );
        return;
    }

    debug!(
        "[WAKE +{}ms] spawn_reconnection_loop started",
        elapsed_since_wake_ms()
    );

    RUNTIME.spawn(async move {
        // The generation this loop is recovering. Between two attempts it can sleep for up
        // to 30 seconds, and during that time something else — a manual restart from the
        // wake path, or aural_playback_cleanup on logout — may have already rebuilt or torn down
        // the session. Waking up and rebuilding anyway would replace a healthy new session
        // with one built from a stale token. RECONNECTING alone never caught this: it says
        // "a loop is running", not "the thing it is fixing still exists".
        // Mutable on purpose: each rebuild attempt bumps SESSION_GENERATION itself, so the
        // loop adopts the value its own attempt produced. Without that it reads its own
        // work as a foreign supersede and gives up after a single failed attempt.
        let mut recovering_generation = SESSION_GENERATION.load(Ordering::SeqCst);

        // Backoff that never gives up. This used to be a fixed schedule of ten attempts
        // totalling about three minutes, after which the loop exited — so an outage longer
        // than that left the app dead with nothing running to notice the network coming
        // back, and only a manual play would recover it. The loop is not idle polling: it
        // exists only while disconnected and exits on any lifecycle event, because every
        // iteration re-checks the generation and the teardown flags below.
        let mut attempt: u32 = 0;

        loop {
            let delay = match attempt {
                0 => 0,
                1 => 2,
                2 => 5,
                3 => 10,
                _ => 30,
            };
            // Advance before any `continue` below, so a token failure still backs off
            // instead of spinning on a zero delay.
            let attempt_number = attempt + 1;
            attempt = attempt.saturating_add(1);

            if delay > 0 {
                tokio::time::sleep(Duration::from_secs(delay)).await;
            }

            if !reconnect_may_proceed(
                recovering_generation,
                SESSION_GENERATION.load(Ordering::SeqCst),
                teardown_in_progress(),
            ) {
                debug!(
                    "[WAKE +{}ms] Abandoning reconnect for generation {}: superseded or torn down",
                    elapsed_since_wake_ms(),
                    recovering_generation
                );
                RECONNECTING.store(false, Ordering::SeqCst);
                return;
            }

            debug!(
                "[WAKE +{}ms] Reconnect attempt {}",
                elapsed_since_wake_ms(),
                attempt_number
            );
            with_connection(|c| {
                c.reconnect_attempt = attempt_number;
                c.last_error = Some(format!("Reconnecting (attempt {})", attempt_number));
            });
            notify_connection_state_change();

            // No token is fetched here. Swift's token is minted with the user's dashboard
            // client id, which login5 now rejects — a reconnect built on one fails exactly
            // where the original outage did. The credentials cached by the streaming grant
            // are what a rebuild connects from, so the ten-second round-trip that used to
            // sit here, and the re-check that existed only to cover it, are both gone.

            // One recovery strategy: tear everything down and rebuild Session, Player,
            // Mixer and Spirc as a single generation, then restore the captured intent.
            //
            // There used to be a "soft reconnect" that kept the Player alive across
            // sessions to avoid an audible gap. It bought a shorter interruption at the
            // cost of a Player outliving the Session it was built for, which is what
            // forced the librespot patch that makes Spirc adopt an orphaned
            // play_request_id, the context-reload-after-reconnect blip, and a watchdog
            // that re-issued play commands when the audio key fetch on the dead session
            // silently timed out. A brief gap during an outage is the better trade.
            do_reconnect_cleanup();

            // Rehydration happens inside init_player_async, so that the session is fully
            // settled before its readiness is published. See the note there.
            match init_player_async(None, intent.was_active, intent.should_resume()).await {
                Ok(_) => {
                    debug!(
                        "[WAKE +{}ms] Reconnect successful on attempt {}",
                        elapsed_since_wake_ms(),
                        attempt_number
                    );
                    RECONNECTING.store(false, Ordering::SeqCst);
                    return;
                }
                Err(e) => {
                    debug!(
                        "[WAKE +{}ms] Reconnect attempt {} failed: {}",
                        elapsed_since_wake_ms(),
                        attempt_number,
                        e
                    );
                    // Adopt the generation this attempt created. init_player_async bumps it
                    // before it can fail, so leaving the old value here would make the next
                    // iteration mistake our own rebuild for someone else's and abandon.
                    //
                    // Read from the attempt rather than from the counter: a logout and the
                    // login after it can both have bumped it while this attempt ran, and
                    // adopting *that* would have the loop rebuild over a session belonging
                    // to another account. Reading our own value leaves the next iteration's
                    // supersede check to notice and abandon, which is the right outcome.
                    recovering_generation = LAST_BUILD_GENERATION.load(Ordering::SeqCst);
                    with_connection(|c| c.last_error = Some(format!("Reconnect failed: {}", e)));
                    notify_connection_state_change();
                }
            }
        }
    });
}

/// Forces a reconnection to Spotify servers.
/// Use this after system wake to ensure a fresh connection.
/// Returns:
/// - 0: Reconnection triggered
/// - 1: Reconnection already in progress
/// - 2: No session initialized (nothing to reconnect)
#[no_mangle]
pub extern "C" fn aural_playback_force_reconnect() -> i32 {
    ffi_command("aural_playback_force_reconnect", || {
        // Clear sleeping flag - we're explicitly waking up
        SLEEPING.store(false, Ordering::SeqCst);

        // Record wake timestamp for timing analysis
        let wake_ts = current_timestamp_ms();
        WAKE_TIMESTAMP_MS.store(wake_ts, Ordering::SeqCst);
        debug!(
            "[WAKE +0ms] aural_playback_force_reconnect called at {}",
            wake_ts
        );

        // Check if we even have a session
        if SESSION.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
            debug!(
                "[WAKE +{}ms] Force reconnect: no session initialized",
                elapsed_since_wake_ms()
            );
            return 2;
        }

        // Check if already reconnecting
        if RECONNECTING.load(Ordering::SeqCst) {
            debug!(
                "[WAKE +{}ms] Force reconnect: reconnection already in progress",
                elapsed_since_wake_ms()
            );
            return 1;
        }

        debug!(
            "[WAKE +{}ms] Force reconnect: triggering reconnection",
            elapsed_since_wake_ms()
        );

        mark_disconnected("Reconnecting after system wake");
        spawn_reconnection_loop(RecoveryIntent::capture());

        0
    })
}

/// Performs full cleanup for reconnection.
/// Clears Session, Spirc, Player, and Mixer because Player is tightly coupled
/// to the Session's ChannelManager for decryption key requests.
pub(crate) fn do_reconnect_cleanup() {
    debug!("do_reconnect_cleanup: full cleanup for reconnection");

    // Signal event listener to stop
    if let Some(tx) = PLAYER_EVENT_TX
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .take()
    {
        let _ = tx.send(());
    }

    // Shutdown Spirc first - this terminates the spirc_task and closes the dealer,
    // which will cause the cluster listener stream to end. Without this, old tasks
    // remain alive holding references to Session/Player until the server closes the connection.
    shutdown_spirc("do_reconnect_cleanup");

    // Now clear Spirc reference
    *SPIRC.lock().unwrap_or_else(|e| e.into_inner()) = None;
    with_connection(|c| c.spirc_ready = false);

    // Clear Player - must be recreated with new Session. Tell Swift first: dropping the
    // Player does not run Sink::stop, so the renderer would otherwise keep believing it is
    // rendering and skip resetting its real-time throttle on the next start.
    proxy_sink::ProxySink::notify_player_gone();
    *PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // Clear Mixer
    *MIXER.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // Clear Session
    *SESSION.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // Clear device ID (will be regenerated) and reset session connection state
    with_connection(|c| {
        c.device_id = None;
        c.session_connected = false;
        c.session_connection_id = None;
        c.connected_since_ms = 0;
    });

    debug!("do_reconnect_cleanup complete");
}

/// Initializes the player with the given access token.
/// Must be called before play/pause operations.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn aural_playback_init_player(access_token: *const c_char) -> i32 {
    ffi_command("aural_playback_init_player", || {
        // Initialize env_logger to capture librespot's log output (only once)
        static LOGGER_INIT: std::sync::Once = std::sync::Once::new();
        LOGGER_INIT.call_once(|| {
            // try_init rather than init: Builder::init panics if another logger is already
            // installed, which would be a panic unwinding straight into Swift.
            let _ = env_logger::Builder::from_env(env_logger::Env::default())
                .format_timestamp_millis()
                .try_init();
        });

        // Print RUST_LOG env var for debugging
        let rust_log = std::env::var("RUST_LOG").unwrap_or_else(|_| "(not set)".to_string());
        debug!("RUST_LOG={}", rust_log);

        // Reset shutdown and sleeping flags in case we're reinitializing
        SHUTTING_DOWN.store(false, Ordering::SeqCst);
        SLEEPING.store(false, Ordering::SeqCst);

        // A null token means "connect from the cached streaming credentials", which is the normal
        // case: only the first init after the one-time grant carries a token.
        let token_str = unsafe { c_string_arg(access_token) };

        // Check if we already have a session
        {
            let session_guard = SESSION.lock().unwrap_or_else(|e| e.into_inner());
            if session_guard.is_some() {
                // Already initialized
                return 0;
            }
        }

        let result = match block_on_export(async {
            init_player_async(token_str.as_deref(), false, false).await
        }) {
            Ok(result) => result,
            Err(code) => return code,
        };

        match result {
            Ok(_) => 0,
            Err(_e) => {
                debug!("Player init error: {}", _e);
                -1
            }
        }
    })
}

/// Helper function to create a new Player instance
pub(crate) fn create_new_player(session: &Session) -> Arc<Player> {
    let (bitrate, bitrate_kbps) = match BITRATE_SETTING.load(Ordering::SeqCst) {
        0 => (Bitrate::Bitrate96, 96),
        2 => (Bitrate::Bitrate320, 320),
        _ => (Bitrate::Bitrate160, 160),
    };
    let gapless = GAPLESS_SETTING.load(Ordering::SeqCst);

    debug!(
        "Player initialized: bitrate={}kbps, gapless={}",
        bitrate_kbps, gapless
    );

    let player_config = PlayerConfig {
        bitrate,
        gapless,
        position_update_interval: Some(Duration::from_millis(200)),
        ..PlayerConfig::default()
    };
    let audio_format = AudioFormat::default();

    // Use ProxySink - a persistent audio output that survives across Player instances.
    // This enables seamless audio during session reconnection.
    //
    // NoOpVolume: do NOT attenuate samples here. Volume is applied at the output
    // (AVSampleBufferAudioRenderer.volume in Swift) so changes take effect
    // immediately instead of after the ~2s of already-decoded PCM drains. The
    // SoftMixer still tracks the logical volume for Spotify Connect reporting; it
    // just no longer feeds the player's sample gain.
    let player = Player::new(
        player_config,
        session.clone(),
        Box::new(NoOpVolume),
        move || mk_proxy_sink(None, audio_format),
    );

    // Store player globally
    *PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&player));

    player
}

/// Builds a session, and clears anything it left behind if a teardown began while it ran.
///
/// `build_player_async` stores Session, Player, Mixer and Spirc in the globals well before
/// it can decide whether it is still wanted, so every error path after those stores would
/// leak them. Normally the next reconnect attempt tidies up on its way in — but during a
/// logout there is no next attempt: the loop sees the teardown flag and exits, leaving a
/// live session for an account that is gone.
pub(crate) async fn init_player_async(
    access_token: Option<&str>,
    activate_after_connect: bool,
    resume_after_connect: bool,
) -> Result<(), String> {
    let result =
        build_player_async(access_token, activate_after_connect, resume_after_connect).await;

    if result.is_err() && teardown_in_progress() {
        debug!("Initialization failed during teardown — clearing what it left behind");
        do_reconnect_cleanup();
    }

    result
}

/// Builds a complete, settled session and publishes its readiness exactly once, at the end.
///
/// The ordering matters. Readiness used to be published the moment Spirc existed, while
/// activation and the rehydrating load still had to run — so Swift, which reacts to that
/// publication by bootstrapping from the Web API, fetched and applied a server snapshot
/// that Rust then immediately overwrote. That was visible as the playback position jumping
/// forward to a stale value and back. Publishing once, when nothing further is pending,
/// removes the window rather than racing it.
pub(crate) async fn build_player_async(
    access_token: Option<&str>,
    activate_after_connect: bool,
    resume_after_connect: bool,
) -> Result<(), String> {
    // Increment session generation - this invalidates any old cluster listeners
    let current_generation = SESSION_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    LAST_BUILD_GENERATION.store(current_generation, Ordering::SeqCst);
    debug!(
        "[WAKE +{}ms] init_player_async starting, generation={}",
        elapsed_since_wake_ms(),
        current_generation
    );

    let device_id = format!("aural_playback_{}", std::process::id());
    with_connection(|c| c.device_id = Some(device_id.clone()));

    let (session, credentials) = create_session(&device_id, access_token)?;

    // Create new mixer
    let mixer_config = MixerConfig::default();
    let mixer: Arc<SoftMixer> =
        Arc::new(SoftMixer::open(mixer_config).map_err(|e| format!("Mixer error: {}", e))?);
    *MIXER.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&mixer));

    // Create new player - must be created with the new session because Player is
    // tightly coupled to Session's ChannelManager for decryption key requests
    let player = create_new_player(&session);

    // Get event channel from player, opting in to SetQueue events
    let mut event_channel = player.get_player_event_channel();

    // Create channel for stopping event listener
    let (tx, mut rx) = mpsc::unbounded_channel::<()>();

    // This listener belongs to the generation being built here, for its whole life: a
    // rebuild replaces the listener along with the session, so the value never has to
    // change underneath it.
    let player_clone = Arc::clone(&player);
    let event_listener_generation = current_generation;
    RUNTIME.spawn(async move {
        loop {
            tokio::select! {
                _ = rx.recv() => {
                    // Shutdown signal received
                    debug!("Player event listener shutting down (generation={})", event_listener_generation);
                    break;
                }
                event = event_channel.recv() => {
                    // Drop everything from a superseded generation. A replaced listener
                    // drains asynchronously after its successor is live — the logs show old
                    // listeners still delivering seconds later — and without this guard it
                    // would keep writing position, track, playing and active-device state
                    // belonging to a session that no longer exists.
                    //
                    // `event.is_some()` matters: a closed channel must still reach the
                    // `None` arm below and break the loop. Skipping on `None` would spin.
                    if event.is_some()
                        && !listener_may_act(
                            event_listener_generation,
                            SESSION_GENERATION.load(Ordering::SeqCst),
                        )
                    {
                        continue;
                    }

                    match event {
                        Some(PlayerEvent::Playing {
                            track_id,
                            position_ms,
                            ..
                        }) => {
                            let track_uri = track_id.to_string();
                            debug!(
                                "PlayerEvent::Playing: logical track {} at {}ms",
                                track_uri, position_ms
                            );
                            set_current_track_uri(track_uri);
                            IS_PLAYING.store(true, Ordering::SeqCst);
                            set_active_device(true);
                            PLAYING_EVENT_SEQ.fetch_add(1, Ordering::SeqCst);
                            // Playback is running again, so any saved resume point belongs
                            // to a deactivation that has been recovered from.
                            RESUME_POSITION_MS.store(0, Ordering::SeqCst);
                            update_position(position_ms);
                            // Send playback state update to Swift
                            send_local_playback_state(true, position_ms);
                        }
                        Some(PlayerEvent::Paused {
                            track_id,
                            position_ms,
                            ..
                        }) => {
                            let track_uri = track_id.to_string();
                            debug!(
                                "PlayerEvent::Paused: logical track {} at {}ms",
                                track_uri, position_ms
                            );
                            set_current_track_uri(track_uri);
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            // Still active when paused - just not playing
                            update_position(position_ms);
                            // Send playback state update to Swift
                            send_local_playback_state(false, position_ms);
                        }
                        Some(PlayerEvent::PositionChanged { position_ms, .. }) => {
                            // Periodic position update (every 200ms)
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::Seeked { position_ms, .. }) => {
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::PositionCorrection { position_ms, .. }) => {
                            debug!("[WAKE +{}ms] PositionCorrection event: {}ms", elapsed_since_wake_ms(), position_ms);
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::Stopped { .. }) => {
                            // Deliberately does not touch active-device state: playback
                            // stopping is not the same as losing the active Connect role.
                            // This used to clear it, which fought the cluster-derived value
                            // and made the UI think a remote speaker had taken over
                            // whenever local playback simply ended.
                            //
                            // The position *is* reset here, because this event cannot say
                            // why playback stopped: `handle_stop` runs for a deactivation,
                            // for a queue that has run out, and for `prev` at the first
                            // track. Keeping the position for all of them made `next` on the
                            // last track leave a resume point mid-track, so pressing play
                            // afterwards restarted it there instead of from the beginning.
                            // A deactivation saves what it needs in RESUME_POSITION_MS
                            // before this arrives.
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            update_position(0);
                        }
                        Some(PlayerEvent::EndOfTrack { track_id, .. }) => {
                            // Logged with the position it ended at: a natural end and a
                            // stream that stopped early are otherwise indistinguishable in
                            // the log, because Spirc's auto-advance is silent on success.
                            // Without this, "did the track finish or get cut off?" cannot be
                            // answered from a log at all.
                            debug!(
                                "PlayerEvent::EndOfTrack: {} at {}ms",
                                track_id,
                                POSITION_MS.load(Ordering::SeqCst)
                            );
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            update_position(0);
                        }
                        Some(PlayerEvent::TrackChanged { audio_item }) => {
                            let audio_item_uri = audio_item.track_id.to_string();
                            let duration_ms = audio_item.duration_ms;
                            let logical_track_uri = CURRENT_TRACK_URI.lock().unwrap_or_else(|e| e.into_inner()).clone();
                            debug!(
                                "TrackChanged event: playable audio item {} ({}ms), logical track {}",
                                audio_item_uri,
                                duration_ms,
                                logical_track_uri.as_deref().unwrap_or("unknown")
                            );

                            // The AudioItem may be a relinked alternative. Its duration is
                            // authoritative for the decoded stream, but its ID must not
                            // replace the requested/context track identity.
                            CURRENT_DURATION_MS.store(duration_ms, Ordering::SeqCst);
                        }
                        Some(PlayerEvent::VolumeChanged { volume }) => {
                            debug!("VolumeChanged event: {}", volume);
                            check_and_send_volume(volume as u32);
                        }
                        Some(PlayerEvent::ShuffleChanged { shuffle }) => {
                            debug!("PlayerEvent::ShuffleChanged: {}", shuffle);
                            SHUFFLE_STATE.store(shuffle, Ordering::SeqCst);
                            send_local_playback_state(
                                IS_PLAYING.load(Ordering::SeqCst),
                                POSITION_MS.load(Ordering::SeqCst),
                            );
                        }
                        Some(PlayerEvent::RepeatChanged { context, track }) => {
                            debug!(
                                "PlayerEvent::RepeatChanged: context={}, track={}",
                                context, track
                            );
                            REPEAT_CONTEXT_STATE.store(context, Ordering::SeqCst);
                            REPEAT_TRACK_STATE.store(track, Ordering::SeqCst);
                            send_local_playback_state(
                                IS_PLAYING.load(Ordering::SeqCst),
                                POSITION_MS.load(Ordering::SeqCst),
                            );
                        }
                        Some(PlayerEvent::Loading { track_id, position_ms, .. }) => {
                            let track_uri_str = track_id.to_string();
                            debug!("Loading event: {} at {}ms", track_uri_str, position_ms);

                            // Both, together. The position and the track URI are read as a
                            // pair — `resume_via_load` seeks `POSITION_MS` within
                            // `CURRENT_TRACK_URI` — so leaving the position behind here
                            // meant that for the length of a load they described different
                            // tracks. A natural transition hides it, because `EndOfTrack`
                            // zeroes the position first; a manual `next` does not, and a
                            // deactivation landing in that window saved the outgoing track's
                            // offset against the incoming track's URI.
                            set_current_track_uri(track_uri_str.clone());
                            update_position(position_ms);
                            // A load supersedes anything saved for an earlier one. Safe
                            // against the resume path it serves, which reads the saved point
                            // before issuing the load that produces this event — and passes
                            // it in as the seek target, so `position_ms` above is that same
                            // value. The baton is handed from the saved point to the live
                            // one, and a retry after a load that never plays still finds it.
                            RESUME_POSITION_MS.store(0, Ordering::SeqCst);

                            if let Some(callback) = registered_callback(&CONTROL_CALLBACKS.loading) {
                                let notification = stamped_snapshot(|stamp| LoadingNotification {
                                    revision: stamp.revision,
                                    session_generation: stamp.session_generation,
                                    track_uri: track_uri_str,
                                    position_ms,
                                });
                                send_json(callback, &notification);
                            }
                        }
                        Some(PlayerEvent::SetQueue {
                            context_uri,
                            current_track,
                            next_tracks,
                            prev_tracks,
                        }) => {
                            debug!(
                                "SetQueue event: context={}, next={}, prev={}",
                                context_uri,
                                next_tracks.len(),
                                prev_tracks.len()
                            );
                            update_current_context_uri(&context_uri);
                            if let Some(callback) = registered_callback(&CONTROL_CALLBACKS.set_queue) {
                                let to_track_info = |t: QueueTrack| QueueTrackInfo {
                                    uri: t.uri,
                                    provider: t.provider,
                                };
                                let notification = stamped_snapshot(|stamp| SetQueueNotification {
                                    revision: stamp.revision,
                                    session_generation: stamp.session_generation,
                                    context_uri,
                                    current_track: current_track.map(to_track_info),
                                    next_tracks: next_tracks.into_iter().map(to_track_info).collect(),
                                    prev_tracks: prev_tracks.into_iter().map(to_track_info).collect(),
                                });
                                send_json(callback, &notification);
                            }
                        }
                        // librespot emits SessionDisconnected when the local Connect device
                        // becomes INACTIVE — not when the network session fails.
                        // SpircTask::handle_disconnect() runs on an explicit Disconnect, on
                        // shutdown, and on any cluster update that hands the active role to
                        // another device. (This is upstream behavior, not part of our patch.)
                        //
                        // Treating it as an outage meant an ordinary handoff to a phone or a
                        // speaker marked the connection dead and started a reconnect loop
                        // against a perfectly healthy session.
                        Some(PlayerEvent::SessionDisconnected { connection_id, user_name }) => {
                            debug!("[WAKE +{}ms] became inactive (SessionDisconnected): connection_id={}, user={}, listener_generation={}",
                                   elapsed_since_wake_ms(), connection_id, user_name, event_listener_generation);

                            // Capture before clearing: the recovery decision below needs to
                            // know what was playing, and set_active_device wipes half of it.
                            let intent = RecoveryIntent::capture();
                            // Same reason, for the position. librespot calls handle_stop
                            // right after emitting this, and the Stopped event that produces
                            // resets the live position — so this is the last moment at which
                            // where playback stopped is still known to be recoverable.
                            //
                            // Only when there is something to save. Zero is how this reads
                            // as "nothing saved", so writing one would not merely be
                            // useless: a second disconnect while already inactive — sleeping
                            // after a handoff sends one, since `aural_playback_disconnect` shuts
                            // Spirc down — would overwrite a good point with the zero the
                            // first disconnect's `Stopped` had just written.
                            let stopped_at_ms = POSITION_MS.load(Ordering::SeqCst);
                            if stopped_at_ms > 0 {
                                RESUME_POSITION_MS.store(stopped_at_ms, Ordering::SeqCst);
                            }
                            set_active_device(false);

                            // Only recover if the transport is genuinely broken. A dead
                            // Session here means the Spirc task went down with it (librespot
                            // calls handle_disconnect on unexpected shutdown), which the
                            // cluster listener may not observe if the dealer stream is still
                            // open. A missing Session means some other path already owns the
                            // lifecycle, so leave it alone.
                            let session_invalid = SESSION
                                .lock()
                                .unwrap_or_else(|e| e.into_inner())
                                .as_ref()
                                .is_some_and(|s| s.is_invalid());

                            if should_recover_after_deactivation(
                                session_invalid,
                                teardown_in_progress(),
                            ) {
                                debug!("[WAKE +{}ms] Session is invalid at deactivation - recovering", elapsed_since_wake_ms());
                                mark_disconnected("Session invalid");
                                spawn_reconnection_loop(intent);
                            } else {
                                notify_connection_state_change();
                            }

                            if let Some(callback) = registered_callback(&CONTROL_CALLBACKS.became_inactive) {
                                callback();
                            }
                        }
                        // Emitted when the local Connect device becomes ACTIVE. Carries the
                        // session's connection id, but says nothing about network health -
                        // the session was already connected before activation.
                        Some(PlayerEvent::SessionConnected { connection_id, user_name }) => {
                            debug!("[WAKE +{}ms] became active (SessionConnected): connection_id={}, user={}", elapsed_since_wake_ms(), connection_id, user_name);
                            set_active_device(true);
                            with_connection(|c| c.session_connection_id = Some(connection_id));

                            // Notify connection state change
                            notify_connection_state_change();
                            if let Some(callback) = registered_callback(&CONTROL_CALLBACKS.became_active) {
                                callback();
                            }
                        }
                        Some(PlayerEvent::SessionClientChanged {
                            client_id,
                            client_name,
                            client_brand_name,
                            client_model_name,
                        }) => {
                            debug!(
                                "SessionClientChanged event: id={}, name={}, brand={}, model={}",
                                client_id, client_name, client_brand_name, client_model_name
                            );
                            if let Some(callback) =
                                registered_callback(&CONTROL_CALLBACKS.session_client_changed)
                            {
                                send_json(callback, &SessionClientInfo {
                                    client_id,
                                    client_name,
                                    client_brand_name,
                                    client_model_name,
                                });
                            }
                        }
                        None => break,
                        _ => {}
                    }
                }
            }
        }
        drop(player_clone);
    });

    *SESSION.lock().unwrap_or_else(|e| e.into_inner()) = Some(session.clone());
    *PLAYER_EVENT_TX.lock().unwrap_or_else(|e| e.into_inner()) = Some(tx);

    spawn_cluster_listener(&session, current_generation)?;
    spawn_initial_cluster_fetch(&session, current_generation);
    spawn_session_health_check(current_generation);

    match create_and_store_spirc(&session, &credentials, player, mixer).await {
        Ok(spirc) => {
            // Passive startup by default: do not take over the active device on launch.
            // Re-activate only when reconnecting from a previously-active local session.
            //
            // Recorded, not published — the single notify at the end of this function
            // covers it. set_active_device would publish here, before the rehydration
            // below, reopening the window this ordering exists to close.
            if activate_after_connect {
                match spirc.activate() {
                    Ok(_) => {
                        store_active_device(true);
                    }
                    Err(e) => debug!("Auto-activation failed: {:?}", e),
                }
            } else {
                store_active_device(false);
            }

            // Rehydrate before announcing readiness. The rebuilt Player has no track
            // loaded, and nothing else will load one: Spirc coming up and the device
            // becoming active only make it *available* to play, not playing. Without this
            // the session returns healthy and silent while Swift still shows the pre-outage
            // position, because IS_PLAYING and the position anchor survive the rebuild.
            //
            // This used to arm a five-second window waiting for a Paused event, on the
            // assumption that the track would load itself via transfer(None) — nothing in
            // this path ever called transfer(None), so the event never came.
            if resume_after_connect {
                let seq_before = PLAYING_EVENT_SEQ.load(Ordering::SeqCst);
                let result = resume_via_load(&spirc);
                debug!(
                    "[WAKE +{}ms] Rehydrate after reconnect: load result={}",
                    elapsed_since_wake_ms(),
                    result
                );

                if result == ERROR_NEEDS_REINIT {
                    // Closed command channel: this Spirc is already dead, so the session can
                    // never play. Nothing to roll back — success is committed below, after
                    // this point, so the connection state still reads disconnected.
                    return Err("Rehydration failed: Spirc command channel closed".to_string());
                }

                if result != 0 {
                    // Nothing to resume — no saved context or track URI. Reachable when an
                    // outage lands between a play command and the player events that record
                    // what is playing. The session itself is fine, so failing here would
                    // make every later attempt fail identically, forever.
                    debug!(
                        "[WAKE +{}ms] Rehydrate: nothing to resume (result={})",
                        elapsed_since_wake_ms(),
                        result
                    );
                } else if !wait_for_playing_event_async(seq_before, REHYDRATE_PLAYING_TIMEOUT).await
                {
                    // Spirc::load only queues a command, so a zero result means "accepted",
                    // not "playing". Waiting keeps Swift's Web API bootstrap out of the gap
                    // between the two. A timeout is not fatal: the load may still land, and
                    // tearing down an otherwise healthy session would be worse than
                    // announcing it late.
                    debug!(
                        "[WAKE +{}ms] Rehydrate: no Playing event within {:?}, publishing anyway",
                        elapsed_since_wake_ms(),
                        REHYDRATE_PLAYING_TIMEOUT
                    );
                }
            }

            // Committing late means this can be reached after something else took over —
            // aural_playback_cleanup on logout, a manual retry, or sleep, any of which can land
            // during the rehydration wait above. Writing success then would resurrect a
            // dead session as healthy and stop the health check from recovering it.
            let superseded = !listener_may_act(
                current_generation,
                SESSION_GENERATION.load(Ordering::SeqCst),
            );
            let tearing_down = teardown_in_progress();

            if superseded || tearing_down {
                // Returning an error is not enough on the teardown path. This attempt has
                // already stored its Session, Player and Spirc in the globals, so refusing
                // to publish leaves them live and connected — on logout that means the
                // account stays announced on Spotify Connect, which is exactly what the
                // shutdown was for. Teardown is unambiguous: nothing newer is coming, so
                // clear what this attempt built.
                //
                // A supersede on its own is the opposite case — a newer generation owns the
                // globals by now, and tearing them down would destroy its work, not ours.
                // Teardown outranks that: `init_player_async` clears both teardown flags as
                // it starts, so a flag that is set now means no newer generation began after
                // it, whatever the counter says.
                if tearing_down {
                    debug!(
                        "Generation {} finished during teardown — clearing what it built",
                        current_generation
                    );
                    // Through the handle this attempt holds, not the global one. A cleanup
                    // that landed between storing the Spirc and reaching here has already
                    // nilled the global, so `do_reconnect_cleanup` would find nothing to
                    // stop — while this Spirc's task stays alive holding the session, which
                    // is precisely the thing that must not survive a logout.
                    let _ = spirc.shutdown();
                    do_reconnect_cleanup();
                }

                return Err(format!(
                    "Initialization for generation {} was superseded before it completed",
                    current_generation
                ));
            }

            // Single commit-and-publish point: session up, device activated, playback
            // rehydrated. Recording success only here means a failure anywhere above
            // leaves the previous disconnected state untouched, and no snapshot in
            // between can announce a session that cannot yet play.
            with_connection(|c| {
                c.spirc_ready = true;
                c.session_connected = true;
                c.connected_since_ms = current_timestamp_ms();
                c.reconnect_attempt = 0;
                c.last_error = None;
            });
            notify_connection_state_change();
        }
        Err(e) => {
            // No fallback: every Aural control goes through Spirc, so a bare connected
            // Session is not a usable player. This used to call session.connect() and
            // return Ok, which reported success while leaving Swift with a player whose
            // every command would fail - and because initializeIfNeeded then refused to
            // retry, that state was permanent.
            return Err(format!("Spirc initialization failed: {}", e));
        }
    }

    Ok(())
}

/// Checks if volume changed and sends callback if so
pub(crate) fn check_and_send_volume(volume: u32) {
    let volume_u16 = volume as u16;
    let last = LAST_VOLUME.load(Ordering::SeqCst);

    // Only send callback if volume actually changed
    if volume_u16 != last {
        LAST_VOLUME.store(volume_u16, Ordering::SeqCst);
        debug!("Volume changed: {} -> {}", last, volume_u16);

        if let Some(callback) = registered_callback(&CONTROL_CALLBACKS.volume) {
            callback(volume_u16);
        }
    }
}
