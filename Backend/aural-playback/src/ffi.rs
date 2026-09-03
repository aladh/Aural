use crate::*;

// Helper function to convert URL to URI
pub(crate) fn url_to_uri(input: &str) -> String {
    // If already a URI, return as-is
    if input.starts_with("spotify:") {
        return input.to_string();
    }

    // If it's a URL, parse it
    if input.starts_with("http://") || input.starts_with("https://") {
        if let Some(marker_pos) = input.find("open.spotify.com/") {
            let after_marker = &input[marker_pos + "open.spotify.com/".len()..];
            let parts: Vec<&str> = after_marker.split('/').collect();

            // Filter out locale prefixes like "intl-de"
            let filtered: Vec<&str> = parts
                .iter()
                .filter(|p| !p.starts_with("intl-"))
                .copied()
                .collect();

            if filtered.len() >= 2 {
                let content_type = filtered[0];
                let mut id = filtered[1];

                // Remove query parameters
                if let Some(query_pos) = id.find('?') {
                    id = &id[..query_pos];
                }

                return format!("spotify:{}:{}", content_type, id);
            }
        }
    }

    // Return original if can't parse
    input.to_string()
}

// Helper function to parse Spotify URI from string
pub(crate) fn parse_spotify_uri(uri_str: &str) -> Result<SpotifyUri, String> {
    SpotifyUri::from_uri(uri_str).map_err(|e| format!("Invalid Spotify URI: {:?}", e))
}

/// Copies a C string argument into an owned `String`, or `None` if it is null or not UTF-8.
///
/// # Safety
/// `ptr` must be null or point to a valid NUL-terminated C string.
pub(crate) unsafe fn c_string_arg(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let c_str = unsafe { CStr::from_ptr(ptr) };
    c_str.to_str().ok().map(str::to_owned)
}

/// Copies a registered callback out of its slot, releasing the slot lock before returning.
///
/// No callback may run with its slot lock held: it re-enters Swift, which can call straight
/// back into Rust. Taking the pointer out here makes that structural instead of a
/// `drop(guard)` that every call site has to remember. The export panic barrier does not
/// make an invalid callback pointer safe, and it does not wrap these outbound calls.
pub(crate) fn registered_callback<F: Copy>(slot: &Mutex<Option<F>>) -> Option<F> {
    *slot.lock().unwrap_or_else(|e| e.into_inner())
}

/// Hands an owned string to Swift, which frees it with `aural_playback_free_string`.
///
/// A string carrying an interior NUL cannot cross the boundary, and every caller already
/// treats null as "nothing to report", so that is what it becomes.
pub(crate) fn into_owned_c_string(value: String) -> *mut c_char {
    c_string_from_text(&value)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn c_string_from_text(text: &str) -> Option<CString> {
    match CString::new(text) {
        Ok(c_str) => Some(c_str),
        Err(e) => {
            debug!("C string contained interior NUL: {}", e);
            None
        }
    }
}

fn optional_callback_c_string(value: Option<&str>) -> Option<CString> {
    value
        .filter(|text| !text.is_empty())
        .and_then(c_string_from_text)
}

/// Connection observation delivered as a C struct. Pointers are valid only for the
/// callback; Swift must copy before returning. Interior NULs become null fields.
#[repr(C)]
pub struct AuralConnectionSnapshot {
    pub revision: u64,
    pub session_generation: u64,
    pub session_connected: u8,
    pub spirc_ready: u8,
    pub is_active_device: u8,
    pub device_id: *const c_char,
    pub last_error: *const c_char,
}

pub(crate) type ConnectionSnapshotCallback = extern "C" fn(*const AuralConnectionSnapshot);

pub(crate) fn send_connection_snapshot(
    callback: ConnectionSnapshotCallback,
    stamp: SnapshotStamp,
    state: &ConnectionState,
) {
    let device_id = optional_callback_c_string(state.device_id.as_deref());
    let last_error = optional_callback_c_string(state.last_error.as_deref());
    let snapshot = AuralConnectionSnapshot {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        session_connected: u8::from(state.session_connected),
        spirc_ready: u8::from(state.spirc_ready),
        is_active_device: u8::from(state.is_active_device),
        device_id: device_id
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null()),
        last_error: last_error
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null()),
    };
    callback(&snapshot);
}

