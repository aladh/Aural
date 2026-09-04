# Architecture decision records

Architecture decision records (ADRs) capture choices that constrain future Spotty changes. Read the
records relevant to a task before changing the corresponding boundary. An accepted ADR remains in
force until a later ADR explicitly supersedes it; edit an accepted record only to correct factual or
linking errors, not to silently change its decision.

## Index

| Record | Status | Decision |
| --- | --- | --- |
| [ADR 001: Playback engine boundary](ADR-001-playback-engine.md) | Accepted; under staged review per #201 | Keep the playback engine a contained leaf behind one adapter and one C header; Swift owns application logic. The leaf is replaced in stages, and the boundary rule applies to whatever remains. |
| [ADR 002: Atomic playback state and explicit dependency ownership](ADR-002-playback-state-and-dependencies.md) | Accepted | Use one reducer-owned playback snapshot, explicit dependency assembly, and generation-aware async ownership. |
| [ADR 003: Keep PlaybackEffectRegistry; reject TCA and a generic Effect type](ADR-003-playback-command-effects.md) | Accepted | Keep store-level `PlaybackEffectRegistry`; do not adopt TCA or a generic Effect type. Reducer acceptance gates follow-ups through `playbackCommandFollowUp`; one reconnect rule. |
| [ADR 004: Move Spotty-owned playback logic into Swift incrementally](ADR-004-swift-owned-playback-logic.md) | Accepted; Stage 0 of #201 | Rust stays a protocol/runtime adapter; Spotty-owned policy moves to Swift one owner at a time with its checks. Live classification is [playback engine ownership](playback-engine-ownership.md). |

Related index: [Architecture enforcement inventory](architecture-enforcement.md) routes hard-rule
families to their canonical decision, strongest proof, scoped agent guidance, and known enforcement
gaps. It is a registry, not another ADR.

## Related technical context

These documents are supporting evidence or protocol notes, not accepted ADRs:

- [Private extended-metadata protocol](extended-metadata.md)
- [Playback engine ownership](playback-engine-ownership.md): live Swift/Rust classification, FFI
  surface, planned owner per #201 stage, and the measured resource baseline

## Maintaining these records

- Live state goes only in [playback engine ownership](playback-engine-ownership.md). A slice PR
  edits that table, never an ADR.
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
