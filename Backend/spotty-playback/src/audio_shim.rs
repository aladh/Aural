//! Stage 1 core of the Swift-owned audio path (#208, refs #201).
//!
//! `ShimPlayer` stands in for `librespot_playback::player::Player` as far as `Spirc` and
//! `player_event_pump.rs` can tell: it hands out `PlayRequestId`s, resolves the playable file
//! for a track, and turns Swift's playback reports back into the same `PlayerEvent` stream
//! librespot's own `Player` produces. What actually fetches, decrypts, and decodes audio moves
//! to Swift; this module only decides *what* to play and *when*, and forwards that decision as
//! a plain `AudioCommand` through an injected [`AudioCommandSink`].
//!
//! `ShimPlayer` implements the vendored `SpircPlayer` trait (see
//! `Backend/vendor/librespot-connect/src/player_bridge.rs`), so `session_lifecycle.rs` can hand
//! `Spirc::new` either this or librespot's own `Player` — see `create_new_player`, which picks
//! by whether Swift registered an audio-command callback before init.
//!
//! `audio_command_sink.rs` implements [`AudioCommandSink`] over the C boundary; this module
//! stays FFI-free so its whole surface is unit-testable with a plain fake sink.

use librespot_connect::SpircPlayer;
use librespot_core::{Error as LibrespotError, FileId, Session, SpotifyUri};
use librespot_metadata::audio::{AudioFileFormat, AudioFiles, AudioItem};
use librespot_metadata::track::Tracks;
use librespot_playback::player::QueueTrack;
use librespot_playback::player::{PlayerEvent, PlayerEventChannel};
use log::debug;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

/// One command Rust asks the Swift audio path to perform, mirroring the `SpottyAudioCommand` C
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
/// The eventual FFI PR implements this for a type that forwards to a registered C callback,
/// which Swift may invoke synchronously and which may itself call back into
/// [`ShimPlayer::report`] before `send` returns. No `ShimPlayer` method may hold one of its own
/// locks across a call to `send`. Kept as a plain trait (not a callback pointer) so this module
/// stays testable without FFI.
pub trait AudioCommandSink: Send + Sync {
    fn send(&self, command: AudioCommand);
}

/// What Swift reports back about a command's outcome, mirroring the planned
/// `spotty_playback_report_audio` FFI parameter.
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

/// Mirrors librespot's `PlayerTrackLoader::find_available_alternative` (pinned rev
/// `9c7d75615fc093bdcbdb29adbce3fed38c531852`, `playback/src/player.rs:941-963`): an item whose
/// availability check failed has no playable alternative; an item that already has files is used
/// directly; an item with no files but `alternatives` tries each alternative in turn (via
/// `resolver`, so this stays testable) and takes the first whose own availability check passes.
///
/// Upstream resolves every alternative concurrently and takes whichever finishes first; this
/// resolves them in order instead, which is simpler and deterministic and only changes which
/// alternative wins a race that upstream itself does not guarantee the order of.
pub(crate) async fn find_available_alternative(
    resolver: &Arc<dyn AudioItemResolver>,
    item: AudioItem,
) -> Option<AudioItem> {
    if item.availability.is_err() {
        return None;
    }
    if !item.files.is_empty() {
        return Some(item);
    }
    let Tracks(alternatives) = item.alternatives?;
    for alt_id in alternatives {
        if let Ok(alt_item) = resolver.resolve(alt_id).await {
            if alt_item.availability.is_ok() {
                return Some(alt_item);
            }
        }
    }
    None
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

/// Mirrors librespot's `PlayerState`, simplified to what `ShimPlayer` needs to decide whether the
/// currently loaded track counts as "loaded" for a failed preload's `Unavailable` report and for
/// the explicit-content skip in [`ShimPlayer::emit_filter_explicit_content_changed`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TrackPhase {
    Loading,
    Playing,
    Paused,
    Stopped,
}

