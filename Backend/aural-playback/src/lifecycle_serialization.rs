use crate::*;
use std::future::Future;

/// Serializes player-session lifecycle operations that write the engine globals.
///
/// One async mutex, not a cross-language actor. Held across the awaits inside a build or
/// a reconnect cleanup+build so those writes cannot interleave. Never hold a per-global
/// `std::sync::Mutex` guard across `await`; this lock is the one exception, and inner
/// helpers must not acquire it again.
pub(crate) static LIFECYCLE: Lazy<tokio::sync::Mutex<()>> =
    Lazy::new(|| tokio::sync::Mutex::new(()));

/// Whether a queued reconnect may tear down and rebuild after it has the lifecycle lock.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ReconnectUnitPlan {
    /// Generation moved or teardown started; do not touch the globals.
    Abandon,
    /// Still the generation this loop set out to recover.
    CleanupAndBuild,
}

/// Whether exported init should build after waiting for the lifecycle lock.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExportedInitPlan {
    AlreadyInitialized,
    Build,
}

/// Outcome of [`run_serialized_init`] after the in-lock recheck.
#[derive(Debug)]
pub(crate) enum SerializedInitOutcome<T> {
    AlreadyInitialized,
    Built(T),
}

/// Outcome of [`run_reconnect_unit`] after the in-lock revalidation.
#[derive(Debug)]
pub(crate) enum ReconnectUnitOutcome<T> {
    Abandoned,
    Ran(T),
}

/// What a reconnect loop needs once `RECONNECTING` has been claimed.
///
/// `recovering_generation` is captured at trigger time, not when the task first runs.
/// A rebuild that lands between those two points must look like a foreign supersede.
#[derive(Debug, Clone, Copy)]
pub(crate) struct ReconnectLoopStart {
    pub(crate) intent: RecoveryIntent,
    pub(crate) recovering_generation: u64,
}

/// Claims the reconnect owner flag and records the generation being recovered.
pub(crate) fn start_reconnect_loop(
    intent: RecoveryIntent,
    current_generation: u64,
) -> Option<ReconnectLoopStart> {
    if RECONNECTING.swap(true, Ordering::SeqCst) {
        return None;
    }
    Some(ReconnectLoopStart {
        intent,
        recovering_generation: current_generation,
    })
}

pub(crate) fn plan_reconnect_unit(
    recovering_generation: u64,
    current_generation: u64,
    teardown_in_progress: bool,
) -> ReconnectUnitPlan {
    if reconnect_may_proceed(
        recovering_generation,
        current_generation,
        teardown_in_progress,
    ) {
        ReconnectUnitPlan::CleanupAndBuild
    } else {
        ReconnectUnitPlan::Abandon
    }
}

pub(crate) fn plan_exported_init(session_present: bool) -> ExportedInitPlan {
    if session_present {
        ExportedInitPlan::AlreadyInitialized
    } else {
        ExportedInitPlan::Build
    }
}

/// Whether a finished build should refuse to publish.
///
/// Teardown and a moved generation both discard the attempt. Only teardown may clear
/// globals: a supersede means a newer generation already owns them.
pub(crate) fn build_should_discard_on_commit(superseded: bool, tearing_down: bool) -> bool {
    superseded || tearing_down
}

pub(crate) fn build_should_cleanup_globals(tearing_down: bool) -> bool {
    tearing_down
}

pub(crate) fn failed_build_should_cleanup(tearing_down: bool) -> bool {
    tearing_down
}

pub(crate) fn session_is_present() -> bool {
    SESSION.lock().unwrap_or_else(|e| e.into_inner()).is_some()
}

pub(crate) async fn acquire_lifecycle() -> tokio::sync::MutexGuard<'static, ()> {
    LIFECYCLE.lock().await
}

/// Runs `fut` while the lifecycle lock is held. `fut` is not polled until the lock is acquired.
pub(crate) async fn with_lifecycle_lock<T>(fut: impl Future<Output = T>) -> T {
    let _guard = acquire_lifecycle().await;
    fut.await
}

