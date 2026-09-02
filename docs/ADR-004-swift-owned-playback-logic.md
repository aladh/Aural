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

### First slice (this change)

Queue presentation already had a Swift owner: `QueueProtocolProjection` (delimiter hiding,
playable-track filtering, occurrence rows). Rust no longer sends duplicate
`next_tracks` / `prev_tracks` arrays or catalog labels on the current-track identity. The
engine snapshot carries unfiltered protocol tracks plus slim current-track identity
(`uri`, `provider`, `uid`). Swift derives the upcoming rail from protocol `next` tracks.

## Consequences

- Upcoming-queue UI and `QueueService.acceptConnect` entries come from one Swift
  projection. Mutation snapshots still need the unfiltered protocol lists for `set_queue`.
- Engine JSON fixtures pin the slimmer envelope. Older check JSON may still include
  optional current-track labels; production Connect callbacks do not.
- Cluster apply, resume-load fallbacks, Connect device mapping, and session reconnect
  remain in Rust until a later slice can forward protocol observations without duplicating
  protobuf ownership in Swift.
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