/// What track and position `ShimPlayer` believes is current, for stamping reports and
/// translating them back into `PlayerEvent`s.
struct CurrentTrack {
    play_request_id: u64,
    track_id: SpotifyUri,
    position_ms: u32,
    duration_ms: u32,
    /// From the resolved [`AudioItem`]; unknown (`false`) until `load`'s resolution lands.
    is_explicit: bool,
    phase: TrackPhase,
    /// Identity of the most recent `preload` request, so a superseded one can be dropped after
    /// its resolution completes. Does not track a `PlayerPreload::Ready` slot the way upstream
    /// `Player` does — Stage 1 does not yet reuse a preloaded file on the following `load`.
    preload_id: u64,
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
    next_preload_id: AtomicU64,
    /// Shared with the detached resolution task spawned by `load`/`preload`, so it can re-check
    /// (after its `await`) whether it is still the current request, and — for `load` — record
    /// the resolved `is_explicit` once it lands.
    current: Arc<Mutex<CurrentTrack>>,
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

/// Broadcasts the `Unavailable` a failed `load`/`preload` resolution reports.
///
/// A `Load` failure is stamped with the load's own `request_id`/`track_id`, matching upstream
/// `Player` (`handle_command_load`'s loader-poll arm). A `Preload` failure instead reports the
/// *currently loaded* track — and only while one is actually playing or paused — matching
/// upstream's preload-poll arm, which has no play-request id of its own to report against.
fn broadcast_unavailable(
    event_senders: &Mutex<Vec<mpsc::UnboundedSender<PlayerEvent>>>,
    current: &Mutex<CurrentTrack>,
    kind: AudioCommandKind,
    request_id: u64,
    track_id: &SpotifyUri,
) {
    match kind {
        AudioCommandKind::Load => {
            broadcast_event(
                event_senders,
                PlayerEvent::Unavailable {
                    play_request_id: request_id,
                    track_id: track_id.clone(),
                },
            );
        }
        AudioCommandKind::Preload => {
            let reported = {
                let guard = current.lock().unwrap_or_else(|e| e.into_inner());
                matches!(guard.phase, TrackPhase::Playing | TrackPhase::Paused)
                    .then(|| (guard.play_request_id, guard.track_id.clone()))
            };
            if let Some((play_request_id, track_id)) = reported {
                broadcast_event(
                    event_senders,
                    PlayerEvent::Unavailable {
                        play_request_id,
                        track_id,
                    },
                );
            }
        }
        _ => {}
    }
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
            next_preload_id: AtomicU64::new(1),
            current: Arc::new(Mutex::new(CurrentTrack {
                play_request_id: 0,
                track_id: SpotifyUri::Unknown {
                    kind: "unknown".into(),
                    id: String::new(),
                },
                position_ms: 0,
                duration_ms: 0,
                is_explicit: false,
                phase: TrackPhase::Stopped,
                preload_id: 0,
            })),
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
            current.is_explicit = false;
            current.phase = TrackPhase::Loading;
        }

        self.broadcast(PlayerEvent::PlayRequestIdChanged { play_request_id });
        self.broadcast(PlayerEvent::Loading {
            play_request_id,
            track_id: track_id.clone(),
            position_ms,
        });

