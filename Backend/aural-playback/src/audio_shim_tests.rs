use crate::audio_shim::*;
use crate::block_on_export;
use librespot_core::{Error, SpotifyId, SpotifyUri};
use librespot_metadata::audio::{AudioFileFormat, AudioFiles, AudioItem, UniqueFields};
use librespot_metadata::availability::UnavailabilityReason;
use librespot_metadata::track::Tracks;
use librespot_playback::player::{PlayerEvent, PlayerEventChannel};
use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
use tokio::sync::Notify;

#[derive(Default)]
struct FakeSink {
    commands: Mutex<Vec<AudioCommand>>,
    arrived: Condvar,
}

impl FakeSink {
    /// Blocks (on a real OS thread, not `crate::RUNTIME`) until at least `count` commands have
    /// arrived, or panics after `timeout`. Deterministic: unlike a sleep-and-poll loop, this
    /// cannot pass before the command that should arrive actually has.
    fn wait_for_commands(&self, count: usize, timeout: Duration) -> Vec<AudioCommand> {
        let guard = self.commands.lock().unwrap_or_else(|e| e.into_inner());
        let (guard, result) = self
            .arrived
            .wait_timeout_while(guard, timeout, |commands| commands.len() < count)
            .unwrap_or_else(|e| e.into_inner());
        assert!(
            !result.timed_out(),
            "timed out waiting for {count} command(s)"
        );
        guard.clone()
    }
}

impl AudioCommandSink for FakeSink {
    fn send(&self, command: AudioCommand) {
        let mut commands = self.commands.lock().unwrap_or_else(|e| e.into_inner());
        commands.push(command);
        self.arrived.notify_all();
    }
}

/// Resolves whatever [`AudioItem`]s were registered with `with`, keyed by the item's own
/// `track_id`; an unregistered track fails. `gate_track` optionally makes one track's
/// resolution wait on a [`Notify`] before returning, for deterministic supersession tests.
#[derive(Default)]
struct FakeResolver {
    items: Mutex<HashMap<SpotifyUri, AudioItem>>,
    gate: Mutex<Option<(SpotifyUri, Arc<Notify>)>>,
}

impl FakeResolver {
    fn resolving_to(item: AudioItem) -> Self {
        Self::default().with(item)
    }

    fn with(self, item: AudioItem) -> Self {
        self.items
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(item.track_id.clone(), item);
        self
    }

    fn gate_track(self, track_id: SpotifyUri, notify: Arc<Notify>) -> Self {
        *self.gate.lock().unwrap_or_else(|e| e.into_inner()) = Some((track_id, notify));
        self
    }
}

impl AudioItemResolver for FakeResolver {
    fn resolve(
        &self,
        track_id: SpotifyUri,
    ) -> Pin<Box<dyn Future<Output = Result<AudioItem, Error>> + Send>> {
        let item = self
            .items
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&track_id)
            .cloned();
        let gate = self
            .gate
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .filter(|entry| entry.0 == track_id)
            .map(|entry| Arc::clone(&entry.1));
        Box::pin(async move {
            if let Some(notify) = gate {
                notify.notified().await;
            }
            item.ok_or_else(|| Error::unavailable("no fixture configured"))
        })
    }
}

fn fixture_track_id() -> SpotifyUri {
    SpotifyUri::Track {
        id: SpotifyId::from_raw(&[7u8; 16]).expect("16-byte raw id"),
    }
}

fn fixture_audio_item(
    track_id: SpotifyUri,
    files: AudioFiles,
    duration_ms: u32,
    is_explicit: bool,
) -> AudioItem {
    AudioItem {
        uri: track_id.to_uri(),
        track_id,
        files,
        name: "Fixture Track".to_string(),
        covers: Vec::new(),
        language: Vec::new(),
        duration_ms,
        is_explicit,
        availability: Ok(()),
        alternatives: None,
        unique_fields: UniqueFields::Local {
            artists: None,
            album: None,
            album_artists: None,
            number: None,
            disc_number: None,
            path: PathBuf::new(),
        },
    }
}

fn vorbis_files(formats: &[AudioFileFormat]) -> AudioFiles {
    let mut map = HashMap::new();
    for (i, format) in formats.iter().enumerate() {
        map.insert(*format, librespot_core::FileId::from_raw(&[i as u8; 20]));
    }
    AudioFiles(map)
}

