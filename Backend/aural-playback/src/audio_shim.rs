//! Stage 1 core of the Swift-owned audio path (#208, refs #201).
//!
//! `ShimPlayer` stands in for `librespot_playback::player::Player` as far as `Spirc` and
//! `player_event_pump.rs` can tell: it hands out `PlayRequestId`s, resolves the playable file
//! for a track, and turns Swift's playback reports back into the same `PlayerEvent` stream
//! librespot's own `Player` produces. What actually fetches, decrypts, and decodes audio moves
//! to Swift; this module only decides *what* to play and *when*, and forwards that decision as
//! a plain `AudioCommand` through an injected [`AudioCommandSink`].
//!
//! This module is intentionally unwired: nothing in the crate constructs a `ShimPlayer` yet, and
//! it does not implement the `SpircPlayer` trait a later PR adds once librespot-connect is
//! vendored with that seam. No FFI, header, or Swift change belongs in this slice.
//!
//! `#![allow(dead_code)]`: every item below is exercised only by `audio_shim_tests`, not by any
//! other crate module — this crate builds `staticlib`-only, so a plain `pub` here does not by
//! itself exempt an item from the dead-code lint the way it would for an `rlib`. The FFI PR that
//! wires this module in removes this allow.
#![allow(dead_code)]

use librespot_core::{Error as LibrespotError, FileId, Session, SpotifyUri};
use librespot_metadata::audio::{AudioFileFormat, AudioFiles, AudioItem};
use librespot_playback::player::{PlayerEvent, PlayerEventChannel};
use log::debug;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

/// One command Rust asks the Swift audio path to perform, mirroring the `AuralAudioCommand` C
/// snapshot a later FFI PR adds. `track_uri`/`track_gid`/`file_id`/`audio_format`/`duration_ms`
/// only carry meaningful values for [`AudioCommandKind::Load`] and
/// [`AudioCommandKind::Preload`]; the transport commands (`Play`/`Pause`/`Seek`/`Stop`) leave
/// them at their defaults.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioCommand {
    pub session_generation: u64,
    pub play_request_id: u64,
    pub kind: AudioCommandKind,
    pub track_uri: String,
    pub track_gid: [u8; 16],
    pub file_id: [u8; 20],
    pub audio_format: AudioFileFormat,
    pub position_ms: u32,
    pub start_playing: bool,
    pub duration_ms: u32,
}

/// What `AudioCommand` asks Swift to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioCommandKind {
    Load,
    Play,
    Pause,
    Seek,
    Stop,
    Preload,
}

/// Delivers `AudioCommand`s to the Swift audio path.
///
/// The eventual FFI PR implements this for a type that forwards to a registered C callback.
/// Kept as a plain trait (not a callback pointer) so this module stays testable without FFI.
pub trait AudioCommandSink: Send + Sync {
    fn send(&self, command: AudioCommand);
}

/// What Swift reports back about a command's outcome, mirroring the planned
/// `aural_playback_report_audio` FFI parameter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioReportKind {
    Playing,
    Paused,
    Position,
    Seeked,
    PositionCorrection,
    EndOfTrack,
    Unavailable,
    Stopped,
    TimeToPreloadNext,
    Duration,
}

/// One report from the Swift audio path, stamped with the session and play-request identity it
/// claims to belong to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioReport {
    pub session_generation: u64,
    pub play_request_id: u64,
    pub kind: AudioReportKind,
    pub position_ms: u32,
    pub duration_ms: u32,
}

/// Resolves the [`AudioItem`] for a track. Injectable so `ShimPlayer` is unit-testable without a
/// live `Session`.
pub trait AudioItemResolver: Send + Sync {
    fn resolve(
        &self,
        track_id: SpotifyUri,
    ) -> Pin<Box<dyn Future<Output = Result<AudioItem, LibrespotError>> + Send>>;
}

/// Resolves through a live `Session`, exactly as `librespot_playback::player::Player` does.
pub struct SessionAudioItemResolver {
    session: Session,
}

impl SessionAudioItemResolver {
    pub fn new(session: Session) -> Self {
        Self { session }
    }
}

impl AudioItemResolver for SessionAudioItemResolver {
    fn resolve(
        &self,
        track_id: SpotifyUri,
    ) -> Pin<Box<dyn Future<Output = Result<AudioItem, LibrespotError>> + Send>> {
        let session = self.session.clone();
        Box::pin(async move { AudioItem::get_file(&session, track_id).await })
    }
}

/// Preference order for the one format family Stage 1 decodes: Vorbis, highest bitrate first.
pub const VORBIS_FORMAT_PREFERENCE: [AudioFileFormat; 3] = [
    AudioFileFormat::OGG_VORBIS_320,
    AudioFileFormat::OGG_VORBIS_160,
    AudioFileFormat::OGG_VORBIS_96,
];

