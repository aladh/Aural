use crate::*;
use std::future::Future;

// Global tokio runtime for async operations
pub(crate) static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

/// Returns `Err(ERROR_GENERAL)` if this thread already owns a Tokio runtime.
///
/// Centralizes the nested-`block_on` rule so exports can refuse before mutating
/// lifecycle flags, without each call site reading `Handle::try_current`.
pub(crate) fn refuse_if_nested_runtime() -> Result<(), i32> {
    if tokio::runtime::Handle::try_current().is_ok() {
        debug!("Refusing nested Runtime::block_on from a Tokio-owned thread");
        return Err(ERROR_GENERAL);
    }
    Ok(())
}

/// Runs `fut` on the process runtime from a thread that does not already own a Tokio runtime.
///
/// Swift calls these exports from its own threads. `Runtime::block_on` panics if the current
/// thread already belongs to a runtime — including a re-entry from a Tokio worker after a
/// callback into Swift. That panic must not reach the C ABI, and it must not be confused with
/// the grant-supersession code `-2`.
///
/// Callers map `Err` to `ERROR_GENERAL`. Do not call `RUNTIME.block_on` from an export.
pub(crate) fn block_on_export<T>(fut: impl Future<Output = T>) -> Result<T, i32> {
    refuse_if_nested_runtime()?;
    Ok(RUNTIME.block_on(fut))
}