/// Protocol playing/paused flags, URIs, timing, and options. Transport presentation
/// is Swift-owned. Not a JSON DTO.
pub(crate) struct PlaybackObservation {
    pub is_playing: bool,
    pub is_paused: bool,
    pub track_uri: String,
    pub context_uri: String,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub shuffle: bool,
    pub repeat_track: bool,
    pub repeat_context: bool,
    pub timestamp_ms: i64,
}

#[repr(C)]
pub struct AuralPlaybackSnapshot {
    pub revision: u64,
    pub session_generation: u64,
    pub position_ms: i64,
    pub duration_ms: i64,
    pub timestamp_ms: i64,
    pub is_playing: u8,
    pub is_paused: u8,
    pub shuffle: u8,
    pub repeat_track: u8,
    pub repeat_context: u8,
    pub track_uri: *const c_char,
    pub context_uri: *const c_char,
}

pub(crate) type PlaybackSnapshotCallback = extern "C" fn(*const AuralPlaybackSnapshot);

pub(crate) fn send_playback_snapshot(
    callback: PlaybackSnapshotCallback,
    stamp: SnapshotStamp,
    observation: &PlaybackObservation,
) {
    let track_uri = optional_callback_c_string(Some(observation.track_uri.as_str()));
    let context_uri = optional_callback_c_string(Some(observation.context_uri.as_str()));
    let snapshot = AuralPlaybackSnapshot {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        position_ms: observation.position_ms,
        duration_ms: observation.duration_ms,
        timestamp_ms: observation.timestamp_ms,
        is_playing: u8::from(observation.is_playing),
        is_paused: u8::from(observation.is_paused),
        shuffle: u8::from(observation.shuffle),
        repeat_track: u8::from(observation.repeat_track),
        repeat_context: u8::from(observation.repeat_context),
        track_uri: track_uri
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null()),
        context_uri: context_uri
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null()),
    };
    callback(&snapshot);
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AuralProtocolDevice {
    pub id: *const c_char,
    pub name: *const c_char,
    pub device_type: *const c_char,
}

#[repr(C)]
pub struct AuralDevicesSnapshot {
    pub revision: u64,
    pub session_generation: u64,
    pub active_device_id: *const c_char,
    pub devices: *const AuralProtocolDevice,
    pub device_count: usize,
}

pub(crate) type DevicesSnapshotCallback = extern "C" fn(*const AuralDevicesSnapshot);