/// Picks the file to play from `files`, in `preferred` order. Pure and Session-free so the
/// preference logic is unit-testable on its own.
///
/// Returns `None` when `files` offers nothing in `preferred` — in Stage 1 that means a track
/// with only MP3/AAC/FLAC alternatives, which the Vorbis-only decoder cannot play.
pub fn select_audio_file(
    files: &AudioFiles,
    preferred: &[AudioFileFormat],
) -> Option<(AudioFileFormat, FileId)> {
    preferred
        .iter()
        .find_map(|format| files.get(format).map(|file_id| (*format, *file_id)))
}

/// What track and position `ShimPlayer` believes is current, for stamping reports and
/// translating them back into `PlayerEvent`s.
struct CurrentTrack {
    play_request_id: u64,
    track_id: SpotifyUri,
    position_ms: u32,
    duration_ms: u32,
}

/// Stand-in for `librespot_playback::player::Player`, backed by the Swift audio path instead of
/// an in-process decoder.
///
/// `play_request_id` is a plain `AtomicU64` counter, seeded at 1 and incremented before each use
/// (upstream `Player` uses `util::SeqGenerator<u64>` seeded at 0, whose first id is also 0 — a
/// value this module reserves for "nothing loaded yet" in [`CurrentTrack`], so no real load may
/// produce it).
pub struct ShimPlayer {
    command_sink: Arc<dyn AudioCommandSink>,
    resolver: Arc<dyn AudioItemResolver>,
    session_generation: u64,
    next_play_request_id: AtomicU64,
    current: Mutex<CurrentTrack>,
    /// Shared with the detached resolution task spawned by `load`/`preload`, so a failed
    /// resolution can broadcast `Unavailable` without holding a `&ShimPlayer` past the point
    /// `load`/`preload` already returned.
    event_senders: Arc<Mutex<Vec<mpsc::UnboundedSender<PlayerEvent>>>>,
    /// Reports rejected for a stale `session_generation` or `play_request_id`. Test-only:
    /// production has `log::debug!` for the same signal.
    #[cfg(test)]
    stale_report_count: AtomicU64,
}

/// Sends `event` to every live subscriber, dropping any whose receiver has been closed.
/// A free function (rather than a `&ShimPlayer` method) so the resolution task spawned by
/// `load`/`preload` can broadcast after `ShimPlayer::load`/`preload` have already returned.
fn broadcast_event(senders: &Mutex<Vec<mpsc::UnboundedSender<PlayerEvent>>>, event: PlayerEvent) {
    senders
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .retain(|sender| sender.send(event.clone()).is_ok());
}

impl ShimPlayer {
    pub fn new(
        command_sink: Arc<dyn AudioCommandSink>,
        resolver: Arc<dyn AudioItemResolver>,
        session_generation: u64,
    ) -> Self {
        Self {
            command_sink,
            resolver,
            session_generation,
            next_play_request_id: AtomicU64::new(1),
            current: Mutex::new(CurrentTrack {
                play_request_id: 0,
                track_id: SpotifyUri::Unknown {
                    kind: "unknown".into(),
                    id: String::new(),
                },
                position_ms: 0,
                duration_ms: 0,
            }),
            event_senders: Arc::new(Mutex::new(Vec::new())),
            #[cfg(test)]
            stale_report_count: AtomicU64::new(0),
        }
    }

    #[cfg(test)]
    pub(crate) fn stale_report_count(&self) -> u64 {
        self.stale_report_count.load(Ordering::SeqCst)
    }

    /// Registers a new subscriber, mirroring `Player::get_player_event_channel`: every call
    /// gets its own receiver, and a closed one is dropped the next time an event is sent.
    pub fn get_player_event_channel(&self) -> PlayerEventChannel {
        let (tx, rx) = mpsc::unbounded_channel();
        self.event_senders
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(tx);
        rx
    }

    fn broadcast(&self, event: PlayerEvent) {
        broadcast_event(&self.event_senders, event);
    }

    /// Requests a track, returning its fresh `play_request_id` immediately. Emits
    /// `PlayRequestIdChanged` then `Loading` synchronously (both before this call returns), then
    /// resolves the file on [`crate::RUNTIME`] and sends `AudioCommand::Load` once resolution
    /// finishes — or emits `Unavailable` if it fails.
    pub fn load(&self, track_id: SpotifyUri, start_playing: bool, position_ms: u32) -> u64 {
        let play_request_id = self.next_play_request_id.fetch_add(1, Ordering::SeqCst);

        {
            let mut current = self.current.lock().unwrap_or_else(|e| e.into_inner());
            current.play_request_id = play_request_id;
            current.track_id = track_id.clone();
            current.position_ms = position_ms;
            current.duration_ms = 0;
        }

        self.broadcast(PlayerEvent::PlayRequestIdChanged { play_request_id });
        self.broadcast(PlayerEvent::Loading {
            play_request_id,
            track_id: track_id.clone(),
            position_ms,
        });

        self.spawn_load(track_id, play_request_id, start_playing, position_ms);
        play_request_id
    }

