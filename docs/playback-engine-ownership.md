# Playback engine ownership

Working inventory for [ADR 004](ADR-004-swift-owned-playback-logic.md). Classify logic as
**librespot/protocol** (stays in `Backend/aural-playback` unless a later slice forwards a
rawer observation) or **Spotty-owned** (must live in Swift when practical).

This is not a second architecture manual. Product behavior stays in the
[product and acceptance contract](product-and-acceptance-contract.md). Hard-rule owners stay
in the [enforcement inventory](architecture-enforcement.md).

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
| `ResumeLoadPlan` | User-resume load target order from sticky resume-load URIs. `PlaybackStore` captures those URIs; `RustPlaybackEngine` iterates targets through `aural_playback_load`. Reconnect rehydration still uses the engine plan |
| Catalog, OAuth, shuffle policy, HTTP retry | Unchanged; never belonged in Rust |

## Rust crate by module

| Module | Classification | Notes |
| --- | --- | --- |
| `ffi.rs`, `runtime.rs` | Protocol/runtime adapter | Panic barrier, C string/JSON delivery, nested-runtime refusal |
| `proxy_sink.rs` | Protocol/runtime adapter | PCM to Swift audio callback; not UI state |
| `session_lifecycle.rs` | Mixed | AP connect and credential cache are librespot. Path policy and logout cache wipe are Spotty-owned but must run next to the cache. Streaming grant completion stays here because only librespot performs AP login. |
| `lifecycle_serialization.rs` | Spotty-owned coordination that must stay with Rust globals | One async lifecycle mutex, reconnect unit outcomes, generation revalidation |
| `connect.rs` | Mixed | Dealer subscribe, hidden-member bootstrap PUT, and protobuf parse are protocol. Device-list and connection-snapshot presentation are Swift-owned. `cluster_offer_decision`, bootstrap-vs-push linearization, and `is_active_in_cluster` (this engine's Connect role) stay until cluster observations can cross the boundary without a second protobuf stack. |
| `queue.rs` | Adapter after this slice | Serializes unfiltered `ProvidedTrack` rows, slim current-track identity, protocol playback flags, and protocol `context_uri` on cluster snapshots. Local `PlayerEvent` playback snapshots send an empty context. Does **not** own delimiter hiding, upcoming presentation, or transport presentation. |
| `state.rs` | Mixed | Librespot object slots (`SESSION`, `SPIRC`, `PLAYER`, `MIXER`). Snapshot stamps and connection aggregation live here. Remaining JSON DTOs exist to cross FFI for queue; connection, playback, and device-list observations use typed C snapshots. |
| `transport.rs` | Mixed | Reconnect `ResumeLoadPlan` / `resume_via_load`, playing-event waits, and seek-capable `load_at_position` stay here. User-resume capture and target iteration are Swift-owned. |
| `player_control.rs` | Adapter | Spirc play/pause/seek/shuffle/repeat/transfer/queue-add, plus FFI getters for sticky resume URIs |
| `player_event_pump.rs` | Adapter | Local `PlayerEvent` → position and protocol playing/paused bits when this device is active |
| `spirc_command_error.rs` | Adapter | Map librespot errors onto FFI codes Swift already understands |

## JSON / FFI surface

Remaining control callbacks for queue are JSON envelopes with
`revision` and `session_generation`. Connection observations use a typed C snapshot
(`AuralConnectionSnapshot`) with the same stamps plus session flags, `device_id`, and
`last_error`. Playback observations use `AuralPlaybackSnapshot` with protocol
playing/paused flags, URIs, timing, and options. Device-list observations use
`AuralDevicesSnapshot` with protocol members plus `active_device_id`. Queue snapshots no longer carry presentation `next_tracks` / `prev_tracks` or catalog
labels. Device snapshots no longer carry `is_active` or unused Web API volume/restriction
fields; they send protocol members plus `active_device_id`. Playback snapshots send protocol
playing/paused flags, track URI, context URI, timing, and options; Swift projects transport.
Local player-event snapshots send an empty `context_uri`. Hardcoded `device_name` is gone, and
write-only `reconnect_attempt`, `connected_since_ms`, and `session_connection_id` were removed
from `ConnectionState`. Later slices should prefer typed payloads or rawer protocol rows over
new Spotty-only fields.

`aural_playback_get_queue_snapshot` still returns the last serialized cluster queue so
Swift can recover after a provisional empty `SetQueue`. Caching that JSON in Rust is
adapter convenience, not a second app-facing store.

## Later slices (not this change)

- Replacing the remaining queue JSON callback (and `aural_playback_get_queue_snapshot`)
  with a tighter ABI
- Moving reconnect rehydration loads onto Swift targets without duplicating session globals
  (reconnect must still rehydrate before announcing readiness)

Do not move PCM, Spirc, session connect, or dealer cluster fetch into Swift in order to
satisfy this inventory.