/// Blocks the calling (non-Tokio) thread briefly on `crate::RUNTIME`, giving a task spawned
/// there by `load`/`preload` a chance to run.
fn wait_briefly() {
    block_on_export(async {
        tokio::time::sleep(Duration::from_millis(20)).await;
    })
    .expect("block_on_export must succeed from a plain test thread");
}

/// Polls `events` until a `PlayerEvent` arrives or ~1s has elapsed.
fn wait_for_event(events: &mut PlayerEventChannel) -> PlayerEvent {
    for _ in 0..50 {
        if let Ok(event) = events.try_recv() {
            return event;
        }
        wait_briefly();
    }
    panic!("no PlayerEvent arrived within the timeout");
}

fn shim_player(
    sink: Arc<FakeSink>,
    resolver: Arc<FakeResolver>,
    session_generation: u64,
) -> ShimPlayer {
    ShimPlayer::new(sink, resolver, session_generation)
}

/// A resolver that always succeeds, so the background resolution triggered by `load` sends a
/// `Load` `AudioCommand` and nothing else — reports built by hand in these tests are the only
/// thing that reaches the event channel.
fn resolving_resolver(track_id: SpotifyUri) -> Arc<FakeResolver> {
    let files = vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]);
    Arc::new(FakeResolver::resolving_to(fixture_audio_item(
        track_id, files, 1_000, false,
    )))
}

#[test]
fn load_emits_play_request_id_changed_then_loading_before_the_load_command() {
    let track_id = fixture_track_id();
    let files = vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]);
    let item = fixture_audio_item(track_id.clone(), files, 4_000, false);

    let sink = Arc::new(FakeSink::default());
    let resolver = Arc::new(FakeResolver::resolving_to(item));
    let player = shim_player(Arc::clone(&sink), resolver, 1);
    let mut events = player.get_player_event_channel();

    let play_request_id = player.load(track_id, true, 500);

    let first = events
        .try_recv()
        .expect("PlayRequestIdChanged must be sent synchronously");
    assert!(matches!(
        first,
        PlayerEvent::PlayRequestIdChanged { play_request_id: id } if id == play_request_id
    ));

    let second = events
        .try_recv()
        .expect("Loading must be sent synchronously");
    assert!(matches!(
        second,
        PlayerEvent::Loading { play_request_id: id, position_ms: 500, .. } if id == play_request_id
    ));

    // File resolution is async: the Load command must not exist yet.
    assert!(
        sink.commands.lock().unwrap().is_empty(),
        "the Load command must wait for file resolution"
    );

    let commands = sink.wait_for_commands(1, Duration::from_secs(2));
    assert_eq!(commands.len(), 1);
    assert_eq!(commands[0].kind, AudioCommandKind::Load);
    assert_eq!(commands[0].play_request_id, play_request_id);
    assert_eq!(commands[0].session_generation, 1);
    assert_eq!(commands[0].audio_format, AudioFileFormat::OGG_VORBIS_160);
    assert_eq!(commands[0].duration_ms, 4_000);
    assert!(commands[0].start_playing);
}

#[test]
fn each_load_gets_a_fresh_play_request_id() {
    let track_id = fixture_track_id();
    let files = vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]);
    let sink = Arc::new(FakeSink::default());
    let resolver = Arc::new(FakeResolver::resolving_to(fixture_audio_item(
        track_id.clone(),
        files,
        1_000,
        false,
    )));
    let player = shim_player(sink, resolver, 1);

    let first_id = player.load(track_id.clone(), false, 0);
    let second_id = player.load(track_id, false, 0);

    assert_ne!(first_id, second_id);
}

#[test]
fn stale_report_with_wrong_play_request_id_is_dropped() {
    let track_id = fixture_track_id();
    let sink = Arc::new(FakeSink::default());
    let resolver = resolving_resolver(track_id.clone());
    let player = shim_player(sink, resolver, 9);
    let mut events = player.get_player_event_channel();

    let play_request_id = player.load(track_id, false, 0);
    events.try_recv().expect("PlayRequestIdChanged");
    events.try_recv().expect("Loading");

    assert_eq!(player.stale_report_count(), 0);
    player.report(AudioReport {
        session_generation: 9,
        play_request_id: play_request_id + 1,
        kind: AudioReportKind::Playing,
        position_ms: 1_234,
        duration_ms: 0,
    });

    assert_eq!(player.stale_report_count(), 1);
    assert!(
        events.try_recv().is_err(),
        "a stale report must not be translated into a PlayerEvent"
    );
}

