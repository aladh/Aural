# AuralDomain agent guidance

`AuralDomain` is the portable, deterministic policy layer. Read
[ADR 002](../../docs/ADR-002-playback-state-and-dependencies.md) and relevant product rules before
changing state transitions, queue/device policy, parsing, sorting, or lifetime semantics.

## Invariants

- This target has no UI, audio, network, storage, or FFI dependency. Do not import AppKit, SwiftUI,
  AVFoundation, or `AuralPlaybackCore`, and do not smuggle environment access through closures or
  globals.
- `PlaybackState` is the single atomic playback-presentation snapshot. `PlaybackReducer` is its only
  mutation entrance. Keep transitions deterministic and explicit; do not add partial in-place writers.
- Reducer acceptance and lifetime values are behavior, not implementation trivia. Preserve stale,
  superseded, teardown, cancellation, epoch, and revision semantics when adding events or effects.
- Queue, device, connection-snapshot, and playback-snapshot projection policy belongs here when it
  is pure. Preserve occurrence identity, authoritative ordering/provenance, the distinction between
  protocol state and metadata labels, the session-phase/empty-device-ID semantics in
  `ConnectionSnapshotProjection`, and transport/empty-URI/timestamp semantics in
  `PlaybackSnapshotProjection`. `playbackContextURI` is protocol playlist/album/artist
  identity from authoritative engine playback, not `queue.contextURI`.
- Prefer immutable `Sendable` values, typed state, exhaustive switches, and pure functions. Match the
  surrounding naming and comment density; document only non-obvious invariants.

## Code review rules

Flag target-boundary imports, hidden I/O, a second playback-state writer, mutable global policy, or a
transition without stale/cancellation behavior. The safe path is a pure typed transformation with a
focused deterministic check.

## Verification

Add or update the closest suite under `Sources/AuralChecks/`. Use focused `AuralChecks` suites while
iterating, then run `./Scripts/check.sh` from the repository root.
