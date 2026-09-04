# Rust playback leaf agent guidance

This crate is the contained librespot protocol, Connect, streaming, decoding, recovery, and C-ABI
leaf. Read [ADR 001](../../docs/ADR-001-playback-engine.md),
[ADR 004](../../docs/ADR-004-swift-owned-playback-logic.md), and
[playback engine ownership](../../docs/playback-engine-ownership.md) before moving responsibility
across the Swift/Rust boundary.

## Lifecycle and ownership

- Lifecycle operations that write `SESSION`, `SPIRC`, `PLAYER`, `MIXER`, or `PLAYER_EVENT_TX`
  serialize through one async lifecycle mutex. Do not hold a per-global guard across `await`, and do
  not re-enter the lifecycle mutex from an inner helper.
- Reconnect captures `SESSION_GENERATION` at trigger time and revalidates it after acquiring the
  lifecycle mutex. A stale cleanup/reconnect must not tear down or rebuild a newer generation.
  Exported init rechecks its already-initialized no-op inside the mutex.
- A superseded grant/run must not write credentials or lifecycle state. Routine cleanup is not grant
  supersession; preserve the distinct generation rules and their tests.
- Every `aural-playback` `extern "C"` export enters through the panic-barrier helpers in `ffi.rs`.
  Use `block_on_export`; call `refuse_if_nested_runtime` before mutating flags that nested `block_on`
  would have reached. Nested runtime re-entry returns `ERROR_GENERAL` and is not supersession.
- Map panics to the defined sentinel. Do not replace the process panic hook, hold Rust locks while
  invoking Swift, or assume the barrier makes invalid foreign pointers safe.
- Rust emits bounded PCM and immutable protocol/state envelopes. Keep callbacks non-blocking. Queue
  and device rows plus connection and playback observations remain protocol/runtime truth; Swift owns
  queue, device-list, connection-phase, local-label, playback-transport, and metadata presentation.
  Do not reintroduce `device_name`, `reconnect_attempt`, `connected_since_ms`, or
  `session_connection_id` into `ConnectionState` or its envelope; reconnect backoff remains
  loop-local. Connection, playback, device-list, and queue observations are typed C snapshots, not JSON. Do not synthesize
  transport presentation in Rust; send protocol playing/paused flags.
  Cluster playback snapshots send protocol `context_uri`; local `PlayerEvent` snapshots send an
  empty context. Swift reads sticky `CURRENT_CONTEXT_URI` / `CURRENT_TRACK_URI` through
  FFI getters and issues seek-capable `aural_playback_load` from Swift targets, for user
  resume and for reconnect rehydration. A reconnect publishes `resume_pending` with
  `spirc_ready` clear and holds readiness until a load lands, a load reports a dead Spirc, or
  the window times out; do not rebuild a resume plan in Rust. Do not widen
  `aural_playback_resume`. Do not send sticky context on local PlayerEvent snapshots.
- Keep the checked-in C header, exported symbol set, signatures, ownership, allocation, and callback
  lifetime aligned.
- Treat librespot changes as protocol migrations. Preserve the ownership classification instead of
  opportunistically expanding the Rust leaf.

## Code review rules

Flag lifecycle writes outside the mutex, guards held across `await`, inner lock re-entry, missing
post-lock generation checks, writes from superseded work, unguarded exports, locks across Swift
callbacks, blocking PCM paths, presentation filtering in Rust, or ABI/fixture drift. The safe path is
one serialized lifecycle owner, captured-and-revalidated generations, panic-contained exports, and
paired Rust/Swift boundary evidence.

## Verification

Add Rust coverage beside the owning module. Focused Cargo commands are acceptable for iteration; the
completion gate for Rust, lifecycle, FFI, dependency, or archive changes is
`./Scripts/check-clean.sh` from the repository root. Inspect C-header/export parity.
Live playback is never required for unit or ABI proof.
