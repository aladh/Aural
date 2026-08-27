use crate::*;

pub(crate) fn send_playback_state(player_state: &PlayerState) {
    debug!("send_playback_state called");

    // Log context URI - this is the "active playlist/album/artist" being played from
    let context_uri = &player_state.context_uri;
    if !context_uri.is_empty() {
        debug!("Context URI: {}", context_uri);
        update_current_context_uri(context_uri);
    }

    let Some(callback) = registered_callback(&CONTROL_CALLBACKS.playback_state) else {
        debug!("No playback state callback registered, skipping update");
        return;
    };

    // Extract track URI
    let track_uri = player_state
        .track
        .as_ref()
        .map(|t| t.uri.clone())
        .unwrap_or_default();

    // Extract playback options (shuffle, repeat)
    let options = player_state.options.as_ref();
    let shuffle = options.map(|o| o.shuffling_context).unwrap_or(false);
    let repeat_track = options.map(|o| o.repeating_track).unwrap_or(false);
    let repeat_context = options.map(|o| o.repeating_context).unwrap_or(false);
    update_playback_options(shuffle, repeat_track, repeat_context);

    let update = stamped_snapshot(|stamp| PlaybackStateUpdate {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        is_playing: player_state.is_playing,
        is_paused: player_state.is_paused,
        track_uri,
        position_ms: player_state.position_as_of_timestamp,
        duration_ms: player_state.duration,
        shuffle,
        repeat_track,
        repeat_context,
        timestamp_ms: player_state.timestamp,
    });

    debug!(
        "PlaybackState: playing={}, paused={}, position={}ms, duration={}ms, timestamp={}ms, shuffle={}, repeat_track={}, repeat_context={}",
        update.is_playing,
        update.is_paused,
        update.position_ms,
        update.duration_ms,
        update.timestamp_ms,
        update.shuffle,
        update.repeat_track,
        update.repeat_context
    );

    send_json(callback, &update);
}

/// Send playback state update from local player events (Playing, Paused)
/// This is used when Aural is the active device - state changes happen locally
/// and don't come through Mercury cluster updates.
pub(crate) fn send_local_playback_state(is_playing: bool, position_ms: u32) {
    debug!(
        "send_local_playback_state called: is_playing={}, position_ms={}",
        is_playing, position_ms
    );

    let Some(callback) = registered_callback(&CONTROL_CALLBACKS.playback_state) else {
        return;
    };

    // Get track URI from local state
    let track_uri = CURRENT_TRACK_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .unwrap_or_default();

    // Get duration from local state
    let duration_ms = CURRENT_DURATION_MS.load(Ordering::SeqCst);
    let (shuffle, repeat_track, repeat_context) = current_playback_options();

    let update = stamped_snapshot(|stamp| PlaybackStateUpdate {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        is_playing,
        is_paused: !is_playing,
        track_uri,
        position_ms: position_ms as i64,
        duration_ms: duration_ms as i64,
        shuffle,
        repeat_track,
        repeat_context,
        timestamp_ms: current_timestamp_ms() as i64,
    });

    debug!(
        "Local PlaybackState: playing={}, paused={}, position={}ms, duration={}ms, shuffle={}, repeat_track={}, repeat_context={}",
        update.is_playing,
        update.is_paused,
        update.position_ms,
        update.duration_ms,
        update.shuffle,
        update.repeat_track,
        update.repeat_context
    );

    send_json(callback, &update);
}

/// Converts a Connect-state track into a queue item.
///
/// Metadata is left empty on purpose: Swift resolves it from the AppStore by URI, so
/// carrying names and artwork across the FFI boundary would just duplicate it.
pub(crate) fn to_queue_item(track: &ProvidedTrack) -> QueueItem {
    QueueItem {
        uri: track.uri.clone(),
        name: String::new(),
        artist: String::new(),
        image_url: String::new(),
        duration_ms: 0,
        album_name: String::new(),
        provider: track.provider.clone(),
        uid: track.uid.clone(),
    }
}

