use crate::*;
use librespot_core::{FileId, SpotifyId};

/// Raw Spotify track ID length (`SpotifyId::SIZE`), in bytes.
const TRACK_GID_LEN: usize = 16;
/// Raw file ID length (`FileId::RAW_LEN`), in bytes.
const FILE_ID_LEN: usize = 20;
/// `AudioKey` wraps a raw AES key of this length, in bytes.
const AUDIO_KEY_LEN: usize = 16;

/// Fetches the AES decryption key for one file over the existing AP session, blocking.
///
/// Stage 1 scaffolding for #201/#208: nothing calls this export yet. Spotify throttles key
/// requests, so callers must cache a successful result per file id rather than re-requesting
/// it (see `AudioKeyCache` in Swift) — librespot itself times a single request out at 1500ms.
///
/// # Safety
/// `track_gid` must be null or point to `TRACK_GID_LEN` readable bytes; `file_id` must be
/// null or point to `FILE_ID_LEN` readable bytes; `key_out` must be null or point to
/// `AUDIO_KEY_LEN` writable bytes.
#[no_mangle]
pub extern "C" fn aural_playback_audio_key(
    track_gid: *const u8,
    file_id: *const u8,
    key_out: *mut u8,
) -> i32 {
    ffi_command("aural_playback_audio_key", || {
        if track_gid.is_null() || file_id.is_null() || key_out.is_null() {
            debug!("Audio key error: null pointer argument");
            return ERROR_GENERAL;
        }

        if let Err(e) = require_session_connected() {
            return e;
        }

        // Safety: both slots are non-null (checked above) and callers must uphold the
        // fixed lengths documented on this export.
        let track_bytes = unsafe { std::slice::from_raw_parts(track_gid, TRACK_GID_LEN) };
        let file_bytes = unsafe { std::slice::from_raw_parts(file_id, FILE_ID_LEN) };

        let track = match SpotifyId::from_raw(track_bytes) {
            Ok(id) => id,
            Err(e) => {
                debug!("Audio key error: invalid track id: {:?}", e);
                return ERROR_GENERAL;
            }
        };
        let file = FileId::from_raw(file_bytes);

        let session = match SESSION.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            Some(session) => session.clone(),
            None => {
                debug!("Audio key error: session not initialized");
                return ERROR_NOT_CONNECTED;
            }
        };

        let result =
            block_on_export(async move { session.audio_key().request(track, file).await });
        match result {
            Ok(Ok(key)) => {
                // Safety: key_out is non-null (checked above) and points to at least
                // AUDIO_KEY_LEN writable bytes per this export's contract.
                unsafe {
                    std::ptr::copy_nonoverlapping(key.0.as_ptr(), key_out, AUDIO_KEY_LEN);
                }
                0
            }
            Ok(Err(e)) => {
                // Never log key bytes; only the error, e.g. AesKeyError or Timeout.
                debug!("Audio key error: request failed: {:?}", e);
                ERROR_GENERAL
            }
            Err(code) => code,
        }
    })
}