pub(crate) fn send_devices_snapshot(
    callback: DevicesSnapshotCallback,
    stamp: SnapshotStamp,
    active_device_id: &str,
    devices: &[ProtocolConnectDevice],
) {
    let active = optional_callback_c_string(Some(active_device_id));
    let row_strings: Vec<(Option<CString>, Option<CString>, Option<CString>)> = devices
        .iter()
        .map(|device| {
            (
                optional_callback_c_string(Some(device.id.as_str())),
                optional_callback_c_string(Some(device.name.as_str())),
                optional_callback_c_string(Some(device.device_type.as_str())),
            )
        })
        .collect();
    let rows: Vec<AuralProtocolDevice> = row_strings
        .iter()
        .map(|(id, name, device_type)| AuralProtocolDevice {
            id: id
                .as_ref()
                .map(|value| value.as_ptr())
                .unwrap_or(std::ptr::null()),
            name: name
                .as_ref()
                .map(|value| value.as_ptr())
                .unwrap_or(std::ptr::null()),
            device_type: device_type
                .as_ref()
                .map(|value| value.as_ptr())
                .unwrap_or(std::ptr::null()),
        })
        .collect();
    let snapshot = AuralDevicesSnapshot {
        revision: stamp.revision,
        session_generation: stamp.session_generation,
        active_device_id: active
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null()),
        devices: if rows.is_empty() {
            std::ptr::null()
        } else {
            rows.as_ptr()
        },
        device_count: rows.len(),
    };
    callback(&snapshot);
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AuralStringPair {
    pub key: *const c_char,
    pub value: *const c_char,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AuralRestriction {
    pub key: *const c_char,
    pub reasons: *const *const c_char,
    pub reason_count: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AuralProtocolQueueTrack {
    pub uri: *const c_char,
    pub uid: *const c_char,
    pub provider: *const c_char,
    pub metadata: *const AuralStringPair,
    pub metadata_count: usize,
    pub removed: *const *const c_char,
    pub removed_count: usize,
    pub blocked: *const *const c_char,
    pub blocked_count: usize,
    pub restrictions: *const AuralRestriction,
    pub restriction_count: usize,
    pub album_uri: *const c_char,
    pub disallow_reasons: *const *const c_char,
    pub disallow_reason_count: usize,
    pub artist_uri: *const c_char,
}

#[repr(C)]
pub struct AuralQueueSnapshot {
    pub revision: u64,
    pub session_generation: u64,
    pub track_uri: *const c_char,
    pub track_provider: *const c_char,
    pub track_uid: *const c_char,
    pub next_tracks: *const AuralProtocolQueueTrack,
    pub next_count: usize,
    pub prev_tracks: *const AuralProtocolQueueTrack,
    pub prev_count: usize,
    pub queue_revision: *const c_char,
    pub disallow_set_queue: u8,
    pub disallow_removing_from_next_tracks: u8,
}

pub(crate) type QueueSnapshotCallback = extern "C" fn(*const AuralQueueSnapshot);

struct CStringList {
    _values: Vec<Option<CString>>,
    pointers: Vec<*const c_char>,
}

impl CStringList {
    fn from_strings(items: &[String]) -> Self {
        let values: Vec<Option<CString>> = items
            .iter()
            .map(|item| optional_callback_c_string(Some(item)))
            .collect();
        let pointers = values
            .iter()
            .map(|value| {
                value
                    .as_ref()
                    .map(|c_string| c_string.as_ptr())
                    .unwrap_or(std::ptr::null())
            })
            .collect();
        Self {
            _values: values,
            pointers,
        }
    }

    fn as_ptr(&self) -> *const *const c_char {
        if self.pointers.is_empty() {
            std::ptr::null()
        } else {
            self.pointers.as_ptr()
        }
    }

    fn len(&self) -> usize {
        self.pointers.len()
    }
}

struct RestrictionBacking {
    key: Option<CString>,
    reasons: CStringList,
}

struct ProtocolTrackBacking {
    uri: Option<CString>,
    uid: Option<CString>,
    provider: Option<CString>,
    /// Keeps metadata CStrings alive for `metadata_rows` pointers.
    #[allow(dead_code)]
    metadata: Vec<(Option<CString>, Option<CString>)>,
    metadata_rows: Vec<AuralStringPair>,
    removed: CStringList,
    blocked: CStringList,
    /// Keeps restriction keys and reason lists alive for `restriction_rows`.
    #[allow(dead_code)]
    restrictions: Vec<RestrictionBacking>,
    restriction_rows: Vec<AuralRestriction>,
    album_uri: Option<CString>,
    disallow_reasons: CStringList,
    artist_uri: Option<CString>,
}

struct QueueSnapshotBacking {
    track_uri: Option<CString>,
    track_provider: Option<CString>,
    track_uid: Option<CString>,
    queue_revision: Option<CString>,
    next: Vec<ProtocolTrackBacking>,
    prev: Vec<ProtocolTrackBacking>,
    next_rows: Vec<AuralProtocolQueueTrack>,
    prev_rows: Vec<AuralProtocolQueueTrack>,
}

#[repr(C)]
struct OwnedQueueSnapshot {
    snapshot: AuralQueueSnapshot,
    backing: QueueSnapshotBacking,
}

fn c_ptr(value: &Option<CString>) -> *const c_char {
    value
        .as_ref()
        .map(|c_string| c_string.as_ptr())
        .unwrap_or(std::ptr::null())
}

fn protocol_track_backing(track: &ProtocolQueueTrack) -> ProtocolTrackBacking {
    let metadata: Vec<(Option<CString>, Option<CString>)> = track
        .metadata
        .iter()
        .map(|(key, value)| {
            (
                optional_callback_c_string(Some(key)),
                optional_callback_c_string(Some(value)),
            )
        })
        .collect();
    let metadata_rows = metadata
        .iter()
        .map(|(key, value)| AuralStringPair {
            key: c_ptr(key),
            value: c_ptr(value),
        })
        .collect();
    let restrictions: Vec<RestrictionBacking> = track
        .restrictions
        .iter()
        .map(|(key, reasons)| RestrictionBacking {
            key: optional_callback_c_string(Some(key)),
            reasons: CStringList::from_strings(reasons),
        })
        .collect();
    let restriction_rows = restrictions
        .iter()
        .map(|restriction| AuralRestriction {
            key: c_ptr(&restriction.key),
            reasons: restriction.reasons.as_ptr(),
            reason_count: restriction.reasons.len(),
        })
        .collect();
    ProtocolTrackBacking {
        uri: optional_callback_c_string(Some(track.uri.as_str())),
        uid: optional_callback_c_string(Some(track.uid.as_str())),
        provider: optional_callback_c_string(Some(track.provider.as_str())),
        metadata,
        metadata_rows,
        removed: CStringList::from_strings(&track.removed),
        blocked: CStringList::from_strings(&track.blocked),
        restrictions,
        restriction_rows,
        album_uri: optional_callback_c_string(Some(track.album_uri.as_str())),
        disallow_reasons: CStringList::from_strings(&track.disallow_reasons),
        artist_uri: optional_callback_c_string(Some(track.artist_uri.as_str())),
    }
}

fn protocol_track_row(backing: &ProtocolTrackBacking) -> AuralProtocolQueueTrack {
    AuralProtocolQueueTrack {
        uri: c_ptr(&backing.uri),
        uid: c_ptr(&backing.uid),
        provider: c_ptr(&backing.provider),
        metadata: if backing.metadata_rows.is_empty() {
            std::ptr::null()
        } else {
            backing.metadata_rows.as_ptr()
        },
        metadata_count: backing.metadata_rows.len(),
        removed: backing.removed.as_ptr(),
        removed_count: backing.removed.len(),
        blocked: backing.blocked.as_ptr(),
        blocked_count: backing.blocked.len(),
        restrictions: if backing.restriction_rows.is_empty() {
            std::ptr::null()
        } else {
            backing.restriction_rows.as_ptr()
        },
        restriction_count: backing.restriction_rows.len(),
        album_uri: c_ptr(&backing.album_uri),
        disallow_reasons: backing.disallow_reasons.as_ptr(),
        disallow_reason_count: backing.disallow_reasons.len(),
        artist_uri: c_ptr(&backing.artist_uri),
    }
}

fn queue_snapshot_backing(state: &QueueState) -> QueueSnapshotBacking {
    let (track_uri, track_provider, track_uid) = match &state.track {
        Some(track) => (
            optional_callback_c_string(Some(track.uri.as_str())),
            optional_callback_c_string(Some(track.provider.as_str())),
            optional_callback_c_string(Some(track.uid.as_str())),
        ),
        None => (None, None, None),
    };
    let mut backing = QueueSnapshotBacking {
        track_uri,
        track_provider,
        track_uid,
        queue_revision: optional_callback_c_string(Some(state.queue_revision.as_str())),
        next: state
            .protocol_next_tracks
            .iter()
            .map(protocol_track_backing)
            .collect(),
        prev: state
            .protocol_prev_tracks
            .iter()
            .map(protocol_track_backing)
            .collect(),
        next_rows: Vec::new(),
        prev_rows: Vec::new(),
    };
    backing.next_rows = backing.next.iter().map(protocol_track_row).collect();
    backing.prev_rows = backing.prev.iter().map(protocol_track_row).collect();
    backing
}

fn queue_snapshot_from_backing(
    backing: &QueueSnapshotBacking,
    state: &QueueState,
) -> AuralQueueSnapshot {
    AuralQueueSnapshot {
        revision: state.revision,
        session_generation: state.session_generation,
        track_uri: c_ptr(&backing.track_uri),
        track_provider: c_ptr(&backing.track_provider),
        track_uid: c_ptr(&backing.track_uid),
        next_tracks: if backing.next_rows.is_empty() {
            std::ptr::null()
        } else {
            backing.next_rows.as_ptr()
        },
        next_count: backing.next_rows.len(),
        prev_tracks: if backing.prev_rows.is_empty() {
            std::ptr::null()
        } else {
            backing.prev_rows.as_ptr()
        },
        prev_count: backing.prev_rows.len(),
        queue_revision: c_ptr(&backing.queue_revision),
        disallow_set_queue: u8::from(state.disallow_set_queue),
        disallow_removing_from_next_tracks: u8::from(state.disallow_removing_from_next_tracks),
    }
}

pub(crate) fn send_queue_snapshot(callback: QueueSnapshotCallback, state: &QueueState) {
    let backing = queue_snapshot_backing(state);
    let snapshot = queue_snapshot_from_backing(&backing, state);
    callback(&snapshot);
}

pub(crate) fn alloc_queue_snapshot(state: &QueueState) -> *mut AuralQueueSnapshot {
    let backing = queue_snapshot_backing(state);
    let mut owned = Box::new(OwnedQueueSnapshot {
        snapshot: AuralQueueSnapshot {
            revision: 0,
            session_generation: 0,
            track_uri: std::ptr::null(),
            track_provider: std::ptr::null(),
            track_uid: std::ptr::null(),
            next_tracks: std::ptr::null(),
            next_count: 0,
            prev_tracks: std::ptr::null(),
            prev_count: 0,
            queue_revision: std::ptr::null(),
            disallow_set_queue: 0,
            disallow_removing_from_next_tracks: 0,
        },
        backing,
    });
    owned.snapshot = queue_snapshot_from_backing(&owned.backing, state);
    Box::into_raw(owned) as *mut AuralQueueSnapshot
}

pub(crate) fn free_queue_snapshot(snapshot: *mut AuralQueueSnapshot) {
    if snapshot.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(snapshot as *mut OwnedQueueSnapshot));
    }
}

