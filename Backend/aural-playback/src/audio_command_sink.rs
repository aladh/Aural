//! The C boundary of the Stage 1 Swift-owned audio path (#208, refs #201).
//!
//! Two exports, mirroring the two directions:
//!
//! - `aural_playback_register_audio_command_callback` installs Swift's sink. Registering it
//!   *before* `aural_playback_init_player` is also the switch that makes the next session build a
//!   [`ShimPlayer`] instead of librespot's own `Player` (see `create_new_player`), so main stays
//!   playable through `proxy_sink.rs` for as long as Swift declines to register.
//! - `aural_playback_report_audio` carries one playback fact back, stamped with the
//!   `session_generation` and `play_request_id` it claims to belong to. [`ShimPlayer::report`]
//!   rejects a stamp that no longer matches what it believes is loaded, so a report from a torn
//!   down session or an abandoned load can never move state or emit a `PlayerEvent`.
//!
//! Both directions obey the crate rule that no Rust lock may be held while Swift runs: the
//! callback pointer is copied out of its slot before it is called, and the `ShimPlayer` is
//! cloned out of its global before `report` runs.

use crate::*;
use librespot_metadata::audio::AudioFileFormat;

/// One forwarded Spirc command, delivered to Swift as a typed snapshot.
///
/// `track_uri` is valid only for the duration of the callback; Swift must copy it before
/// returning. `track_gid`, `file_id`, `audio_format`, `duration_ms`, `position_ms` and
/// `start_playing` only carry meaningful values for `Load` and `Preload`; the transport kinds
/// leave them zeroed (except `position_ms`, which `Seek` uses).
///
/// Fields are ordered widest-first, matching the header and the other typed snapshots in
/// `ffi.rs`: written in the order #219 lists them the struct would carry eight bytes of
/// padding for nothing.
#[repr(C)]
pub struct AuralAudioCommand {
    pub session_generation: u64,
    pub play_request_id: u64,
    pub track_uri: *const c_char,
    pub position_ms: u32,
    pub duration_ms: u32,
    pub track_gid: [u8; 16],
    pub file_id: [u8; 20],
    pub kind: u8,
    pub audio_format: u8,
    pub start_playing: u8,
}

pub(crate) type AudioCommandCallback = extern "C" fn(*const AuralAudioCommand);

/// C-ABI numbering for [`AudioCommandKind`], matching Swift's `AudioCommand.Kind` raw values.
/// Written out rather than derived from the enum's discriminants so a reordering of the Rust
/// enum cannot silently renumber the wire contract.
pub(crate) fn command_kind_code(kind: AudioCommandKind) -> u8 {
    match kind {
        AudioCommandKind::Load => 0,
        AudioCommandKind::Play => 1,
        AudioCommandKind::Pause => 2,
        AudioCommandKind::Seek => 3,
        AudioCommandKind::Stop => 4,
        AudioCommandKind::Preload => 5,
    }
}

/// C-ABI numbering for the audio format, matching Swift's `SpotifyAudioFormat` raw values,
/// which in turn match librespot's own `AudioFileFormat` numbering.
///
/// Only the Vorbis family is named: `VORBIS_FORMAT_PREFERENCE` is the only preference list
/// `ShimPlayer` ever selects with, so nothing else can reach a command. Anything else is logged
/// and reported as `OGG_VORBIS_96`, which is what a Swift decoder that only handles Vorbis would
/// have had to assume anyway.
pub(crate) fn audio_format_code(format: AudioFileFormat) -> u8 {
    match format {
        AudioFileFormat::OGG_VORBIS_96 => 0,
        AudioFileFormat::OGG_VORBIS_160 => 1,
        AudioFileFormat::OGG_VORBIS_320 => 2,
        other => {
            debug!(
                "Unexpected non-Vorbis audio format {:?} on an audio command",
                other
            );
            0
        }
    }
}

