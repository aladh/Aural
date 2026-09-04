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
| `ResumeLoadPlan` | Resume-load target order from sticky resume-load URIs, for user resume and reconnect rehydration. `PlaybackStore` captures those URIs through the engine getters; `RustPlaybackEngine` iterates targets through `aural_playback_load`. The engine signals a reconnect window with `resume_pending` and holds readiness until a Swift load lands, a load reports `ERROR_NEEDS_REINIT` (dead Spirc, which ends the wait for that window and triggers a rebuild), or the window times out |
| Catalog, OAuth, shuffle policy, HTTP retry | Unchanged; never belonged in Rust |
| `OggVorbisDecoder` / `OggPageHeader` | Stage 1 of #201: a Swift wrapper over vendored stb_vorbis's pushdata API, plus a pure Ogg page scanner for later seeking. Not yet wired into playback — the audio-key/CDN/decrypt path and `AudioRenderer` still get PCM from `proxy_sink.rs` |
| `AudioPlaybackSession` | Stage 1 of #201: pure reducer for the future `ShimPlayer` audio-command boundary. Turns forwarded `Load/Play/Pause/Seek/Stop/Preload` commands and decode-pipeline events into effects — staleness/generation-reset handling, preload-file-id reuse, seek clamping, and a once-per-load `timeToPreloadNext` threshold. Not yet wired to any FFI; there is no `ShimPlayer`, audio-command callback, or `aural_playback_report_audio` yet |

## Rust crate by module

