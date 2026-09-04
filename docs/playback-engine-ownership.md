# Playback engine ownership

Working inventory for [ADR 004](ADR-004-swift-owned-playback-logic.md). Classify logic as
**librespot/protocol** (stays in `Backend/spotty-playback` unless a later slice forwards a
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
| `ResumeLoadPlan` | Resume-load target order from sticky resume-load URIs, for user resume and reconnect rehydration. `PlaybackStore` captures those URIs through the engine getters; `RustPlaybackEngine` iterates targets through `spotty_playback_load`. The engine signals a reconnect window with `resume_pending` and holds readiness until a Swift load lands, a load reports `ERROR_NEEDS_REINIT` (dead Spirc, which ends the wait for that window and triggers a rebuild), or the window times out |
| Catalog, OAuth, shuffle policy, HTTP retry | Unchanged; never belonged in Rust |
| `SpotifyAudioFormat` / `SpotifyAudioHeader` | Stage 1 building block (#208): librespot audio-file format tags and the fixed-size normalisation-gain header prefix. Used by `SpotifyTrackByteSource` on the default-off Swift audio path |
| `StorageResolveResponse` / `CDNURLExpiry` | Stage 1 building block (#208): storage-resolve protobuf decoding and librespot's CDN-URL expiry heuristics. Used by `StorageResolveClient` |
| `AESCTRDecryptor` | Stage 1 building block (#208): AES-128-CTR decryption with Spotify's fixed IV and seekable byte-offset counter arithmetic. Used by `SpotifyTrackByteSource` |
| `RangedAudioFetcher` | Stage 1 building block (#208): ranged CDN download with a sparse downloaded-byte store, 429/403 handling, and read-ahead prefetch. Used by `SpotifyTrackByteSource` |
| `OggVorbisDecoder` / `OggPageHeader` | Stage 1 of #201: a Swift wrapper over vendored stb_vorbis's pushdata API, plus a pure Ogg page scanner. Driven by `VorbisDecodePipeline` on the default-off Swift audio path; the shipped path still gets PCM from `proxy_sink.rs` |
| `VorbisDecodePipeline` | Stage 1 of #201, slice 2b (#208): drives `OggVorbisDecoder` from a `DecodeByteSource` to a `PCMSink` on a dedicated thread, pacing on the sink's backpressure and reporting playing/position/seeked/endOfTrack/stopped/failed. Failures are `AudioPipelineFailure`, never a raw error (a CDN-backed source's errors can embed signed URLs). `SwiftAudioPath` constructs and drives it when the debug switch is on |
| `DecodeByteSource` (`Sources/Spotty/Spotify`) | The pipeline's input seam: a synchronous, random-access byte-range read over one decrypted track. Synchronous because the decode thread exists precisely so it is free to block. `SpotifyTrackByteSource` is the production adapter; checks use a fake |
| `PCMSink` (`Sources/Spotty/Spotify`) | The pipeline's output seam: a cancellable, blocking `write(_:frames:until:)` plus `flush`/`bufferedSeconds`. `AudioRenderer` conforms via a small extension, backed by a `write(_:frames:until:)` that shares its ring/throttle with `writeAudioData` but waits instead of dropping. Checks use a fake |
| `OggSeeker` | Stage 1 of #201: pure time-to-byte-offset seek — bisects Ogg pages by granule position. `SwiftAudioPath` adapts `SpotifyTrackByteSource` as the `OggByteReader` |
| `AudioPlaybackSession` | Stage 1 of #201: pure reducer for the `ShimPlayer` audio-command boundary. Turns forwarded `Load/Play/Pause/Seek/Stop/Preload` commands and decode-pipeline events into effects — command and generation-reset teardown (`.stop`/`.cancelPreload` for any live pipeline or held preload), preload-file-id reuse vs. cancellation, transport commands honored while still `.loading`, seek clamping, a once-per-load `timeToPreloadNext` threshold, and pipeline events scoped by `sessionGeneration`/`playRequestID` so a stale delivery can never resurrect a torn-down load. Driven by `SwiftAudioPath` |
| `SwiftAudioPath` | Stage 1 of #201, slice 3c (#219): drives `AudioPlaybackSession` from the forwarded audio commands and turns its effects into work — audio key, storage-resolve, ranged CDN fetch, AES-CTR decrypt, Ogg seek, `VorbisDecodePipeline` into `AudioRenderer` — feeding pipeline events back through the reducer and sending reports through `spotty_playback_report_audio`. One mailbox, one consumer, so commands and pipeline events never reorder |
| `SpotifyTrackByteSource` / `SpotifyAudioSourceProvider` | The decrypted byte source behind one track (`DecodeByteSource` + read-ahead + whole-file download for the `TimeToPreloadNext` gate), and the audio-key/storage-resolve/fetcher assembly that builds it. The key is cached per file id and never retried in a loop |
| `StorageResolveClient` | The signed spclient `storage-resolve` request; decoding and CDN-URL expiry policy stay pure in `StorageResolveResponse`/`CDNURLExpiry` |
| `AudioPipelineEvent` / `AudioPipelineFailure` | The one decode-pipeline event type both `VorbisDecodePipeline` and `AudioPlaybackSession` use. Failures are a closed set, never a stringified error, so a signed CDN URL cannot reach logs, the UI, or Connect |
| `SwiftAudioPathSwitch` | Debug-only, default-off gate for the whole Swift audio path (`SpottySwiftAudioPath`). Registering the audio-command callback is what selects `ShimPlayer` over librespot's `Player`, so leaving it off keeps `main` on the shipped `proxy_sink` path |

## Rust crate by module

| Module | Classification | Notes |
| --- | --- | --- |
| `ffi.rs`, `runtime.rs` | Protocol/runtime adapter | Panic barrier, C string delivery, nested-runtime refusal |
| `proxy_sink.rs` | Protocol/runtime adapter | PCM to Swift audio callback; not UI state |
| `audio_shim.rs` | Mixed | `ShimPlayer` implements the vendored `SpircPlayer` trait: play-request ids, file resolution (format preference, alternatives, explicit filter) and the `PlayerEvent` stream stay librespot-shaped; what to play and when is forwarded to Swift |
| `audio_command_sink.rs` | Protocol/runtime adapter | The `SpottyAudioCommand` snapshot out and `spotty_playback_report_audio` in. Registering the callback before init is the switch that selects `ShimPlayer` |
| `session_lifecycle.rs` | Mixed | AP connect and credential cache are librespot. Path policy and logout cache wipe are Spotty-owned but must run next to the cache. Streaming grant completion stays here because only librespot performs AP login. |
| `lifecycle_serialization.rs` | Spotty-owned coordination that must stay with Rust globals | One async lifecycle mutex, reconnect unit outcomes, generation revalidation |
| `connect.rs` | Mixed | Dealer subscribe, hidden-member bootstrap PUT, and protobuf parse are protocol. Device-list and connection-snapshot presentation are Swift-owned. `cluster_offer_decision`, bootstrap-vs-push linearization, and `is_active_in_cluster` (this engine's Connect role) stay until cluster observations can cross the boundary without a second protobuf stack. |
| `queue.rs` | Adapter | Forwards unfiltered `ProvidedTrack` rows and slim current-track identity as `SpottyQueueSnapshot`. Cluster protocol playback flags and `context_uri` cross separately as `SpottyPlaybackSnapshot`; local `PlayerEvent` playback snapshots send an empty context. Does **not** own delimiter hiding, upcoming presentation, or transport presentation. |
| `state.rs` | Mixed | Librespot object slots (`SESSION`, `SPIRC`, `PLAYER`, `MIXER`). Snapshot stamps and connection aggregation live here. Queue, connection, playback, and device-list observations use typed C snapshots. |
| `transport.rs` | Adapter | Seek-capable `load_at_position`, one-target `LoadRequest` construction, playing-event waits, and the reconnect rehydration window (`has_resume_identity`, `wait_for_rehydration`). Target order and capture are Swift-owned for user resume and reconnect alike. |
| `player_control.rs` | Adapter | Spirc play/pause/seek/shuffle/repeat/transfer/queue-add, plus FFI getters for sticky resume URIs |
| `player_event_pump.rs` | Adapter | Local `PlayerEvent` → position and protocol playing/paused bits when this device is active |
| `spirc_command_error.rs` | Adapter | Map librespot errors onto FFI codes Swift already understands |
| `Backend/vendor/librespot-connect` | Vendored third-party, patched | librespot's `connect` crate pinned to the same rev as the git dependencies, patched so `Spirc::new` takes `Arc<dyn SpircPlayer>` instead of the concrete `Arc<Player>`. See its `PATCHES.md` for the exact diff. This is the seam Stage 1 needs to drive playback through a Swift-owned player without forking `Spirc`/`SpircTask`. |
| `audio_key.rs` | Adapter | Stage 1 (#208) AP audio-key request over FFI. `SpotifyAudioSourceProvider` is the caller: it caches successes per file id and never retries a failure in a loop |

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

- `SpottyConnectionSnapshot`: `session_connected`, `spirc_ready`, `is_active_device`,
  `resume_pending`, `device_id`, `last_error`.
- `SpottyPlaybackSnapshot`: protocol playing/paused flags, track URI, context URI (empty on local
  player-event snapshots), timing, and shuffle/repeat options.
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

`spotty_playback_audio_key` fetches one file's AES decryption key over the existing AP session.
`SpotifyAudioSourceProvider` is the Stage 1 caller: it caches successes per file id and never
retries a failure in a loop, because Spotify throttles key requests.

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
- Do not widen `spotty_playback_resume`; resume targets are Swift-owned loads.
- Do not forward raw cluster protobuf to Swift ahead of a stage that owns the models.
- `Vendor/stb_vorbis` is the only vendored C in this repo (the `CVorbis` SwiftPM target). It is
  pinned to an exact upstream commit in `Vendor/stb_vorbis/UPSTREAM.md`; refresh the pin there
  rather than editing `stb_vorbis.c` in place.

## Measured baseline (2026-08-23)

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

The browse path behind these numbers included surfaces that have since been removed, so a rerun
must record its own commit and surfaces. #201 requires re-measurement at each stage boundary.

### Binary size

Every CI run's "Release distribution compile" job publishes a size table (app binary,
`libspotty_playback.a`, binary segment totals, archive exported symbol count) to the job
summary via `Scripts/report-size.sh`, and uploads the same data as the `size-report` artifact
(`size-report.json`, 30-day retention).

To compare two runs: `gh run view <run-id>` for the job summary, or
`gh run download <run-id> -n size-report` to fetch the JSON for a scripted diff.

Pre-Stage-1 reference: fill in run id at switchover.
