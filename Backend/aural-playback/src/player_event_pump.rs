use crate::*;

/// What the event listener should do with one `recv` result.
///
/// `None` (a closed channel) must stop even when the listener generation is stale: skipping
/// that result would spin. A `Some` event from a replaced generation is ignored so a draining
/// predecessor cannot write position, track, or activity for a session that no longer exists.
/// `Apply` carries the event so the loop does not re-open the option after the policy decision.
///
/// `PlayerEvent` is `Debug` + `Clone` only, so this enum does not derive `Copy`/`Eq`.
#[derive(Debug, Clone)]
pub(crate) enum PlayerEventDisposition {
    Apply(PlayerEvent),
    IgnoreSuperseded,
    ChannelClosed,
}

pub(crate) fn player_event_disposition(
    event: Option<PlayerEvent>,
    listener_generation: u64,
    current_generation: u64,
) -> PlayerEventDisposition {
    match event {
        None => PlayerEventDisposition::ChannelClosed,
        Some(_) if !listener_may_act(listener_generation, current_generation) => {
            PlayerEventDisposition::IgnoreSuperseded
        }
        Some(event) => PlayerEventDisposition::Apply(event),
    }
}

/// Live position captured at `SessionDisconnected`. Zero is how a missing baton reads, so a
/// second disconnect after `Stopped` reset the live position must not overwrite a good one.
pub(crate) fn resume_position_to_save_on_deactivation(live_position_ms: u32) -> Option<u32> {
    (live_position_ms > 0).then_some(live_position_ms)
}

/// Starts the player-event listener for `generation` and returns the stop sender.
///
/// The caller stores the sender in [`PLAYER_EVENT_TX`]. Teardown takes it and signals stop
/// before dropping the Player. This listener belongs to `generation` for its whole life: a
/// rebuild replaces the listener along with the session, so the captured value never has to
/// change underneath it. A Player clone is held until the task exits so the event channel
/// does not close while the pump is still running.
pub(crate) fn start_player_event_pump(
    player: Arc<Player>,
    generation: u64,
) -> mpsc::UnboundedSender<()> {
    // Opt in to SetQueue events along with the rest of the player stream.
    let mut event_channel = player.get_player_event_channel();
    let (tx, mut rx) = mpsc::unbounded_channel::<()>();
    let player_keepalive = Arc::clone(&player);
    RUNTIME.spawn(async move {
        loop {
            tokio::select! {
                _ = rx.recv() => {
                    // Shutdown signal received
                    debug!("Player event listener shutting down (generation={})", generation);
                    break;
                }
                event = event_channel.recv() => {
                    // Drop everything from a superseded generation. A replaced listener
                    // drains asynchronously after its successor is live — the logs show old
                    // listeners still delivering seconds later — and without this guard it
                    // would keep writing position, track, playing and active-device state
                    // belonging to a session that no longer exists.
                    //
                    // `None` must still reach ChannelClosed and break. Skipping it would spin.
                    match player_event_disposition(
                        event,
                        generation,
                        SESSION_GENERATION.load(Ordering::SeqCst),
                    ) {
                        PlayerEventDisposition::IgnoreSuperseded => continue,
                        PlayerEventDisposition::ChannelClosed => break,
                        PlayerEventDisposition::Apply(event) => {
                            apply_player_event(event, generation);
                        }
                    }
                }
            }
        }
        drop(player_keepalive);
    });
    tx
}