#[test]
fn stale_report_with_wrong_session_generation_is_dropped() {
    let track_id = fixture_track_id();
    let sink = Arc::new(FakeSink::default());
    let resolver = resolving_resolver(track_id.clone());
    let player = shim_player(sink, resolver, 9);
    let mut events = player.get_player_event_channel();

    let play_request_id = player.load(track_id, false, 0);
    events.try_recv().expect("PlayRequestIdChanged");
    events.try_recv().expect("Loading");

    player.report(AudioReport {
        session_generation: 10,
        play_request_id,
        kind: AudioReportKind::Playing,
        position_ms: 1_234,
        duration_ms: 0,
    });

    assert_eq!(player.stale_report_count(), 1);
    assert!(events.try_recv().is_err());
}

#[test]
fn matching_report_emits_playing_with_current_track_id() {
    let track_id = fixture_track_id();
    let sink = Arc::new(FakeSink::default());
    let resolver = resolving_resolver(track_id.clone());
    let player = shim_player(sink, resolver, 3);
    let mut events = player.get_player_event_channel();

    let play_request_id = player.load(track_id.clone(), false, 0);
    events.try_recv().expect("PlayRequestIdChanged");
    events.try_recv().expect("Loading");

    player.report(AudioReport {
        session_generation: 3,
        play_request_id,
        kind: AudioReportKind::Playing,
        position_ms: 9_000,
        duration_ms: 0,
    });

    let event = events
        .try_recv()
        .expect("matching report must emit an event");
    match event {
        PlayerEvent::Playing {
            play_request_id: id,
            track_id: reported_track_id,
            position_ms,
        } => {
            assert_eq!(id, play_request_id);
            assert_eq!(reported_track_id, track_id);
            assert_eq!(position_ms, 9_000);
        }
        other => panic!("expected PlayerEvent::Playing, got {other:?}"),
    }
    assert_eq!(player.stale_report_count(), 0);
}

#[test]
fn matching_end_of_track_report_emits_end_of_track() {
    let track_id = fixture_track_id();
    let sink = Arc::new(FakeSink::default());
    let resolver = resolving_resolver(track_id.clone());
    let player = shim_player(sink, resolver, 3);
    let mut events = player.get_player_event_channel();

    let play_request_id = player.load(track_id.clone(), false, 0);
    events.try_recv().expect("PlayRequestIdChanged");
    events.try_recv().expect("Loading");

    player.report(AudioReport {
        session_generation: 3,
        play_request_id,
        kind: AudioReportKind::EndOfTrack,
        position_ms: 0,
        duration_ms: 0,
    });

    let event = events
        .try_recv()
        .expect("matching report must emit an event");
    assert!(matches!(
        event,
        PlayerEvent::EndOfTrack { play_request_id: id, track_id: t }
            if id == play_request_id && t == track_id
    ));
}

#[test]
fn select_audio_file_prefers_highest_bitrate_vorbis() {
    let files = vorbis_files(&[
        AudioFileFormat::OGG_VORBIS_96,
        AudioFileFormat::OGG_VORBIS_160,
        AudioFileFormat::OGG_VORBIS_320,
    ]);

    let (format, _) =
        select_audio_file(&files, &VORBIS_FORMAT_PREFERENCE).expect("a Vorbis file is available");
    assert_eq!(format, AudioFileFormat::OGG_VORBIS_320);
}

#[test]
fn select_audio_file_falls_back_when_the_top_preference_is_missing() {
    let files = vorbis_files(&[
        AudioFileFormat::OGG_VORBIS_96,
        AudioFileFormat::OGG_VORBIS_160,
    ]);

    let (format, _) =
        select_audio_file(&files, &VORBIS_FORMAT_PREFERENCE).expect("a Vorbis file is available");
    assert_eq!(format, AudioFileFormat::OGG_VORBIS_160);
}

