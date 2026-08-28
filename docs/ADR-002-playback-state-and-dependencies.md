# ADR 002: Atomic playback state and explicit dependency ownership

Status: accepted on 2026-08-23

## Context

Playback, account, Connect ownership, queue provenance, metadata, and catalog work previously met
in one mutable controller. Correct local fixes accumulated, but a callback or suspended request
could still combine values from different account, engine, command, queue, or selection lifetimes.

## Decision

- `AuralDomain.PlaybackState` is the single playback presentation snapshot.
- `PlaybackReducer` is the only mutation mechanism for that snapshot. External callbacks enter as
  account/engine/source-stamped events; ordered sources also carry revisions.
- `PlaybackStore` is a `@MainActor` compatibility and action surface. `PlaybackCoordinator`
  serializes playback effects and talks only to injected ports.
- `AccountStore` owns restore, interactive authorization, revocation, logout, and account epochs.
  Every suspended account operation revalidates its generation and epoch before mutation.
- `QueueService` owns source precedence, context identity, and the Connect mutation snapshot used
  for `set_queue`. Metadata enrichment cannot reorder a queue, and stale or provisional results
  cannot erase a newer authoritative snapshot. Same-context Web API `/me/player/queue` snapshots
  may enrich labels only; complete Connect occurrence order remains authoritative and is not
  replaced by Web entry order. A same-context Web snapshot must not copy its revision or
  receivedAt onto that Connect ordering snapshot; those clocks stay distinct per source. Connect `set_queue` replacement reads that mutation snapshot
  (`next`/`prev` protocol tracks, including Connect occurrence uids and the incoming metadata map,
  `queue_revision`, restriction flags). QueueService updates it from Connect intake and from a
  committed remote replacement, not from Web metadata enrichment. `PlaybackStore.queueMutation` is
  a MainActor projection of that owner, not a second mutation source.
- Home/library, search, and selected-playlist work have separate stores, request scopes, and
  account-epoch snapshots. The metadata repository independently rejects cross-account writes.
  Playlist add/remove is a focused `PlaylistMutating` port injected beside read-only
  `CatalogProviding`; views consume catalog models and `PlaylistMutationController`, not
  Pathfinder DTOs.
- `RustPlaybackEngine` is the process-lifetime callback adapter. It emits a bounded typed stream;
  PCM continues directly to `AudioRenderer` and never enters the state architecture.
- The `AuralApp` scene in `AuralCore` is the production composition root; the shipping `AuralApp`
  target is a deliberately thin launcher. Views receive feature stores or narrow immutable
  playback values/actions. Stores and views do not construct production APIs or call the C bridge.
  `TransientFeedbackPresenter` is composed once there and injected into `PlaybackStore` and
  `RootView`. Transient mutation success/info/failure is not `PlaybackState` and is not a
  NotificationCenter or generic event bus.

`AuralDomain`, `AuralCore`, `AuralChecks`, and `AuralBoundaryChecks` are separate SwiftPM products.
The two check executables do not ship. A separate infrastructure target is not created solely for
folder aesthetics: those adapters still share private Spotify transport models, while dependency
direction is enforced by injected protocols and static checks.

## Consequences

Event ordering, optimistic command reconciliation, account replacement, queue precedence, and
paused remote ownership can be replayed in `AuralDomain` without Spotify, Rust, Keychain, AppKit,
or SwiftUI. Concrete app boundaries and injected coordinator/queue workflows run separately in
`AuralBoundaryChecks`. The shipping executable contains neither check harness.

Ordered engine *playback*, *connection*, *device*, and *queue* callbacks are applied only when
`PlaybackReducer.reduce` accepts the stamped envelope. Queue intake stamps
`RustQueueState.sessionGeneration` from the payload (including `refreshQueueSnapshot` after decode),
not the MainActor `engineGeneration` mirror. `PlaybackStore.engineGeneration` mirrors
`state.engineEpoch` after that success; intake must not guess a newer generation. Connect *queue
callback* identity remains a distinct generation+revision watermark; adopting an engine epoch in
`reduce` does not clear it, because provenance-snapshot revisions on `.engineQueue` are a
different namespace.

Adding a new callback, queue provider, or account-scoped request now requires an explicit epoch,
revision/provenance rule, effect owner, and cancellation rule. This is intentional friction at the
boundaries where Aural historically regressed.

Command and other store-level asynchronous work keeps `PlaybackEffectRegistry` as the task owner.
Reducer-driven generic effects and The Composable Architecture were evaluated and rejected in
[ADR 003](ADR-003-playback-command-effects.md). Reducer acceptance normally gates follow-ups. A
rejected transport finish may report success only when a same-lifetime authoritative snapshot
already reconciled the pending expected transport; stale, superseded, teardown, epoch-invalidated,
and non-transport results stay inert.