/// The current Spirc, or `None` after logging that there is none.
///
/// Handed out as a clone rather than behind the guard: several callers go on to publish a
/// connection snapshot, which re-enters Swift, and Swift may call straight back into Rust.
/// No FFI entry point may hold the `SPIRC` lock across that.
pub(crate) fn current_spirc(what: &str) -> Option<Arc<Spirc>> {
    let spirc = SPIRC.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if spirc.is_none() {
        debug!("{} error: Spirc not initialized", what);
    }
    spirc
}

/// Logs a failed Spirc command against `what` and maps it to its FFI error code.
///
/// A closed command channel is reported separately (`ERROR_NEEDS_REINIT`) because Swift
/// responds to it by rebuilding the player rather than by surfacing a failure. The recovery
/// code comes from [`classify_spirc_command_error`]; the `Debug` formatting here is log-only.
pub(crate) fn spirc_error(what: &str, err: &librespot_core::Error) -> i32 {
    debug!("{} error: {:?}", what, err);
    classify_spirc_command_error(err)
}

/// Runs a command against the current Spirc and maps the outcome to an FFI error code.
pub(crate) fn spirc_command(
    what: &str,
    command: impl FnOnce(&Spirc) -> Result<(), librespot_core::Error>,
) -> i32 {
    let Some(spirc) = current_spirc(what) else {
        return ERROR_GENERAL;
    };

    match command(&spirc) {
        Ok(()) => 0,
        Err(e) => spirc_error(what, &e),
    }
}

