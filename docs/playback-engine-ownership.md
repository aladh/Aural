# Playback engine ownership

Live inventory for [ADR 005](ADR-005-retain-librespot.md). [ADR 004](ADR-004-swift-owned-playback-logic.md)
is historical; its staged migration is superseded. Production logic is either
**librespot/protocol/runtime** in `Backend/spotty-playback` or **Spotty-owned** in Swift.

Product behavior belongs in the [product and acceptance contract](product-and-acceptance-contract.md);
hard-rule owners belong in the [enforcement inventory](architecture-enforcement.md).

## Swift (authoritative app state)

| Owner | Responsibility |
| --- | --- |
| `PlaybackState` / `PlaybackReducer` | Atomic presentation snapshot; stale/revision/epoch rejection |
| `PlaybackStore` / `PlaybackCoordinator` / `PlaybackEffectRegistry` | MainActor actions, serialized effects, task lifetimes |
| `QueueService` | Source precedence, context identity, Connect mutation snapshot |
| `QueueProtocolProjection` | Upcoming-rail rows from protocol `next` tracks; occurrence removal |
| `ConnectDeviceProjection` | Device-list activity, display sort, empty-type fallback |
| `ConnectionSnapshotProjection` | Connection session phase, empty-device-id fallback |
| `PlaybackSnapshotProjection` | Engine playback transport, empty-URI identity, timestamp correction |
| `ResumeLoadPlan` | Target order from sticky resume-load URIs for user resume and reconnect rehydration. `PlaybackStore` captures the URIs through engine getters; `RustPlaybackEngine` loads each target. During reconnect, the engine holds readiness behind `resume_pending` until a Swift load lands, reports `ERROR_NEEDS_REINIT`, or times out. |
| Catalog, OAuth, shuffle policy, HTTP retry | Application policy owned by Swift; these responsibilities do not belong in the engine |
| `AudioRenderer` | Native AVFoundation output for the bounded PCM callback from the retained Rust/librespot player; owns output buffering, backpressure, route changes, and renderer teardown |

## Rust crate by module

