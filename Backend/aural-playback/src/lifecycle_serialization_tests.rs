use super::*;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64};
use std::sync::Arc;
use std::time::Duration;

fn lock_globals() -> std::sync::MutexGuard<'static, ()> {
    lock_lifecycle_test_globals()
}

#[test]
fn teardown_cleanup_runs_and_supersede_alone_does_not() {
    assert!(build_should_discard_on_commit(true, false));
    assert!(build_should_discard_on_commit(false, true));
    assert!(build_should_discard_on_commit(true, true));
    assert!(!build_should_discard_on_commit(false, false));

    assert!(
        !build_should_cleanup_globals(false),
        "a superseded attempt must not tear down a newer generation"
    );
    assert!(build_should_cleanup_globals(true));
    assert!(failed_build_should_cleanup(true));
    assert!(!failed_build_should_cleanup(false));
}

#[test]
fn reconnect_generation_is_captured_at_trigger_not_task_start() {
    let _guard = lock_globals();
    RECONNECTING.store(false, Ordering::SeqCst);

    let intent = RecoveryIntent {
        was_playing: false,
        was_active: false,
    };
    let at_trigger = 2;
    let start = start_reconnect_loop(intent, at_trigger).expect("claimed reconnect");
    assert_eq!(start.recovering_generation, at_trigger);
    assert_eq!(start.intent, intent);

    // A rebuild landed before the task ran. Loading the counter at task start
    // would adopt 3 and proceed to tear that session down.
    let at_task_start = 3;
    assert_eq!(
        plan_reconnect_unit(start.recovering_generation, at_task_start, false),
        ReconnectUnitPlan::Abandon
    );
    assert_eq!(
        plan_reconnect_unit(at_task_start, at_task_start, false),
        ReconnectUnitPlan::CleanupAndBuild,
        "capturing at task start would have adopted the newer generation"
    );

    RECONNECTING.store(false, Ordering::SeqCst);
}

#[test]
fn two_lifecycle_ops_never_enter_the_store_section_together() {
    let _guard = lock_globals();
    reset_store_section_stats();

    block_on_export(async {
        let ready = Arc::new(tokio::sync::Barrier::new(2));

        let op = |ready: Arc<tokio::sync::Barrier>| async move {
            ready.wait().await;
            with_lifecycle_lock(async {
                let _section = enter_store_section();
                // Block this worker so the sibling can contend for the lock while
                // the store section is still open. Multi-thread runtime lets it run.
                std::thread::sleep(Duration::from_millis(80));
            })
            .await;
        };

        tokio::join!(op(ready.clone()), op(ready));
    })
    .expect("lifecycle test");

    assert_eq!(store_section_entries(), 2);
    assert!(
        !store_section_overlapped(),
        "two serialized ops entered the store/commit section at the same time"
    );
}

#[test]
fn queued_stale_reconnect_revalidates_and_skips_cleanup_and_build() {
    let _guard = lock_globals();
    reset_store_section_stats();

    let cleaned = Arc::new(AtomicU32::new(0));
    let built = Arc::new(AtomicU32::new(0));
    let current = Arc::new(AtomicU64::new(2));

    block_on_export(async {
        let queued = Arc::new(tokio::sync::Barrier::new(2));

        let newer_session = {
            let queued = queued.clone();
            let current = current.clone();
            async move {
                let _lock = acquire_lifecycle().await;
                queued.wait().await;
                current.store(3, Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(40));
            }
        };

        let stale_reconnect = {
            let queued = queued.clone();
            let current = current.clone();
            let cleaned = cleaned.clone();
            let built = built.clone();
            async move {
                queued.wait().await;
                run_reconnect_unit(
                    2,
                    || current.load(Ordering::SeqCst),
                    || false,
                    || {
                        let _section = enter_store_section();
                        cleaned.fetch_add(1, Ordering::SeqCst);
                    },
                    async {
                        let _section = enter_store_section();
                        built.fetch_add(1, Ordering::SeqCst);
                    },
                )
                .await
            }
        };

        let (_, outcome) = tokio::join!(newer_session, stale_reconnect);
        assert!(matches!(outcome, ReconnectUnitOutcome::Abandoned));
    })
    .expect("lifecycle test");

    assert_eq!(cleaned.load(Ordering::SeqCst), 0);
    assert_eq!(built.load(Ordering::SeqCst), 0);
    assert_eq!(store_section_entries(), 0);
}

#[test]
fn exported_init_recheck_prevents_a_second_build_after_waiting() {
    let _guard = lock_globals();
    let session_present = Arc::new(AtomicBool::new(false));
    let built = Arc::new(AtomicU32::new(0));

    block_on_export(async {
        let waiter_ready = Arc::new(tokio::sync::Barrier::new(2));

        let first_build = {
            let waiter_ready = waiter_ready.clone();
            let session_present = session_present.clone();
            async move {
                let _lock = acquire_lifecycle().await;
                waiter_ready.wait().await;
                session_present.store(true, Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(40));
            }
        };

        let second_init = {
            let waiter_ready = waiter_ready.clone();
            let session_present = session_present.clone();
            let built = built.clone();
            async move {
                waiter_ready.wait().await;
                run_serialized_init(|| session_present.load(Ordering::SeqCst), async {
                    built.fetch_add(1, Ordering::SeqCst);
                })
                .await
            }
        };

        let (_, outcome) = tokio::join!(first_build, second_init);
        assert!(matches!(outcome, SerializedInitOutcome::AlreadyInitialized));
    })
    .expect("lifecycle test");

    assert_eq!(built.load(Ordering::SeqCst), 0);
}

#[test]
fn exported_init_builds_when_the_recheck_still_sees_no_session() {
    let _guard = lock_globals();
    block_on_export(async {
        let outcome = run_serialized_init(|| false, async { 7u8 }).await;
        match outcome {
            SerializedInitOutcome::Built(value) => assert_eq!(value, 7),
            SerializedInitOutcome::AlreadyInitialized => {
                panic!("empty session must still build")
            }
        }
    })
    .expect("lifecycle test");
}

#[test]
fn reconnect_unit_runs_cleanup_and_build_when_generation_still_matches() {
    let _guard = lock_globals();
    let cleaned = Arc::new(AtomicBool::new(false));
    let built = Arc::new(AtomicBool::new(false));

    block_on_export(async {
        let outcome = run_reconnect_unit(
            4,
            || 4,
            || false,
            || cleaned.store(true, Ordering::SeqCst),
            async {
                built.store(true, Ordering::SeqCst);
                Ok::<(), String>(())
            },
        )
        .await;
        assert!(matches!(outcome, ReconnectUnitOutcome::Ran(Ok(()))));
    })
    .expect("lifecycle test");

    assert!(cleaned.load(Ordering::SeqCst));
    assert!(built.load(Ordering::SeqCst));
}

#[test]
fn reconnect_unit_abandons_during_teardown_without_cleanup() {
    let _guard = lock_globals();
    let cleaned = Arc::new(AtomicBool::new(false));

    block_on_export(async {
        let outcome = run_reconnect_unit(
            4,
            || 4,
            || true,
            || cleaned.store(true, Ordering::SeqCst),
            async {
                panic!("teardown must not build");
            },
        )
        .await;
        assert!(matches!(outcome, ReconnectUnitOutcome::Abandoned));
    })
    .expect("lifecycle test");

    assert!(!cleaned.load(Ordering::SeqCst));
}