pub(crate) fn to_protocol_track(track: &ProvidedTrack) -> ProtocolQueueTrack {
    ProtocolQueueTrack {
        uri: track.uri.clone(),
        uid: track.uid.clone(),
        provider: track.provider.clone(),
        metadata: track.metadata.clone(),
        removed: track.removed.clone(),
        blocked: track.blocked.clone(),
        restrictions: protocol_restrictions(track),
        album_uri: track.album_uri.clone(),
        disallow_reasons: track.disallow_reasons.clone(),
        artist_uri: track.artist_uri.clone(),
    }
}

fn protocol_restrictions(
    track: &ProvidedTrack,
) -> Option<serde_json::Map<String, serde_json::Value>> {
    let restrictions = track.restrictions.as_ref()?;
    let mut map = serde_json::Map::new();
    let fields: [(&str, &[String]); 25] = [
        (
            "disallow_pausing_reasons",
            &restrictions.disallow_pausing_reasons,
        ),
        (
            "disallow_resuming_reasons",
            &restrictions.disallow_resuming_reasons,
        ),
        (
            "disallow_seeking_reasons",
            &restrictions.disallow_seeking_reasons,
        ),
        (
            "disallow_peeking_prev_reasons",
            &restrictions.disallow_peeking_prev_reasons,
        ),
        (
            "disallow_peeking_next_reasons",
            &restrictions.disallow_peeking_next_reasons,
        ),
        (
            "disallow_skipping_prev_reasons",
            &restrictions.disallow_skipping_prev_reasons,
        ),
        (
            "disallow_skipping_next_reasons",
            &restrictions.disallow_skipping_next_reasons,
        ),
        (
            "disallow_toggling_repeat_context_reasons",
            &restrictions.disallow_toggling_repeat_context_reasons,
        ),
        (
            "disallow_toggling_repeat_track_reasons",
            &restrictions.disallow_toggling_repeat_track_reasons,
        ),
        (
            "disallow_toggling_shuffle_reasons",
            &restrictions.disallow_toggling_shuffle_reasons,
        ),
        (
            "disallow_set_queue_reasons",
            &restrictions.disallow_set_queue_reasons,
        ),
        (
            "disallow_interrupting_playback_reasons",
            &restrictions.disallow_interrupting_playback_reasons,
        ),
        (
            "disallow_transferring_playback_reasons",
            &restrictions.disallow_transferring_playback_reasons,
        ),
        (
            "disallow_remote_control_reasons",
            &restrictions.disallow_remote_control_reasons,
        ),
        (
            "disallow_inserting_into_next_tracks_reasons",
            &restrictions.disallow_inserting_into_next_tracks_reasons,
        ),
        (
            "disallow_inserting_into_context_tracks_reasons",
            &restrictions.disallow_inserting_into_context_tracks_reasons,
        ),
        (
            "disallow_reordering_in_next_tracks_reasons",
            &restrictions.disallow_reordering_in_next_tracks_reasons,
        ),
        (
            "disallow_reordering_in_context_tracks_reasons",
            &restrictions.disallow_reordering_in_context_tracks_reasons,
        ),
        (
            "disallow_removing_from_next_tracks_reasons",
            &restrictions.disallow_removing_from_next_tracks_reasons,
        ),
        (
            "disallow_removing_from_context_tracks_reasons",
            &restrictions.disallow_removing_from_context_tracks_reasons,
        ),
        (
            "disallow_updating_context_reasons",
            &restrictions.disallow_updating_context_reasons,
        ),
        (
            "disallow_playing_reasons",
            &restrictions.disallow_playing_reasons,
        ),
        (
            "disallow_stopping_reasons",
            &restrictions.disallow_stopping_reasons,
        ),
        (
            "disallow_add_to_queue_reasons",
            &restrictions.disallow_add_to_queue_reasons,
        ),
        (
            "disallow_setting_playback_speed_reasons",
            &restrictions.disallow_setting_playback_speed_reasons,
        ),
    ];
    for (key, values) in fields {
        if !values.is_empty() {
            map.insert(key.to_string(), serde_json::json!(values));
        }
    }
    if map.is_empty() {
        None
    } else {
        Some(map)
    }
}

pub(crate) fn collect_protocol_tracks(tracks: &[ProvidedTrack]) -> Vec<ProtocolQueueTrack> {
    tracks.iter().map(to_protocol_track).collect()
}

