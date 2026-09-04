//! Coverage for the audio-command C boundary (#208 slice 3c): the wire numbering both
//! directions depend on, what a delivered `AuralAudioCommand` actually carries, and the
//! generation/play-request rejection `aural_playback_report_audio` performs.
//!
//! These tests mutate process-wide registries (`CONTROL_CALLBACKS.audio_command`,
//! `SHIM_PLAYER`), so each takes [`TEST_LOCK`] and restores what it changed through a drop
//! guard — `cargo test` runs the crate's tests on parallel threads.

use crate::*;
use librespot_core::{Error as LibrespotError, SpotifyId, SpotifyUri};
use librespot_metadata::audio::{AudioFileFormat, AudioItem};
use std::ffi::CStr;
use std::future::Future;
use std::pin::Pin;

static TEST_LOCK: Mutex<()> = Mutex::new(());

/// Every `AuralAudioCommand` the static test callback below received, as owned data — the
/// snapshot's `track_uri` is only valid for the call, exactly as Swift sees it.
static RECEIVED: Mutex<Vec<CapturedCommand>> = Mutex::new(Vec::new());

#[derive(Clone, Debug, PartialEq, Eq)]
struct CapturedCommand {
    session_generation: u64,
    play_request_id: u64,
    kind: u8,
    track_uri: Option<String>,
    track_gid: [u8; 16],
    file_id: [u8; 20],
    audio_format: u8,
    position_ms: u32,
    start_playing: u8,
    duration_ms: u32,
}

extern "C" fn capture_callback(command: *const AuralAudioCommand) {
    let command = unsafe { &*command };
    let track_uri = if command.track_uri.is_null() {
        None
    } else {
        Some(
            unsafe { CStr::from_ptr(command.track_uri) }
                .to_string_lossy()
                .into_owned(),
        )
    };
    RECEIVED
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .push(CapturedCommand {
            session_generation: command.session_generation,
            play_request_id: command.play_request_id,
            kind: command.kind,
            track_uri,
            track_gid: command.track_gid,
            file_id: command.file_id,
            audio_format: command.audio_format,
            position_ms: command.position_ms,
            start_playing: command.start_playing,
            duration_ms: command.duration_ms,
        });
}

/// Clears both process-wide registries this file touches when it goes out of scope, so a test
/// cannot leave the Swift audio path switched on for the rest of the run.
struct RestoreAudioGlobals;

impl Drop for RestoreAudioGlobals {
    fn drop(&mut self) {
        *CONTROL_CALLBACKS
            .audio_command
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = None;
        *SHIM_PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = None;
        RECEIVED.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }
}

/// Never resolves an item. `load` sets the shim's current `play_request_id` synchronously,
/// before this is ever awaited, which is all these tests need — the detached resolution then
/// fails and broadcasts `Unavailable` into a channel nobody is listening on.
struct FailingResolver;

impl AudioItemResolver for FailingResolver {
    fn resolve(
        &self,
        _track_id: SpotifyUri,
    ) -> Pin<Box<dyn Future<Output = Result<AudioItem, LibrespotError>> + Send>> {
        Box::pin(async { Err(LibrespotError::unavailable("test resolver")) })
    }
}

fn fixture_track_id() -> SpotifyUri {
    SpotifyUri::Track {
        id: SpotifyId::from_raw(&[7u8; 16]).expect("16-byte raw id"),
    }
}

fn load_command(session_generation: u64, play_request_id: u64) -> AudioCommand {
    AudioCommand {
        session_generation,
        play_request_id,
        kind: AudioCommandKind::Load,
        track_uri: "spotify:track:fixture".to_string(),
        track_gid: [3u8; 16],
        file_id: [9u8; 20],
        audio_format: AudioFileFormat::OGG_VORBIS_320,
        position_ms: 1_234,
        start_playing: true,
        duration_ms: 210_000,
    }
}

/// A shim whose current load is `play_request_id` 1, stored where the report export looks.
fn install_shim(session_generation: u64) -> Arc<ShimPlayer> {
    let sink: Arc<dyn AudioCommandSink> = Arc::new(FfiAudioCommandSink);
    let resolver: Arc<dyn AudioItemResolver> = Arc::new(FailingResolver);
    let player = Arc::new(ShimPlayer::new(sink, resolver, session_generation));
    let play_request_id = player.load(fixture_track_id(), true, 0);
    assert_eq!(play_request_id, 1, "first load must be play_request_id 1");
    *SHIM_PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::clone(&player));
    player
}

#[test]
fn command_kind_codes_match_the_swift_raw_values() {
    assert_eq!(command_kind_code(AudioCommandKind::Load), 0);
    assert_eq!(command_kind_code(AudioCommandKind::Play), 1);
    assert_eq!(command_kind_code(AudioCommandKind::Pause), 2);
    assert_eq!(command_kind_code(AudioCommandKind::Seek), 3);
    assert_eq!(command_kind_code(AudioCommandKind::Stop), 4);
    assert_eq!(command_kind_code(AudioCommandKind::Preload), 5);
}

