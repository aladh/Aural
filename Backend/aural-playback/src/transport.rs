use crate::*;

/// How often the playing-event waits re-read [`PLAYING_EVENT_SEQ`].
pub(crate) const PLAYING_EVENT_POLL_INTERVAL: Duration = Duration::from_millis(25);

/// How long `resume_playback` gives `Spirc::play` before Swift may issue load fallbacks.
/// `play` only queues a command, so this is the window in which an accepted one produces audio.
pub(crate) const PLAY_COMMAND_PLAYING_TIMEOUT: Duration = Duration::from_millis(500);

/// How long each seek-capable load waits for a Playing event before Swift may try the next
/// target (reconnect rehydration uses [`REHYDRATE_PLAYING_TIMEOUT`] instead).
pub(crate) const RESUME_LOAD_PLAYING_TIMEOUT: Duration = Duration::from_secs(2);

/// How long rehydration waits for the Player to actually start before giving up on the
/// wait (not on the session). Observed load-to-playing is around a second.
pub(crate) const REHYDRATE_PLAYING_TIMEOUT: Duration = Duration::from_secs(3);

/// Context and track URIs captured for a resume load, with the seek position they share.
///
/// Target order is the Swift `ResumeLoadPlan` policy. Reconnect rehydration still
/// builds a plan from session globals here. User resume iterates Swift targets through
/// [`load_at_position`]. Empty strings are missing: that is how the session globals
/// read after cleanup, not a URI Spirc can load.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResumeLoadPlan {
    pub(crate) position_ms: u32,
    pub(crate) context_uri: Option<String>,
    pub(crate) track_uri: Option<String>,
}

/// One ordered resume-load fallback. Context is tried first, with an optional current-track
/// hint; a single-track load is last. A queued success stops the sequence — the next target
/// is only for a non-terminal failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ResumeLoadTarget {
    Context {
        uri: String,
        track_hint: Option<String>,
        position_ms: u32,
    },
    Track {
        uri: String,
        position_ms: u32,
    },
}

impl ResumeLoadPlan {
    pub(crate) fn capture(
        saved_at_deactivation: u32,
        live: u32,
        context_uri: Option<String>,
        track_uri: Option<String>,
    ) -> Self {
        Self {
            position_ms: resume_position(saved_at_deactivation, live),
            context_uri: nonempty_uri(context_uri),
            // Keep Some("") as a context track hint; only the single-track fallback
            // treats empty as missing, matching the previous inline load sequence.
            track_uri,
        }
    }

    pub(crate) fn from_saved_playback() -> Self {
        let context_uri = CURRENT_CONTEXT_URI
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        let track_uri = CURRENT_TRACK_URI
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        Self::capture(
            RESUME_POSITION_MS.load(Ordering::SeqCst),
            POSITION_MS.load(Ordering::SeqCst),
            context_uri,
            track_uri,
        )
    }

    pub(crate) fn targets(&self) -> Vec<ResumeLoadTarget> {
        let mut targets = Vec::new();
        if let Some(context_uri) = self.context_uri.clone() {
            targets.push(ResumeLoadTarget::Context {
                uri: context_uri,
                track_hint: self.track_uri.clone(),
                position_ms: self.position_ms,
            });
        }
        if let Some(track_uri) = nonempty_uri(self.track_uri.clone()) {
            targets.push(ResumeLoadTarget::Track {
                uri: track_uri,
                position_ms: self.position_ms,
            });
        }
        targets
    }
}

impl ResumeLoadTarget {
    /// Logs this fallback and builds the Spirc load. The loop in [`resume_via_load`] only
    /// issues the request; start-playing, seek, track-hint, and the diagnostic wording live
    /// here so they cannot drift from the ordered targets.
    fn into_load(self) -> (LoadRequest, &'static str) {
        match self {
            Self::Context {
                uri,
                track_hint,
                position_ms,
            } => {
                let playing_track = track_hint.map(PlayingTrack::Uri);
                debug!(
                    "Resume fallback: loading context {} at {}ms (track hint: {:?})",
                    uri, position_ms, playing_track
                );
                (
                    LoadRequest::from_context_uri(
                        uri,
                        LoadRequestOptions {
                            start_playing: true,
                            seek_to: position_ms,
                            playing_track,
                            ..Default::default()
                        },
                    ),
                    "Resume fallback context load",
                )
            }
            Self::Track { uri, position_ms } => {
                debug!(
                    "Resume fallback: loading single track {} at {}ms",
                    uri, position_ms
                );
                (
                    LoadRequest::from_tracks(
                        vec![uri],
                        LoadRequestOptions {
                            start_playing: true,
                            seek_to: position_ms,
                            ..Default::default()
                        },
                    ),
                    "Resume fallback track load",
                )
            }
        }
    }
}

