# ADR 004: Move Spotty-owned playback logic into Swift incrementally

Status: accepted on 2026-09-02. Revisit is gated by #201.

Like all of Spotty, this decision concerns an unofficial, independent, experimental client with no
affiliation with Spotify AB, built on reverse-engineered Spotify interfaces.

## Context

[ADR 001](ADR-001-playback-engine.md) keeps librespot behind a narrow boundary. The leaf also
accumulated Spotty-owned orchestration: queue presentation filtering, snapshot envelopes shaped
for the UI, device-list projections, resume fallback sequencing, and generation gates used to
coordinate app state across the C boundary. A big-bang rewrite would put live Connect correctness
at risk, so application policy moves to Swift one owner at a time.

## Decision

- `SpottyDomain.PlaybackState` remains the authoritative app-facing playback snapshot, with
  `PlaybackReducer` as its only mutation entrance
  ([ADR 002](ADR-002-playback-state-and-dependencies.md)).
- Rust remains a protocol/runtime adapter: session, Spirc, cluster subscribe/bootstrap, PCM
  decode, reconnection that rebuilds librespot objects, and panic-barrier FFI.
- When a projection exists only to cross the FFI boundary, prefer typed Swift models and shrink
  the envelope instead of keeping a second presentation copy in Rust.
- Keep behavior-preserving seams. Port one coherent owner at a time and move its deterministic
  checks with it.

## Consequences

All four observation callbacks (connection, playback, device list, queue) cross FFI as typed C
snapshots. Presentation and resume/rehydration policy are Swift-owned; the engine forwards
protocol rows and flags and holds readiness open behind `resume_pending` while Swift's reconnect
loads run. The live classification of each Rust module, the FFI surface, and the planned owner
per #201 stage live in [playback engine ownership](playback-engine-ownership.md). ADR 001 is not
superseded: the boundary rule applies to whatever remains in the leaf.

## Options considered

- Rewrite the engine in Swift: deferred to #201.
- Forward raw cluster protobuf to Swift immediately: deferred. It would expand the ABI and require
  Swift protobuf models of Connect state in one step.
