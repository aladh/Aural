# Patches over upstream librespot-connect

Vendored from `librespot-connect` 0.8.0 at upstream rev
[`9c7d75615fc093bdcbdb29adbce3fed38c531852`](https://github.com/librespot-org/librespot/tree/9c7d75615fc093bdcbdb29adbce3fed38c531852/connect),
the same rev `Backend/aural-playback` pins for `librespot-core`/`librespot-playback`/`librespot-protocol`.

## Why

`Spirc::new` takes the concrete `Arc<librespot_playback::player::Player>`, and there is no seam
inside `Player` to swap fetch/decrypt/decode. Aural's Stage 1 audio path (`#208`) needs `Spirc` to
drive a player implemented in Swift instead of librespot's own fetch/decrypt/Vorbis pipeline, so
`SpircTask` needs to hold something other than the concrete `Player`. This patch is the smallest
change that unblocks that: a trait naming exactly the methods `SpircTask` calls, implemented for
`Player` so upstream behavior is unchanged.

## Changes

1. **`src/player_bridge.rs` (new)** — `pub trait SpircPlayer: Send + Sync` with the exact methods
   `SpircTask` calls on the player (`load`, `preload`, `play`, `pause`, `stop`, `seek`,
   `get_player_event_channel`, and the `emit_*_event` helpers), plus
   `impl SpircPlayer for librespot_playback::player::Player` that delegates to the inherent
   methods of the same names.
2. **`src/lib.rs`** — declare `mod player_bridge;` and `pub use player_bridge::SpircPlayer;`.
3. **`src/spirc.rs`** — `SpircTask.player` and the `player` parameter of `Spirc::new` change from
   `Arc<Player>` to `Arc<dyn SpircPlayer>`; drop the now-unused `Player` import.
4. **`Cargo.toml`** — replace `workspace = true` inheritance and `path = "../..."` deps (this
   crate no longer lives inside the librespot workspace) with literal values taken from the
   librespot workspace `Cargo.toml` at the pinned rev, and `git`/`rev` dependencies on
   `librespot-core`, `librespot-playback`, and `librespot-protocol` pinned to the same rev. The
   workspace `[lints]` table is dropped rather than reproduced, since there is no workspace to
   inherit from; no lint config in this vendored copy is a deliberate, minor deviation from
   upstream.

5. **`README.md`** (doc-only) — the "basic example" link to `examples/play_connect.rs` pointed
   at `../examples/play_connect.rs`, which doesn't exist in this vendored copy (only `connect/`
   was vendored, not the rest of the librespot tree). Repointed at the upstream file at the pinned
   rev instead, since `lib.rs` includes this README verbatim as its rustdoc.

No other file changed. Callers pass `player.clone() as Arc<dyn SpircPlayer>`; behavior is
unchanged because the only implementation in this codebase today is still librespot's `Player`.

This is intended to be small enough to upstream as an optional seam; if librespot accepts a
version of it, this vendor copy can be replaced with the git dependency again.
