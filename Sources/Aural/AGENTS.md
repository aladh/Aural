# AuralCore agent guidance

Applies to `Sources/Aural/` except where a deeper `AGENTS.md` is more specific. Read
[ADR 002](../../docs/ADR-002-playback-state-and-dependencies.md) and
[ADR 003](../../docs/ADR-003-playback-command-effects.md) before changing playback state, effects,
dependency assembly, or feature-store ownership.

## Ownership and implementation

- `AuralCore` owns composition, native presentation, feature stores, adapters, and the boundary to
  `AuralDomain`. Keep `Sources/AuralApp/` a thin launcher.
- Assemble live dependencies once in `PlaybackEnvironment.live` and the app scene. Views and feature
  stores render state and call narrow actions; they do not construct Spotify APIs, auth singletons,
  or the Rust engine.
- Preserve the existing feature-store split. Add a protocol only at a real system or substitution
  boundary; do not rebuild the app around a god controller, TCA, or a generic `Effect` type.
- `PlaybackStore` is the `@MainActor` state/action surface, `PlaybackCoordinator` serializes command
  side effects, and `PlaybackEffectRegistry` owns store-level task lifetimes. Reducer acceptance
  normally gates follow-up work; the documented same-lifetime transport reconciliation is the narrow
  exception.
- `TransientFeedbackPresenter` owns transient mutation feedback. It is not playback state and must not
  become a generic event bus.
- Every suspended account-, engine-, selection-, or request-scoped operation captures and revalidates
  its identity before applying a result. Define cancellation, generation/epoch, ordering/revision,
  stale-result behavior, and error policy at the owner.
- Keep UI code declarative and small. Move orchestration to the owning store/coordinator and pure
  transformations to `AuralDomain`.
- Prefer typed state and exhaustive switches over related booleans or sentinel strings. Prefer
  Observation, structured concurrency, and `AsyncStream`; use Combine only at a publisher-native
  system boundary where it is materially simpler.

## Code review rules

Flag any change that creates a second playback-state writer, bypasses reducer acceptance, constructs a
live dependency below composition, or launches unowned work. The safe path is one explicit owner, a
typed transition, an owned cancellable lifetime, and deterministic coverage at that boundary.

## Verification

Add pure policy/state coverage under `Sources/AuralChecks/`; add concrete adapter/store/workflow
coverage under `Sources/AuralChecks/DeferredBoundaryChecks/`. Run the focused suite while iterating,
then `./Scripts/check.sh` from the repository root. Manual live-account activity remains opt-in under
the root safety contract.
