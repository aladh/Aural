use crate::*;
use std::collections::HashMap;

// Player state
pub(crate) static PLAYER: Lazy<Mutex<Option<Arc<Player>>>> = Lazy::new(|| Mutex::new(None));
pub(crate) static SESSION: Lazy<Mutex<Option<Session>>> = Lazy::new(|| Mutex::new(None));
pub(crate) static MIXER: Lazy<Mutex<Option<Arc<SoftMixer>>>> = Lazy::new(|| Mutex::new(None));
pub(crate) static SPIRC: Lazy<Mutex<Option<Arc<Spirc>>>> = Lazy::new(|| Mutex::new(None));
pub(crate) static IS_PLAYING: AtomicBool = AtomicBool::new(false);
pub(crate) static PLAYING_EVENT_SEQ: AtomicU64 = AtomicU64::new(0);

/// Set while a `aural_playback_resume` is working, so only one runs at a time.
///
/// Resuming is not instantaneous: `Spirc::play` only queues a command, and the fallback
/// below it waits half a second for a `Playing` event before loading the saved context and
/// waiting two more. Swift dispatches each press to its own detached task, so without this
/// a user pressing play repeatedly — which is exactly what an unresponsive play button
/// provokes — stacks several play-then-load sequences, each capturing `POSITION_MS` at its
/// own moment and restarting the track there. `IS_PLAYING` does not cover the gap: it stays
/// false until the first sequence actually produces audio.
pub(crate) static RESUMING: AtomicBool = AtomicBool::new(false);

/// Clears [`RESUMING`] however `aural_playback_resume` returns — it has six exits.
pub(crate) struct ResumeGuard;

impl Drop for ResumeGuard {
    fn drop(&mut self) {
        RESUMING.store(false, Ordering::SeqCst);
    }
}
pub(crate) static PLAYER_EVENT_TX: Lazy<Mutex<Option<mpsc::UnboundedSender<()>>>> =
    Lazy::new(|| Mutex::new(None));

pub(crate) type JsonCallback = extern "C" fn(*const c_char);

/// Process-lifetime control callback registry.
///
/// Each slot keeps an independent lock, so a callback on one event stream cannot block another.
/// Call sites always copy the function pointer and release its slot before entering Swift. PCM
/// and audio-control callbacks remain in `proxy_sink`: the real-time audio path does not touch
/// this registry or any of these locks.
#[derive(Default)]
pub(crate) struct ControlCallbacks {
    pub(crate) queue: Mutex<Option<JsonCallback>>,
    pub(crate) playback_state: Mutex<Option<JsonCallback>>,
    pub(crate) volume: Mutex<Option<extern "C" fn(u16)>>,
    pub(crate) loading: Mutex<Option<JsonCallback>>,
    pub(crate) became_inactive: Mutex<Option<extern "C" fn()>>,
    pub(crate) became_active: Mutex<Option<extern "C" fn()>>,
    pub(crate) session_client_changed: Mutex<Option<JsonCallback>>,
    pub(crate) set_queue: Mutex<Option<JsonCallback>>,
    pub(crate) active_device: Mutex<Option<JsonCallback>>,
    pub(crate) devices: Mutex<Option<JsonCallback>>,
    pub(crate) connection_state: Mutex<Option<JsonCallback>>,
}

pub(crate) static CONTROL_CALLBACKS: Lazy<ControlCallbacks> = Lazy::new(ControlCallbacks::default);
/// The last device list sent to Swift, so an unchanged cluster update stays silent. Cluster
/// updates arrive for every playback tick, and the device list changes far more rarely.
pub(crate) static LAST_DEVICES_JSON: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(String::new()));
/// The last queue the cluster described, so Swift can ask again rather than re-deriving it
/// from the Web API. See `aural_playback_get_queue_snapshot`.
pub(crate) static LAST_QUEUE_JSON: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
pub(crate) static LAST_ACTIVE_DEVICE_ID: Lazy<Mutex<String>> =
    Lazy::new(|| Mutex::new(String::new()));
/// Serializes snapshot building so a revision always orders snapshots by the state they
/// actually saw. Held only across the build, never across delivery into Swift.
pub(crate) static SNAPSHOT_REVISION: Mutex<u64> = Mutex::new(0);