| Module | Classification | Notes |
| --- | --- | --- |
| `ffi.rs`, `runtime.rs` | Protocol/runtime adapter | Panic barrier, C string delivery, nested-runtime refusal |
| `proxy_sink.rs` | Protocol/runtime adapter | PCM to Swift audio callback; not UI state |
| `session_lifecycle.rs` | Mixed | AP connect and credential cache are librespot. Path policy and logout cache wipe are Spotty-owned but must run next to the cache. Streaming grant completion stays here because only librespot performs AP login. |
| `lifecycle_serialization.rs` | Spotty-owned coordination that must stay with Rust globals | One async lifecycle mutex, reconnect unit outcomes, generation revalidation |
| `connect.rs` | Mixed | Dealer subscribe, hidden-member bootstrap PUT, and protobuf parse are protocol. Device-list and connection-snapshot presentation are Swift-owned. `cluster_offer_decision`, bootstrap-vs-push linearization, and `is_active_in_cluster` (this engine's Connect role) stay until cluster observations can cross the boundary without a second protobuf stack. |
| `queue.rs` | Adapter | Forwards unfiltered `ProvidedTrack` rows, slim current-track identity, protocol playback flags, and protocol `context_uri` on cluster snapshots as a typed C queue snapshot. Local `PlayerEvent` playback snapshots send an empty context. Does **not** own delimiter hiding, upcoming presentation, or transport presentation. |
| `state.rs` | Mixed | Librespot object slots (`SESSION`, `SPIRC`, `PLAYER`, `MIXER`). Snapshot stamps and connection aggregation live here. Queue, connection, playback, and device-list observations use typed C snapshots. |
| `transport.rs` | Adapter | Seek-capable `load_at_position`, one-target `LoadRequest` construction, playing-event waits, and the reconnect rehydration window (`has_resume_identity`, `wait_for_rehydration`). Target order and capture are Swift-owned for user resume and reconnect alike. |
| `player_control.rs` | Adapter | Spirc play/pause/seek/shuffle/repeat/transfer/queue-add, plus FFI getters for sticky resume URIs |
| `player_event_pump.rs` | Adapter | Local `PlayerEvent` → position and protocol playing/paused bits when this device is active |
| `spirc_command_error.rs` | Adapter | Map librespot errors onto FFI codes Swift already understands |
| `audio_key.rs` | Adapter | Stage 1 (#208) AP audio-key request over FFI. No caller yet; the consumer must cache successes per file id and coalesce concurrent misses |

### Planned owner per #201 stage

- Stage 1 (audio path): audio-key request, CDN fetch, decrypt, and Vorbis decode move to Swift
  and feed `AudioRenderer`; `proxy_sink.rs` and the PCM callback retire. The #159 spike decides
  go/no-go.
- Stage 2 (session): AP resolve, handshake, login, and credential cache move to Swift;
  `session_lifecycle.rs` and `lifecycle_serialization.rs` shrink to what Spirc still needs.
- Stage 3 (Spirc): dealer, cluster, transfer, and `set_queue` move to Swift once synthetic,
  non-account-derived protocol fixtures for transfer, remote pause, `set_queue`, and cluster
  bootstrap exist (test-only; never captured account payloads, per the root `AGENTS.md`); the
  remaining modules, the C ABI, and `Backend/` retire.

Each stage lands as its own issue and re-measures the baseline below.

## FFI surface

Control observations for connection, playback, devices, and queue are typed C snapshots with
`revision` and `session_generation`:

- `AuralConnectionSnapshot`: `session_connected`, `spirc_ready`, `is_active_device`,
  `resume_pending`, `device_id`, `last_error`.
- `AuralPlaybackSnapshot`: protocol playing/paused flags, track URI, context URI (empty on local
  player-event snapshots), timing, and shuffle/repeat options.
- `AuralDevicesSnapshot`: protocol members (`id`, `name`, type name) plus `active_device_id`.
- `AuralQueueSnapshot`: unfiltered protocol rows, slim current-track identity, `queue_revision`,
  and replacement-disallow flags.

Swift projects transport, session phase, device activity, and upcoming rows from these; Rust sends
no presentation copy. New fields should be typed payloads or rawer protocol rows, not Spotty-only
presentation.

`aural_playback_get_queue_snapshot` returns the last cluster queue (freed with
`aural_playback_free_queue_snapshot`) so Swift can recover after a provisional empty `SetQueue`.
It returns null when no cluster snapshot has been received yet; null means "not told anything",
which Swift must keep distinct from an empty queue.
Caching that snapshot in Rust is adapter convenience, not a second app-facing store.

`aural_playback_audio_key` fetches one file's AES decryption key over the existing AP session;
it is Stage 1 scaffolding for #201/#208 and nothing calls it yet. Spotify throttles key requests,
so the eventual consumer must cache successes per file id and coalesce concurrent misses.

## Remaining Spotty-owned logic in Rust

- Moving the sticky resume-load globals (`CURRENT_CONTEXT_URI`, `CURRENT_TRACK_URI`,
  `RESUME_POSITION_MS`) to Swift, which would retire the three resume getters and the
  engine's `has_resume_identity` check

## Standing constraints

- Do not move PCM, Spirc, session connect, or dealer cluster fetch into Swift to satisfy a slice
  of this inventory. Only a measured #201 stage issue, with its go/no-go recorded, may move them.
- Rehydrate before announcing readiness. Bootstrapping from the Web API on readiness reopens the
  stale-position window the `resume_pending` hold exists to close.
- Do not reintroduce `device_name`, `reconnect_attempt`, `connected_since_ms`, or
  `session_connection_id` into `ConnectionState` or its snapshot; reconnect backoff stays
  loop-local.
- Do not widen `aural_playback_resume`; resume targets are Swift-owned loads.
- Do not forward raw cluster protobuf to Swift ahead of a stage that owns the models.
- `Vendor/stb_vorbis` is the only vendored C in this repo (the `CVorbis` SwiftPM target). It is
  pinned to an exact upstream commit in `Vendor/stb_vorbis/UPSTREAM.md`; refresh the pin there
  rather than editing `stb_vorbis.c` in place.

## Measured baseline (2026-08-23)

Aural 0.4.0 (4), optimized signed Release bundle, macOS 27.0 (26A5416b), Apple M1 Max, 32 GB.
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

The browse path behind these numbers included surfaces that have since been removed, so a rerun
must record its own commit and surfaces. #201 requires re-measurement at each stage boundary.