        self.spawn_resolution(
            track_id,
            play_request_id,
            AudioCommandKind::Load,
            start_playing,
            position_ms,
        );
        play_request_id
    }

    /// Same file resolution as [`Self::load`], without the `PlayRequestIdChanged`/`Loading`
    /// announcement — mirrors `Player::preload`, which is silent to Spirc until the track is
    /// actually loaded. A second `preload` call supersedes the first; the superseded one is
    /// dropped once its resolution completes (see [`Self::spawn_resolution`]).
    pub fn preload(&self, track_id: SpotifyUri) {
        let preload_id = self.next_preload_id.fetch_add(1, Ordering::SeqCst);
        {
            let mut current = self.current.lock().unwrap_or_else(|e| e.into_inner());
            current.preload_id = preload_id;
        }
        self.spawn_resolution(track_id, preload_id, AudioCommandKind::Preload, false, 0);
    }

    /// Resolves `track_id` on [`crate::RUNTIME`] and sends the matching `Load`/`Preload`
    /// command, or reports `Unavailable`, once resolution finishes. `request_id` is the
    /// `play_request_id` for `Load` or the `preload_id` for `Preload`; see
    /// [`Self::resolve_and_send`] for how it is used to detect supersession.
    fn spawn_resolution(
        &self,
        track_id: SpotifyUri,
        request_id: u64,
        kind: AudioCommandKind,
        start_playing: bool,
        position_ms: u32,
    ) {
        let resolver = Arc::clone(&self.resolver);
        let command_sink = Arc::clone(&self.command_sink);
        let event_senders = Arc::clone(&self.event_senders);
        let current = Arc::clone(&self.current);
        let session_generation = self.session_generation;
        crate::RUNTIME.spawn(async move {
            Self::resolve_and_send(
                resolver,
                command_sink,
                event_senders,
                current,
                session_generation,
                track_id,
                request_id,
                kind,
                start_playing,
                position_ms,
            )
            .await;
        });
    }

    /// Resolves `track_id` (following alternatives per [`find_available_alternative`]) and sends
    /// the matching `Load`/`Preload` command, or reports `Unavailable` (resolution failure, no
    /// available alternative, or no Vorbis file on whichever item was found).
    ///
    /// Re-checks `current` once, right after the `await`, before doing anything observable: a
    /// second `load`/`preload` may have started and finished while this one was resolving, and a
    /// superseded request must not send a command or report for a track that is no longer
    /// current. A free function of owned `Arc`s (not a `&self` method) so it can run detached on
    /// [`crate::RUNTIME`] after `load`/`preload` have already returned.
    #[allow(clippy::too_many_arguments)]
    async fn resolve_and_send(
        resolver: Arc<dyn AudioItemResolver>,
        command_sink: Arc<dyn AudioCommandSink>,
        event_senders: Arc<Mutex<Vec<mpsc::UnboundedSender<PlayerEvent>>>>,
        current: Arc<Mutex<CurrentTrack>>,
        session_generation: u64,
        track_id: SpotifyUri,
        request_id: u64,
        kind: AudioCommandKind,
        start_playing: bool,
        position_ms: u32,
    ) {
        let resolved = match resolver.resolve(track_id.clone()).await {
            Ok(item) => find_available_alternative(&resolver, item).await,
            Err(err) => {
                debug!("Audio item resolution failed for {:?}: {}", track_id, err);
                None
            }
        };

        // This is the only re-entry point into `current` after the `await` above, and it holds
        // the lock only long enough to read/write plain fields — never across `send` or a
        // broadcast.
        let still_current = {
            let mut guard = current.lock().unwrap_or_else(|e| e.into_inner());
            match kind {
                AudioCommandKind::Load => {
                    let is_current = guard.play_request_id == request_id;
                    if is_current {
                        if let Some(item) = &resolved {
                            guard.is_explicit = item.is_explicit;
                            guard.duration_ms = item.duration_ms;
                        }
                    }
                    is_current
                }
                AudioCommandKind::Preload => guard.preload_id == request_id,
                _ => true,
            }
        };
        if !still_current {
            debug!(
                "Dropping {:?} resolution for a superseded request (id={})",
                kind, request_id
            );
            return;
        }

        let Some(item) = resolved else {
            broadcast_unavailable(&event_senders, &current, kind, request_id, &track_id);
            return;
        };

        let Some((audio_format, file_id)) =
            select_audio_file(&item.files, &VORBIS_FORMAT_PREFERENCE)
        else {
            debug!("No Vorbis file available for {:?}", track_id);
            broadcast_unavailable(&event_senders, &current, kind, request_id, &track_id);
            return;
        };

        // The chosen item may be an alternative with its own identity distinct from the
        // requested `track_id` — Swift needs the alternative's own gid to fetch it. Events
        // (`Unavailable` above, and `Loading`/`Playing`/… elsewhere) stay stamped with the
        // originally requested `track_id`, matching upstream `Player::start_playback`.
        let track_gid = match &item.track_id {
            SpotifyUri::Track { id } | SpotifyUri::Episode { id } => id.to_raw(),
            _ => [0; 16],
        };

        command_sink.send(AudioCommand {
            session_generation,
            play_request_id: request_id,
            kind,
            track_uri: item.uri.clone(),
            track_gid,
            file_id: file_id.0,
            audio_format,
            position_ms,
            start_playing,
            duration_ms: item.duration_ms,
        });

        // Spirc's `update_duration` and the local `CURRENT_DURATION_MS` snapshot only
        // listen for `TrackChanged`. Upstream `Player` broadcasts that with the resolved
        // `AudioItem` on load; do the same here so Connect duration and the now-playing
        // bar are not stuck at 0ms. Do not invent an `AudioItem` later from a duration
        // report — this is the only place the full item exists.
        if kind == AudioCommandKind::Load {
            broadcast_event(
                &event_senders,
                PlayerEvent::TrackChanged {
                    audio_item: Box::new(item),
                },
            );
        }
    }

    fn command(&self, kind: AudioCommandKind, position_ms: u32) {
        // `command_sink.send` will eventually be a synchronous Swift callback that can itself
        // call back into `report` before returning — so the lock must be released before `send`,
        // not held across it.
        let play_request_id = self
            .current
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .play_request_id;
        self.command_sink.send(AudioCommand {
            session_generation: self.session_generation,
            play_request_id,
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

    /// Mirrors upstream `Player::emit_filter_explicit_content_changed_event`: broadcasts
    /// `FilterExplicitContentChanged`, and if `filter` just turned on while an explicit track is
    /// currently playing or paused, also emits `EndOfTrack` for it so Spirc advances — the same
    /// "client setting forbids this track" skip upstream performs.
    pub fn emit_filter_explicit_content_changed(&self, filter: bool) {
        self.broadcast(PlayerEvent::FilterExplicitContentChanged { filter });
        if !filter {
            return;
        }
        let skip = {
            let current = self.current.lock().unwrap_or_else(|e| e.into_inner());
            let loaded = matches!(current.phase, TrackPhase::Playing | TrackPhase::Paused);
            (loaded && current.is_explicit)
                .then(|| (current.play_request_id, current.track_id.clone()))
        };
        if let Some((play_request_id, track_id)) = skip {
            debug!("Currently loaded track is explicit; ending it for the filter change");
            self.broadcast(PlayerEvent::EndOfTrack {
                play_request_id,
                track_id,
            });
        }
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
    /// `AudioReportKind::Duration` only updates the internal duration. Connect and the local
    /// snapshot learn duration from `TrackChanged`, which `resolve_and_send` already
    /// broadcasts from the resolved `AudioItem` on `Load`. Do not reconstruct an `AudioItem`
    /// here from a duration-only report.
    ///
    /// Returns whether the report was applied, so `spotty_playback_report_audio` can tell Swift
    /// that a report it sent was rejected as stale rather than silently swallowing it.
    pub fn report(&self, report: AudioReport) -> bool {
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
            return false;
        }

        let play_request_id = current.play_request_id;
        let track_id = current.track_id.clone();

        let event = match report.kind {
            AudioReportKind::Playing => {
                current.position_ms = report.position_ms;
                current.phase = TrackPhase::Playing;
                Some(PlayerEvent::Playing {
                    play_request_id,
                    track_id,
                    position_ms: report.position_ms,
                })
            }
            AudioReportKind::Paused => {
                current.position_ms = report.position_ms;
                current.phase = TrackPhase::Paused;
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
            AudioReportKind::EndOfTrack => {
                current.phase = TrackPhase::Stopped;
                Some(PlayerEvent::EndOfTrack {
                    play_request_id,
                    track_id,
                })
            }
            AudioReportKind::Unavailable => {
                current.phase = TrackPhase::Stopped;
                Some(PlayerEvent::Unavailable {
                    play_request_id,
                    track_id,
                })
            }
            AudioReportKind::Stopped => {
                current.phase = TrackPhase::Stopped;
                Some(PlayerEvent::Stopped {
                    play_request_id,
                    track_id,
                })
            }
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
        true
    }
}

/// Presents `ShimPlayer` to `Spirc` exactly as librespot's own `Player` is presented.
///
/// Every method forwards to the inherent method of the same purpose. `emit_set_queue_event` is
/// the one operation with no inherent counterpart: it is pure broadcast, with no shim state to
/// touch, so it is written out here.
impl SpircPlayer for ShimPlayer {
    fn load(&self, track_id: SpotifyUri, start_playing: bool, position_ms: u32) {
        ShimPlayer::load(self, track_id, start_playing, position_ms);
    }

    fn preload(&self, track_id: SpotifyUri) {
        ShimPlayer::preload(self, track_id);
    }

    fn play(&self) {
        ShimPlayer::play(self);
    }

    fn pause(&self) {
        ShimPlayer::pause(self);
    }

    fn stop(&self) {
        ShimPlayer::stop(self);
    }

    fn seek(&self, position_ms: u32) {
        ShimPlayer::seek(self, position_ms);
    }

    fn get_player_event_channel(&self) -> PlayerEventChannel {
        ShimPlayer::get_player_event_channel(self)
    }

    fn emit_volume_changed_event(&self, volume: u16) {
        self.emit_volume_changed(volume);
    }

    fn emit_filter_explicit_content_changed_event(&self, filter: bool) {
        self.emit_filter_explicit_content_changed(filter);
    }

    fn emit_session_connected_event(&self, connection_id: String, user_name: String) {
        self.emit_session_connected(connection_id, user_name);
    }

    fn emit_session_disconnected_event(&self, connection_id: String, user_name: String) {
        self.emit_session_disconnected(connection_id, user_name);
    }

    fn emit_session_client_changed_event(
        &self,
        client_id: String,
        client_name: String,
        client_brand_name: String,
        client_model_name: String,
    ) {
        self.emit_session_client_changed(
            client_id,
            client_name,
            client_brand_name,
            client_model_name,
        );
    }

    fn emit_shuffle_changed_event(&self, shuffle: bool) {
        self.emit_shuffle_changed(shuffle);
    }

    fn emit_repeat_changed_event(&self, context: bool, track: bool) {
        self.emit_repeat_changed(context, track);
    }

    fn emit_auto_play_changed_event(&self, auto_play: bool) {
        self.emit_auto_play_changed(auto_play);
    }

    fn emit_set_queue_event(
        &self,
        context_uri: String,
        current_track: Option<QueueTrack>,
        next_tracks: Vec<QueueTrack>,
        prev_tracks: Vec<QueueTrack>,
    ) {
        self.broadcast(PlayerEvent::SetQueue {
            context_uri,
            current_track,
            next_tracks,
            prev_tracks,
        });
    }
}