pub(crate) fn queue_replacement_disallowed(player_state: &PlayerState) -> (bool, bool) {
    let Some(restrictions) = player_state.restrictions.as_ref() else {
        return (false, false);
    };
    (
        !restrictions.disallow_set_queue_reasons.is_empty(),
        !restrictions
            .disallow_removing_from_next_tracks_reasons
            .is_empty(),
    )
}

/// Collects the playable tracks of one queue side, stopping at the first delimiter.
///
/// `spotify:delimiter` marks the boundary of what the user actually queued: after it in
/// next_tracks comes Spotify's autoplay continuation, and in prev_tracks it marks the
/// start of the context. Showing either as part of the queue would present tracks the
/// user never chose.
pub(crate) fn collect_queue_items(tracks: &[ProvidedTrack], side: &str) -> Vec<QueueItem> {
    let mut items = Vec::new();

    for (i, track) in tracks.iter().enumerate() {
        if i < 3 || !track.uri.starts_with("spotify:track:") {
            debug!(
                "{} track[{}] uri='{}' provider='{}'",
                side, i, track.uri, track.provider
            );
        }

        if track.uri == "spotify:delimiter" {
            debug!(
                "Stopping {} at delimiter (index {}), hiding {} tracks",
                side,
                i,
                tracks.len() - i - 1
            );
            break;
        }

        if track.uri.starts_with("spotify:track:") {
            items.push(to_queue_item(track));
        }
    }

    items
}

pub(crate) fn process_and_send_queue(player_state: PlayerState) {
    debug!("process_and_send_queue called");

    // Log context URI for queue processing too
    if !player_state.context_uri.is_empty() {
        debug!("Queue context URI: {}", player_state.context_uri);
        update_current_context_uri(&player_state.context_uri);
    }

    let Some(callback) = registered_callback(&CONTROL_CALLBACKS.queue) else {
        debug!("No callback registered, skipping queue update");
        return;
    };

    let protocol_next_tracks = collect_protocol_tracks(&player_state.next_tracks);
    let protocol_prev_tracks = collect_protocol_tracks(&player_state.prev_tracks);
    let queue_revision = player_state.queue_revision.clone();
    let (disallow_set_queue, disallow_removing_from_next_tracks) =
        queue_replacement_disallowed(&player_state);
    let current_track = player_state.track.into_option().and_then(|t| {
        debug!("current track[0] uri='{}' provider='{}'", t.uri, t.provider);
        if t.uri.starts_with("spotify:track:") {
            Some(to_queue_item(&t))
        } else {
            None
        }
    });
    let next_tracks = collect_queue_items(&player_state.next_tracks, "next");
    let prev_tracks = collect_queue_items(&player_state.prev_tracks, "prev");

    debug!(
        "Queue counts: current={}, next={}, prev={}",
        if current_track.is_some() { 1 } else { 0 },
        next_tracks.len(),
        prev_tracks.len()
    );

    let state = stamped_snapshot(|stamp| QueueState {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        track: current_track,
        next_tracks,
        prev_tracks,
        protocol_next_tracks,
        protocol_prev_tracks,
        queue_revision,
        disallow_set_queue,
        disallow_removing_from_next_tracks,
    });

    // Remembered as well as sent. A callback is a one-shot, and Swift has recovery paths that
    // need to ask "what is playing?" at a moment of their own choosing — a provisional
    // SetQueue from librespot being the awkward one, since it arrives carrying no queue at
    // all. That question used to go to `/me/player/queue`; now it comes back here.
    if let Ok(json) = serde_json::to_string(&state) {
        *LAST_QUEUE_JSON.lock().unwrap_or_else(|e| e.into_inner()) = Some(json);
    }

    send_json(callback, &state);
}

/// The last queue the cluster described, as JSON, or null if no cluster update has arrived.
///
/// Replaces `/me/player/queue` and `/me/player` for Swift's bootstrap. Deliberately a snapshot
/// of what was already pushed rather than a fresh request: the cluster is the only source now,
/// so there is nothing newer to fetch, and a caller that gets null has genuinely not been told
/// anything yet rather than having been told there is nothing.
#[no_mangle]
pub extern "C" fn aural_playback_get_queue_snapshot() -> *mut c_char {
    ffi_owned_string("aural_playback_get_queue_snapshot", || {
        let snapshot = LAST_QUEUE_JSON
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        snapshot.map_or(std::ptr::null_mut(), into_owned_c_string)
    })
}
