# Playback engine ownership

Working inventory for [ADR 004](ADR-004-swift-owned-playback-logic.md). Classify logic as
**librespot/protocol** (stays in `Backend/aural-playback` unless a later slice forwards a
rawer observation) or **Aural-owned** (must live in Swift when practical).

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
| Catalog, OAuth, shuffle policy, HTTP retry | Unchanged; never belonged in Rust |

## Rust crate by module

| Module | Classification | Notes |
| --- | --- | --- |
| `ffi.rs`, `runtime.rs` | Protocol/runtime adapter | Panic barrier, C string/JSON delivery, nested-runtime refusal |
| `proxy_sink.rs` | Protocol/runtime adapter | PCM to Swift audio callback; not UI state |
| `session_lifecycle.rs` | Mixed | AP connect and credential cache are librespot. Path policy and logout cache wipe are Aural-owned but must run next to the cache. Streaming grant completion stays here because only librespot performs AP login. |
| `lifecycle_serialization.rs` | Aural-owned coordination that must stay with Rust globals | One async lifecycle mutex, reconnect unit outcomes, generation revalidation |
| `connect.rs` | Mixed | Dealer subscribe, hidden-member bootstrap PUT, and protobuf parse are protocol. Device-list presentation is Swift-owned. `cluster_offer_decision`, bootstrap-vs-push linearization, and `is_active_in_cluster` (this engine's Connect role) stay until cluster observations can cross the boundary without a second protobuf stack. |
| `queue.rs` | Adapter after this slice | Serializes unfiltered `ProvidedTrack` rows and slim current-track identity. Does **not** own delimiter hiding or upcoming presentation. |
| `state.rs` | Mixed | Librespot object slots (`SESSION`, `SPIRC`, `PLAYER`, `MIXER`). Snapshot stamps, connection aggregation, and JSON DTOs exist to cross FFI. |
| `transport.rs` | Aural-owned sequencing over protocol commands | `ResumeLoadPlan` and playing-event waits; `LoadRequest` construction is protocol |
| `player_control.rs` | Adapter | Spirc play/pause/seek/shuffle/repeat/transfer/queue-add |
| `player_event_pump.rs` | Adapter | Local `PlayerEvent` → position and playback snapshots when this device is active |
| `spirc_command_error.rs` | Adapter | Map librespot errors onto FFI codes Swift already understands |

## JSON / FFI surface

Remaining control callbacks are JSON envelopes with `revision` and `session_generation`.
Queue snapshots no longer carry presentation `next_tracks` / `prev_tracks` or catalog
labels. Device snapshots no longer carry `is_active` or unused Web API volume/restriction
fields; they send protocol members plus `active_device_id`. Later slices should prefer
typed payloads or rawer protocol rows over new Aural-only fields.

`aural_playback_get_queue_snapshot` still returns the last serialized cluster queue so
Swift can recover after a provisional empty `SetQueue`. Caching that JSON in Rust is
adapter convenience, not a second app-facing store.

## Later slices (not this change)

- Resume-load fallback policy, if Swift can name load targets without a wider FFI
- Connection snapshot assembly, if Swift can own presentation of reconnect attempts
- Replacing JSON callbacks with a tighter ABI

Do not move PCM, Spirc, session connect, or dealer cluster fetch into Swift in order to
satisfy this inventory.