fn nonempty_uri(uri: Option<String>) -> Option<String> {
    uri.filter(|uri| !uri.is_empty())
}

/// Helper to ensure the device is active before loading content.
/// If not active, activates via Spirc directly (no spclient HTTP needed).
/// Returns Ok(()) if ready to load, Err(i32) with error code if activation failed.
pub(crate) fn ensure_active_for_playback(spirc: &Arc<Spirc>) -> Result<(), i32> {
    if !is_active_device() {
        debug!("Device not active, activating via spirc.activate()");
        match spirc.activate() {
            Ok(_) => {
                debug!("Activate succeeded");
                set_active_device(true);
            }
            Err(_e) => {
                debug!("Activate failed: {:?}", _e);
                return Err(-1);
            }
        }
    }
    Ok(())
}

/// Whether [`PLAYING_EVENT_SEQ`] has advanced past the value captured before a command.
pub(crate) fn playing_event_advanced(previous_seq: u64) -> bool {
    PLAYING_EVENT_SEQ.load(Ordering::SeqCst) > previous_seq
}

/// Waits for the Player to report playback, blocking the calling thread.
///
/// For the synchronous FFI entry points, which are called on Swift's own threads. Inside the
/// runtime use the async twin below instead.
pub(crate) fn wait_for_playing_event(previous_seq: u64, timeout: Duration) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        if playing_event_advanced(previous_seq) {
            return true;
        }
        if std::time::Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(PLAYING_EVENT_POLL_INTERVAL);
    }
}

/// Waits for the Player to report playback, without parking a runtime worker.
///
/// Runs inside `init_player_async`, where the thread sleep above would block a tokio worker.
pub(crate) async fn wait_for_playing_event_async(previous_seq: u64, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if playing_event_advanced(previous_seq) {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(PLAYING_EVENT_POLL_INTERVAL).await;
    }
}

/// Queues one `LoadRequest`. `None` means try the next fallback; a closed channel is terminal.
pub(crate) fn issue_load_target(spirc: &Spirc, target: ResumeLoadTarget) -> Option<i32> {
    let (load_request, what) = target.into_load();
    match spirc.load(load_request) {
        Ok(_) => Some(0),
        Err(e) => match spirc_error(what, &e) {
            ERROR_NEEDS_REINIT => Some(ERROR_NEEDS_REINIT),
            _ => None,
        },
    }
}

/// Reloads what was playing, at the position it stopped.
///
/// **The caller must have activated the device.** `Spirc::load` only hands the command to a
/// channel, so `Ok` means "queued", not "accepted" — and `SpircTask` drops `Load` while its
/// connect state is inactive. This used to call `set_active_device(true)` on that `Ok`,
/// which turned a discarded load into an apparent takeover: Swift then believed Aural was
/// the active device and routed every later transport command to a local player that was
/// ignoring all of them. Activity is recorded where it is actually established — by
/// `ensure_active_for_playback` and by `init_player_async` — never inferred from a queued
/// command. The remaining caller is rehydration in `init_player_async`, which runs only when
/// `should_resume()` held (so `was_active` and `spirc.activate()` already ran). User resume
/// load fallbacks are Swift `ResumeLoadPlan` targets via [`load_at_position`].
pub(crate) fn resume_via_load(spirc: &Arc<Spirc>) -> i32 {
    // Read rather than taken. `Spirc::load` only queues a command, so reaching this point
    // does not mean playback resumed — the load can fail on a closed channel, or be accepted
    // and never produce audio. Clearing here would throw away the only pre-deactivation
    // position and leave the retry restarting the track from zero. The `Playing` event
    // clears it instead, which is the one signal that the resume actually landed.
    let plan = ResumeLoadPlan::from_saved_playback();

    for target in plan.targets() {
        if let Some(result) = issue_load_target(spirc, target) {
            return result;
        }
    }

    ERROR_GENERAL
}