/// C-ABI numbering for [`AudioReportKind`], matching Swift's `AudioReportKind` raw values.
/// `None` for an unrecognized code, which the export rejects rather than guessing at.
pub(crate) fn report_kind(code: u8) -> Option<AudioReportKind> {
    match code {
        0 => Some(AudioReportKind::Playing),
        1 => Some(AudioReportKind::Paused),
        2 => Some(AudioReportKind::Position),
        3 => Some(AudioReportKind::Seeked),
        4 => Some(AudioReportKind::PositionCorrection),
        5 => Some(AudioReportKind::EndOfTrack),
        6 => Some(AudioReportKind::Unavailable),
        7 => Some(AudioReportKind::Stopped),
        8 => Some(AudioReportKind::TimeToPreloadNext),
        9 => Some(AudioReportKind::Duration),
        _ => None,
    }
}

/// Whether Swift has registered an audio-command sink, i.e. whether the next session build
/// should run the Swift audio path.
pub(crate) fn swift_audio_path_enabled() -> bool {
    registered_callback(&CONTROL_CALLBACKS.audio_command).is_some()
}

/// The [`AudioCommandSink`] `ShimPlayer` is constructed with: forwards each command to whatever
/// callback is registered at the moment the command is sent, and drops it when none is.
pub(crate) struct FfiAudioCommandSink;

impl AudioCommandSink for FfiAudioCommandSink {
    fn send(&self, command: AudioCommand) {
        // Copied out of its slot first: the callback enters Swift, which may call straight back
        // into `aural_playback_report_audio`, and holding the slot lock across that would both
        // deadlock a re-entrant registration and serialize unrelated commands.
        let Some(callback) = registered_callback(&CONTROL_CALLBACKS.audio_command) else {
            debug!(
                "Dropping audio command {:?}: no Swift audio-command callback registered",
                command.kind
            );
            return;
        };

        // An interior NUL cannot cross the boundary; every other field still can, so the URI
        // becomes null rather than the whole command becoming undeliverable.
        let track_uri = optional_callback_c_string(Some(command.track_uri.as_str()));
        let snapshot = AuralAudioCommand {
            session_generation: command.session_generation,
            play_request_id: command.play_request_id,
            track_uri: track_uri
                .as_ref()
                .map(|value| value.as_ptr())
                .unwrap_or(std::ptr::null()),
            position_ms: command.position_ms,
            duration_ms: command.duration_ms,
            track_gid: command.track_gid,
            file_id: command.file_id,
            kind: command_kind_code(command.kind),
            audio_format: audio_format_code(command.audio_format),
            start_playing: u8::from(command.start_playing),
        };
        callback(&snapshot);
    }
}

/// Registers the sink Swift's audio path receives forwarded Spirc commands on.
///
/// Call before `aural_playback_init_player`: the presence of a registration is what makes the
/// session build a `ShimPlayer`. Registering afterwards affects only the next rebuild.
#[no_mangle]
pub extern "C" fn aural_playback_register_audio_command_callback(callback: AudioCommandCallback) {
    ffi_void("aural_playback_register_audio_command_callback", || {
        *CONTROL_CALLBACKS
            .audio_command
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
        debug!("Swift audio path enabled: audio-command callback registered");
    })
}

/// Reports one playback fact from the Swift audio path.
///
/// Returns 0 when the report was applied, and `ERROR_GENERAL` when it was not: no `ShimPlayer`
/// is running (the old `proxy_sink` path is), the `kind` is not a known
/// [`AudioReportKind`] code, or the report is stale. Staleness is decided inside
/// `ShimPlayer::report`, which compares `session_generation` against the generation the shim was
/// built for and `play_request_id` against the load it currently believes is playing; a
/// mismatch on either is dropped without emitting a `PlayerEvent`.
#[no_mangle]
pub extern "C" fn aural_playback_report_audio(
    session_generation: u64,
    play_request_id: u64,
    kind: u8,
    position_ms: u32,
    duration_ms: u32,
) -> i32 {
    ffi_command("aural_playback_report_audio", || {
        let Some(kind) = report_kind(kind) else {
            debug!("Dropping audio report with unknown kind code {}", kind);
            return ERROR_GENERAL;
        };
        // Cloned out of the global before `report` runs: `report` broadcasts player events, and
        // no engine lock may be held across work that can re-enter this crate.
        let Some(player) = current_shim_player() else {
            debug!("Dropping audio report {:?}: no ShimPlayer is running", kind);
            return ERROR_GENERAL;
        };
        if !player.report(AudioReport {
            session_generation,
            play_request_id,
            kind,
            position_ms,
            duration_ms,
        }) {
            return ERROR_GENERAL;
        }
        0
    })
}