#[test]
fn report_kind_codes_match_the_swift_raw_values_and_reject_unknowns() {
    assert_eq!(report_kind(0), Some(AudioReportKind::Playing));
    assert_eq!(report_kind(1), Some(AudioReportKind::Paused));
    assert_eq!(report_kind(2), Some(AudioReportKind::Position));
    assert_eq!(report_kind(3), Some(AudioReportKind::Seeked));
    assert_eq!(report_kind(4), Some(AudioReportKind::PositionCorrection));
    assert_eq!(report_kind(5), Some(AudioReportKind::EndOfTrack));
    assert_eq!(report_kind(6), Some(AudioReportKind::Unavailable));
    assert_eq!(report_kind(7), Some(AudioReportKind::Stopped));
    assert_eq!(report_kind(8), Some(AudioReportKind::TimeToPreloadNext));
    assert_eq!(report_kind(9), Some(AudioReportKind::Duration));
    assert_eq!(report_kind(10), None);
    assert_eq!(report_kind(255), None);
}

#[test]
fn audio_format_codes_match_librespot_numbering() {
    assert_eq!(audio_format_code(AudioFileFormat::OGG_VORBIS_96), 0);
    assert_eq!(audio_format_code(AudioFileFormat::OGG_VORBIS_160), 1);
    assert_eq!(audio_format_code(AudioFileFormat::OGG_VORBIS_320), 2);
}

#[test]
fn a_registered_callback_receives_the_whole_typed_command() {
    let _serial = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _restore = RestoreAudioGlobals;

    aural_playback_register_audio_command_callback(capture_callback);
    assert!(swift_audio_path_enabled());

    FfiAudioCommandSink.send(load_command(4, 11));

    let received = RECEIVED.lock().unwrap_or_else(|e| e.into_inner()).clone();
    assert_eq!(
        received,
        vec![CapturedCommand {
            session_generation: 4,
            play_request_id: 11,
            kind: 0,
            track_uri: Some("spotify:track:fixture".to_string()),
            track_gid: [3u8; 16],
            file_id: [9u8; 20],
            audio_format: 2,
            position_ms: 1_234,
            start_playing: 1,
            duration_ms: 210_000,
        }]
    );
}

#[test]
fn a_command_sent_with_no_callback_registered_is_dropped() {
    let _serial = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _restore = RestoreAudioGlobals;

    *CONTROL_CALLBACKS
        .audio_command
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = None;
    assert!(!swift_audio_path_enabled());

    FfiAudioCommandSink.send(load_command(4, 11));

    assert!(RECEIVED
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .is_empty());
}

#[test]
fn a_report_for_the_current_generation_and_load_is_accepted() {
    let _serial = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _restore = RestoreAudioGlobals;
    install_shim(7);

    assert_eq!(aural_playback_report_audio(7, 1, 0, 500, 0), 0);
}

#[test]
fn a_report_from_a_superseded_session_generation_is_rejected() {
    let _serial = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _restore = RestoreAudioGlobals;
    let player = install_shim(7);

    // Same load, one generation behind and one ahead: both name a session this shim is not.
    assert_eq!(aural_playback_report_audio(6, 1, 0, 500, 0), ERROR_GENERAL);
    assert_eq!(aural_playback_report_audio(8, 1, 0, 500, 0), ERROR_GENERAL);
    assert_eq!(player.stale_report_count(), 2);
    assert_eq!(aural_playback_report_audio(7, 1, 0, 500, 0), 0);
}

#[test]
fn a_report_for_an_abandoned_play_request_is_rejected() {
    let _serial = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _restore = RestoreAudioGlobals;
    let player = install_shim(7);

    // The load the report names has been replaced by a second one.
    let current = player.load(fixture_track_id(), true, 0);
    assert_eq!(current, 2);

    assert_eq!(aural_playback_report_audio(7, 1, 5, 0, 0), ERROR_GENERAL);
    assert_eq!(player.stale_report_count(), 1);
    assert_eq!(aural_playback_report_audio(7, 2, 5, 0, 0), 0);
}

#[test]
fn a_report_with_no_shim_or_an_unknown_kind_is_rejected() {
    let _serial = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let _restore = RestoreAudioGlobals;

    *SHIM_PLAYER.lock().unwrap_or_else(|e| e.into_inner()) = None;
    assert_eq!(aural_playback_report_audio(1, 1, 0, 0, 0), ERROR_GENERAL);

    install_shim(1);
    assert_eq!(aural_playback_report_audio(1, 1, 200, 0, 0), ERROR_GENERAL);
}
