use crate::{ERROR_GENERAL, ERROR_NEEDS_REINIT};
use librespot_core::error::ErrorKind;

/// Maps a failed public Spirc command to the FFI recovery code.
///
/// Pinned librespot (`9c7d75615fc093bdcbdb29adbce3fed38c531852`) exposes
/// `librespot_core::Error.kind`. Every `Spirc` handle used by [`crate::spirc_error`]
/// either only sends on the unbounded command `mpsc` (`play`, `pause`, `next`,
/// `prev`, `shuffle`, `repeat`, `repeat_track`, `set_position_ms`, `load`,
/// `shutdown`, `transfer`) or, for `add_to_queue`, may also return
/// `ErrorKind::InvalidArgument` when the URI kind is not track, episode, album, or
/// playlist. `handle_command` runs on the task after a successful send and never
/// returns to these handles.
///
/// A dropped command receiver becomes `tokio::sync::mpsc::error::SendError`, which
/// that revision converts with `From<SendError<T>>` to `ErrorKind::Internal` and a
/// private `ErrorMessage` of `SendError::to_string()`. The `SendError` type is
/// erased, so `Internal` is the inspectable closed-channel signal at this boundary.
/// Other kinds, including that `add_to_queue` `InvalidArgument`, stay
/// [`ERROR_GENERAL`]. Classification uses `kind` only; `Debug` text is not consulted.
pub(crate) fn classify_spirc_command_error(err: &librespot_core::Error) -> i32 {
    match err.kind {
        ErrorKind::Internal => ERROR_NEEDS_REINIT,
        _ => ERROR_GENERAL,
    }
}