/// Ordering metadata shared by every structured control snapshot sent over the C boundary.
///
/// `revision` is process-monotonic, while `session_generation` identifies the engine instance
/// whose state was observed. Swift can therefore reject both a late callback and a callback from
/// a session that has already been replaced.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SnapshotStamp {
    pub(crate) revision: u64,
    pub(crate) session_generation: u64,
}

/// Builds a value while owning the revision lock, preserving creation order across connection,
/// playback, and queue snapshots. Callback delivery remains outside this function so no Swift
/// re-entry occurs while the lock is held.
pub(crate) fn stamped_snapshot<T>(build: impl FnOnce(SnapshotStamp) -> T) -> T {
    let mut revision = SNAPSHOT_REVISION.lock().unwrap_or_else(|e| e.into_inner());
    *revision = revision.saturating_add(1);
    build(SnapshotStamp {
        revision: *revision,
        session_generation: SESSION_GENERATION.load(Ordering::SeqCst),
    })
}
pub(crate) static LAST_VOLUME: AtomicU16 = AtomicU16::new(0);
pub(crate) static SHUFFLE_STATE: AtomicBool = AtomicBool::new(false);
pub(crate) static REPEAT_TRACK_STATE: AtomicBool = AtomicBool::new(false);
pub(crate) static REPEAT_CONTEXT_STATE: AtomicBool = AtomicBool::new(false);

// Flag to track if reconnection is in progress
pub(crate) static RECONNECTING: AtomicBool = AtomicBool::new(false);
// Flag to track intentional shutdown (prevents reconnection attempts during app quit)
pub(crate) static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);
// Flag to track sleep state (prevents auto-reconnect, but allows explicit forceReconnect on wake)
pub(crate) static SLEEPING: AtomicBool = AtomicBool::new(false);

/// Everything the connection snapshot publishes, behind a single lock.
///
/// These fields used to live in six independent globals (three mutexes and three
/// atomics), so a snapshot assembled from them could mix values from different
/// transitions — ready from one, connection metadata from another. Keeping them
/// together makes every published snapshot internally consistent by construction.
///
/// `connected_since_ms` uses 0 for "never connected"; the wire format maps that to null.
///
/// `is_active_device` also lives here rather than in a separate atomic. It used to be
/// tracked in `IS_ACTIVE_DEVICE`, written from fourteen scattered command and event sites
/// and never reconciled against the cluster, while Swift separately tracked activity from
/// the active-device-id callback — so playback routing and the UI could disagree about
/// whether Aural or a remote speaker was active.
#[derive(Default, Clone)]
pub(crate) struct ConnectionState {
    pub(crate) session_connected: bool,
    pub(crate) session_connection_id: Option<String>,
    pub(crate) spirc_ready: bool,
    pub(crate) device_id: Option<String>,
    pub(crate) reconnect_attempt: u32,
    pub(crate) last_error: Option<String>,
    pub(crate) connected_since_ms: u64,
    pub(crate) is_active_device: bool,
}

/// Derives whether this device is the active one from a cluster update.
///
/// An empty active-device ID means nothing is active anywhere. That is a real state and
/// must clear activity rather than be ignored, otherwise the last active device stays
/// displayed forever once playback stops.
pub(crate) fn is_active_in_cluster(active_device_id: &str, own_device_id: Option<&str>) -> bool {
    !active_device_id.is_empty() && own_device_id == Some(active_device_id)
}

/// Whether an intentional teardown is under way. Recovery must never fight one.
pub(crate) fn teardown_in_progress() -> bool {
    SHUTTING_DOWN.load(Ordering::SeqCst) || SLEEPING.load(Ordering::SeqCst)
}

/// Whether losing the active Connect role should start network recovery.
///
/// Deactivation is normally just a handoff to another device and must not reconnect. The
/// one case that must is a Session that has gone invalid: librespot calls
/// `handle_disconnect` on unexpected Spirc shutdown, and the cluster listener can miss
/// that while the dealer stream is still open.
pub(crate) fn should_recover_after_deactivation(
    session_invalid: bool,
    teardown_in_progress: bool,
) -> bool {
    session_invalid && !teardown_in_progress
}

/// What playback looked like when recovery was decided on.
///
/// Captured at the trigger rather than inside the reconnect task. Between those two points
/// the deactivation handler clears the active flag, a `Stopped` event clears `IS_PLAYING`,
/// and a final cluster update can clear both — so reading it late made "does an outage
/// resume playback" depend on event ordering rather than on what was actually playing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RecoveryIntent {
    pub(crate) was_playing: bool,
    pub(crate) was_active: bool,
}