/// Shuts down the Spirc instance if it exists.
/// This terminates the spirc_task and closes the dealer connection.
pub(crate) fn shutdown_spirc(context: &str) {
    let spirc_guard = SPIRC.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(spirc) = spirc_guard.as_ref() {
        if let Err(e) = spirc.shutdown() {
            debug!("{}: spirc.shutdown() failed: {:?}", context, e);
        } else {
            debug!("{}: spirc.shutdown() succeeded", context);
        }
    }
}

/// Defined fallback when an FFI export panics: command `i32`s become [`ERROR_GENERAL`].
pub(crate) fn ffi_command(export: &'static str, work: impl FnOnce() -> i32) -> i32 {
    ffi_catch(export, ERROR_GENERAL, work)
}

/// Defined fallback when an FFI flag query panics: conservative `0` / false.
#[cfg(test)]
pub(crate) fn ffi_query_i32(export: &'static str, work: impl FnOnce() -> i32) -> i32 {
    ffi_catch(export, 0, work)
}

/// Defined fallback when an FFI `u32` query panics: conservative `0`.
pub(crate) fn ffi_query_u32(export: &'static str, work: impl FnOnce() -> u32) -> u32 {
    ffi_catch(export, 0, work)
}

/// Defined fallback when an FFI `u8` query panics: conservative `0`.
#[cfg(test)]
pub(crate) fn ffi_query_u8(export: &'static str, work: impl FnOnce() -> u8) -> u8 {
    ffi_catch(export, 0, work)
}

/// Defined fallback when an FFI `bool` query panics: conservative `false`.
#[cfg(test)]
pub(crate) fn ffi_query_bool(export: &'static str, work: impl FnOnce() -> bool) -> bool {
    ffi_catch(export, false, work)
}

