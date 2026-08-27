# ADR 003: Keep PlaybackEffectRegistry; reject TCA and a generic Effect type

Status: accepted on 2026-08-27

Like all of Aural, this decision concerns an unofficial, experimental client. It does not authorize
a Composable Architecture migration or a new effect framework.

## Goal

Decide how asynchronous playback command work should be described, cancelled, and fed back into
`PlaybackReducer` after #15, using one representative transport-command workflow.

The comparison is whether reducer-driven effect descriptions remove meaningful `Task` / registry
boilerplate, or replace straightforward Swift concurrency with framework weight.

## Baseline (post-#15)

`PlaybackReducer.reduce` is the only mutation entrance for `PlaybackState`. Ordered engine
playback, connection, and device callbacks are accepted only when the stamped envelope passes
account epoch, engine epoch, and source revision gates. `PlaybackStore.send(...)` returns `Bool`.
Dependent work (metadata adopt, device preference writes, engine-connection session updates) already
runs only after a successful send.

`ConnectQueueCallbackWatermark` remains a distinct callback-identity gate. Adopting an engine epoch
in `reduce` does not clear it, because provenance-snapshot revisions on `.engineQueue` are a
different namespace. Command effects must not fold that watermark into reducer-owned state.

`PlaybackEffectRegistry` is the store-level owner of `Task` lifetimes. Named tokens are replaced
(cancel-in-flight for that token), completed, or cancelled. Account teardown calls
`cancelAccountScoped()`.

Transport commands today:

1. Refuse a second command of the same `PlaybackCommandKind` while one is pending.
2. `send(.commandStarted)` for an optimistic transport when requested.
3. `effects.replace(.command(commandID), …)` with a unique UUID token.
4. Await `PlaybackCoordinator.performLocal` / `performRemoteOperation`.
5. Exit if the task was cancelled, the account epoch changed, or teardown began.
6. `send(.commandFinished)` and, until this change, run reconnect / completion / extra notices
   even when that send was rejected.

The representative workflow is **local pause**: optimistic pause, success, remote-style failure
rollback, local reconnect-required, cancel-in-flight, account-epoch invalidation, a finish that
`PlaybackStore.send` rejects after an engine-epoch bump, and a matching paused snapshot that
reconciles the pending command before the coordinator returns.

## Options considered

### 1. Keep `PlaybackEffectRegistry` (evolve in place)

The registry stays a small `@MainActor` dictionary of tasks. The store continues to decide *when*
to start work. The reducer continues to decide *whether* a result may mutate state. Callers gate
dependent work on `send(...) == true`.

This is the production path, with two tightly scoped corrections: command start still requires an
accepted send, and command-finish follow-ups use `playbackCommandFollowUp` so a matching engine
snapshot cannot drop success completions. Command-error notices keep their existing timed lifetime;
successful acknowledgements do not clear unrelated notices.

### 2. Tiny Aural-specific command runner

A command-specific plan (`token`, captured account epoch, single in-flight pause) that the store
starts and later completes. Not a generic `Effect<Action, Failure, Result>`. Cancellation and
account invalidation drop the plan. Completion still calls `send` and ignores rejected finishes.

This is easier to test with a scripted `deliver` than unstructured `Task`s, and it makes the
transport policy (one pending kind, unique command id, reconnect only after accepted failure)
explicit. It does not help engine event streams, metadata, queue refresh, or notice dismissal,
which already use the registry. Promoting it into `AuralDomain` would either leak coordinator types
into the domain or invent a generic effect type this ADR rejects.

The tiny-runner sketch is not retained as executable code.

### 3. The Composable Architecture (current 1.x)

Accurate TCA 1.x shape for the same pause:

```swift
@Reducer
struct PauseCommand {
  @ObservableState
  struct State { var playback: PlaybackState; var accountEpoch: UInt64; /* … */ }

  enum Action {
    case pauseTapped
    case paused(Result<CommandOutcome, CancellationError>)
  }

  enum CancelID { case command }

  @Dependency(\.playbackCoordinator) var coordinator

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .pauseTapped:
        guard state.playback.pendingCommands[.transport] == nil else { return .none }
        // Optimistic mutation either inlined or via PlaybackReducer.reduce.
        return .run { [epoch = state.accountEpoch] send in
          let result = await coordinator.performLocal(.pause)
          await send(.paused(/* map result, drop if epoch mismatch */))
        }
        .cancellable(id: CancelID.command)
      case .paused:
        // Further reduce through PlaybackReducer; return .none or .run reconnect.
        return .none
      }
    }
  }
}
```

