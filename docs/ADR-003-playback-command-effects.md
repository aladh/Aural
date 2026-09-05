# ADR 003: Keep PlaybackEffectRegistry; reject TCA and a generic Effect type

Status: accepted on 2026-08-27.

## Context

The playback reducer decides whether a result may change state. Asynchronous commands still need
an owner for task lifetimes, cancellation, and follow-up work. That does not by itself require a
second state-management framework.

## Decision

Keep the store-level `PlaybackEffectRegistry`. The store starts and owns tasks; reducer acceptance
and the shared command-follow-up policy determine what their results may do. Reuse that policy at
new command sites rather than creating another runner. Callback identity remains separate from
command-effect ownership.

Do not adopt The Composable Architecture (TCA) or introduce a generic `Effect` abstraction for the
current playback architecture.

## Alternatives and tradeoffs

- The existing registry adds no dependency or isolation model and keeps the domain reducer
  framework-free. Its cost is maintaining explicit command lifecycle and reconciliation tests.
- A specialized command runner would cover only transport commands while still needing the same
  lifetime and follow-up policy.
- TCA or a generic effect system would add an abstraction alongside the existing reducer and task
  owner. TCA's testing and cancellation facilities do not justify that integration for the current
  needs; its cancellation model would also need adaptation to Spotty's refusal of a second
  in-flight command of the same kind.

Exact acceptance, reconciliation, rollback, and reconnect behavior belongs in the command lifecycle,
presentation, failure, registry, and session tests. The [enforcement inventory](architecture-enforcement.md)
indexes command lifecycle coverage under `TST-CMD-001`, Rust reconnect generation checks under
`TST-LIF-001`, and generation/cancellation checks under `TST-EPC-001`.

## Revisit trigger

Reconsider when replacing `PlaybackStore` or when a demonstrated testing or effect-management need
cannot be met by the existing registry and focused suites.