fn apply_player_event(event: PlayerEvent, event_listener_generation: u64) {
    match event {
        PlayerEvent::Playing {
            track_id,
            position_ms,
            ..
        } => {
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
        PlayerEvent::Paused {
            track_id,
            position_ms,
            ..
        } => {
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
        PlayerEvent::PositionChanged { position_ms, .. } => {
            // Periodic position update (every 200ms)
            update_position(position_ms);
        }
        PlayerEvent::Seeked { position_ms, .. } => {
            update_position(position_ms);
        }
        PlayerEvent::PositionCorrection { position_ms, .. } => {
            debug!(
                "[WAKE +{}ms] PositionCorrection event: {}ms",
                elapsed_since_wake_ms(),
                position_ms
            );
            update_position(position_ms);
        }
        PlayerEvent::Stopped { .. } => {
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
        PlayerEvent::EndOfTrack { track_id, .. } => {
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
        PlayerEvent::TrackChanged { audio_item } => {
            let audio_item_uri = audio_item.track_id.to_string();
            let duration_ms = audio_item.duration_ms;
            let logical_track_uri = CURRENT_TRACK_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
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
        PlayerEvent::ShuffleChanged { shuffle } => {
            debug!("PlayerEvent::ShuffleChanged: {}", shuffle);
            SHUFFLE_STATE.store(shuffle, Ordering::SeqCst);
            send_local_playback_state(
                IS_PLAYING.load(Ordering::SeqCst),
                POSITION_MS.load(Ordering::SeqCst),
            );
        }
        PlayerEvent::RepeatChanged { context, track } => {
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
        PlayerEvent::Loading {
            track_id,
            position_ms,
            ..
        } => {
            let track_uri_str = track_id.to_string();
            debug!("Loading event: {} at {}ms", track_uri_str, position_ms);

            // Both, together. The position and the track URI are read as a
            // pair — a resume load seeks `POSITION_MS` within
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
        }
        PlayerEvent::SetQueue {
            context_uri,
            next_tracks,
            prev_tracks,
            ..
        } => {
            debug!(
                "SetQueue event: context={}, next={}, prev={}",
                context_uri,
                next_tracks.len(),
                prev_tracks.len()
            );
            update_current_context_uri(&context_uri);
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
        PlayerEvent::SessionDisconnected {
            connection_id,
            user_name: _,
        } => {
            // Account identifiers stay out of public logs; connection_id is session context.
            debug!(
                "[WAKE +{}ms] became inactive (SessionDisconnected): connection_id={}, listener_generation={}",
                elapsed_since_wake_ms(),
                connection_id,
                event_listener_generation
            );

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
            if let Some(stopped_at_ms) =
                resume_position_to_save_on_deactivation(POSITION_MS.load(Ordering::SeqCst))
            {
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

            if should_recover_after_deactivation(session_invalid, teardown_in_progress()) {
                debug!(
                    "[WAKE +{}ms] Session is invalid at deactivation - recovering",
                    elapsed_since_wake_ms()
                );
                mark_disconnected("Session invalid");
                spawn_reconnection_loop(intent);
            } else {
                notify_connection_state_change();
            }
        }
        // Emitted when the local Connect device becomes ACTIVE. Carries the
        // session's connection id, but says nothing about network health -
        // the session was already connected before activation.
        PlayerEvent::SessionConnected {
            connection_id,
            user_name: _,
        } => {
            debug!(
                "[WAKE +{}ms] became active (SessionConnected): connection_id={}",
                elapsed_since_wake_ms(),
                connection_id
            );
            set_active_device(true);

            // Notify connection state change
            notify_connection_state_change();
        }
        PlayerEvent::SessionClientChanged {
            client_id,
            client_name,
            client_brand_name,
            client_model_name,
        } => {
            debug!(
                "SessionClientChanged event: id={}, name={}, brand={}, model={}",
                client_id, client_name, client_brand_name, client_model_name
            );
        }
        _ => {}
    }
}

#[cfg(test)]
mod player_event_pump_policy {
    use super::*;

    fn sample_event() -> PlayerEvent {
        PlayerEvent::VolumeChanged { volume: 1 }
    }

    #[test]
    fn a_closed_channel_stops_even_if_the_generation_is_current() {
        match player_event_disposition(None, 4, 4) {
            PlayerEventDisposition::ChannelClosed => {}
            other => panic!("expected ChannelClosed, got {other:?}"),
        }
    }

    #[test]
    fn a_closed_channel_stops_even_if_the_generation_is_superseded() {
        match player_event_disposition(None, 3, 4) {
            PlayerEventDisposition::ChannelClosed => {}
            other => panic!("expected ChannelClosed, got {other:?}"),
        }
    }

    #[test]
    fn a_superseded_event_is_ignored() {
        match player_event_disposition(Some(sample_event()), 3, 4) {
            PlayerEventDisposition::IgnoreSuperseded => {}
            other => panic!("expected IgnoreSuperseded, got {other:?}"),
        }
    }

    #[test]
    fn a_current_generation_event_is_applied() {
        match player_event_disposition(Some(sample_event()), 4, 4) {
            PlayerEventDisposition::Apply(PlayerEvent::VolumeChanged { volume: 1 }) => {}
            other => panic!("expected Apply(VolumeChanged), got {other:?}"),
        }
    }

    #[test]
    fn deactivation_saves_a_nonzero_live_position() {
        assert_eq!(resume_position_to_save_on_deactivation(93606), Some(93606));
    }

    #[test]
    fn deactivation_does_not_overwrite_with_a_zero_live_position() {
        assert_eq!(resume_position_to_save_on_deactivation(0), None);
    }

    fn synthetic_track() -> SpotifyUri {
        parse_spotify_uri("spotify:track:0000000000000000000000").expect("synthetic track URI")
    }

    fn playing_event(position_ms: u32) -> PlayerEvent {
        PlayerEvent::Playing {
            play_request_id: 1,
            track_id: synthetic_track(),
            position_ms,
        }
    }

    #[derive(Clone)]
    struct PlaybackGlobals {
        is_playing: bool,
        is_active: bool,
        playing_seq: u64,
        resume_position_ms: u32,
        position_ms: u32,
        track_uri: Option<String>,
        context_uri: Option<String>,
    }

    fn capture_playback_globals() -> PlaybackGlobals {
        PlaybackGlobals {
            is_playing: IS_PLAYING.load(Ordering::SeqCst),
            is_active: is_active_device(),
            playing_seq: PLAYING_EVENT_SEQ.load(Ordering::SeqCst),
            resume_position_ms: RESUME_POSITION_MS.load(Ordering::SeqCst),
            position_ms: POSITION_MS.load(Ordering::SeqCst),
            track_uri: CURRENT_TRACK_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone(),
            context_uri: CURRENT_CONTEXT_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone(),
        }
    }

    fn restore_playback_globals(snapshot: PlaybackGlobals) {
        IS_PLAYING.store(snapshot.is_playing, Ordering::SeqCst);
        set_active_device(snapshot.is_active);
        PLAYING_EVENT_SEQ.store(snapshot.playing_seq, Ordering::SeqCst);
        RESUME_POSITION_MS.store(snapshot.resume_position_ms, Ordering::SeqCst);
        POSITION_MS.store(snapshot.position_ms, Ordering::SeqCst);
        *CURRENT_TRACK_URI.lock().unwrap_or_else(|e| e.into_inner()) = snapshot.track_uri;
        *CURRENT_CONTEXT_URI
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = snapshot.context_uri;
    }

    struct RestorePlaybackGlobals(PlaybackGlobals);

    impl Drop for RestorePlaybackGlobals {
        fn drop(&mut self) {
            restore_playback_globals(self.0.clone());
        }
    }

    #[test]
    fn a_playing_event_is_the_authoritative_playing_transition() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        IS_PLAYING.store(false, Ordering::SeqCst);
        let seq_before = PLAYING_EVENT_SEQ.load(Ordering::SeqCst);

        apply_player_event(playing_event(1_250), 1);

        assert!(IS_PLAYING.load(Ordering::SeqCst));
        assert!(PLAYING_EVENT_SEQ.load(Ordering::SeqCst) > seq_before);
        assert_eq!(POSITION_MS.load(Ordering::SeqCst), 1_250);
        assert_eq!(
            CURRENT_TRACK_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_deref(),
            Some("spotify:track:0000000000000000000000")
        );
    }

    #[test]
    fn paused_stopped_and_end_of_track_still_clear_playing() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        let track_id = synthetic_track();

        IS_PLAYING.store(true, Ordering::SeqCst);
        apply_player_event(
            PlayerEvent::Paused {
                play_request_id: 1,
                track_id: track_id.clone(),
                position_ms: 800,
            },
            1,
        );
        assert!(!IS_PLAYING.load(Ordering::SeqCst));
        assert_eq!(POSITION_MS.load(Ordering::SeqCst), 800);

        IS_PLAYING.store(true, Ordering::SeqCst);
        apply_player_event(
            PlayerEvent::Stopped {
                play_request_id: 1,
                track_id: track_id.clone(),
            },
            1,
        );
        assert!(!IS_PLAYING.load(Ordering::SeqCst));

        IS_PLAYING.store(true, Ordering::SeqCst);
        apply_player_event(
            PlayerEvent::EndOfTrack {
                play_request_id: 1,
                track_id,
            },
            1,
        );
        assert!(!IS_PLAYING.load(Ordering::SeqCst));
    }

    #[test]
    fn loading_still_updates_track_position_and_resume_state() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        RESUME_POSITION_MS.store(9_001, Ordering::SeqCst);
        POSITION_MS.store(400, Ordering::SeqCst);
        *CURRENT_TRACK_URI.lock().unwrap_or_else(|e| e.into_inner()) =
            Some("spotify:track:outgoing".to_string());

        apply_player_event(
            PlayerEvent::Loading {
                play_request_id: 1,
                track_id: synthetic_track(),
                position_ms: 250,
            },
            1,
        );

        assert_eq!(POSITION_MS.load(Ordering::SeqCst), 250);
        assert_eq!(RESUME_POSITION_MS.load(Ordering::SeqCst), 0);
        assert_eq!(
            CURRENT_TRACK_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_deref(),
            Some("spotify:track:0000000000000000000000")
        );
    }

    #[test]
    fn set_queue_still_updates_context() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        *CURRENT_CONTEXT_URI
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = None;

        apply_player_event(
            PlayerEvent::SetQueue {
                context_uri: "spotify:playlist:context".to_string(),
                current_track: None,
                next_tracks: Vec::new(),
                prev_tracks: Vec::new(),
            },
            1,
        );

        assert_eq!(
            CURRENT_CONTEXT_URI
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_deref(),
            Some("spotify:playlist:context")
        );
    }

    #[test]
    fn session_connected_and_disconnected_still_update_active_state() {
        let _guard = lock_lifecycle_test_globals();
        let _restore = RestorePlaybackGlobals(capture_playback_globals());
        set_active_device(false);
        apply_player_event(
            PlayerEvent::SessionConnected {
                connection_id: "conn".to_string(),
                user_name: String::new(),
            },
            1,
        );
        assert!(is_active_device());

        POSITION_MS.store(1_200, Ordering::SeqCst);
        apply_player_event(
            PlayerEvent::SessionDisconnected {
                connection_id: "conn".to_string(),
                user_name: String::new(),
            },
            1,
        );
        assert!(!is_active_device());
        assert_eq!(RESUME_POSITION_MS.load(Ordering::SeqCst), 1_200);
    }

    #[test]
    fn cleanup_still_clears_playing() {
        let _guard = lock_lifecycle_test_globals();
        IS_PLAYING.store(true, Ordering::SeqCst);
        aural_playback_cleanup();
        assert!(!IS_PLAYING.load(Ordering::SeqCst));
    }
}