impl RecoveryIntent {
    /// Reads what is playing right now. Call this before touching playback state.
    pub(crate) fn capture() -> Self {
        Self {
            was_playing: IS_PLAYING.load(Ordering::SeqCst),
            was_active: is_active_device(),
        }
    }

    /// Only local playback is rehydrated. If another device was playing, it still is, and
    /// taking over would steal it from the user.
    pub(crate) fn should_resume(self) -> bool {
        self.was_playing && self.was_active
    }
}

/// Whether the periodic health check should start recovery.
///
/// Invalidity alone is not a sufficient trigger. `Session::is_invalid` is only set by
/// `shutdown()`, so a session that was created but never managed to connect — exactly what
/// a failed `init_player_async` leaves behind — reports itself valid forever. The state
/// that actually needs rescuing is "not connected and nobody is recovering", however it was
/// reached: a session that died, or one that never came up.
///
/// The reconnect check matters because the loop is the thing that fixes this; firing while
/// it is already running would only re-publish a disconnected snapshot once a minute.
pub(crate) fn health_check_should_recover(
    session_invalid: bool,
    session_connected: bool,
    reconnect_in_progress: bool,
    teardown_in_progress: bool,
) -> bool {
    !teardown_in_progress && !reconnect_in_progress && (session_invalid || !session_connected)
}

/// Whether a listener may act on an event, given the generation it was created for.
///
/// A superseded listener drains asynchronously after its replacement is installed, so it
/// can still deliver events belonging to a session that no longer exists.
pub(crate) fn listener_may_act(listener_generation: u64, current_generation: u64) -> bool {
    listener_generation == current_generation
}

/// Whether a reconnect loop may still rebuild, given the generation it set out to recover.
///
/// The loop sleeps up to 30 seconds between attempts. A manual restart or a teardown in
/// that window means the thing it is fixing is gone, and rebuilding would clobber whatever
/// replaced it.
pub(crate) fn reconnect_may_proceed(
    recovering_generation: u64,
    current_generation: u64,
    teardown_in_progress: bool,
) -> bool {
    recovering_generation == current_generation && !teardown_in_progress
}

/// Whether a cluster listener that ended should start network recovery.
///
/// Only the listener belonging to the current session generation may act. An older
/// listener ending is the expected consequence of the session it belonged to being
/// replaced, not evidence of a transport failure — acting on it would reconnect a session
/// that is already healthy.
pub(crate) fn should_recover_after_cluster_end(
    listener_generation: u64,
    current_generation: u64,
    teardown_in_progress: bool,
) -> bool {
    listener_generation == current_generation && !teardown_in_progress
}

/// Which position a resume should seek to.
///
/// A point saved at deactivation outranks the live one, because the `Stopped` event that
/// librespot sends on the way out has since reset the live position to zero. Zero means
/// nothing was saved: either no deactivation is being recovered from, or playback was at
/// the very start, and both want the live value.
pub(crate) fn resume_position(saved_at_deactivation: u32, live: u32) -> u32 {
    if saved_at_deactivation > 0 {
        saved_at_deactivation
    } else {
        live
    }
}

/// Whether this device is currently the active Spotify Connect device.
pub(crate) fn is_active_device() -> bool {
    with_connection(|c| c.is_active_device)
}

/// Records whether this device is the active one, publishing the change if it moved.
pub(crate) fn set_active_device(active: bool) {
    if store_active_device(active) {
        notify_connection_state_change();
    }
}

/// Records activity without publishing, returning whether it changed.
///
/// For callers that are mid-transition and will publish once when they are done —
/// `init_player_async` still has to rehydrate after activating, and publishing in between
/// is what let Swift bootstrap against a half-built session.
pub(crate) fn store_active_device(active: bool) -> bool {
    let changed = with_connection(|c| {
        let changed = c.is_active_device != active;
        c.is_active_device = active;
        changed
    });
    if changed {
        debug!("Active device changed: is_active={}", active);
    }
    changed
}

pub(crate) static CONNECTION: Lazy<Mutex<ConnectionState>> =
    Lazy::new(|| Mutex::new(ConnectionState::default()));

