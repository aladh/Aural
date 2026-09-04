# ADR 005: Retain librespot as the playback engine

Status: accepted on 2026-09-04.

This record supersedes the incremental migration commitment in [ADR 004](ADR-004-swift-owned-playback-logic.md).
[ADR 001](ADR-001-playback-engine.md)'s contained-boundary and application-ownership principles
remain accepted. ADR 002 and ADR 003 are unchanged.

## Context

Spotty has a working, contained Rust/librespot engine for the private Spotify session, Connect,
streaming, decryption, decoding, reconnection, and PCM delivery. The merged Swift playback
experiment created a second audio implementation and additional cross-language seams while the
shipping path continued to use librespot. Maintaining both paths increases lifecycle, protocol,
and verification cost without an established product or reliability benefit.

The project therefore retains the existing engine and removes the abandoned replacement experiment
as a surgical cleanup. The native macOS application, application policy, and AVFoundation output
remain part of Spotty's architecture.

## Decision

- The pinned Rust/librespot engine is Spotty's sole production implementation for Spotify session,
  Connect, streaming, decryption, decoding, reconnection, and playback protocol behavior.
- Swift owns application policy and presentation: the atomic playback state and reducer, queue and
  resume policy, catalog, OAuth, persistence, and user-facing error policy. `AudioRenderer` remains
  the native AVFoundation output for bounded PCM delivered by the engine.
- Swift reaches the engine through the existing narrow `SpottyPlaybackCore` C boundary and
  `RustPlaybackEngine`. Typed snapshots carry protocol observations; PCM stays off the observable
  UI state path. No alternate audio decoder, protocol implementation, engine shim, or runtime
  selector is part of the production design.
- The Rust leaf remains contained and replaceable at the boundary. Librespot changes are protocol
  and license changes that require deliberate review; they are not routine dependency bumps.
- The applicable ownership principles from ADR 004 remain: one reducer-owned app snapshot, explicit
  dependency and lifetime ownership, typed boundary data, and behavior-preserving deterministic
  checks. They do not create a migration roadmap.

## Consequences

- Debug and Release share one playback implementation, which removes dual-path maintenance and
  keeps playback behavior aligned with the pinned librespot revision.
- Spotty continues to carry the Rust toolchain, C ABI, private-protocol compatibility risk, and
  native PCM bridge. Those costs are accepted in exchange for retaining the working protocol and
  decoder implementation.
- Lifecycle, account/session, snapshot, and ABI hardening remain improvements within this retained
  boundary. They must preserve generation, cancellation, ownership, privacy, and callback-lifetime
  rules rather than introducing a second protocol state machine.
- A live-account spike is not required to justify this architectural decision. Live playback and
  account mutation remain subject to the [safe acceptance contract](product-and-acceptance-contract.md#safe-acceptance-testing).

## Options rejected

- Continue the staged Swift audio/session/Connect replacement: the second implementation would keep
  the complexity this decision removes and has no established benefit to justify its maintenance.
- Commit to a complete native Swift protocol stack: this would transfer private-protocol upkeep and
  verification responsibility to Spotty without a demonstrated need.
- Add a supported or desktop-controlled playback mechanism: that would change the native standalone
  product boundary and requires a separate product and integration decision.

## Revisit trigger

Revisit this decision only through a new ADR when a material product requirement or supported
playback capability changes the boundary, backed by measured reliability, resource, and maintenance
evidence. This record creates no staged migration, live spike, or eventual Rust-removal commitment.