Current TCA (`swift-composable-architecture` main, Swift 6.1 tools) also pulls CasePaths, Clocks,
CombineSchedulers, ConcurrencyExtras, CustomDump, Dependencies, IdentifiedCollections,
IssueReporting, Perception, Sharing, Swift Navigation, swift-collections, and a SwiftSyntax macro
plugin. That is incompatible with Aural's zero-dependency check executables, Renovate-scoped
Rust/Swift surface, and `AuralDomain` rule that the reducer stay testable without frameworks.

The package was **not** added to `Package.swift`. The check-suite `TCAStyleRuntime` reproduces
`Reduce` → `Effect.run` / `.cancel`, `cancellable` IDs, and `send` rejection for dependent work.

## Comparison on the pause workflow

| Concern | Registry (option 1) | Tiny runner (option 2) | TCA 1.x (option 3) |
| --- | --- | --- | --- |
| Cancel / cancel-in-flight | Unique `.command(UUID)` owns one task. Same-token `replace` cancels. A **second pause is refused**, not replaced. Kind-level `cancelInFlight: true` would change product behavior. | One plan; a second request is refused. `cancel` drops the plan. | `.cancellable(id:)` can cancel; `cancelInFlight: true` **replaces** the in-flight pause. Matching Aural requires returning `.none` while pending and not setting `cancelInFlight`. |
| Account-epoch invalidation | `cancelAccountScoped()` plus captured epoch before `send`. | Drop the plan, then reset. Still need the epoch check. | `.cancel(id:)` plus a custom epoch guard. TCA does not know Aural account epochs. |
| Reducer-owned engine/revision gates | Unchanged. Effects must not reimplement them. | Same: still call `PlaybackReducer`. | Wrapping `PlaybackReducer` inside `Reduce` duplicates the store's `send` or moves Core types into a TCA feature. |
| Rejected `send` / stale events | `playbackCommandFollowUp` treats matching-snapshot rejection as success and epoch/superseded rejection as inert. | Same. | Actions always enter the TCA reducer. Stale work is `.none` without mutation only if the wrapper checks `PlaybackReducer.reduce == false` before returning follow-up `Effect`s. That *is* Aural's `send` Bool, reimplemented. |
| Optimistic success / rollback | `commandStarted` / `commandFinished` already in the domain reducer. | Same events. | Same events if TCA defers to `PlaybackReducer`; duplicated if TCA state is a parallel model. |
| Local reconnect-required | Engine result flag on the coordinator; reconnect is **not** reducer state. Gate on accepted finish. | Same. | Follow-up `.run { await connect() }` from the failure action. Still a Core side effect. |
| Remote failure | `async throws` collapsed to a string notice today (#17). Rollback is reducer-owned. | Same until typed errors exist. | `Result` in `Action` helps tests; still needs a domain error at the coordinator boundary. |
| MainActor / Sendable | Store and registry are `@MainActor`. Coordinator is an actor. Command closures hop back to the store. No new isolation model. | Same. | TCA `Store` / `@Dependency` / `Effect.run` (cooperative pool, `send` hops to the store) is a second isolation story beside `PlaybackEnvironment.live` and the coordinator actor. `PlaybackStore` is not a TCA `Store`. |
| Deterministic tests | Reducer traces in `AuralChecks`; scripted pause runtimes in the spike; real `Task` cancel in `AuralBoundaryChecks`. | Scripted `deliver` is the nicest local ergonomics, but only for this workflow. | `TestStore` is excellent **if** the app is TCA. Adopting it for one command path still requires the package, macros, and wrapping the existing reducer. |
| Call-site boilerplate | Explicit `Task`, epoch capture, `send` Bool. Honest about lifetimes. | Moves the same checks into a helper. | `@Reducer` + `Effect` + dependencies + cancel IDs for every feature. |
| Package / build | No new dependency. | No new dependency if the helper stays in Core or checks. | Large transitive graph, macro plugin, SwiftUI/UIKit navigation extras Aural does not use. |
| Fit with `AuralDomain` / `AuralCore` | Domain stays pure. Registry stays Core. | Safe only as a Core helper or check prototype. | Either Domain depends on TCA, or Core becomes a TCA app around a second store. Both violate ADR 002. |

`ConnectQueueCallbackWatermark` stays outside this table on purpose: it is callback identity, not a
command effect. None of the three options should merge it into `PlaybackEffectID` or TCA cancel IDs.

## Decision

**Keep and evolve `PlaybackEffectRegistry`. Do not adopt TCA. Do not introduce a generic Effect
abstraction.**

Reasons:

1. The missing correctness was not “effects are not described by the reducer.” It was **dependent
   work after a rejected send**. #15 already returned `Bool` from `send`. The command path now uses
   it. That is an evolution of the current architecture, not a new one.
2. Aural already has the useful part of an effect system: atomic state, stamped events, a
   coordinator, and named task cancellation. TCA’s remaining value is `TestStore` and
   `cancelInFlight` sugar. The former needs a TCA app; the latter **disagrees** with the pending-kind
   refusal policy unless carefully disabled.
3. A tiny command runner helps tests for this one workflow on paper. Promoting it would either
   become a generic Effect (rejected) or a second way to start the same tasks.
4. Domain tests already replay pause/resume/superseded-ack/rollback without any effect runtime.
   After this decision, keep one registry-shaped pause workflow plus the `cancelInFlight`
   divergence note, not three executable runtimes.

## Production change justified by the spike

In `PlaybackStore+Commands`, `commandStarted` must be accepted before a command task starts.
`commandFinished` follow-ups (completion, detailed notice, reconnect) go through
`playbackCommandFollowUp`:

- Reducer-accepted success reports success.
- Reducer-accepted failure may reconnect.
- A rejected finish on the same account/engine lifetime with no pending *transport* command is
  already-reconciled success (matching snapshot). That includes a later coordinator failure:
  `completion(true)` still runs, with no error notice, rollback, or reconnect.
- Epoch changes, teardown, cancellation, non-transport kinds, and superseded ids stay inert.

Successful `commandFinished` does not clear `notice`. Command errors keep the existing
`.commandError` lifetime.

No other command sites were migrated. Queue add, metadata, and catalog loads remain follow-ups for
issue 16.

## Follow-up for issue 16

Route remaining playback outcomes through `PlaybackEvent` without a framework:

- Keep using `send(...) == true` for every dependent side effect (metadata, history, preferences,
  `accountStore.receiveEngineConnection`, reconnect).
- Prefer new `PlaybackEvent` cases over `setTransport` / `setNotice` after awaits where that makes
  success, failure, and stale results the same function.
- Do not add engine revision gates outside `PlaybackReducer`.
- Leave `ConnectQueueCallbackWatermark` as a callback watermark.
- Do not introduce `Effect<Action, Failure>`. A private `PlaybackStore` helper that shares the
  command start/finish + epoch + `send` Bool pattern is enough if duplication hurts.
- Add reducer/workflow checks for each newly routed outcome (stale, cancelled, failed, success).

## Follow-up for issue 17

Replace stringly command control flow at the **coordinator / store boundary**, not via TCA `Result`
actions:

- Map `PlaybackEngineResult` (`isOK`, `requiresReconnect`) and remote `throws` into a small
  `PlaybackCommandFailure` (or equivalent) with cases such as rejected, reconnectRequired,
  remoteRejected, unavailable — not one app-wide error enum.
- Preserve `CancellationError` as cancellation, distinct from failure.
- Derive user-facing notice text at the store/presentation boundary from those cases.
- Tests should assert cases, not `localizedDescription` substrings.
- Do not put Spotify/Rust codes into `AuralDomain` unless they are truly domain behavior; mapping
  stays in Core.

## Consequences

- `Package.swift` still has no TCA (or other) effect-framework dependency.
- Agents must not plan a TCA migration from this spike.
- The check-suite keeps one registry-shaped pause workflow. Rejected effect runtimes are not
  executable architecture.

Revisit only if Aural replaces `PlaybackStore` wholesale, or if a measured need appears for
`TestStore`-style exhaustiveness that the existing check executables cannot provide.
