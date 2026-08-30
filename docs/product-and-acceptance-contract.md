# Product and acceptance contract

This document records intentional product behavior that is easy to lose during a refactor, plus
the safe way to test Aural against a real Spotify account. Architecture decisions belong in the
ADRs; historical measurements belong in the performance baseline.

## Product direction

- Aural is a focused, polished, native macOS client for personal Spotify Premium use.
- macOS is the only current platform target. Cross-platform UI work is not a present constraint.
- Prefer idiomatic SwiftUI and AppKit behavior over custom chrome. Do not add a WebView, Chromium
  runtime, or a second UI framework.
- Keep the product surface small. In particular, Aural has no in-app volume control or manual
  Spotify refresh action. Playlist creation, rename, cover editing, collaborative permission
  management, and arbitrary reordering are out of scope. Occurrence-safe add/remove for playlists
  Aural can justify as owned is in scope.
- The accent color is user-selectable in the native Settings scene. System semantics, keyboard
  behavior, accessibility, focus, and inactive-window appearance must continue to work for every
  accent.

## Window and navigation behavior

- The main window uses a native, fixed-width sidebar and inspector. Both side panels have the same
  220-point width and neither is user-collapsible by dragging.
- The sidebar has native navigation symbols for primary destinations, but playlist shortcuts are
  text-only. Do not add a redundant app logo or app-name header to the content area.
- The right inspector contains Queue and History in a stable segmented header. Switching tabs must
  not move the header. The current queue item is text-only; history may show artwork. VoiceOver for
  that now-playing row uses the same catalog-enriched title and artist as the visible text.
- Closing the main window purges presentation caches but does not quit Aural. The app remains in the
  Dock and reopens through the Dock icon or the standard macOS Window command.
- Sign Out belongs in the macOS **Aural** application menu, not in a custom profile card. Settings
  belongs in the standard Settings scene.

## Playback presentation and ownership

- Aural mirrors the active Spotify Connect device automatically, including a device owned by a
  different computer. The now-playing title, artist, artwork, position, play/pause state, queue,
  and available controls must follow that owner without requiring a manual refresh.
- Transport commands target the device that owns playback. Aural must not silently transfer
  playback to this Mac merely because the user pressed a remote control. When no device is marked
  active but a current track remains, a remembered last remote device stays an uncertain remote
  candidate so commands remain remote-routable; a missing or stale fallback never becomes local.
- With no current track, the primary control shows Play and is disabled. Pause appears only while
  the observed playback state is actually playing.
- The transport order is shuffle, previous, play/pause, next, repeat. Previous and next use the
  track-skip symbols with an outside bar, not rewind or fast-forward symbols. Repeat stays to the
  right of Next.
- Progress is interpolated smoothly between authoritative snapshots while playing. A new snapshot,
  seek, pause, track change, or ownership change must re-anchor it instead of allowing drift.
- Shuffle is a single on/off control backed by Aural's persistent fewer-repeats policy. Spotify
  Connect does not expose a shuffle-style parameter, so no shuffle-style picker is presented.
- Repeat cycles off → queue → track → off. Each step sends only the Connect flags that change,
  planned from the reducer's raw context/track pair rather than the display mode. Ordinary
  track-repeat (context off, track on) → off is one mutation; a both-true track snapshot → off
  clears both flags. Queue → track is the only two-flag step and applies context off before track
  on. If the second mutation fails after the first was accepted, Aural best-effort restores the
  captured previous flags and still reports failure. A later snapshot of the requested target is
  kept; the known intermediate off after a compensated queue → track failure restores queue
  repeat; a compensated both-true track → off failure whose intermediate snapshot is still
  displayed as track (`context: false`, `track: true`) restores the captured previous track
  mode and both-true flags; unrelated newer authoritative repeat state is left intact.
- Queue order comes from the playback source of truth. Catalog and Web API metadata may enrich
  names but must not reorder the queue. Resolvable entries should progressively replace fallback
  labels rather than remaining misleadingly `Unknown`.
- Upcoming queue rows use a native selectable list. Delete/Backspace and **Remove from Queue**
  remove only selected *upcoming* occurrences by queue identity (Connect occurrence uid when
  present), never by track URI. Duplicate URIs or duplicate UIDs that cannot be proven fail
  closed. The now-playing row and History tab are not removable queue entries. Play from the queue
  remains a deliberate primary action (Return/double-click), not a single-click.
- Queue replacement is a Spotify Connect `set_queue` of remaining protocol `next_tracks` plus the
  current `prev_tracks` and the exact incoming ProvidedTrack metadata map (`metadata`, `uid`,
  `provider`, and the other player.proto fields the snapshot carried). Aural does not synthesize
  `is_queued` or edit presentation state to fake success. Sequential Add to Queue is not atomic:
  feedback reports full success, zero success, or a partial completed count.
  Removal is gated on a complete Connect mutation snapshot, account/engine epoch, owner, and
  player `disallow_set_queue` / `disallow_removing_from_next_tracks` reasons. Partial, provisional,
  web-API-only, restricted, joining, local-owner, stale-selection, and rejected results leave the
  visible queue intact and report through `TransientFeedbackPresenter`. A second removal while one
  authoritative replacement is in flight is refused without feedback: cancelling the local task
  cannot undo a `set_queue` Spotify already accepted. Cancelled and
  account-epoch-invalidated in-flight removals also leave the visible queue intact, without
  transient feedback.
