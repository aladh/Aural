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
empty `device_id` as missing. The hardcoded `device_name` ("Aural") is not sent: the
local display name is Swift-owned (`thisDeviceName`), and the Connect advertised name
still lives in `ConnectConfig` for protocol identity. `reconnect_attempt`,
`connected_since_ms`, and `session_connection_id` were write-only leftovers on
`ConnectionState` and are removed; reconnect backoff is a loop-local counter in
`session_lifecycle.rs`.

### Fourth slice

Playback-snapshot presentation is Swift-owned (`PlaybackSnapshotProjection`). The engine
snapshot carries protocol playing/paused flags, track URI, timing, and shuffle/repeat
options plus stamp fields. Swift derives transport (including the first-local-snapshot
suppression), treats an empty `track_uri` as missing, corrects playing positions from the
snapshot timestamp, and fills omitted repeat flags from the last accepted pair.
`is_paused` is a required decode field: a missing key must fail intake and keep the last
accepted snapshot. Local `PlayerEvent` still has one bit; Rust shapes that as the same
playing/paused pair.

### Fifth slice

Protocol `context_uri` is forwarded on engine playback snapshots (empty string means
missing; the key is required). Swift stores that as `PlaybackState.playbackContextURI`
and does not treat it as QueueService mutation identity. Empty-as-missing uses the same
URI helper as `track_uri`. Authoritative engine-playback samples adopt context; an
optimistic-play hold must not. Local `PlayerEvent` snapshots send an empty context: a
local event has no protocol context, and sticky `CURRENT_CONTEXT_URI` is resume-load
input only.

Resume-load target order and `LoadRequest` execution stay in Rust. `aural_playback_play_uri`
always seeks to 0, `aural_playback_resume` is not widened, and reconnect rehydration
calls `resume_via_load` without Swift.

### Sixth slice

User-initiated resume-load target order is Swift-owned (`ResumeLoadPlan`), captured from
sticky resume-load URIs (`CURRENT_CONTEXT_URI` / `CURRENT_TRACK_URI` / `RESUME_POSITION_MS`)
rather than presentation `playbackContextURI`. `aural_playback_resume` activates and
`play()`s only. On timeout, `RustPlaybackEngine` iterates Swift targets through
seek-capable `aural_playback_load`. Reconnect rehydration still calls `resume_via_load`
from the same session globals without Swift.

### Seventh slice

Connection observations cross FFI as `AuralConnectionSnapshot` rather than JSON. The
engine still sends session flags plus `device_id` and `last_error`; Swift copies the
struct in `PlaybackCore` and `ConnectionSnapshotProjection` remains the presentation
owner. Queue, playback, and device callbacks stay JSON.

## Consequences

- Upcoming-queue UI and `QueueService.acceptConnect` entries come from one Swift
  projection. Mutation snapshots still need the unfiltered protocol lists for `set_queue`.
- Device-list activity, display sort, and empty-type fallback come from one Swift
  projection. Rust still uses `is_active_in_cluster` for this engine's Connect role.
- Engine JSON fixtures pin the remaining slimmer envelopes (queue, playback, devices).
  Older check JSON may still include optional current-track labels or Web API device
  fields; production Connect callbacks do not. Connection observations are a typed C
  snapshot, not a JSON fixture.
- Connection session phase and empty-device-id handling come from one Swift projection.
  Local display name is Swift-owned. Reconnect backoff is a loop-local counter in
  `session_lifecycle.rs`, not a `ConnectionState` field. The connection callback is a typed
  C snapshot, not JSON.
- Engine playback transport, empty-track-URI identity, and timestamp correction come from
  one Swift projection. Rust still forwards protocol playing/paused bits (and shapes local
  `PlayerEvent` as that pair). Protocol `context_uri` is forwarded as playlist/album/artist
  identity on cluster snapshots. Local player-event snapshots send an empty context.
- Resume-load target order for user resume comes from Swift `ResumeLoadPlan` issued through
  `aural_playback_load`, using sticky resume-load URIs rather than presentation context.
  Reconnect rehydration still loads from session globals in the engine.
- Cluster apply and session reconnect remain in Rust until a later slice can forward
  protocol observations without duplicating protobuf ownership in Swift.
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

### Keep resume-load target order only in Swift without a load caller

Rejected in the fifth slice. This slice adds `aural_playback_load` so user resume can
iterate Swift targets. Reconnect rehydration still uses the engine-side plan.

### Widen `aural_playback_resume` with URIs and a seek position

Rejected for this slice. That would expand the C ABI before a tighter payload exists
and would still leave playing-event waits and reconnect rehydration in the engine.

### Keep connection snapshots as JSON until every callback moves together

Rejected. Connection was the smallest remaining envelope and already had a production
callback. A typed C struct shrinks that FFI surface without waiting on queue, playback,
or device payloads.

### Keep reconnect bookkeeping on the connection snapshot “for compatibility”

Rejected. Swift never decoded `reconnect_attempt`, `connected_since_ms`, or
`session_connection_id`. They were write-only in Rust as well (backoff is a loop-local
counter), so they were deleted from `ConnectionState`. The hardcoded `device_name`
overwrote Swift's local label.