#[test]
fn select_audio_file_returns_none_without_a_vorbis_alternative() {
    let mut map = HashMap::new();
    map.insert(
        AudioFileFormat::MP3_320,
        librespot_core::FileId::from_raw(&[1u8; 20]),
    );
    let files = AudioFiles(map);

    assert!(select_audio_file(&files, &VORBIS_FORMAT_PREFERENCE).is_none());
}

#[test]
fn unavailable_resolution_emits_unavailable() {
    let track_id = fixture_track_id();
    let sink = Arc::new(FakeSink::default());
    let resolver = Arc::new(FakeResolver::default()); // no fixture configured -> resolution fails
    let player = shim_player(Arc::clone(&sink), resolver, 5);
    let mut events = player.get_player_event_channel();

    let play_request_id = player.load(track_id.clone(), false, 0);
    events.try_recv().expect("PlayRequestIdChanged");
    events.try_recv().expect("Loading");

    let event = wait_for_event(&mut events);
    assert!(matches!(
        event,
        PlayerEvent::Unavailable { play_request_id: id, track_id: t }
            if id == play_request_id && t == track_id
    ));
    assert!(
        sink.commands.lock().unwrap().is_empty(),
        "a failed resolution must not send a Load command"
    );
}

#[test]
fn closed_event_subscriber_is_pruned() {
    let sink = Arc::new(FakeSink::default());
    let resolver = Arc::new(FakeResolver::default());
    let player = shim_player(sink, resolver, 1);

    let closed_channel = player.get_player_event_channel();
    drop(closed_channel);
    let mut live_channel = player.get_player_event_channel();

    player.emit_volume_changed(42);

    let event = live_channel
        .try_recv()
        .expect("the live subscriber must still receive events");
    assert!(matches!(event, PlayerEvent::VolumeChanged { volume: 42 }));

    // Broadcasting again must not panic or error even though the first subscriber was dropped;
    // its sender is pruned on the first attempted send after the receiver closed.
    player.emit_volume_changed(7);
    assert!(live_channel.try_recv().is_ok());
}

/// Regression test: `command_sink.send` will eventually be a synchronous Swift callback that
/// can itself call back into `ShimPlayer::report` before returning. If `command()` held
/// `current`'s lock across `send`, this test deadlocks; the assertion below turns that into a
/// clean failure (a `recv_timeout`) instead of an indefinitely hung test run.
#[test]
fn command_does_not_hold_a_lock_while_the_sink_reenters_report() {
    struct ReentrantSink {
        player: Mutex<Option<Arc<ShimPlayer>>>,
    }

    impl AudioCommandSink for ReentrantSink {
        fn send(&self, command: AudioCommand) {
            let player = self
                .player
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .clone();
            if let Some(player) = player {
                player.report(AudioReport {
                    session_generation: command.session_generation,
                    play_request_id: command.play_request_id,
                    kind: AudioReportKind::Paused,
                    position_ms: 0,
                    duration_ms: 0,
                });
            }
        }
    }

    let sink = Arc::new(ReentrantSink {
        player: Mutex::new(None),
    });
    let resolver = Arc::new(FakeResolver::default());
    let sink_dyn: Arc<dyn AudioCommandSink> = sink.clone();
    let player = Arc::new(ShimPlayer::new(sink_dyn, resolver, 1));
    *sink.player.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&player));

    let (done_tx, done_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        player.pause();
        let _ = done_tx.send(());
    });

    done_rx
        .recv_timeout(Duration::from_secs(2))
        .expect("command() must not hold a lock across command_sink.send (deadlock)");
}

