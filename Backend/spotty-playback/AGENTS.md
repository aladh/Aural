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
- Every `spotty-playback` `extern "C"` export enters through the panic-barrier helpers in `ffi.rs`.
  Use `block_on_export`; call `refuse_if_nested_runtime` before mutating flags that nested `block_on`
  would have reached. Nested runtime re-entry returns `ERROR_GENERAL` and is not supersession.
- Map panics to the defined sentinel. Do not replace the process panic hook, hold Rust locks while
  invoking Swift, or assume the barrier makes invalid foreign pointers safe. When a sink or callback
  is typed `Arc<dyn Trait>`, coerce a concrete `Arc` with `x.clone()` or `as Arc<dyn Trait>`;
  `Arc::clone(&x)` infers the trait object from the expected type and fails to compile.
- Rust emits bounded PCM and immutable protocol/state envelopes. Keep callbacks non-blocking. What
  crosses the boundary, and which side owns each field, is
  [playback engine ownership](../../docs/playback-engine-ownership.md); do not enumerate it here.
  Hard rules: connection, playback, device-list, and queue observations are typed C snapshots, not
  JSON. Do not synthesize presentation in Rust; send protocol rows and playing/paused flags. Do not
  widen `spotty_playback_resume`. Do not send sticky context on local `PlayerEvent` snapshots. A
  reconnect publishes `resume_pending` with `spirc_ready` clear and holds readiness until a Swift
  load lands, a load reports a dead Spirc, or the window times out; do not rebuild a resume plan
  in Rust.
- Keep the checked-in C header, exported symbol set, signatures, ownership, allocation, and callback
  lifetime aligned.
- Treat librespot changes as protocol migrations. Preserve the ownership classification instead of
  opportunistically expanding the Rust leaf.
- `librespot-connect` is vendored under `Backend/vendor/librespot-connect` with a small patch (see
  its `PATCHES.md`) so `Spirc::new` takes `Arc<dyn SpircPlayer>` instead of the concrete `Player`;
  keep the patch minimal and re-diff it against upstream when the pinned rev moves.
