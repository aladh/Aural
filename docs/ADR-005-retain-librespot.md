# ADR 005: Retain librespot as the playback engine

Status: accepted on 2026-09-04. Supersedes [ADR 004](ADR-004-swift-owned-playback-logic.md).
[ADR 001](ADR-001-playback-engine.md)'s containment decision remains current.

## Context

Spotty has a working Rust/librespot leaf for private Spotify session, Connect, streaming, decryption,
decoding, and reconnection. A Swift playback experiment introduced a second implementation and
additional cross-language lifetimes without an established product or reliability benefit.
Rewriting the engine would transfer private-protocol maintenance to Spotty rather than remove it.

## Decision

Keep the pinned Rust/librespot leaf as the sole production playback engine and remove the replacement
experiment. Swift retains application policy and presentation, including playback state, queue and
resume policy, catalog, OAuth, persistence, and user-facing errors. AVFoundation renders the bounded
PCM supplied by the engine.

Keep the narrow C boundary from ADR 001. No alternate decoder, protocol stack, or runtime engine
selector is part of the production design. The boundary remains replaceable, but there is no staged
migration or eventual Rust-removal commitment. [ADR 002](ADR-002-playback-state-and-dependencies.md)
and [ADR 003](ADR-003-playback-command-effects.md) continue to govern application state and effects.

## Alternatives and tradeoffs

- Continuing staged Swift replacement would retain two implementations and their verification
  costs. A complete Swift protocol stack has no demonstrated benefit that justifies taking over
  that maintenance.
- A supported or desktop-controlled playback mechanism would change the standalone product
  boundary and needs a separate product decision.
- Retaining librespot accepts C ABI, callback-lifetime, and private-protocol compatibility costs
  in exchange for the working implementation. Dependency updates require protocol and license
  review, not routine version bumps.

Rust tooling remains necessary for engine development and source CI. Under
[ADR 006](ADR-006-prebuilt-playback-engine.md), ordinary app builds consume a prebuilt artifact and
need no Rust installation. This changes distribution, not engine ownership.

Current responsibilities and retained-engine guarantees live in
[playback engine ownership](playback-engine-ownership.md). Live-account testing remains governed by
the [safe acceptance contract](product-and-acceptance-contract.md#safe-acceptance-testing).

## Revisit trigger

Reconsider the engine choice when a material product requirement or supported playback capability
changes the tradeoff, with evidence about reliability, resource use, and maintenance cost.