/// Defined fallback when an owned-string export panics: a null pointer.
pub(crate) fn ffi_owned_string(
    export: &'static str,
    work: impl FnOnce() -> *mut c_char,
) -> *mut c_char {
    ffi_catch(export, std::ptr::null_mut(), work)
}

/// Defined fallback when an owned-pointer export panics: a null pointer.
pub(crate) fn ffi_owned_ptr<T>(export: &'static str, work: impl FnOnce() -> *mut T) -> *mut T {
    ffi_catch(export, std::ptr::null_mut(), work)
}

/// Defined fallback when a void export panics: a no-op completion.
pub(crate) fn ffi_void(export: &'static str, work: impl FnOnce()) {
    ffi_catch(export, (), work)
}

/// Contains a panic originating in `work` so it cannot unwind across the C ABI.
///
/// `AssertUnwindSafe` is used because FFI bodies capture raw pointers and process-wide
/// locks, which are not `UnwindSafe`. That wrapper does not make invalid foreign pointers
/// defined; it only stops a Rust panic from crossing into Swift. After a panic, existing
/// poisoned-lock recovery (`into_inner`) remains the recovery path. The process panic hook
/// is left untouched, and the panic payload is not copied into logs.
fn ffi_catch<T>(export: &'static str, fallback: T, work: impl FnOnce() -> T) -> T {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(work)) {
        Ok(value) => value,
        Err(_) => {
            log::error!("FFI export {export} panicked; returning defined fallback");
            fallback
        }
    }
}

/// Frees a C string allocated by this library.
#[no_mangle]
pub extern "C" fn aural_playback_free_string(s: *mut c_char) {
    ffi_void("aural_playback_free_string", || {
        if !s.is_null() {
            unsafe {
                let _ = CString::from_raw(s);
            }
        }
    })
}

/// Registers a callback to receive queue updates as a C snapshot.
/// String and nested pointers are valid only for the call.
#[no_mangle]
pub extern "C" fn aural_playback_register_queue_callback(callback: QueueSnapshotCallback) {
    ffi_void("aural_playback_register_queue_callback", || {
        *CONTROL_CALLBACKS
            .queue
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
    })
}

/// Registers a callback to receive playback state updates as a C snapshot.
/// String pointers are valid only for the call.
#[no_mangle]
pub extern "C" fn aural_playback_register_playback_state_callback(
    callback: PlaybackSnapshotCallback,
) {
    ffi_void("aural_playback_register_playback_state_callback", || {
        *CONTROL_CALLBACKS
            .playback_state
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
    })
}

/// Registers a callback to receive the Connect device list from cluster updates.
/// The callback receives a C snapshot; string pointers are valid only for the call.
/// Fires only when the list actually changes, not on every cluster tick.
#[no_mangle]
pub extern "C" fn aural_playback_register_devices_callback(callback: DevicesSnapshotCallback) {
    ffi_void("aural_playback_register_devices_callback", || {
        *CONTROL_CALLBACKS
            .devices
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
    })
}

/// Registers a callback to receive connection state change notifications.
/// Called whenever the connection state changes (connect, disconnect, error, etc.).
/// The callback receives a C snapshot; string pointers are valid only for the call.
#[no_mangle]
pub extern "C" fn aural_playback_register_connection_state_callback(
    callback: ConnectionSnapshotCallback,
) {
    ffi_void("aural_playback_register_connection_state_callback", || {
        *CONTROL_CALLBACKS
            .connection_state
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
    })
}

/// Registers a callback to receive raw PCM audio data (f32, 44100Hz, stereo interleaved).
/// Called from librespot's player thread for each decoded audio chunk.
/// The callback receives a pointer to f32 samples and the number of f32 values.
#[no_mangle]
pub extern "C" fn aural_playback_register_audio_data_callback(
    callback: extern "C" fn(*const f32, usize),
) {
    ffi_void("aural_playback_register_audio_data_callback", || {
        proxy_sink::register_audio_data_callback(callback);
    })
}

/// Registers a callback for audio control events (start/stop/clear).
/// Called from librespot's player thread.
/// Events: 0 = stop, 1 = start/resume, 2 = clear/flush
#[no_mangle]
pub extern "C" fn aural_playback_register_audio_control_callback(callback: extern "C" fn(u8)) {
    ffi_void("aural_playback_register_audio_control_callback", || {
        proxy_sink::register_audio_control_callback(callback);
    })
}
