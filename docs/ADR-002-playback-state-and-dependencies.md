# ADR 002: Atomic playback state and explicit dependency ownership

Status: accepted on 2026-08-23.

## Context

Playback callbacks and suspended account, catalog, and queue requests can finish after the state
that started them has changed. Independently mutating presentation fields can combine observations
from different lifetimes and make stale work appear current.

## Decision

- Keep one reducer-owned playback presentation snapshot in `SpottyDomain`. External observations
  carry their account/engine lifetime and, where applicable, source revision. The reducer decides
  whether they may change presentation.
- Give account lifecycle, queue authority, catalog requests, and command work explicit owners.
  Projections expose their state without creating another writable authority. Suspended work
  revalidates its lifetime before applying a result.
- Assemble production dependencies at the app composition root. Views and feature stores use
  injected ports; they do not construct authentication, network, or C playback dependencies.
- Keep PCM delivery outside observable presentation state. Transient mutation feedback also has a
  separate owner; it is not playback state or a general event bus.
- Keep portable policy in `SpottyDomain`, concrete app adapters in `SpottyCore`, and the executable
  launcher thin. Test targets do not ship.

## Tradeoffs

Explicit stamps and ownership add coordination work, but make cancellation, stale results, and
source precedence testable without a live account. A single mutable controller or several
independently writable snapshots would make those relationships implicit again.

A separate infrastructure target is not justified solely by folder organization: the adapters share
private transport models, while injected ports and import checks enforce the useful boundaries.

## Implementation and evidence

[Playback engine ownership](playback-engine-ownership.md) maps current responsibilities.
The [enforcement inventory](architecture-enforcement.md) routes state, epoch, queue, dependency,
and feedback rules to their tests and scoped instructions. Those owners describe exact behavior;
this record does not duplicate callback fields or reconciliation cases.

[ADR 003](ADR-003-playback-command-effects.md) selects the task owner for asynchronous command work.
