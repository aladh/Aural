# Architecture decision records

Architecture decision records (ADRs) capture choices that constrain future Aural changes. Read the
records relevant to a task before changing the corresponding boundary. An accepted ADR remains in
force until a later ADR explicitly supersedes it; edit an accepted record only to correct factual or
linking errors, not to silently change its decision.

## Index

| Record | Status | Decision |
| --- | --- | --- |
| [ADR 001: Keep librespot as a contained playback leaf](ADR-001-playback-engine.md) | Accepted | Keep playback and Spotify Connect behind the narrow Rust/C boundary rather than reimplementing the engine in Swift. |
| [ADR 002: Atomic playback state and explicit dependency ownership](ADR-002-playback-state-and-dependencies.md) | Accepted | Use one reducer-owned playback snapshot, explicit dependency assembly, and generation-aware async ownership. |
| [ADR 003: Keep PlaybackEffectRegistry; reject TCA and a generic Effect type](ADR-003-playback-command-effects.md) | Accepted | Keep store-level `PlaybackEffectRegistry` for command Task lifetimes and gate follow-ups on reducer-accepted finishes; do not adopt TCA or a generic Effect type. |

## Maintaining the index

- Give each new record the next three-digit number and add it to this table in the same change.
- State whether the record is Proposed, Accepted, Superseded, or Rejected.
- When one record replaces another, retain both files, mark the old row Superseded, and link the
  replacement from both records.
- Keep implementation details in code and stable architectural reasoning in the ADR. If a decision
  changes, write a new record instead of rewriting history.
