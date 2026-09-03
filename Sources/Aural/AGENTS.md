# AuralCore agent guidance

This scope owns the `AuralCore` composition shell and top-level services. Deeper `AGENTS.md` files
own Spotify boundaries and view rules. Read
[ADR 002](../../docs/ADR-002-playback-state-and-dependencies.md) and
[ADR 003](../../docs/ADR-003-playback-command-effects.md) before changing composition, task
ownership, or transient feedback.

## Ownership

- Keep `Sources/AuralApp/` a thin launcher. Assemble the live object graph in the app scene and
  explicit environment factories, never inside a view or feature.
- `PlaybackEffectRegistry` owns store-level task lifetimes. Use explicit keys, cancellation, and
  replacement semantics instead of untracked work.
- `TransientFeedbackPresenter` owns transient mutation banners. It is not playback state or a
  generic event bus.
- Keep top-level composition declarative. Route Spotify/auth/playback detail through
  `Sources/Aural/Spotify/`, pure policy through `AuralDomain`, and recurring view behavior through
  `Sources/Aural/Views/`.
- Add a protocol only at a real system or substitution boundary. Do not rebuild the app around a
  god controller, TCA, or a generic `Effect` type.
- Prefer typed state, exhaustive switches, Observation, structured concurrency, and owned
  cancellation. Use Combine only at a publisher-native system boundary where it is simpler.

## Review and verification

Flag live-dependency construction below composition, a task without a lifetime owner, feedback
entering playback state, or top-level files absorbing behavior owned by a deeper scope.

Add pure policy/state coverage under `Sources/AuralChecks/`; add concrete service or composition
coverage under `Sources/AuralChecks/DeferredBoundaryChecks/`. Use focused suites while iterating,
then run the proportional root gate. Live-account activity remains opt-in.
