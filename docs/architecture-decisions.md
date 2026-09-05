# Architecture decision records

Architecture decision records (ADRs) capture choices that constrain future Spotty changes. Read the
records relevant to a task before changing the corresponding boundary. An accepted ADR remains in
force until a later ADR explicitly supersedes it; edit an accepted record only to correct factual or
linking errors, not to silently change its decision.

## Index

| Record | Status | Decision |
| --- | --- | --- |
| [ADR 001: Playback engine boundary](ADR-001-playback-engine.md) | Accepted; retained by ADR 005 | Keep librespot as a contained, replaceable leaf behind one adapter and one C header; Swift owns application logic. |
| [ADR 002: Atomic playback state and explicit dependency ownership](ADR-002-playback-state-and-dependencies.md) | Accepted | Use one reducer-owned playback snapshot, explicit dependency assembly, and generation-aware async ownership. |
| [ADR 003: Keep PlaybackEffectRegistry; reject TCA and a generic Effect type](ADR-003-playback-command-effects.md) | Accepted | Keep the store-level `PlaybackEffectRegistry`; reducer acceptance gates command follow-ups and reconnect recovery. |
| [ADR 004: Move Spotty-owned playback logic into Swift incrementally](ADR-004-swift-owned-playback-logic.md) | Superseded by ADR 005 | Historical incremental ownership decision; applicable ownership principles are retained by ADR 005. |
| [ADR 005: Retain librespot as the playback engine](ADR-005-retain-librespot.md) | Accepted | Keep the pinned Rust/librespot engine as the sole production playback implementation; Swift owns application policy and native presentation behind the narrow C boundary. |
| [ADR 006: Prebuilt playback engine through SwiftPM](ADR-006-prebuilt-playback-engine.md) | Accepted | Ordinary app builds consume a checksum-pinned static XCFramework; Rust tools remain in the explicit engine-development and artifact-production workflow. |

Related index: [Architecture enforcement inventory](architecture-enforcement.md) routes hard-rule
families to their canonical decision, strongest proof, scoped agent guidance, and known enforcement
gaps. It is a registry, not another ADR.

## Related technical context

These documents are supporting evidence or protocol notes, not accepted ADRs:

- [Private extended-metadata protocol](extended-metadata.md)
- [Playback engine ownership](playback-engine-ownership.md): live Swift/Rust classification, FFI
  surface, retained-engine guarantees, and the historical resource baseline

## Maintaining these records

- Live state goes only in [playback engine ownership](playback-engine-ownership.md). A change to
  live ownership edits that table, never an ADR.
- No PR- or issue-numbered narrative inside an ADR. An ADR may name the issue that gates its
  revisit; it does not log which PR implemented which slice.
- Behavior semantics live in checks. An ADR names the suite that proves them instead of restating
  the cases.
- Superseded records stay in place with a two-line "Superseded by" header linking the replacement.

## Maintaining the index

- Give each new record the next three-digit number and add it to this table in the same change.
- State whether the record is Proposed, Accepted, Superseded, or Rejected.
- When one record replaces another, retain both files, mark the old row Superseded, and link the
  replacement from both records.
- Keep implementation details in code and stable architectural reasoning in the ADR. If a decision
  changes, write a new record instead of rewriting history.
