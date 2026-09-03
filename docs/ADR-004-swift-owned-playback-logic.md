# ADR 004: Move Aural-owned playback logic into Swift incrementally

Status: accepted on 2026-09-02

Like all of Aural, this decision concerns an unofficial, experimental client built on
reverse-engineered Spotify interfaces.

## Context

[ADR 001](ADR-001-playback-engine.md) keeps librespot as a contained playback leaf. The leaf
also accumulated Aural-owned orchestration: queue presentation filtering, snapshot JSON
shaped for the UI, device-list projections, resume fallback sequencing, and generation
gates used to coordinate app state across a C/JSON boundary.

[Issue #157](https://github.com/aladh/Aural/issues/157) asks to leave Rust responsible for
Spotify/librespot protocol work that is hard to replace, and to move application policy into
Swift. A big-bang rewrite would put live Connect correctness at risk.

## Decision

Migrate Aural-owned playback responsibilities into Swift incrementally, without reimplementing
Spotify's private protocol and without removing librespot.

- `AuralDomain.PlaybackState` remains the authoritative app-facing playback snapshot, with
  `PlaybackReducer` as its only mutation entrance ([ADR 002](ADR-002-playback-state-and-dependencies.md)).
- Rust remains a protocol/runtime adapter: session, Spirc, cluster subscribe/bootstrap, PCM
  decode, reconnection that rebuilds librespot objects, and panic-barrier FFI.
- When a projection exists only to cross the FFI boundary, prefer typed Swift models and
  shrink the JSON envelope instead of keeping a second presentation copy in Rust.
- Keep behavior-preserving seams. Port one coherent owner at a time and move its
  deterministic checks with it.

The live classification of each Rust module lives in
[Playback engine ownership](playback-engine-ownership.md). That inventory is the working
checklist for later slices; this record is the ownership rule.

### First slice

Queue presentation already had a Swift owner: `QueueProtocolProjection` (delimiter hiding,
playable-track filtering, occurrence rows). Rust no longer sends duplicate
`next_tracks` / `prev_tracks` arrays or catalog labels on the current-track identity. The
engine snapshot carries unfiltered protocol tracks plus slim current-track identity
(`uri`, `provider`, `uid`). Swift derives the upcoming rail from protocol `next` tracks.

### Second slice

Device-list presentation is Swift-owned (`ConnectDeviceProjection`). The engine snapshot
carries unfiltered cluster members (`id`, `name`, protobuf type name) plus
`active_device_id`. Swift derives activity, sorts for display, and maps an empty type to
`UNKNOWN`. Unused Web API leftovers (`volume_percent`, `disable_volume`, `is_restricted`,
`is_private_session`) are not sent: Aural has no in-app volume control, and nothing
read those fields. Rust still uses `is_active_in_cluster` for this engine's Connect role.

### Third slice

Connection-snapshot presentation is Swift-owned (`ConnectionSnapshotProjection`). The engine
snapshot carries session flags (`session_connected`, `spirc_ready`, `is_active_device`,
`device_id`, `last_error`) plus stamp fields. Swift derives session phase and treats an
empty `device_id` as missing. Unused reconnect bookkeeping (`reconnect_attempt`,
`connected_since_ms`, `session_connection_id`) and the hardcoded `device_name` ("Aural")
are not sent: the local display name is Swift-owned (`thisDeviceName`), and the Connect
advertised name still lives in `ConnectConfig` for protocol identity.

## Consequences

- Upcoming-queue UI and `QueueService.acceptConnect` entries come from one Swift
  projection. Mutation snapshots still need the unfiltered protocol lists for `set_queue`.
- Device-list activity, display sort, and empty-type fallback come from one Swift
  projection. Rust still uses `is_active_in_cluster` for this engine's Connect role.
- Engine JSON fixtures pin the slimmer envelopes. Older check JSON may still include
  optional current-track labels or Web API device fields; production Connect callbacks do not.
- Connection session phase and empty-device-id handling come from one Swift projection.
  Local display name is Swift-owned. Reconnect backoff still uses Rust-internal
  `ConnectionState` fields that are not on the FFI snapshot.
- Cluster apply, resume-load fallbacks, and session reconnect remain in Rust until a later
  slice can forward protocol observations without duplicating protobuf ownership in Swift.
- [ADR 001](ADR-001-playback-engine.md) is not superseded: the C leaf and librespot stay.

## Options considered

### Rewrite the engine in Swift

Rejected. There is still no maintained Swift Connect/audio engine. See ADR 001.

### Forward raw cluster protobuf to Swift immediately

Deferred. It would expand the ABI and require Swift protobuf models of Connect state in
one step. Queue presentation could move without that.

### Keep duplicate presentation arrays “for compatibility”

Rejected. Two lists of the same queue invite drift. Swift already had the projection used
for occurrence-safe removal.

### Keep Web API-shaped device rows “for compatibility”

Rejected. Nothing read volume or restriction fields. Activity belongs next to the cluster's
`active_device_id`, not as a second copy on each member.

### Keep reconnect bookkeeping on the connection snapshot “for compatibility”

Rejected. Swift never decoded `reconnect_attempt`, `connected_since_ms`, or
`session_connection_id`. The hardcoded `device_name` overwrote Swift's local label.
