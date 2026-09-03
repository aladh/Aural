# Spotify boundary agent guidance

This directory contains account/auth, catalog, Connect, playback-engine, queue, audio, and network
boundaries. Read the relevant accepted ADRs plus the
[product contract](../../../docs/product-and-acceptance-contract.md) before changing behavior.

## Boundary invariants

- `PlaybackCore.swift` is the only Swift importer of `AuralPlaybackCore`, and
  `RustPlaybackEngine.swift` is its only caller. Keep the checked-in C header, exported Rust symbols,
  ownership, pointer lifetimes, callback threading, and JSON fixtures exactly aligned.
- Track identity is the market/requested Spotify track ID. Relinked decode IDs and metadata may enrich
  playback but must not replace that identity or create a second identity model.
- Ordered callback sources carry revisions. Account and engine generations prevent stale callbacks,
  teardown, or delayed requests from mutating replacements. Capture the relevant lifetime before
  suspension and revalidate it immediately before every stateful apply. Do not implement revision
  gates with `lastRevision: inout`; compare and commit revision state explicitly at its owner.
- `RustPlaybackEngine` assigns process-local envelope sequence on one drain. Never call
  `AsyncStream.Continuation.yield` or `onTermination` while the fan-out lock is held.
- `QueueService` owns queue precedence and context identity. `QueueProtocolProjection` projects
  upcoming rows from unfiltered Connect protocol tracks; metadata may enrich labels but must not
  reorder or erase newer authoritative state.
- `ConnectDeviceProjection` owns display activity, sort, and empty-type fallback from cluster members
  plus `active_device_id`. Do not move presentation policy back into Rust.
- `ConnectionSnapshotProjection` owns connection session phase and empty-device-ID fallback from the
  engine's session flags, `device_id`, and `last_error`. Local display name is Swift-owned
  (`thisDeviceName`); do not reintroduce hardcoded `device_name` or write-only reconnect bookkeeping
  into the Rust envelope.
- Keep read-only catalog access separate from playlist mutation. Writes flow through
  `PlaylistMutating` and `PlaylistMutationController`; Pathfinder mutation DTOs do not enter views.
- PCM travels directly from the engine adapter to `AudioRenderer`, never through observable UI state.
  Keep callbacks bounded and never block the Rust callback thread.
- Auth, catalog, and playback logs are privacy boundaries. Do not log tokens, cookies, redirects, raw
  payloads, or private identifiers. Fixtures must be reduced, synthetic, and non-identifying.

## Live-account rule

Reading remote state is read-only. Transport, seek, transfer, queue, library, playlist, follow, and
sign-out actions require explicit current-request authorization. Do not treat an authenticated launch
or a prior request as standing permission.

## Code review rules

Flag any second C-module importer/caller, identity replacement, unchecked post-`await` apply, stale
callback without generation/revision handling, lock-held continuation callback, presentation policy in
Rust, raw payload logging, or unauthorized live mutation. The safe path is a narrow typed adapter,
explicit lifetime/revision validation, synthetic cross-boundary fixtures, and a deterministic failure
or stale-result check.

## Verification

Add boundary coverage under `Sources/AuralChecks/DeferredBoundaryChecks/`; FFI or Rust-facing changes
also need Rust coverage and ABI parity. Run `./Scripts/check.sh`; use `./Scripts/check-clean.sh` for
FFI, engine lifecycle, build, or archive changes. Perform live acceptance only when authorized.
