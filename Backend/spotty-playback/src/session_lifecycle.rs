use crate::*;

/// Whether the run that started at `started_generation` has been superseded.
pub(crate) fn run_is_superseded(started_generation: u64, current_generation: u64) -> bool {
    started_generation != current_generation
}

/// Why the streaming credential cache cannot be opened.
///
/// Variants carry no filesystem path so public logs stay sanitized.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CredentialsCacheError {
    /// `HOME` is unset or empty.
    Missing,
    /// `HOME` is not an absolute location, so it cannot be an app container path.
    Relative,
    /// `HOME` is a shared temporary root such as `/tmp` or `/private/tmp`.
    SharedTemporary,
}

impl CredentialsCacheError {
    pub(crate) fn message(self) -> &'static str {
        "Streaming credential cache is unavailable"
    }
}

/// Resolves the cache directory from an injected `HOME`.
///
/// Path selection is pure: callers pass a value rather than mutating the process
/// environment, so checks do not touch the developer's real home or race on `HOME`.
pub(crate) fn credentials_cache_dir_from_home(
    home: Option<&std::path::Path>,
) -> Result<std::path::PathBuf, CredentialsCacheError> {
    credentials_cache_dir_from_home_named(home, "Spotty")
}

fn credentials_cache_dir_from_home_named(
    home: Option<&std::path::Path>,
    product_directory_name: &str,
) -> Result<std::path::PathBuf, CredentialsCacheError> {
    let home = home
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or(CredentialsCacheError::Missing)?;
    if !home.is_absolute() {
        return Err(CredentialsCacheError::Relative);
    }
    let home = lexically_normalized_absolute(home).ok_or(CredentialsCacheError::SharedTemporary)?;
    if is_shared_temporary_home(&home) {
        return Err(CredentialsCacheError::SharedTemporary);
    }
    Ok(home
        .join("Library")
        .join("Application Support")
        .join(product_directory_name)
        .join("credentials"))
}

fn previous_product_directory_name() -> &'static str {
    std::str::from_utf8(&[65, 117, 114, 97, 108])
        .expect("previous product directory bytes must be valid UTF-8")
}

fn previous_credentials_cache_dir() -> Result<std::path::PathBuf, CredentialsCacheError> {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    credentials_cache_dir_from_home_named(home.as_deref(), previous_product_directory_name())
}

/// Collapse `.` and refuse `..` without touching the filesystem or following symlinks.
fn lexically_normalized_absolute(home: &std::path::Path) -> Option<std::path::PathBuf> {
    let mut normalized = std::path::PathBuf::new();
    for component in home.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => return None,
            other => normalized.push(other),
        }
    }
    Some(normalized)
}

/// Shared world-writable temp roots, including the macOS `/tmp` → `/private/tmp` pair.
/// Comparison is lexical so path selection stays pure and does not follow symlinks.
fn is_shared_temporary_home(home: &std::path::Path) -> bool {
    const ROOTS: &[&str] = &["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"];
    ROOTS.iter().any(|root| {
        let root = std::path::Path::new(root);
        home == root || home.starts_with(root)
    })
}

/// Where librespot persists the AP credentials produced by the streaming grant.
///
/// Under the sandbox `HOME` is already the app container, so this stays inside it.
/// Missing, relative, or shared-temporary `HOME` fails closed: it must not fall back to `/tmp`.
pub(crate) fn credentials_cache_dir() -> Result<std::path::PathBuf, CredentialsCacheError> {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    credentials_cache_dir_from_home(home.as_deref())
}

/// Creates `dir` and restricts it to the current user when the platform allows.
pub(crate) fn ensure_private_credentials_dir(dir: &std::path::Path) -> Result<(), String> {
    std::fs::create_dir_all(dir)
        .map_err(|_| CredentialsCacheError::Missing.message().to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| CredentialsCacheError::Missing.message().to_string())?;
    }
    Ok(())
}

/// Moves the previous installation's credential cache when Spotty has not created one yet.
pub(crate) fn migrate_previous_credentials_dir(
    current: &std::path::Path,
    previous: &std::path::Path,
    allow_fresh_cache: bool,
) -> Result<(), String> {
    match move_previous_credentials_dir(current, previous) {
        Err(_) if allow_fresh_cache => Ok(()),
        result => result,
    }
}

