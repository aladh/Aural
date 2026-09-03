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
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

/// Serializes `payload` and hands it to a Swift callback as a C string.
///
/// The C string outlives the call and is freed on return: Swift copies what it needs
/// before the callback returns.
pub(crate) fn send_json<T: Serialize>(callback: extern "C" fn(*const c_char), payload: &T) {
    match serde_json::to_string(payload) {
        // serde_json escapes interior NULs, so CString::new cannot fail for its output;
        // treat it like any other serialization failure rather than panicking into Swift.
        Ok(json) => match CString::new(json) {
            Ok(c_str) => callback(c_str.as_ptr()),
            Err(e) => debug!("Callback payload contained NUL: {}", e),
        },
        Err(e) => debug!("Failed to serialize callback payload: {:?}", e),
    }
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
    info: &ConnectionStateInfo,
) {
    let device_id = c_string_or_none(info.device_id.as_deref());
    let last_error = c_string_or_none(info.last_error.as_deref());
    let snapshot = AuralConnectionSnapshot {
        revision: info.revision,
        session_generation: info.session_generation,
        session_connected: u8::from(info.session_connected),
        spirc_ready: u8::from(info.spirc_ready),
        is_active_device: u8::from(info.is_active_device),
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

fn c_string_or_none(value: Option<&str>) -> Option<CString> {
    value
        .filter(|text| !text.is_empty())
        .and_then(|text| match CString::new(text) {
            Ok(c_str) => Some(c_str),
            Err(e) => {
                debug!("Connection snapshot field contained NUL: {}", e);
                None
            }
        })
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

/// Registers a callback to receive queue updates (as JSON string).
#[no_mangle]
pub extern "C" fn aural_playback_register_queue_callback(callback: extern "C" fn(*const c_char)) {
    ffi_void("aural_playback_register_queue_callback", || {
        *CONTROL_CALLBACKS
            .queue
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
    })
}

/// Registers a callback to receive playback state updates (as JSON string).
#[no_mangle]
pub extern "C" fn aural_playback_register_playback_state_callback(
    callback: extern "C" fn(*const c_char),
) {
    ffi_void("aural_playback_register_playback_state_callback", || {
        *CONTROL_CALLBACKS
            .playback_state
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(callback);
    })
}

/// Registers a callback to receive the Connect device list from cluster updates.
///
/// The payload wraps the `/me/player/devices`-shaped array with the same revision and session
/// generation carried by every other structured control event. It fires only when the list
/// actually changes, not on every cluster tick.
#[no_mangle]
pub extern "C" fn aural_playback_register_devices_callback(callback: extern "C" fn(*const c_char)) {
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
