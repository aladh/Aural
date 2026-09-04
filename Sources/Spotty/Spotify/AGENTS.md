# Spotify boundary agent guidance

This directory owns account/auth, catalog, Connect, playback state/effects, queue, audio, and network
boundaries. Read the relevant ADRs and the
[product contract](../../../docs/product-and-acceptance-contract.md).

## State, effects, and dependencies

- `SpottyDomain.PlaybackState` is the single atomic presentation snapshot and `PlaybackReducer` its
  only mutation entrance. `PlaybackStore` is the `@MainActor` state/action surface; never add a
  second writer or partial in-place updates.
- `PlaybackCoordinator` serializes commands and `PlaybackEffectRegistry` owns store-level tasks.
  Reducer acceptance normally gates follow-ups; only documented same-lifetime transport
  reconciliation may succeed after a rejected finish. Other stale, superseded, teardown,
  cancellation, and epoch-invalidated outcomes stay inert.
- Suspended account-, engine-, selection-, or request-scoped work captures and revalidates identity
  immediately before each stateful apply.
- Assemble live dependencies once in `PlaybackEnvironment.live` and the composition root. Feature
  stores consume narrow injected boundaries; preserve the existing store split and keep transient
  mutation feedback in `TransientFeedbackPresenter`.

## Boundary invariants

- `PlaybackCore.swift` is the only Swift importer of `SpottyPlaybackCore`;
  `RustPlaybackEngine.swift` is its only caller. Keep the C header, Rust exports, ownership, pointer
  lifetimes, callback threading, and typed C snapshots aligned.
- Track identity is the market/requested Spotify track ID. Relinked decode IDs and metadata may
  enrich it but never replace it or create a second identity model.
- Ordered sources carry revisions; account and engine generations reject stale callbacks and
  requests. Do not use `lastRevision: inout`; compare and commit revision state at its owner.
- `RustPlaybackEngine` assigns process-local envelope sequence on one drain. Never call
  `AsyncStream.Continuation.yield` or `onTermination` while the fan-out lock is held.
- `QueueService` owns precedence and context identity. `QueueProtocolProjection` projects upcoming
  rows from unfiltered Connect tracks; metadata must not reorder or erase newer authoritative state.
- `ConnectDeviceProjection` owns device activity, sort, and empty-type fallback.
  `ConnectionSnapshotProjection` owns session phase and empty-device-ID fallback. Local display
  name is Swift-owned; do not move presentation policy, `device_name`, or write-only reconnect
  bookkeeping into Rust. Connection observations arrive as `SpottyConnectionSnapshot`, not JSON.
  Playback observations arrive as `SpottyPlaybackSnapshot`, not JSON.
  Device-list observations arrive as `SpottyDevicesSnapshot`, not JSON.
  Queue observations arrive as `SpottyQueueSnapshot`, not JSON.
- `PlaybackSnapshotProjection` owns engine playback transport, empty-URI identity, timestamp
  correction, and omitted-repeat fallback. The engine sends protocol playing/paused flags and
  cluster `context_uri`. User resume and reconnect rehydration capture sticky resume-load
  URIs through FFI and iterate `ResumeLoadPlan` through `spotty_playback_load`; a connection
  snapshot with `resumePending` and `spircReady` clear triggers one rehydration sequence per
  engine session generation. Do not feed `playbackContextURI` into that plan: local
  PlayerEvent snapshots send an empty context on purpose. Do not treat playback context as
  QueueService mutation identity. Do not widen `spotty_playback_resume`.
- Keep read-only catalog access separate from playlist mutation. Writes use `PlaylistMutating` and
  `PlaylistMutationController`; Pathfinder mutation DTOs do not enter views.
- PCM goes directly from the engine adapter to `AudioRenderer`, never observable UI state. Keep
  callbacks bounded and never block the Rust callback thread.
- Never log tokens, cookies, redirects, raw payloads, or private identifiers.