    /// Same file resolution as [`Self::load`], without the `PlayRequestIdChanged`/`Loading`
    /// announcement — mirrors `Player::preload`, which is silent to Spirc until the track is
    /// actually loaded.
    pub fn preload(&self, track_id: SpotifyUri) {
        let play_request_id = self
            .current
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .play_request_id;
        self.spawn_preload(track_id, play_request_id);
    }

    fn spawn_load(
        &self,
        track_id: SpotifyUri,
        play_request_id: u64,
        start_playing: bool,
        position_ms: u32,
    ) {
        let resolver = Arc::clone(&self.resolver);
        let command_sink = Arc::clone(&self.command_sink);
        let event_senders = Arc::clone(&self.event_senders);
        let session_generation = self.session_generation;
        crate::RUNTIME.spawn(async move {
            Self::resolve_and_send(
                resolver,
                command_sink,
                event_senders,
                session_generation,
                track_id,
                play_request_id,
                AudioCommandKind::Load,
                start_playing,
                position_ms,
            )
            .await;
        });
    }

    fn spawn_preload(&self, track_id: SpotifyUri, play_request_id: u64) {
        let resolver = Arc::clone(&self.resolver);
        let command_sink = Arc::clone(&self.command_sink);
        let event_senders = Arc::clone(&self.event_senders);
        let session_generation = self.session_generation;
        crate::RUNTIME.spawn(async move {
            Self::resolve_and_send(
                resolver,
                command_sink,
                event_senders,
                session_generation,
                track_id,
                play_request_id,
                AudioCommandKind::Preload,
                false,
                0,
            )
            .await;
        });
    }

    /// Resolves `track_id` and sends the matching `Load`/`Preload` command, or broadcasts
    /// `PlayerEvent::Unavailable` on failure (resolution error, or no Vorbis alternative). A
    /// free function of owned `Arc`s (not a `&self` method) so it can run detached on
    /// [`crate::RUNTIME`] after `load`/`preload` have already returned.
    #[allow(clippy::too_many_arguments)]
    async fn resolve_and_send(
        resolver: Arc<dyn AudioItemResolver>,
        command_sink: Arc<dyn AudioCommandSink>,
        event_senders: Arc<Mutex<Vec<mpsc::UnboundedSender<PlayerEvent>>>>,
        session_generation: u64,
        track_id: SpotifyUri,
        play_request_id: u64,
        kind: AudioCommandKind,
        start_playing: bool,
        position_ms: u32,
    ) {
        let unavailable = || {
            broadcast_event(
                &event_senders,
                PlayerEvent::Unavailable {
                    play_request_id,
                    track_id: track_id.clone(),
                },
            );
        };

        let item = match resolver.resolve(track_id.clone()).await {
            Ok(item) => item,
            Err(err) => {
                debug!("Audio item resolution failed for {:?}: {}", track_id, err);
                unavailable();
                return;
            }
        };

        let Some((audio_format, file_id)) =
            select_audio_file(&item.files, &VORBIS_FORMAT_PREFERENCE)
        else {
            debug!("No Vorbis file available for {:?}", track_id);
            unavailable();
            return;
        };

        let track_gid = match &track_id {
            SpotifyUri::Track { id } | SpotifyUri::Episode { id } => id.to_raw(),
            _ => [0; 16],
        };

        command_sink.send(AudioCommand {
            session_generation,
            play_request_id,
            kind,
            track_uri: item.uri,
            track_gid,
            file_id: file_id.0,
            audio_format,
            position_ms,
            start_playing,
            duration_ms: item.duration_ms,
        });
    }

    fn command(&self, kind: AudioCommandKind, position_ms: u32) {
        let current = self.current.lock().unwrap_or_else(|e| e.into_inner());
        self.command_sink.send(AudioCommand {
            session_generation: self.session_generation,
            play_request_id: current.play_request_id,
            kind,
            track_uri: String::new(),
            track_gid: [0; 16],
            file_id: [0; 20],
            audio_format: AudioFileFormat::OGG_VORBIS_96,
            position_ms,
            start_playing: false,
            duration_ms: 0,
        });
    }

    pub fn play(&self) {
        self.command(AudioCommandKind::Play, 0);
    }

    pub fn pause(&self) {
        self.command(AudioCommandKind::Pause, 0);
    }

    pub fn stop(&self) {
        self.command(AudioCommandKind::Stop, 0);
    }

    pub fn seek(&self, position_ms: u32) {
        self.command(AudioCommandKind::Seek, position_ms);
    }

