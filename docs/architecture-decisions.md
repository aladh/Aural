# Architecture decisions

ADRs explain consequential choices and their tradeoffs. Read the relevant decision when changing a
boundary; routine implementation work does not require reading the whole history.

## Current decisions

| Record | Decision |
| --- | --- |
| [ADR 001: Playback engine boundary](ADR-001-playback-engine.md) | Contain private protocol work behind one C module and Swift adapter. |
| [ADR 002: Playback state and dependency ownership](ADR-002-playback-state-and-dependencies.md) | Use one reducer-owned presentation snapshot and explicit dependency and lifetime owners. |
| [ADR 003: Playback command effects](ADR-003-playback-command-effects.md) | Keep `PlaybackEffectRegistry`; no TCA or generic Effect abstraction for the current architecture. |
| [ADR 005: Retain librespot](ADR-005-retain-librespot.md) | Keep the pinned Rust/librespot leaf as the sole production engine; no replacement roadmap. |
| [ADR 006: Prebuilt playback engine](ADR-006-prebuilt-playback-engine.md) | Consume a checksum-pinned XCFramework for ordinary app builds; retain explicit engine source workflows. |

## Historical decisions

[ADR 004: Incremental Swift ownership migration](ADR-004-swift-owned-playback-logic.md) was superseded
by ADR 005. Consult it for historical reasoning, not current work instructions.

## Where other information belongs

| Need | Owner |
| --- | --- |
| Current Swift/Rust responsibilities and retained-engine guarantees | [Playback engine ownership](playback-engine-ownership.md) |
| Rules, checks, and known verification limits | [Enforcement inventory](architecture-enforcement.md) |
| Product behavior and live-account acceptance | [Product contract](product-and-acceptance-contract.md) |
| Build, verification, packaging, and publication commands | [Agent operations](../CONTRIBUTING.md) |
| Environment setup and signing recovery | [Development setup](development-setup.md) |
| Private extended-metadata protocol notes | [Extended metadata](extended-metadata.md) |

## Maintaining the decision log

- Record choices whose reasoning cannot be recovered easily from code: context, decision,
  alternatives, and meaningful consequences. Add a revisit trigger when it helps.
- Correct facts, links, and implementation references in place. Clarifications and implementation
  refinements do not need another numbered record when the underlying decision is unchanged.
- For a significant reversal, add a record with the next number, explain what it replaces, and mark
  the old record superseded. Keep a short historical explanation and reciprocal links.
- State whether a record is proposed, accepted, rejected, or superseded. Reflect current and
  historical status in this index.
- Keep commands, field inventories, exact behavior cases, and delivery progress in their existing
  owners. Link to them rather than copying them into an ADR.
