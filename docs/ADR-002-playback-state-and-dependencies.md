# ADR 002: Atomic playback state and explicit dependency ownership

Status: accepted on 2026-08-23

Like all of Spotty, this decision concerns an unofficial, independent, experimental client with no
affiliation with Spotify AB.

## Context

Playback, account, Connect ownership, queue provenance, metadata, and catalog work previously met
in one mutable controller. Correct local fixes accumulated, but a callback or suspended request
could still combine values from different account, engine, command, queue, or selection lifetimes.

## Decision

- `AuralDomain.PlaybackState` is the single playback presentation snapshot. Everything the UI
  shows about playback, connection, devices, and the upcoming queue is projected into it in Swift;
  which projection owns which field is listed in
  [playback engine ownership](playback-engine-ownership.md).
- `PlaybackReducer` is the only mutation mechanism for that snapshot. External callbacks enter as
  account/engine/source-stamped events; ordered sources also carry revisions. An event is applied
  only when the reducer accepts the stamped envelope; intake must not guess a newer generation.
- `PlaybackStore` is a `@MainActor` compatibility and action surface. `PlaybackCoordinator`
  serializes playback effects and talks only to injected ports.
- `AccountStore` owns restore, interactive authorization, revocation, logout, and account epochs.
  `AccountStore.epoch` is the only writable account-epoch owner. `PlaybackStore.accountEpoch` is a
  read-only projection of that value. `PlaybackState.accountEpoch` remains reducer-owned accepted
  snapshot state, not a second imperative lifecycle counter. Every suspended account operation
  revalidates its generation and epoch before mutation.
- `QueueService` owns source precedence, context identity, and the Connect mutation snapshot used
  for `set_queue`. Metadata enrichment cannot reorder a queue, and stale or provisional results
  cannot erase a newer authoritative snapshot. Same-context Web API `/me/player/queue` snapshots
  may enrich labels only; complete Connect occurrence order remains authoritative, and a Web
  snapshot must not copy its revision or `receivedAt` onto that Connect snapshot. Connect queue
  callback identity is a distinct generation+revision watermark that adopting an engine epoch does
  not clear. `PlaybackStore.queueMutation` is a MainActor projection of that owner, not a second
  mutation source.
- Home/library, search, and selected-playlist work have separate stores, request scopes, and
  account-epoch snapshots. The metadata repository independently rejects cross-account writes.
  Playlist add/remove is a focused `PlaylistMutating` port injected beside read-only
  `CatalogProviding`; views consume catalog models and `PlaylistMutationController`, not
  Pathfinder DTOs.
- `RustPlaybackEngine` is the process-lifetime callback adapter. It emits a bounded typed stream
  whose process-local sequence is assigned and delivered by one re-entry-safe drain so every
  subscriber observes strictly increasing order across playback, queue, connection, and devices
  callbacks. PCM continues directly to `AudioRenderer` and never enters the state architecture.
- The `AuralApp` scene in `AuralCore` is the production composition root; the shipping `AuralApp`
  target is a deliberately thin launcher. Views receive feature stores or narrow immutable
  playback values/actions. Stores and views do not construct production APIs or call the C bridge.
  `TransientFeedbackPresenter` is composed once there and injected into `PlaybackStore` and
  `RootView`. Transient mutation success/info/failure is not `PlaybackState` and is not a
  NotificationCenter or generic event bus.

`AuralDomain` and `AuralCore` are separate SwiftPM products; check products do not ship. A
separate infrastructure target is not created solely for folder aesthetics: those adapters still
share private Spotify transport models, while dependency direction is enforced by injected
protocols and static checks.

## Consequences

Event ordering, optimistic command reconciliation, account replacement, queue precedence, and
paused remote ownership can be replayed in `AuralDomain` without Spotify, Rust, Keychain, AppKit,
or SwiftUI. Concrete app boundaries and injected coordinator/queue workflows run in separate
boundary checks. The shipping executable contains no check harness.

Adding a new callback, queue provider, or account-scoped request requires an explicit epoch,
revision/provenance rule, effect owner, and cancellation rule. This is intentional friction at the
boundaries where Spotty historically regressed.

Store-level asynchronous work keeps `PlaybackEffectRegistry` as the task owner; command follow-up
gating is decided in [ADR 003](ADR-003-playback-command-effects.md).