#[test]
fn a_superseded_load_does_not_send_its_load_command() {
    let track_a = fixture_track_id();
    let track_b = SpotifyUri::Track {
        id: SpotifyId::from_raw(&[8u8; 16]).expect("16-byte raw id"),
    };

    let files = vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]);
    let item_a = fixture_audio_item(track_a.clone(), files.clone(), 1_000, false);
    let item_b = fixture_audio_item(track_b.clone(), files, 2_000, false);

    // track_a's resolution is gated so it finishes only after track_b's, simulating the second
    // `load` overtaking the first.
    let gate = Arc::new(Notify::new());
    let resolver = Arc::new(
        FakeResolver::default()
            .with(item_a)
            .with(item_b)
            .gate_track(track_a.clone(), Arc::clone(&gate)),
    );
    let sink = Arc::new(FakeSink::default());
    let player = shim_player(Arc::clone(&sink), resolver, 1);

    let first_id = player.load(track_a, false, 0);
    let second_id = player.load(track_b, false, 0);
    assert_ne!(first_id, second_id);

    // Deterministic: the second (non-gated) load's resolution finishes and sends its command.
    let commands = sink.wait_for_commands(1, Duration::from_secs(2));
    assert_eq!(commands.len(), 1);
    assert_eq!(commands[0].play_request_id, second_id);

    // Release the superseded first load's resolution and give it a moment to (not) act. Without
    // the outbound staleness check, this would push a second command for `first_id`.
    gate.notify_one();
    wait_briefly();
    let commands = sink.commands.lock().unwrap_or_else(|e| e.into_inner());
    assert_eq!(
        commands.len(),
        1,
        "a superseded load must not send its Load command once resolution completes"
    );
}

#[test]
fn find_available_alternative_returns_the_item_when_it_already_has_files() {
    let track_id = fixture_track_id();
    let files = vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]);
    let item = fixture_audio_item(track_id, files, 1_000, false);
    let resolver: Arc<dyn AudioItemResolver> = Arc::new(FakeResolver::default());

    let resolved = block_on_export(find_available_alternative(&resolver, item.clone()))
        .expect("block_on_export must succeed from a plain test thread")
        .expect("an item with files is used directly");
    assert_eq!(resolved.track_id, item.track_id);
}

#[test]
fn find_available_alternative_returns_none_when_availability_failed() {
    let track_id = fixture_track_id();
    let mut item = fixture_audio_item(track_id, AudioFiles::default(), 0, false);
    item.availability = Err(UnavailabilityReason::Embargo);
    let resolver: Arc<dyn AudioItemResolver> = Arc::new(FakeResolver::default());

    let resolved = block_on_export(find_available_alternative(&resolver, item))
        .expect("block_on_export must succeed from a plain test thread");
    assert!(resolved.is_none());
}

#[test]
fn find_available_alternative_falls_back_to_the_first_playable_alternative() {
    let requested = fixture_track_id();
    let alt_unavailable = SpotifyUri::Track {
        id: SpotifyId::from_raw(&[9u8; 16]).expect("16-byte raw id"),
    };
    let alt_playable = SpotifyUri::Track {
        id: SpotifyId::from_raw(&[10u8; 16]).expect("16-byte raw id"),
    };

    let mut unavailable_item =
        fixture_audio_item(alt_unavailable.clone(), AudioFiles::default(), 0, false);
    unavailable_item.availability = Err(UnavailabilityReason::Embargo);
    let playable_item = fixture_audio_item(
        alt_playable.clone(),
        vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]),
        999,
        false,
    );

    let mut primary = fixture_audio_item(requested, AudioFiles::default(), 0, false);
    primary.alternatives = Some(Tracks(vec![alt_unavailable, alt_playable.clone()]));

    let resolver: Arc<dyn AudioItemResolver> = Arc::new(
        FakeResolver::default()
            .with(unavailable_item)
            .with(playable_item),
    );

    let resolved = block_on_export(find_available_alternative(&resolver, primary))
        .expect("block_on_export must succeed from a plain test thread")
        .expect("the playable alternative must be found");
    assert_eq!(resolved.track_id, alt_playable);
    assert_eq!(resolved.duration_ms, 999);
}

#[test]
fn find_available_alternative_returns_none_when_no_alternative_is_playable() {
    let requested = fixture_track_id();
    let alt = SpotifyUri::Track {
        id: SpotifyId::from_raw(&[11u8; 16]).expect("16-byte raw id"),
    };
    let mut alt_item = fixture_audio_item(alt.clone(), AudioFiles::default(), 0, false);
    alt_item.availability = Err(UnavailabilityReason::NoData);

    let mut primary = fixture_audio_item(requested, AudioFiles::default(), 0, false);
    primary.alternatives = Some(Tracks(vec![alt]));

    let resolver: Arc<dyn AudioItemResolver> = Arc::new(FakeResolver::default().with(alt_item));
    let resolved = block_on_export(find_available_alternative(&resolver, primary))
        .expect("block_on_export must succeed from a plain test thread");
    assert!(resolved.is_none());
}