| Module | Classification | Notes |
| --- | --- | --- |
| `ffi.rs`, `runtime.rs` | Protocol/runtime adapter | Panic barrier, C string delivery, nested-runtime refusal |
| `proxy_sink.rs` | Protocol/runtime adapter | Librespot's decoded PCM to the bounded Swift audio callback; no UI state crosses this path |
| `session_lifecycle.rs` | Adapter | Serialized authorization, initialization exports, health checks, and reconnect orchestration. |
| `session_construction.rs` | Adapter | Transactional session/player/Spirc construction, publication, and rollback guards. |
| `engine_resources.rs` | Adapter | Shared resource extraction, graceful task shutdown, and cancellation-safe cleanup. |
| `credentials_cache.rs` | App policy | Streaming cache path selection, retired-directory cleanup, and logout cache clearing. |
| `lifecycle_serialization.rs` | Spotty-owned coordination that must stay with Rust globals | One async lifecycle mutex, reconnect unit outcomes, generation revalidation |
| `connect.rs` | Mixed | Dealer subscribe, hidden-member bootstrap PUT, and protobuf parse are protocol. Device-list and connection-snapshot presentation are Swift-owned. `cluster_offer_decision`, bootstrap-vs-push linearization, and `is_active_in_cluster` (this engine's Connect role) remain Rust-owned Connect logic. |
| `queue.rs` | Adapter | Forwards unfiltered `ProvidedTrack` rows and slim current-track identity as `SpottyQueueSnapshot`. Cluster protocol playback flags and `context_uri` cross separately as `SpottyPlaybackSnapshot`; local `PlayerEvent` playback snapshots send an empty context. Does **not** own delimiter hiding, upcoming presentation, or transport presentation. |
| `state.rs` | Mixed | Librespot object slots (`SESSION`, `SPIRC`, `PLAYER`, `MIXER`). Snapshot stamps and connection aggregation live here. Queue, connection, playback, and device-list observations use typed C snapshots. |
| `transport.rs` | Adapter | Seek-capable `load_at_position`, one-target `LoadRequest` construction, playing-event waits, and the reconnect rehydration window (`has_resume_identity`, `wait_for_rehydration`). Target order and capture are Swift-owned for user resume and reconnect alike. |
| `player_control.rs` | Adapter | Spirc play/pause/seek/shuffle/repeat/transfer/queue-add, plus FFI getters for sticky resume URIs |
| `player_event_pump.rs` | Adapter | Local `PlayerEvent` → position and protocol playing/paused bits when this device is active |
| `spirc_command_error.rs` | Adapter | Map librespot errors onto FFI codes Swift already understands |
| `librespot-connect` | Protocol/runtime dependency | The pinned upstream Connect implementation remains the engine's Connect owner; updates require protocol and license review |

## Retained-engine guarantees

The existing Rust/librespot boundary provides these guarantees:

- Spirc load and activation failures use typed outcomes. A closed command channel or failed
  rehydration returns the reinitialization outcome; the lifecycle owner rebuilds through the
  existing recovery path. A failed activation rolls back its staged generation before readiness is
  published.
- Session, mixer, player, Spirc, and listener tasks stay local until initialization succeeds. The
  generation commits all object slots and task handles together, and failed or superseded builds
  abort and join staged work. Teardown owns the stop, cancellation, join, and generation
  invalidation sequence. Spirc gets a bounded opportunity to finish gracefully; forced shutdown
  explicitly closes its Dealer connection before replacement.
- Definitive streaming-credential rejection uses the public error kind and the two exact AP
  rejection categories at the pinned revision. Librespot keeps the detailed AP error type private,
  so this narrow adapter comparison must be audited on dependency updates; general permission
  failures never qualify. A definitive rejection clears only the engine's streaming credential cache
  for the current generation, stops retrying that credential, and crosses as a typed
  `credentials_rejected` snapshot and a distinct initialization result. Swift stops launch restore
  on that result, preserves the independent Keymaster grant, and persists the reauthorization
  requirement with it. A fresh durably adopted grant clears the requirement; refresh-revoked grants
  are cleared only for their owning account generation.
- Playback and connection snapshots carry the protocol active-device fact with the observation.
  Swift derives ownership from that fact instead of depending on connection and playback callback
  arrival order.
- The retained snapshot ABI is represented in the checked-in C header and Rust `repr(C)` types, with
  symbol/signature fixtures and a C-consumer layout probe. Boundary strings normalize missing,
  empty, and interior-NUL values before Swift consumes a callback.

## FFI surface

Control observations for connection, playback, devices, and queue are typed C snapshots with
`revision` and `session_generation`:

- `SpottyConnectionSnapshot`: `session_connected`, `spirc_ready`, `is_active_device`,
  `resume_pending`, `credentials_rejected`, `device_id`, `last_error`.
- `SpottyPlaybackSnapshot`: protocol playing/paused flags, track URI, context URI, timing,
  shuffle/repeat options, and the active-device fact needed for coherent transport projection.
- `SpottyDevicesSnapshot`: protocol members (`id`, `name`, type name) plus `active_device_id`.
- `SpottyQueueSnapshot`: unfiltered protocol rows, slim current-track identity, `queue_revision`,
  and replacement-disallow flags.

Swift projects transport, session phase, device activity, and upcoming rows from these; Rust sends
no presentation copy. New fields should be typed payloads or rawer protocol rows, not Spotty-only
presentation.

`spotty_playback_get_queue_snapshot` returns the last cluster queue (freed with
`spotty_playback_free_queue_snapshot`) so Swift can recover after a provisional empty `SetQueue`.
It returns null when no cluster snapshot has been received yet; null means "not told anything",
which Swift must keep distinct from an empty queue.
Caching that snapshot in Rust is adapter convenience, not a second app-facing store.

The sticky resume-load identity remains internal to the Rust engine and is exposed only through the
existing narrow getters consumed by Swift's `ResumeLoadPlan`. There is no active Rust-to-Swift
migration plan.

## Standing constraints

- Keep PCM, Spirc, session connect, dealer cluster fetch, streaming, decryption, and decoding in
  the retained Rust/librespot engine. A boundary change requires a new ADR and explicit evidence.
- Rehydrate before announcing readiness. Bootstrapping from the Web API on readiness reopens the
  stale-position window the `resume_pending` hold exists to close.
- Do not reintroduce `device_name`, `reconnect_attempt`, `connected_since_ms`, or
  `session_connection_id` into `ConnectionState` or its snapshot; reconnect backoff stays
  loop-local.
- Do not widen `spotty_playback_resume`; resume targets are Swift-owned loads.
- Do not forward raw cluster protobuf to Swift or create a second protocol state machine.
- Keep the pinned librespot revision and its transitive license set deliberate; an update is a
  protocol migration review, not a routine dependency bump.

## Historical measured baseline (2026-08-23)

This predates the retained-engine cleanup. It is historical context, not a current performance
claim or migration gate. Any new comparison must record its commit and product surfaces.

Spotty 0.4.0 (4), optimized signed Release bundle, macOS 27.0 (26A5416b), Apple M1 Max, 32 GB.
Five `ps` samples at one-second intervals after the state stabilized; memory is RSS; foreground
and background are window open and closed in the same process.

| State | Window | Mean CPU | Mean RSS |
| --- | --- | ---: | ---: |
| Paused | Foreground | 0.0% | 256.20 MiB |
| Paused | Background | 0.0% | 254.83 MiB |
| Playing | Foreground | 28.58% | 262.65 MiB |
| Playing | Background | 20.80% | 262.39 MiB |

Renderer backpressure: of 1,971 one-millisecond playing observations, 1,935 were in the renderer's
deliberate producer sleep, with no allocator hotspot. A Core Media sample-buffer pool is not
warranted; the cursor-based renderer is the lower-risk design.

The measured browse path included surfaces that have since been removed. A rerun must record its
own commit and surfaces.

### Binary size

Every CI run's "Release distribution compile" job publishes a size table (app binary,
`libspotty_playback.a`, binary segment totals, archive exported symbol count) to the job
summary via `Scripts/report-size.sh`, and uploads the same data as the `size-report` artifact
(`size-report.json`, 30-day retention).

To compare two runs: `gh run view <run-id>` for the job summary, or
`gh run download <run-id> -n size-report` to fetch the JSON for a scripted diff.