/// Mutates the connection state under its lock and returns whatever `f` returns.
///
/// Does not publish — callers decide when to `notify_connection_state_change()`, so a
/// multi-field transition emits one snapshot rather than one per field. Never call
/// `notify_connection_state_change()` from inside `f`: it locks `CONNECTION` too.
pub(crate) fn with_connection<R>(f: impl FnOnce(&mut ConnectionState) -> R) -> R {
    let mut state = CONNECTION.lock().unwrap_or_else(|e| e.into_inner());
    f(&mut state)
}

/// Returns the device ID assigned at session creation, if a session has been built.
pub(crate) fn current_device_id() -> Option<String> {
    with_connection(|c| c.device_id.clone())
}

// Position tracking - updated from player events
pub(crate) static POSITION_MS: AtomicU32 = AtomicU32::new(0);

/// Where playback should pick up after a deactivation, or 0 when there is nothing to
/// recover.
///
/// `POSITION_MS` cannot serve this on its own. librespot stops the Player when the device
/// is deactivated, and the `Stopped` event that follows must reset the live position —
/// `handle_stop` fires for a queue that has run out and for `prev` at the first track too,
/// where resuming mid-track would be wrong. Those cases are indistinguishable in the event,
/// which carries only a play-request id and a track id.
///
/// So the resume point is captured where the cause *is* known: the `SessionDisconnected`
/// arm, which librespot emits from `handle_disconnect` before the `handle_stop` that
/// follows it.
///
/// One rule governs its lifetime: it survives until something newer describes where
/// playback is. That is a `Loading` event, which establishes the position for the track it
/// names, or a `Playing` event; a full cleanup drops it with the rest of the session.
///
/// The resume path only reads it, never takes it. `Spirc::load` merely queues a command, so
/// a resume that has been *attempted* is not one that has *landed*: clearing on the attempt
/// would leave a retry after a failed or silent load with nothing but the zero that
/// `Stopped` wrote. Clearing on `Loading` instead is safe precisely because that event
/// carries the seek target the resume passed in, so the live position already holds it.
pub(crate) static RESUME_POSITION_MS: AtomicU32 = AtomicU32::new(0);

// Current track duration (ms) - updated from TrackChanged event
pub(crate) static CURRENT_DURATION_MS: AtomicU32 = AtomicU32::new(0);

// Current logical track URI - for UI identity and detecting same-track reconnects.
// The playable AudioItem may carry a different URI after Spotify relinking.
//
// Session-scoped: `aural_playback_cleanup` drops it, because `resume_via_load` would otherwise
// hand it to a load made by whichever account logged in next.
pub(crate) static CURRENT_TRACK_URI: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

/// Stores the requested/context track identity exposed by librespot player events.
///
/// Keep callback delivery outside this helper: Swift callbacks may re-enter Rust and
/// must never run while `CURRENT_TRACK_URI` is locked.
pub(crate) fn set_current_track_uri(track_uri: String) {
    let mut uri_guard = CURRENT_TRACK_URI.lock().unwrap_or_else(|e| e.into_inner());
    *uri_guard = Some(track_uri);
}

// Current context URI - captured from SetQueue and cluster player state updates.
// We keep the latest non-empty value to recover resume after reconnect.
//
// Session-scoped for the same reason as CURRENT_TRACK_URI above, and more sharply: this is
// what a resume actually loads. "Latest non-empty" means a login cannot clear it by arriving,
// so the cleanup has to.
pub(crate) static CURRENT_CONTEXT_URI: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

// Connection state tracking - for transparency dashboard. See ConnectionState above;
// reconnect attempt, connected-since, and last error all live there now.
// Wake timing tracking - for debugging reconnection timing issues
pub(crate) static WAKE_TIMESTAMP_MS: AtomicU64 = AtomicU64::new(0);

/// Returns milliseconds elapsed since wake was triggered (force_reconnect called).
/// Returns 0 if no wake timestamp recorded.
pub(crate) fn elapsed_since_wake_ms() -> u64 {
    let wake_ts = WAKE_TIMESTAMP_MS.load(Ordering::SeqCst);
    if wake_ts == 0 {
        return 0;
    }
    let now = current_timestamp_ms();
    now.saturating_sub(wake_ts)
}