- Local-owner removal is disabled: librespot `Spirc` at the pinned revision exposes `add_to_queue`
  only, and inbound `SetQueue` is not a public local command. The follow-up is a tested Spirc
  replacement export (or proven same-device HTTP `set_queue`), not a second owner. Add to Queue
  remains available for local and remote owners, including multiple selected tracks in visible
  order.

## Playlist behavior

- The playlist hero begins close to the content edge, keeps a compact prominent Play button, and
  preserves readable foreground contrast when the window is inactive.
- The author and song count share the metadata line beside the artwork. Song count does not belong
  in the track table.
- Track rows contain no artwork. Title, Artist, Album, Popularity, BPM, Key, Date Added, and Time are
  distinct native table columns.
- Clicking **Date Added** sorts directly and reverses the order on the next click through native
  table sorting; it must never open a picker or menu. Clearing table sorting restores playlist
  order.
- Track tables use native multi-selection. **Add to Playlist** is a context-menu command listing
  library playlists whose owner URI matches the signed-in profile. The selected rows are batched
  as one mutation, preserving duplicate track URIs from distinct occurrences and ignoring repeated
  selection IDs.
- In an editable open playlist, Delete/Backspace and **Remove from Playlist** remove the selected
  occurrences by Pathfinder UID (`CatalogTrack.id`), never by track URI. Read-only playlists do
  not advertise or route those commands.
- Successful add/remove refresh only the affected open playlist and report through
  `TransientFeedbackPresenter`. Write failure, cancellation, and stale account/session results leave
  presentation state unchanged. A committed write stays successful if that refresh fails; the open
  playlist then keeps its previous rows, shows that they may be stale, and Retry reloads rows without
  repeating the mutation.
- Dragging selected tracks onto playlist rows is omitted. A native SwiftUI Table transfer
  representation serializes the dragged row rather than the occurrence-aware multi-selection;
  disabled drop targeting for non-editable rows could not be demonstrated without private
  hit-testing or pixel coordinates. The context-menu command is the keyboard-accessible add path.

## Engineering defaults

- Prefer Swift structured concurrency, `AsyncStream`, and Observation for new asynchronous state.
  Do not introduce Combine unless a publisher-native system boundary makes it materially simpler.
- Keep Rust/librespot as the contained playback leaf described in
  [ADR 001](ADR-001-playback-engine.md); Swift continues to own product policy and presentation.
- Production code must use live integrations. Deterministic checks use injected ports and reduced,
  synthetic fixtures—never captured account payloads.
- Account-scoped work must retain the epoch, cancellation, and stale-result rules in
  [ADR 002](ADR-002-playback-state-and-dependencies.md).

## Transient mutation feedback

- User-initiated mutations such as Add to Queue report completion through one app-composed
  `TransientFeedbackPresenter`. Playlist and queue management should use the same owner.
- The banner is a single non-modal overlay just above the persistent player. It must not steal
  focus, intercept unrelated pointer or keyboard input, or shift window layout. A newer message
  replaces the current one; automatic dismissal is cancellable and must not clear a replacement.
- Durable connection, playback, session, and command-reconciliation status stay with their existing
  owners (including `PlaybackNotice` / now-playing status text). Do not turn those strings into
  toasts.

## Safe acceptance testing

Spotify Connect controls a live account and can interrupt playback on another device. Playback and
account mutations are therefore **opt-in**, not part of routine acceptance testing.

### Default: automated and read-only

Without explicit playback permission, it is safe to:

- run `./Scripts/check.sh` and the synthetic check executables;
- launch, sign in, browse Home/Search/library/detail pages, sort tables, inspect devices and queue,
  change Aural-only settings, close/reopen the window, and sign out when sign-out testing is in
  scope;
- observe remote playback state without pressing Play/Pause, Previous, Next, Shuffle, Repeat,
  Seek, Add to Queue, Transfer, Add to Playlist, or Remove from Playlist.

Do not infer playback permission from a request to launch, inspect, accept-test, or test read-only.
Do not transfer playback, alter the queue, seek, or change transport modes as a substitute for a
read-only assertion.

### Explicit playback test

Only when the user has explicitly allowed playback for the current test:

1. Identify the currently active Connect device and confirm the test will not take over playback
   the user wants to keep elsewhere.
2. If local audio is involved, set macOS output volume to zero before starting.
3. Use a named track or playlist and a short, bounded interval. Do not leave playback running while
   waiting on unrelated work.
4. Pause the device used for the test at the end, including after a failed assertion, and report
   any state that could not be restored.
5. Treat transfer, queue mutation, shuffle/repeat changes, sleep/wake, and output-device changes as
   separately scoped mutations; do not bundle them into a basic playback check.

Never include tokens, OAuth callbacks, real API payloads, private library screenshots, or account
identifiers in source, fixtures, diagnostics, issues, or pull requests.