fn move_previous_credentials_dir(
    current: &std::path::Path,
    previous: &std::path::Path,
) -> Result<(), String> {
    if current.exists() || !previous.exists() {
        return Ok(());
    }
    let parent = current
        .parent()
        .ok_or_else(|| CredentialsCacheError::Missing.message().to_string())?;
    ensure_private_credentials_dir(parent)?;
    std::fs::rename(previous, current)
        .map_err(|_| CredentialsCacheError::Missing.message().to_string())?;
    ensure_private_credentials_dir(current)?;
    if let Some(previous_parent) = previous.parent() {
        let _ = std::fs::remove_dir(previous_parent);
    }
    Ok(())
}

pub(crate) fn retire_previous_credentials_dir(previous: &std::path::Path) {
    clear_credentials_at(previous);
    if let Some(previous_parent) = previous.parent() {
        let _ = std::fs::remove_dir(previous_parent);
    }
}

fn retire_previous_credentials_cache() {
    match previous_credentials_cache_dir() {
        Ok(previous) => retire_previous_credentials_dir(&previous),
        Err(error) => debug!(
            "Previous streaming credential cache unavailable after connection: {}",
            error.message()
        ),
    }
}

/// Resolves the live cache directory and removes it. Unavailable locations are success:
/// there is no app-owned cache to clear, and the C ABI remains a void cleanup.
pub(crate) fn clear_resolved_credentials() {
    match credentials_cache_dir() {
        Ok(dir) => clear_credentials_at(&dir),
        Err(_) => debug!("Streaming credential cache unavailable; nothing to clear"),
    }
    if let Ok(dir) = previous_credentials_cache_dir() {
        clear_credentials_at(&dir);
    }
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
pub extern "C" fn spotty_playback_clear_streaming_credentials() {
    ffi_void("spotty_playback_clear_streaming_credentials", || {
        clear_resolved_credentials();
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
pub extern "C" fn spotty_playback_authorize_streaming(access_token: *const c_char) -> i32 {
    ffi_command("spotty_playback_authorize_streaming", || {
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
            let device_id = format!("spotty_{}", std::process::id());
            let (session, credentials) = create_session(&device_id, Some(&token))?;
            session
                .connect(credentials, true)
                .await
                .map_err(|e| format!("Connect failed: {:?}", e))?;
            // Session::connect is the operation that persists a fresh grant. Retire the
            // previous installation only after it has actually accepted the credentials;
            // a failed authorization must leave the recovery cache available for retry.
            retire_previous_credentials_cache();
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
            clear_resolved_credentials();
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
    let cache_dir = credentials_cache_dir().map_err(|error| error.message().to_string())?;
    let previous_cache_dir =
        previous_credentials_cache_dir().map_err(|error| error.message().to_string())?;
    migrate_previous_credentials_dir(&cache_dir, &previous_cache_dir, access_token.is_some())?;
    ensure_private_credentials_dir(&cache_dir)?;
    let cache = Cache::new(Some(cache_dir), None, None, None)
        .map_err(|_| CredentialsCacheError::Missing.message().to_string())?;

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
/// `require_session_connected` only runs when a command is issued. While Spotty is the
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
    // Capture the generation at trigger time, before the task is scheduled. A rebuild
    // that lands between here and the first poll would otherwise be adopted as "the
    // thing being recovered" and torn down on attempt 0.
    let Some(start) = start_reconnect_loop(intent, SESSION_GENERATION.load(Ordering::SeqCst))
    else {
        debug!(
            "[WAKE +{}ms] Reconnection already in progress, skipping",
            elapsed_since_wake_ms()
        );
        return;
    };

    debug!(
        "[WAKE +{}ms] spawn_reconnection_loop started",
        elapsed_since_wake_ms()
    );

    RUNTIME.spawn(async move {
        // The generation this loop is recovering. Between two attempts it can sleep for up
        // to 30 seconds, and during that time something else — a manual restart from the
        // wake path, or spotty_playback_cleanup on logout — may have already rebuilt or torn down
        // the session. Waking up and rebuilding anyway would replace a healthy new session
        // with one built from a stale token. RECONNECTING alone never caught this: it says
        // "a loop is running", not "the thing it is fixing still exists".
        // Mutable on purpose: each rebuild attempt bumps SESSION_GENERATION itself, so the
        // loop adopts the value its own attempt produced. Without that it reads its own
        // work as a foreign supersede and gives up after a single failed attempt.
        let mut recovering_generation = start.recovering_generation;
        let intent = start.intent;

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
                c.last_error = Some(format!("Reconnecting (attempt {})", attempt_number));
            });
            notify_connection_state_change();

            // No token is fetched here. A rebuild connects from the AP credentials cached by
            // the streaming grant, which is the only login path this reconnection flow
            // performs (the initial connect in `create_session` may still use a token), so a
            // Swift token round-trip adds latency without changing the outcome of a network
            // outage. Credentials rejected server-side are a different failure: this loop
            // does not detect them yet, and the bounded credential-rejected exit is tracked
            // in https://github.com/aladh/Spotty/issues/181.

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
            //
            // Cleanup and build share the lifecycle lock with a final generation
            // revalidation so a queued stale reconnect cannot tear down a newer session.
            match run_reconnect_unit(
                recovering_generation,
                || SESSION_GENERATION.load(Ordering::SeqCst),
                teardown_in_progress,
                do_reconnect_cleanup,
                init_player_async(None, intent.was_active, intent.should_resume()),
            )
            .await
            {
                ReconnectUnitOutcome::Abandoned => {
                    debug!(
                        "[WAKE +{}ms] Abandoning reconnect for generation {}: superseded or torn down",
                        elapsed_since_wake_ms(),
                        recovering_generation
                    );
                    RECONNECTING.store(false, Ordering::SeqCst);
                    return;
                }
                ReconnectUnitOutcome::Ran(Ok(_)) => {
                    debug!(
                        "[WAKE +{}ms] Reconnect successful on attempt {}",
                        elapsed_since_wake_ms(),
                        attempt_number
                    );
                    RECONNECTING.store(false, Ordering::SeqCst);
                    return;
                }
                ReconnectUnitOutcome::Ran(Err(e)) => {
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
pub extern "C" fn spotty_playback_force_reconnect() -> i32 {
    ffi_command("spotty_playback_force_reconnect", || {
        // Clear sleeping flag - we're explicitly waking up
        SLEEPING.store(false, Ordering::SeqCst);

        // Record wake timestamp for timing analysis
        let wake_ts = current_timestamp_ms();
        WAKE_TIMESTAMP_MS.store(wake_ts, Ordering::SeqCst);
        debug!(
            "[WAKE +0ms] spotty_playback_force_reconnect called at {}",
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
    let _store = enter_store_section();

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
    // Dropped alongside the player it aliases, so a late `spotty_playback_report_audio` from a
    // Swift pipeline that has not been torn down yet finds nothing to report to.
    *SHIM_PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // Clear Mixer
    *MIXER.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // Clear Session
    *SESSION.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // Clear device ID (will be regenerated) and reset session connection state
    with_connection(|c| {
        c.device_id = None;
        c.session_connected = false;
    });

    debug!("do_reconnect_cleanup complete");
}

/// Initializes the player with the given access token.
/// Must be called before play/pause operations.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotty_playback_init_player(access_token: *const c_char) -> i32 {
    ffi_command("spotty_playback_init_player", || {
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

        // A null token means "connect from the cached streaming credentials", which is the normal
        // case: only the first init after the one-time grant carries a token.
        let token_str = unsafe { c_string_arg(access_token) };

        // Already-initialized remains the established no-op: drop teardown flags and return
        // success without `block_on`. Nested-runtime refusal does not apply here because
        // this path never entered the runtime before the barrier either.
        if session_is_present() {
            SHUTTING_DOWN.store(false, Ordering::SeqCst);
            SLEEPING.store(false, Ordering::SeqCst);
            return 0;
        }

        // Refuse before clearing teardown flags: a Tokio-owned call used to panic inside
        // `block_on`, and mapping that to `ERROR_GENERAL` must not also look like a
        // successful reinitialization that cancelled shutdown or sleep.
        if let Err(code) = refuse_if_nested_runtime() {
            return code;
        }

        SHUTTING_DOWN.store(false, Ordering::SeqCst);
        SLEEPING.store(false, Ordering::SeqCst);

        let result = match block_on_export(async {
            // Recheck inside the serialization boundary: a reconnect may have stored a
            // session while this call waited for the lock.
            match run_serialized_init(
                session_is_present,
                init_player_async(token_str.as_deref(), false, false),
            )
            .await
            {
                SerializedInitOutcome::AlreadyInitialized => {
                    SHUTTING_DOWN.store(false, Ordering::SeqCst);
                    SLEEPING.store(false, Ordering::SeqCst);
                    Ok(())
                }
                SerializedInitOutcome::Built(result) => result,
            }
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

/// Builds the player this session's `Spirc` drives, and stores it globally.
///
/// Two shapes, one choice, made once per build: when Swift has registered an audio-command
/// callback (`spotty_playback_register_audio_command_callback`), the Stage 1 Swift audio path is
/// in use and this builds a [`ShimPlayer`], which forwards `Load/Play/Pause/Seek/Stop/Preload`
/// to Swift and turns Swift's reports back into `PlayerEvent`s. Otherwise it builds librespot's
/// own `Player`, which decodes in-process and hands PCM to Swift through `proxy_sink.rs`. Nothing
/// downstream cares which: `Spirc` and `player_event_pump.rs` both take `Arc<dyn SpircPlayer>`.
///
/// `generation` stamps every `AudioCommand` the shim sends, so a report arriving from a Swift
/// pipeline that belongs to a session already replaced is rejected rather than applied.
/// The shim constructor lives next to `FfiAudioCommandSink` in `audio_command_sink.rs`.
pub(crate) fn create_new_player(session: &Session, generation: u64) -> Arc<dyn SpircPlayer> {
    if swift_audio_path_enabled() {
        return create_shim_player(session, generation);
    }
    create_librespot_player(session)
}

/// Builds librespot's own Player, decoding in-process and delivering PCM through `proxy_sink.rs`.
fn create_librespot_player(session: &Session) -> Arc<dyn SpircPlayer> {
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
    let player: Arc<dyn SpircPlayer> = player;
    *PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&player));

    player
}

/// Builds a session, and clears anything it left behind if a teardown began while it ran.
///
/// Must run while the caller holds the lifecycle lock. `build_player_async` stores Session,
/// Player, Mixer and Spirc in the globals well before it can decide whether it is still wanted,
/// so every error path after those stores would leak them. Normally the next reconnect attempt
/// tidies up on its way in — but during a logout there is no next attempt: the loop sees the
/// teardown flag and exits, leaving a live session for an account that is gone.
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
/// forward to a stale value and back. Publishing readiness once, when nothing further is
/// pending, removes the window rather than racing it.
///
/// The rehydrating load itself is Swift's. When local playback is being recovered, this
/// function publishes one snapshot with `session_connected` set, `spirc_ready` still clear,
/// and `resume_pending` set; Swift answers by issuing its `ResumeLoadPlan` targets through
/// `spotty_playback_load`, and this function holds readiness until a Playing event lands,
/// a load reports a dead Spirc, or [`REHYDRATION_WINDOW`] elapses. Target order and
/// capture stay in one place (Swift); the engine keeps only the session globals the plan
/// reads through the existing getters.
pub(crate) async fn build_player_async(
    access_token: Option<&str>,
    activate_after_connect: bool,
    resume_after_connect: bool,
) -> Result<(), String> {
    let current_generation = tokio::task::spawn_blocking(invalidate_cluster_generation)
        .await
        .map_err(|e| format!("cluster generation invalidation: {e}"))?;
    LAST_BUILD_GENERATION.store(current_generation, Ordering::SeqCst);
    debug!(
        "[WAKE +{}ms] init_player_async starting, generation={}",
        elapsed_since_wake_ms(),
        current_generation
    );

    let device_id = format!("spotty_playback_{}", std::process::id());
    with_connection(|c| c.device_id = Some(device_id.clone()));

    let (session, credentials) = create_session(&device_id, access_token)?;
    let _store = enter_store_section();

    // Create new mixer
    let mixer_config = MixerConfig::default();
    let mixer: Arc<SoftMixer> =
        Arc::new(SoftMixer::open(mixer_config).map_err(|e| format!("Mixer error: {}", e))?);
    *MIXER.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&mixer));

    // Create new player - must be created with the new session because Player is
    // tightly coupled to Session's ChannelManager for decryption key requests
    let player = create_new_player(&session, current_generation);
    let event_stop_tx = start_player_event_pump(Arc::clone(&player), current_generation);

    *SESSION.lock().unwrap_or_else(|e| e.into_inner()) = Some(session.clone());
    *PLAYER_EVENT_TX.lock().unwrap_or_else(|e| e.into_inner()) = Some(event_stop_tx);

    spawn_cluster_listener(&session, current_generation)?;
    spawn_initial_cluster_fetch(&session, current_generation);
    spawn_session_health_check(current_generation);

    match create_and_store_spirc(&session, &credentials, player, mixer).await {
        Ok(spirc) => {
            // `Spirc::new` has completed Session::connect and the login5 authorization
            // needed by the player path. Retire the previous cache only after that
            // connection succeeds; failed reconnects must preserve it for retry.
            retire_previous_credentials_cache();

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
            // The load comes from Swift. Publishing `resume_pending` with `spirc_ready`
            // still clear tells `PlaybackStore` to issue its `ResumeLoadPlan` targets now;
            // `session_connected` must already be true for those loads to pass
            // `require_session_connected`. Inside this window `load_at_position` returns as
            // soon as Spirc queued the load, so Swift stops at the first queued target (as
            // `resume_via_load` did) and the wait below is the only Playing wait. Swift's
            // session phase stays non-ready until the commit below, so its Web API bootstrap
            // still waits for the rehydrated state.
            //
            // This used to arm a five-second window waiting for a Paused event, on the
            // assumption that the track would load itself via transfer(None) — nothing in
            // this path ever called transfer(None), so the event never came.
            if resume_after_connect {
                if has_resume_identity() {
                    let seq_before = open_rehydration_window(current_generation);
                    with_connection(|c| {
                        c.session_connected = true;
                        c.resume_pending = true;
                        c.last_error = None;
                    });
                    notify_connection_state_change();

                    let outcome = wait_for_rehydration(seq_before, REHYDRATION_WINDOW).await;
                    with_connection(|c| c.resume_pending = false);
                    debug!(
                        "[WAKE +{}ms] Rehydrate after reconnect: {:?}",
                        elapsed_since_wake_ms(),
                        outcome
                    );

                    match outcome {
                        RehydrationOutcome::NeedsReinit => {
                            // Closed command channel: this Spirc is already dead, so the
                            // session can never play. Success is committed below, after
                            // this point, so the connection state still reads not ready;
                            // the reconnect loop treats the error as another attempt.
                            with_connection(|c| c.session_connected = false);
                            return Err(
                                "Rehydration failed: Spirc command channel closed".to_string()
                            );
                        }
                        RehydrationOutcome::TimedOut => {
                            // `Spirc::load` only queues a command, so an accepted load may
                            // still land after this. Waiting kept Swift's Web API bootstrap
                            // out of the gap; a timeout is not fatal.
                            debug!(
                                "[WAKE +{}ms] Rehydrate: nothing landed within {:?}, publishing anyway",
                                elapsed_since_wake_ms(),
                                REHYDRATION_WINDOW
                            );
                        }
                        RehydrationOutcome::Playing => {}
                    }
                } else {
                    // Nothing to resume — no saved context or track URI. Reachable when an
                    // outage lands between a play command and the player events that record
                    // what is playing. The session itself is fine, so failing here would
                    // make every later attempt fail identically, forever.
                    debug!(
                        "[WAKE +{}ms] Rehydrate: nothing to resume",
                        elapsed_since_wake_ms()
                    );
                }
            }

            // Committing late means this can be reached after something else took over —
            // spotty_playback_cleanup on logout, a manual retry, or sleep, any of which can land
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
                // Only teardown may clear globals. Teardown outranks a moved counter:
                // `init_player_async` clears both teardown flags as it starts, so a flag
                // that is set now means no newer generation began after it.
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
                c.resume_pending = false;
                c.last_error = None;
            });
            notify_connection_state_change();
        }
        Err(e) => {
            // No fallback: every Spotty control goes through Spirc, so a bare connected
            // Session is not a usable player. This used to call session.connect() and
            // return Ok, which reported success while leaving Swift with a player whose
            // every command would fail - and because initializeIfNeeded then refused to
            // retry, that state was permanent.
            return Err(format!("Spirc initialization failed: {}", e));
        }
    }

    Ok(())
}