#[test]
fn filter_explicit_content_changed_ends_an_explicit_playing_track() {
    let track_id = fixture_track_id();
    let files = vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]);
    let item = fixture_audio_item(track_id.clone(), files, 1_000, true);
    let sink = Arc::new(FakeSink::default());
    let resolver = Arc::new(FakeResolver::resolving_to(item));
    let player = shim_player(Arc::clone(&sink), resolver, 4);
    let mut events = player.get_player_event_channel();

    let play_request_id = player.load(track_id.clone(), false, 0);
    events.try_recv().expect("PlayRequestIdChanged");
    events.try_recv().expect("Loading");
    // Wait for the Load command so `is_explicit` has been recorded from the resolved item.
    sink.wait_for_commands(1, Duration::from_secs(2));

    player.report(AudioReport {
        session_generation: 4,
        play_request_id,
        kind: AudioReportKind::Playing,
        position_ms: 0,
        duration_ms: 0,
    });
    events.try_recv().expect("Playing");

    player.emit_filter_explicit_content_changed(true);

    let filter_changed = events
        .try_recv()
        .expect("FilterExplicitContentChanged must be broadcast");
    assert!(matches!(
        filter_changed,
        PlayerEvent::FilterExplicitContentChanged { filter: true }
    ));

    let end_of_track = events
        .try_recv()
        .expect("the explicit track must be ended so Spirc advances");
    assert!(matches!(
        end_of_track,
        PlayerEvent::EndOfTrack { play_request_id: id, track_id: t }
            if id == play_request_id && t == track_id
    ));
}

#[test]
fn filter_explicit_content_changed_does_not_end_a_non_explicit_track() {
    let track_id = fixture_track_id();
    let files = vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]);
    let item = fixture_audio_item(track_id.clone(), files, 1_000, false);
    let sink = Arc::new(FakeSink::default());
    let resolver = Arc::new(FakeResolver::resolving_to(item));
    let player = shim_player(Arc::clone(&sink), resolver, 4);
    let mut events = player.get_player_event_channel();

    let play_request_id = player.load(track_id, false, 0);
    events.try_recv().expect("PlayRequestIdChanged");
    events.try_recv().expect("Loading");
    sink.wait_for_commands(1, Duration::from_secs(2));

    player.report(AudioReport {
        session_generation: 4,
        play_request_id,
        kind: AudioReportKind::Playing,
        position_ms: 0,
        duration_ms: 0,
    });
    events.try_recv().expect("Playing");

    player.emit_filter_explicit_content_changed(true);

    events
        .try_recv()
        .expect("FilterExplicitContentChanged must still be broadcast");
    assert!(
        events.try_recv().is_err(),
        "a non-explicit track must not be ended by the filter change"
    );
}

#[test]
fn filter_explicit_content_changed_off_never_ends_the_track() {
    let track_id = fixture_track_id();
    let files = vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]);
    let item = fixture_audio_item(track_id.clone(), files, 1_000, true);
    let sink = Arc::new(FakeSink::default());
    let resolver = Arc::new(FakeResolver::resolving_to(item));
    let player = shim_player(Arc::clone(&sink), resolver, 4);
    let mut events = player.get_player_event_channel();

    let play_request_id = player.load(track_id, false, 0);
    events.try_recv().expect("PlayRequestIdChanged");
    events.try_recv().expect("Loading");
    sink.wait_for_commands(1, Duration::from_secs(2));

    player.report(AudioReport {
        session_generation: 4,
        play_request_id,
        kind: AudioReportKind::Playing,
        position_ms: 0,
        duration_ms: 0,
    });
    events.try_recv().expect("Playing");

    player.emit_filter_explicit_content_changed(false);

    let filter_changed = events
        .try_recv()
        .expect("FilterExplicitContentChanged must still be broadcast");
    assert!(matches!(
        filter_changed,
        PlayerEvent::FilterExplicitContentChanged { filter: false }
    ));
    assert!(events.try_recv().is_err());
}