/// One seek-capable load for Swift `ResumeLoadPlan` targets. Each target is given the
/// resume-load playing timeout; a timeout lets Swift try the next fallback.
pub(crate) fn load_at_position(
    uri: String,
    track_hint: Option<String>,
    position_ms: u32,
    from_context: bool,
) -> i32 {
    if uri.is_empty() {
        return ERROR_GENERAL;
    }
    if let Err(e) = require_session_connected() {
        return e;
    }
    let Some(spirc) = current_spirc("Load") else {
        return ERROR_GENERAL;
    };
    if let Err(e) = ensure_active_for_playback(&spirc) {
        return e;
    }
    let target = if from_context {
        ResumeLoadTarget::Context {
            uri,
            track_hint,
            position_ms,
        }
    } else {
        ResumeLoadTarget::Track { uri, position_ms }
    };
    let seq_before = PLAYING_EVENT_SEQ.load(Ordering::SeqCst);
    match issue_load_target(&spirc, target) {
        Some(0) => {
            if wait_for_playing_event(seq_before, RESUME_LOAD_PLAYING_TIMEOUT) {
                0
            } else {
                ERROR_GENERAL
            }
        }
        Some(code) => code,
        None => ERROR_GENERAL,
    }
}

/// Publishes the accepted local pause so Swift does not keep interpolating time.
///
/// `IS_PLAYING` is cleared here rather than left to the event stream: the user can pause
/// while a track is still loading, and in that case `PlayerEvent::Playing` never fires, so
/// there is no playing-to-paused transition for the listener to report. A locally issued
/// pause is also not guaranteed to produce `PlayerEvent::Paused` (for example while the
/// player is still transitioning between tracks). A later player or cluster update remains
/// authoritative and can correct this snapshot if the command did not land.
pub(crate) fn publish_accepted_local_pause() {
    IS_PLAYING.store(false, Ordering::SeqCst);
    send_local_playback_state(false, POSITION_MS.load(Ordering::SeqCst));
}

/// Pauses playback through Spirc and publishes the accepted local paused snapshot.
pub(crate) fn pause_playback() -> i32 {
    debug!("aural_playback_pause called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    spirc_command("Pause", |spirc| {
        spirc.pause()?;
        publish_accepted_local_pause();
        Ok(())
    })
}

/// Resumes playback: activate, `play()`, then return so Swift can issue seek-capable
/// load fallbacks. Reconnect rehydration still calls [`resume_via_load`].
pub(crate) fn resume_playback() -> i32 {
    debug!("aural_playback_resume called");
    if let Err(e) = require_session_connected() {
        return e;
    }

    if IS_PLAYING.load(Ordering::SeqCst) {
        return 0;
    }

    // A resume is already working; joining it is what this caller wanted, so report success
    // rather than starting a second one that would restart the track underneath the first.
    if RESUMING.swap(true, Ordering::SeqCst) {
        debug!("Resume already in progress");
        return 0;
    }
    let _resuming = ResumeGuard;

    let Some(spirc) = current_spirc("Resume") else {
        return ERROR_GENERAL;
    };

    // Activation is a precondition, not an optimization. `SpircTask` matches
    // `_ if !self.connect_state.is_active()` ahead of every transport command, so `Play`,
    // `Load`, `Next`, `Prev`, `Shuffle` and `SetPosition` are discarded with a warning while
    // inactive — the whole resume path below, load fallback included, would be dropped and
    // nothing would play. Waking from sleep lands here every time: the sleep teardown shuts
    // Spirc down, librespot answers with `SessionDisconnected`, and its handler clears the
    // active flag.
    if let Err(e) = ensure_active_for_playback(&spirc) {
        return e;
    }

    let play_seq_before = PLAYING_EVENT_SEQ.load(Ordering::SeqCst);
    if let Err(e) = spirc.play() {
        return spirc_error("Resume", &e);
    }

    if wait_for_playing_event(play_seq_before, PLAY_COMMAND_PLAYING_TIMEOUT) {
        return 0;
    }

    debug!("Resume play() produced no Playing event within timeout; Swift may load fallbacks");
    ERROR_GENERAL
}