// Generation counter for reconnection. Bumped once per rebuild, in init_player_async, and
// captured by every listener that rebuild creates. A listener whose captured generation no
// longer matches belongs to a session that has already been replaced, and must not act.
//
// There used to be a second global, EVENT_LISTENER_GENERATION, holding "the generation the
// current event listener belongs to". Soft reconnect kept one listener alive across
// sessions, so the listener could not simply capture its generation — and the global was
// written to the new value on every bump, which made the two always equal and the staleness
// check unreachable. Now that a rebuild replaces the listener along with its session, the
// listener captures the value directly and the check does what it claims.
pub(crate) static SESSION_GENERATION: AtomicU64 = AtomicU64::new(0);
/// Bumped only when the account itself goes away — logout, or app termination. Distinct from
/// `SESSION_GENERATION`, which moves on every ordinary rebuild: cleanup and
/// `build_player_async` both advance it, so a long-running streaming grant waiting on a
/// browser would see any concurrent play, retry or wake as a supersession and delete the
/// credentials it had just written.
pub(crate) static LOGOUT_GENERATION: AtomicU64 = AtomicU64::new(0);

/// The Spotify account the last successful streaming grant authenticated as.
///
/// The browser may be signed into a different account than the Web API half, and nothing
/// else would notice: the app would browse one account while playing from another. Swift
/// compares this against `/me` before accepting the grant.
pub(crate) static LAST_GRANT_ACCOUNT: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
/// Generation created by the most recent `build_player_async`. Lets the reconnect loop adopt
/// the generation its own attempt made rather than whatever the counter reads afterwards,
/// which may belong to a logout and the login that followed it.
pub(crate) static LAST_BUILD_GENERATION: AtomicU64 = AtomicU64::new(0);

// Playback settings (applied on player init)
// Bitrate: 0 = 96kbps, 1 = 160kbps (default), 2 = 320kbps
pub(crate) static BITRATE_SETTING: AtomicU8 = AtomicU8::new(1);
// Gapless playback: true by default (matches librespot default)
pub(crate) static GAPLESS_SETTING: AtomicBool = AtomicBool::new(true);
// Initial volume (0-65535), default 50%
pub(crate) static INITIAL_VOLUME_SETTING: AtomicU16 = AtomicU16::new(65535 / 2);

#[derive(Serialize)]
pub(crate) struct QueueItem {
    pub(crate) uri: String,
    pub(crate) name: String,
    pub(crate) artist: String,
    pub(crate) image_url: String,
    pub(crate) duration_ms: u32,
    pub(crate) album_name: String,
    /// Track provider: "context", "queue", "autoplay", or "unavailable"
    pub(crate) provider: String,
    /// Connect occurrence uid when the cluster supplied one. Empty when unknown.
    pub(crate) uid: String,
}

/// Unfiltered Connect queue row used for `set_queue` replacement.
/// Fields match `ProvidedTrack` in player.proto at librespot 9c7d756, except
/// `disallow_setting_modes` / `disallow_signals` maps which are omitted when empty
/// (no evidence they appear on queue rows in official `set_queue` JSON).
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub(crate) struct ProtocolQueueTrack {
    pub(crate) uri: String,
    pub(crate) uid: String,
    pub(crate) provider: String,
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub(crate) metadata: HashMap<String, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) removed: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) blocked: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) restrictions: Option<serde_json::Map<String, serde_json::Value>>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub(crate) album_uri: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) disallow_reasons: Vec<String>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub(crate) artist_uri: String,
}

#[derive(Serialize)]
pub(crate) struct QueueState {
    pub(crate) revision: u64,
    pub(crate) session_generation: u64,
    pub(crate) track: Option<QueueItem>,
    pub(crate) next_tracks: Vec<QueueItem>,
    pub(crate) prev_tracks: Vec<QueueItem>,
    pub(crate) protocol_next_tracks: Vec<ProtocolQueueTrack>,
    pub(crate) protocol_prev_tracks: Vec<ProtocolQueueTrack>,
    pub(crate) queue_revision: String,
    pub(crate) disallow_set_queue: bool,
    pub(crate) disallow_removing_from_next_tracks: bool,
}

#[derive(Serialize)]
pub(crate) struct PlaybackStateUpdate {
    pub(crate) revision: u64,
    pub(crate) session_generation: u64,
    pub(crate) is_playing: bool,
    pub(crate) is_paused: bool,
    pub(crate) track_uri: String,
    pub(crate) position_ms: i64,
    pub(crate) duration_ms: i64,
    pub(crate) shuffle: bool,
    pub(crate) repeat_track: bool,
    pub(crate) repeat_context: bool,
    /// Timestamp (ms since epoch) when position_ms was recorded - for computing current position
    pub(crate) timestamp_ms: i64,
}

