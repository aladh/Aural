# ADR 003: Keep PlaybackEffectRegistry; reject TCA and a generic Effect type

Status: accepted on 2026-08-27

## Context

`PlaybackReducer.reduce` is the only mutation entrance for `PlaybackState`, and
`PlaybackStore.send` returns whether the reducer accepted a stamped event. Asynchronous command
work still needs an owner for task lifetimes, cancellation, and the follow-up that runs after a
command finishes. The question was whether that owner should stay a small store-level registry or
become a reducer-described effect system.

## Options

`PlaybackEffectRegistry`: a `@MainActor` dictionary of named tasks. The store decides when work
starts; the reducer decides whether a result may mutate state. No dependency, no second isolation
model, and the domain reducer stays framework-free.

A Spotty-specific command runner: a per-command plan with a token, captured epoch, and single
in-flight rule. Easier to script in checks, but it covers only transport commands, needs the same
follow-up policy as the registry, and promoting it into `SpottyDomain` either leaks coordinator
types or becomes the generic effect type below.

The Composable Architecture or a generic `Effect` type: brings `TestStore` and `cancelInFlight`
sugar at the cost of a large transitive dependency graph, a macro plugin, a second store and
isolation story, and either wrapping `PlaybackReducer` or duplicating its gates. `cancelInFlight`
also disagrees with Spotty's refuse-second-command policy.

## Decision

Keep `PlaybackEffectRegistry`. Do not adopt TCA. Do not introduce a generic Effect abstraction.

- A command starts only after the reducer accepts `commandStarted`; one pending command per
  `PlaybackCommandKind`.
- Follow-ups after `commandFinished` go through `playbackCommandFollowUp`. Reducer acceptance is
  the normal gate, with two documented same-lifetime exceptions:
  - A captured transport resolution is evaluated before `finishAccepted`: confirmed keeps the
    success presentation, superseded stays inert. Consume-only `commandFinished` acceptance only
    removes the map entry, so it cannot turn a coordinator failure into `reportFailure`.
  - A rejected same-lifetime transport finish with no pending command and no captured resolution
    is already-reconciled success: a matching snapshot settled it. It is not inert.
  Stale, teardown, epoch-invalidated, and non-transport results stay inert.
- One reconnect rule: a reconnect-required result with any non-inert outcome rebuilds the engine,
  whether the finish was an accepted failure or a confirmed or already-reconciled success. A
  confirming snapshot settles what the UI shows, not whether the engine's command channel is
  alive. A ready account recovers through `forceReconnect`, since `AccountStore.connect()` only
  acts while the account is not ready.
- `ConnectQueueCallbackWatermark` is callback identity, not a command effect, and stays outside
  the registry.

Optimistic seek hold, play-target presentation, rollback, and cancellation semantics are proven by
the `SpottyChecks` suites `PlaybackCommandPresentationChecks`, `PlaybackCommandEffectSpike`,
`PlaybackCommandLifecycleParityChecks`, `PlaybackCommandFailureChecks`, and the follow-up cases
in `SessionLifetimeChecks`.

## Consequences

- `Package.swift` has no effect-framework dependency.
- New command sites reuse the shared kernel and follow-up rather than adding a runner.

## Revisit trigger

Replacing `PlaybackStore` wholesale, or a measured need for `TestStore`-style exhaustiveness that
the check suites cannot provide.