/// Rechecks the already-initialized no-op *after* acquiring the lock, then maybe builds.
///
/// The future is created by the caller but only polled when the plan is [`ExportedInitPlan::Build`].
pub(crate) async fn run_serialized_init<P, B, T>(
    session_present: P,
    build: B,
) -> SerializedInitOutcome<T>
where
    P: Fn() -> bool,
    B: Future<Output = T>,
{
    let _guard = acquire_lifecycle().await;
    match plan_exported_init(session_present()) {
        ExportedInitPlan::AlreadyInitialized => SerializedInitOutcome::AlreadyInitialized,
        ExportedInitPlan::Build => SerializedInitOutcome::Built(build.await),
    }
}

/// Revalidates, then optionally runs cleanup and build as one serialized unit.
pub(crate) async fn run_reconnect_unit<C, B, T>(
    recovering_generation: u64,
    current_generation: impl Fn() -> u64,
    teardown_in_progress: impl Fn() -> bool,
    cleanup: C,
    build: B,
) -> ReconnectUnitOutcome<T>
where
    C: FnOnce(),
    B: Future<Output = T>,
{
    let _guard = acquire_lifecycle().await;
    match plan_reconnect_unit(
        recovering_generation,
        current_generation(),
        teardown_in_progress(),
    ) {
        ReconnectUnitPlan::Abandon => ReconnectUnitOutcome::Abandoned,
        ReconnectUnitPlan::CleanupAndBuild => {
            cleanup();
            let built = build.await;
            ReconnectUnitOutcome::Ran(built)
        }
    }
}

/// Marks the store/commit critical section that writes the engine globals.
///
/// Nested on one thread is allowed (reconnect cleanup then build). Two threads at once is
/// the interleaving this lock exists to prevent.
pub(crate) struct StoreSectionGuard {
    _private: (),
}

pub(crate) fn enter_store_section() -> StoreSectionGuard {
    #[cfg(test)]
    store_section::enter();
    StoreSectionGuard { _private: () }
}

impl Drop for StoreSectionGuard {
    fn drop(&mut self) {
        #[cfg(test)]
        store_section::exit();
    }
}

#[cfg(test)]
pub(crate) fn lock_lifecycle_test_globals() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(test)]
pub(crate) fn reset_store_section_stats() {
    store_section::reset();
}

#[cfg(test)]
pub(crate) fn store_section_overlapped() -> bool {
    store_section::overlapped()
}

#[cfg(test)]
pub(crate) fn store_section_entries() -> u32 {
    store_section::entries()
}

#[cfg(test)]
mod store_section {
    use super::*;
    use std::cell::Cell;

    static ACTIVE_THREADS: AtomicU32 = AtomicU32::new(0);
    static ENTRIES: AtomicU32 = AtomicU32::new(0);
    static OVERLAP: AtomicBool = AtomicBool::new(false);

    thread_local! {
        static NESTING: Cell<u32> = const { Cell::new(0) };
    }

    pub(crate) fn reset() {
        ACTIVE_THREADS.store(0, Ordering::SeqCst);
        ENTRIES.store(0, Ordering::SeqCst);
        OVERLAP.store(false, Ordering::SeqCst);
    }

    pub(crate) fn enter() {
        NESTING.with(|nesting| {
            let depth = nesting.get();
            nesting.set(depth + 1);
            if depth == 0 {
                ENTRIES.fetch_add(1, Ordering::SeqCst);
                let active = ACTIVE_THREADS.fetch_add(1, Ordering::SeqCst);
                if active >= 1 {
                    OVERLAP.store(true, Ordering::SeqCst);
                }
            }
        });
    }

    pub(crate) fn exit() {
        NESTING.with(|nesting| {
            let depth = nesting.get().saturating_sub(1);
            nesting.set(depth);
            if depth == 0 {
                ACTIVE_THREADS.fetch_sub(1, Ordering::SeqCst);
            }
        });
    }

    pub(crate) fn overlapped() -> bool {
        OVERLAP.load(Ordering::SeqCst)
    }

    pub(crate) fn entries() -> u32 {
        ENTRIES.load(Ordering::SeqCst)
    }
}