#[derive(Serialize)]
pub(crate) struct LoadingNotification {
    pub(crate) revision: u64,
    pub(crate) session_generation: u64,
    pub(crate) track_uri: String,
    pub(crate) position_ms: u32,
}

#[derive(Serialize)]
pub(crate) struct SetQueueNotification {
    pub(crate) revision: u64,
    pub(crate) session_generation: u64,
    pub(crate) context_uri: String,
    pub(crate) current_track: Option<QueueTrackInfo>,
    pub(crate) next_tracks: Vec<QueueTrackInfo>,
    pub(crate) prev_tracks: Vec<QueueTrackInfo>,
}

#[derive(Serialize)]
pub(crate) struct QueueTrackInfo {
    pub(crate) uri: String,
    pub(crate) provider: String,
}

#[derive(Serialize)]
pub(crate) struct ConnectionStateInfo {
    /// Monotonic, assigned while the snapshot is built. Lets Swift discard a snapshot that
    /// reaches the main actor after a newer one — see `handleConnectionStateCallback`.
    pub(crate) revision: u64,
    pub(crate) session_generation: u64,
    pub(crate) session_connected: bool,
    pub(crate) session_connection_id: Option<String>,
    pub(crate) spirc_ready: bool,
    pub(crate) device_id: Option<String>,
    pub(crate) device_name: String,
    pub(crate) reconnect_attempt: u32,
    pub(crate) last_error: Option<String>,
    pub(crate) connected_since_ms: Option<u64>,
    pub(crate) is_active_device: bool,
}

/// One Spotify Connect device, in the shape `Device` in Swift already holds.
///
/// The Web API's `/me/player/devices` is what this replaces, and the field names match its
/// JSON rather than the protobuf's so the Swift decoder did not have to change: `is_active`
/// is derived here by comparing against the cluster's active device rather than being a field
/// of its own, because the protobuf has no such flag — the cluster names one active device and
/// every `DeviceInfo` is otherwise identical.
#[derive(Serialize)]
pub(crate) struct ConnectDeviceInfo {
    pub(crate) id: String,
    pub(crate) name: String,
    #[serde(rename = "type")]
    pub(crate) device_type: String,
    pub(crate) is_active: bool,
    pub(crate) is_private_session: bool,
    pub(crate) is_restricted: bool,
    pub(crate) volume_percent: Option<i32>,
    /// Whether the device refuses remote volume changes.
    ///
    /// An iPhone sets this: iOS does not let an app set system volume on another app's
    /// behalf, so the command comes back `400 DEVICE_DOES_NOT_SUPPORT_COMMAND`. The cluster
    /// says so up front, and forwarding it is what lets the slider grey out rather than fail
    /// after the user has already dragged it.
    pub(crate) disable_volume: bool,
}

#[derive(Serialize)]
pub(crate) struct DevicesState {
    pub(crate) revision: u64,
    pub(crate) session_generation: u64,
    pub(crate) devices: Vec<ConnectDeviceInfo>,
}

#[derive(Serialize)]
pub(crate) struct SessionClientInfo {
    pub(crate) client_id: String,
    pub(crate) client_name: String,
    pub(crate) client_brand_name: String,
    pub(crate) client_model_name: String,
}

/// Get current timestamp in milliseconds since UNIX epoch
pub(crate) fn current_timestamp_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as u64
}

/// Update position from player event
pub(crate) fn update_position(position_ms: u32) {
    POSITION_MS.store(position_ms, Ordering::SeqCst);
}

pub(crate) fn update_current_context_uri(context_uri: &str) {
    if context_uri.is_empty() {
        return;
    }
    let mut context_guard = CURRENT_CONTEXT_URI
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    *context_guard = Some(context_uri.to_string());
}

pub(crate) fn update_playback_options(shuffle: bool, repeat_track: bool, repeat_context: bool) {
    SHUFFLE_STATE.store(shuffle, Ordering::SeqCst);
    REPEAT_TRACK_STATE.store(repeat_track, Ordering::SeqCst);
    REPEAT_CONTEXT_STATE.store(repeat_context, Ordering::SeqCst);
}

pub(crate) fn current_playback_options() -> (bool, bool, bool) {
    (
        SHUFFLE_STATE.load(Ordering::SeqCst),
        REPEAT_TRACK_STATE.load(Ordering::SeqCst),
        REPEAT_CONTEXT_STATE.load(Ordering::SeqCst),
    )
}
