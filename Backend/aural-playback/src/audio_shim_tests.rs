use crate::audio_shim::*;
use crate::block_on_export;
use librespot_core::{Error, SpotifyId, SpotifyUri};
use librespot_metadata::audio::{AudioFileFormat, AudioFiles, AudioItem, UniqueFields};
use librespot_playback::player::{PlayerEvent, PlayerEventChannel};
use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Default)]
struct FakeSink {
    commands: Mutex<Vec<AudioCommand>>,
}

impl AudioCommandSink for FakeSink {
    fn send(&self, command: AudioCommand) {
        self.commands
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(command);
    }
}

/// Resolves to a fixed [`AudioItem`], or fails when none was configured — the file-resolution
/// half of `ShimPlayer::load`/`preload` without a live `Session`.
#[derive(Default)]
struct FakeResolver {
    item: Mutex<Option<AudioItem>>,
}

impl FakeResolver {
    fn resolving_to(item: AudioItem) -> Self {
        Self {
            item: Mutex::new(Some(item)),
        }
    }
}

impl AudioItemResolver for FakeResolver {
    fn resolve(
        &self,
        _track_id: SpotifyUri,
    ) -> Pin<Box<dyn Future<Output = Result<AudioItem, Error>> + Send>> {
        let item = self.item.lock().unwrap_or_else(|e| e.into_inner()).clone();
        Box::pin(async move { item.ok_or_else(|| Error::unavailable("no fixture configured")) })
    }
}

fn fixture_track_id() -> SpotifyUri {
    SpotifyUri::Track {
        id: SpotifyId::from_raw(&[7u8; 16]).expect("16-byte raw id"),
    }
}

fn fixture_audio_item(track_id: SpotifyUri, files: AudioFiles, duration_ms: u32) -> AudioItem {
    AudioItem {
        uri: track_id.to_uri(),
        track_id,
        files,
        name: "Fixture Track".to_string(),
        covers: Vec::new(),
        language: Vec::new(),
        duration_ms,
        is_explicit: false,
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

/// Polls `condition` on `crate::RUNTIME` until it is true or ~1s has elapsed.
fn wait_until(mut condition: impl FnMut() -> bool) {
    for _ in 0..50 {
        if condition() {
            return;
        }
        wait_briefly();
    }
    panic!("condition was not met within the timeout");
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

#[test]
fn load_emits_play_request_id_changed_then_loading_before_the_load_command() {
    let track_id = fixture_track_id();
    let files = vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]);
    let item = fixture_audio_item(track_id.clone(), files, 4_000);

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

    wait_until(|| !sink.commands.lock().unwrap().is_empty());
    let commands = sink.commands.lock().unwrap();
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
    )));
    let player = shim_player(sink, resolver, 1);

    let first_id = player.load(track_id.clone(), false, 0);
    let second_id = player.load(track_id, false, 0);

    assert_ne!(first_id, second_id);
}

/// A resolver that always succeeds, so the background resolution triggered by `load` sends a
/// `Load` `AudioCommand` and nothing else — reports built by hand in these tests are the only
/// thing that reaches the event channel.
fn resolving_resolver(track_id: SpotifyUri) -> Arc<FakeResolver> {
    let files = vorbis_files(&[AudioFileFormat::OGG_VORBIS_160]);
    Arc::new(FakeResolver::resolving_to(fixture_audio_item(
        track_id, files, 1_000,
    )))
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
    let track_id = fixture_track_id();
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