    pub fn emit_volume_changed(&self, volume: u16) {
        self.broadcast(PlayerEvent::VolumeChanged { volume });
    }

    pub fn emit_auto_play_changed(&self, auto_play: bool) {
        self.broadcast(PlayerEvent::AutoPlayChanged { auto_play });
    }

    pub fn emit_filter_explicit_content_changed(&self, filter: bool) {
        self.broadcast(PlayerEvent::FilterExplicitContentChanged { filter });
    }

    pub fn emit_shuffle_changed(&self, shuffle: bool) {
        self.broadcast(PlayerEvent::ShuffleChanged { shuffle });
    }

    pub fn emit_repeat_changed(&self, context: bool, track: bool) {
        self.broadcast(PlayerEvent::RepeatChanged { context, track });
    }

    pub fn emit_session_connected(&self, connection_id: String, user_name: String) {
        self.broadcast(PlayerEvent::SessionConnected {
            connection_id,
            user_name,
        });
    }

    pub fn emit_session_disconnected(&self, connection_id: String, user_name: String) {
        self.broadcast(PlayerEvent::SessionDisconnected {
            connection_id,
            user_name,
        });
    }

    pub fn emit_session_client_changed(
        &self,
        client_id: String,
        client_name: String,
        client_brand_name: String,
        client_model_name: String,
    ) {
        self.broadcast(PlayerEvent::SessionClientChanged {
            client_id,
            client_name,
            client_brand_name,
            client_model_name,
        });
    }

    /// Translates a Swift audio report into the matching `PlayerEvent`, or drops it silently
    /// (after counting it, see [`Self::stale_report_count`]) when its `session_generation` or
    /// `play_request_id` no longer matches what this `ShimPlayer` currently believes is loaded.
    /// A stale report belongs to a track or session that has already been replaced, so applying
    /// it would move state backwards or announce an event for the wrong track.
    ///
    /// `AudioReportKind::Duration` has no matching `PlayerEvent` at this librespot rev — only
    /// `TrackChanged { audio_item }` carries duration, and reconstructing a full `AudioItem`
    /// here is not worth it for one field. It only updates the internal duration.
    pub fn report(&self, report: AudioReport) {
        let mut current = self.current.lock().unwrap_or_else(|e| e.into_inner());
        if report.session_generation != self.session_generation
            || report.play_request_id != current.play_request_id
        {
            #[cfg(test)]
            self.stale_report_count.fetch_add(1, Ordering::SeqCst);
            debug!(
                "Dropping stale audio report {:?}: session_generation={} play_request_id={} \
                 (current: session_generation={} play_request_id={})",
                report.kind,
                report.session_generation,
                report.play_request_id,
                self.session_generation,
                current.play_request_id,
            );
            return;
        }

        let play_request_id = current.play_request_id;
        let track_id = current.track_id.clone();

        let event = match report.kind {
            AudioReportKind::Playing => {
                current.position_ms = report.position_ms;
                Some(PlayerEvent::Playing {
                    play_request_id,
                    track_id,
                    position_ms: report.position_ms,
                })
            }
            AudioReportKind::Paused => {
                current.position_ms = report.position_ms;
                Some(PlayerEvent::Paused {
                    play_request_id,
                    track_id,
                    position_ms: report.position_ms,
                })
            }
            AudioReportKind::Position => {
                current.position_ms = report.position_ms;
                Some(PlayerEvent::PositionChanged {
                    play_request_id,
                    track_id,
                    position_ms: report.position_ms,
                })
            }
            AudioReportKind::Seeked => {
                current.position_ms = report.position_ms;
                Some(PlayerEvent::Seeked {
                    play_request_id,
                    track_id,
                    position_ms: report.position_ms,
                })
            }
            AudioReportKind::PositionCorrection => {
                current.position_ms = report.position_ms;
                Some(PlayerEvent::PositionCorrection {
                    play_request_id,
                    track_id,
                    position_ms: report.position_ms,
                })
            }
            AudioReportKind::EndOfTrack => Some(PlayerEvent::EndOfTrack {
                play_request_id,
                track_id,
            }),
            AudioReportKind::Unavailable => Some(PlayerEvent::Unavailable {
                play_request_id,
                track_id,
            }),
            AudioReportKind::Stopped => Some(PlayerEvent::Stopped {
                play_request_id,
                track_id,
            }),
            AudioReportKind::TimeToPreloadNext => Some(PlayerEvent::TimeToPreloadNextTrack {
                play_request_id,
                track_id,
            }),
            AudioReportKind::Duration => {
                current.duration_ms = report.duration_ms;
                None
            }
        };
        drop(current);

        if let Some(event) = event {
            self.broadcast(event);
        }
    }
}

// TODO(#208): impl SpircPlayer once the vendored connect crate lands
