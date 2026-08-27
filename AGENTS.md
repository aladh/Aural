# AGENTS.md

This file is the fast operating manual for coding agents working on Aural. Read it before changing
the repository. It captures project-specific constraints and routes you to the canonical documents;
it does not replace them.

## Mission and priorities

Aural is an **experimental, personal-use, native macOS client for Spotify Premium**. It should feel
like a focused Mac app: polished, fast, resource-conscious, accessible, and unsurprising. It uses
unsupported, reverse-engineered Spotify interfaces, so reliability and containment matter more than
feature count.

When priorities compete, use this order:

1. Do not disrupt the user's live Spotify account or leak private data.
2. Preserve playback, account, queue, and concurrency correctness.
3. Prefer idiomatic macOS behavior and a small product surface.
4. Keep architecture boundaries explicit and testable.
5. Optimize measured, high-impact paths without adding speculative complexity.

Current product constraints:

- macOS 15+ on Apple silicon is the only supported platform. Linux is not a current constraint.
- Spotify Premium is required.
- The app is SwiftUI/AppKit, not a WebView, Chromium shell, or cross-platform UI.
- Rust/librespot remains a contained playback leaf. Do not plan another Rust removal without new
  evidence that changes [ADR 001](docs/ADR-001-playback-engine.md).
- Production code uses live integrations. Fakes and synthetic fixtures belong only in checks.
- Keep the experimental and unofficial-project warnings prominent in public documentation and
  releases.

## Engineering principles

- **DRY (Don't Repeat Yourself):** keep each piece of knowledge and product policy in one canonical
  place. Remove duplicated behavior that can drift, but do not force superficially similar code
  through an abstraction when the underlying responsibilities or lifetimes differ.
- **KISS (Keep It Simple):** prefer the smallest direct design that makes ownership, state, and
  failure behavior obvious. Fewer concepts, dependencies, layers, and execution paths are usually
  easier to verify and maintain.
- **YAGNI (You Aren't Gonna Need It):** do not add extension points, configuration, portability,
  frameworks, or generalized infrastructure for hypothetical requirements. Build for a concrete
  current need and leave the code easy to change when a real need arrives.
- **“Make the change easy, then make the easy change.” — Kent Beck:** when a requested change fights
  the current structure, first make the smallest behavior-preserving refactor that creates a clean
  seam. Then implement the behavior through that seam. Keep both steps reviewable and verify the
  invariant before and after.

These principles reinforce one another, but they are not slogans to apply mechanically. In
particular, DRY does not justify premature abstraction, KISS does not justify hiding edge cases, and
YAGNI does not justify leaving a known correctness or operability gap.

## Aural's taste and judgment

Rules catch regressions; taste decides among several technically valid solutions. Aural should have
**quiet confidence**: unmistakably native, visually calm, information-dense without feeling cramped,
and capable without advertising every capability. The best implementation often feels obvious in
retrospect and disappears during use.

Use these principles when the specification does not settle a decision:

- **Start with the Mac, not a mockup.** Ask how Finder, Music, Settings, and well-made productivity
  apps solve the interaction. Use system structure, materials, typography, spacing, controls,
  commands, focus, and accessibility before inventing a visual language. Native is a behavioral
  standard, not merely an SF Symbol and a blur.
- **Remove before adding.** Aural became better by removing the redundant app header, profile card,
  manual refresh, volume control, playlist icons, track-row artwork, and unnecessary pickers. Every
  persistent control must earn its space through frequent use or essential state. Capability alone
  is not a reason to expose UI.
- **One clear hierarchy.** At a glance, the user should see where they are, what is playing, and the
  primary action. Supporting metadata should be quieter, aligned, and close to what it describes.
  Avoid competing cards, oversized empty hero regions, decorative containers, and repeated labels.
- **Dense, not crowded.** Music libraries benefit from efficient tables and stable side panels.
  Spend space on readable titles and useful columns, not repeated artwork or ornamental padding.
  Preserve breathing room around groups rather than inflating every row and control.
- **State must be honest.** Never show Pause when nothing is playing, imply that a remote device is
  local, display a control as available when it cannot succeed, or leave `Unknown` when information
  is resolvable. Loading, empty, stale, disabled, error, inactive-window, and reconnecting states are
  part of the design—not cleanup after the happy path.
- **Motion explains; it does not perform.** Smooth progress is useful because time is continuous.
  Stable Queue/History headers are useful because context should not jump. Prefer subtle system
  transitions, preserve spatial anchors, and avoid animation that delays input or attracts attention
  to chrome.
- **Color is semantic and restrained.** The accent identifies selection and primary actions; it
  should not create blue-on-blue ambiguity or overwhelm content. Test every user-selected accent in
  light, dark, active, inactive, selected, disabled, and keyboard-focused states. Do not hardcode a
  color where a semantic style conveys intent.
- **Controls should look and act like their meaning.** Use track-skip icons rather than seek icons,
  direct column sorting rather than a picker, the app menu for Sign Out, and the native Settings
  scene for preferences. Labels, tooltips, shortcuts, hit targets, and VoiceOver descriptions should
  agree with the visible action.
- **Fast is a feeling built from details.** Keep the main thread free, cancel obsolete work, hydrate
  metadata progressively, downsample artwork, bound caches, and avoid gratuitous polling. Preserve
  useful content during refresh instead of flashing empty states. Optimize measured bottlenecks, but
  prefer deleting work over adding elaborate machinery.
- **Architecture should reduce cognitive load.** A small explicit owner, a typed state transition,
  and a deterministic check are preferable to a clever abstraction. Do not generalize from one use,
  introduce a protocol without a boundary, or split code merely to make the tree look architectural.
- **Fix the class of bug.** A white inactive-window Play button is a semantic styling problem, not
  one bad RGB value. Empty playlists after a request race are a lifetime/epoch problem, not a reason
  to reload more often. Find the invariant, enforce it at its owner, then add the closest regression
  check.
- **Polish the whole loop.** Judge launch, sign-in, loading, browsing, resizing, keyboard navigation,
  window deactivation, close/reopen, offline/error recovery, sign-out, and fresh-clone development.
  A beautiful steady-state screenshot does not compensate for a janky transition or fragile setup.

Before accepting a UI or architecture change, perform this taste pass:

1. **Glance:** Is the primary content/action obvious in two seconds?
2. **Delete:** Can an element, state, abstraction, request, or timer disappear with no loss?
3. **Native:** Would a Mac user predict the location, behavior, keyboard path, and inactive state?
4. **Truth:** Does every visible state match authoritative playback/account data?
5. **Stability:** Do refreshes, tab switches, metadata arrival, and window focus preserve spatial
   anchors and useful content?
6. **Edges:** Are empty, loading, error, stale, disabled, long-text, light/dark, and accessibility
   states deliberately handled?
7. **Cost:** What work, memory, wakeups, ownership, and failure modes did the change add?
8. **Coherence:** Does it make Aural feel like one focused app rather than another feature attached?

When two options remain, prefer the one with fewer concepts, fewer persistent controls, clearer
ownership, more native behavior, and a better failure mode. Novelty must justify itself; simplicity
does not mean crude, and polish does not mean decoration.

## First five minutes

1. Run `git status --short` and preserve unrelated user changes. Never reset or overwrite them.
2. Read the documents relevant to the task:
   - [README.md](README.md): supported features, requirements, build, release, architecture.
   - [Product and acceptance contract](docs/product-and-acceptance-contract.md): intentional UX
     behavior and safe live-account testing. Treat this as the product specification.
   - [Development setup](docs/development-setup.md): fresh clone, generated state, recovery.
   - [Architecture decision records](docs/architecture-decisions.md): accepted boundaries,
     ownership decisions, and the index of ADRs relevant to the task.
   - [CONTRIBUTING.md](CONTRIBUTING.md): checks, fixtures, public-repository hygiene.
3. Inspect the implementation and its nearest checks before editing. Search with `rg`/`rg --files`.
4. Make the smallest cohesive change that fixes the underlying behavior, not just its visible
   symptom.
5. Verify in proportion to risk using the matrix below, inspect the diff, then update docs when an
   intentional contract or architecture decision changed.

If this file and a more specific canonical document disagree, follow the more specific document and
update `AGENTS.md` in the same change. Do not let instructions and implementation drift silently.

## Repository map

| Area | Responsibility |
| --- | --- |
| `Sources/AuralApp/` | Thin executable launcher only. |
| `Sources/Aural/` | `AuralCore`: composition root, SwiftUI/AppKit UI, feature stores, Spotify APIs, auth, audio renderer, and playback adapters. |
| `Sources/AuralDomain/` | Portable deterministic models, reducer, session lifetime rules, parsing, sorting, and policies. No UI, audio, network, or FFI imports. |
| `Sources/AuralPlaybackCore/` | Checked-in C header/module map for the Rust ABI. |
| `Backend/aural-playback/` | Rust/librespot session, Spotify Connect, streaming, decoding, reconnection, queue truth, and C exports. |
| `Sources/AuralChecks/` | Pure domain checks and deterministic playback traces. Never ships. |
| `Sources/AuralChecks/DeferredBoundaryChecks/` | Concrete codec, fixture, coordinator, and queue boundary checks. Never ships. |
| `Scripts/` and `script/` | Canonical verification, packaging, signing, diagnostics, icon, archive, and launch entry points. |
| `Packaging/` and `Assets/` | App metadata, entitlements, privacy manifest, and app icon sources. |
| `docs/` | Accepted architecture, product invariants, protocol notes, and measured baselines. |

Swift target direction is `AuralApp -> AuralCore -> AuralDomain`, with `AuralCore` reaching the C
leaf through the narrow adapter below. Do not add reverse dependencies merely for convenience.

## Hard architecture rules

The normal quality gate enforces several of these mechanically. Treat all of them as design rules:

- `AuralDomain.PlaybackState` is the single atomic playback-presentation snapshot.
- `PlaybackReducer` is the only way to mutate that state. Add explicit events/actions rather than
  writable projections or coordinated assignments across several published properties.
- `PlaybackStore` is the `@MainActor` compatibility/action surface. `PlaybackCoordinator` owns and
  serializes side effects. `PlaybackEffectRegistry` owns store-level `Task` lifetimes. Do not adopt
  The Composable Architecture or a generic `Effect` type; see
  [ADR 003](docs/ADR-003-playback-command-effects.md). Reducer acceptance normally gates follow-ups.
  A rejected transport finish may report success only when a same-lifetime authoritative snapshot
  already reconciled the pending expected transport; stale, superseded, teardown, epoch-invalidated,
  and non-transport results stay inert. Views render state and invoke narrow actions.
- Production dependencies are assembled once in `PlaybackEnvironment.live`. Views and feature
  stores must not instantiate Spotify APIs, auth singletons, or the Rust engine directly.
- Every suspended account-scoped operation must capture and revalidate its generation/account
  epoch before applying a result. Selection-scoped and request-scoped work needs equivalent stale
  result protection and cancellation.
- Ordered callback sources carry revisions. Session/engine generations prevent a stale callback or
  teardown from mutating a replacement session.
- Queue source precedence and context identity belong to `QueueService`. Metadata enrichment may
  replace fallback labels, but it must never reorder or erase a newer authoritative queue.
- `Sources/Aural/Spotify/PlaybackCore.swift` is the only Swift file allowed to import
  `AuralPlaybackCore`. `RustPlaybackEngine.swift` is the only caller of `PlaybackCore`.
- PCM travels directly from the engine adapter to `AudioRenderer`; never route it through observable
  UI state. Keep callbacks bounded and do not block the Rust callback thread.
- Keep the checked-in C header and Rust exports exactly aligned. Changes to FFI ownership, pointer
  lifetime, string allocation, callbacks, or threading require Rust tests and the clean gate.
- Prefer Swift structured concurrency, `AsyncStream`, and Observation for new state. Introduce
  Combine only at a publisher-native system boundary where it is materially simpler.
- Avoid `nonisolated(unsafe)`, mutable global state, broad singletons, unstructured `Task` lifetimes,
  and in-place partial playback presentation updates.

When adding a callback, account request, queue provider, or optimistic command, define explicitly:
owner, lifetime, cancellation, generation/epoch, ordering/revision, stale-result behavior, error
policy, and deterministic coverage.

## Implementation conventions

- Swift 6.1 concurrency diagnostics are part of correctness. Prefer actor isolation and immutable,
  `Sendable` values over suppression.
- Keep UI types declarative and small. Move orchestration to the owning store/coordinator, pure
  transformations to `AuralDomain`, and transport details to boundary adapters.
- Preserve the existing store split (`AccountStore`, `CatalogStore`, `HomeLibraryStore`,
  `PlaylistStore`, `SearchStore`, media-detail stores, and the `PlaybackStore` extensions). Do not
  rebuild a god controller.
- Prefer protocols only at real substitution or system boundaries. Do not create layers solely to
  mirror folders.
- Use typed state and exhaustive switches instead of loosely related booleans and sentinel strings.
- User-facing failure should be actionable but privacy-safe. Use Unified Logging through the
  existing logging facilities; never log tokens, OAuth redirects, raw API payloads, or private
  library/account identifiers.
- Keep caches cost-bounded and clear presentation caches when the window closes. Measure before
  adding caching, polling, timers, or retained artwork.
- Do not add mocks, demo data, placeholder catalog content, or captured Spotify payloads to the
  shipping app. Test fixtures must be reduced, synthetic, and non-identifying.
- Follow existing naming and formatting. Run Rust formatting rather than hand-formatting Rust.
- Add comments for invariants and non-obvious lifetime/order constraints, not for line-by-line
  narration.

## macOS product and UI rules

The complete UX contract lives in
[docs/product-and-acceptance-contract.md](docs/product-and-acceptance-contract.md). In particular:

- Prefer native SwiftUI/AppKit controls, tables, menus, Settings, keyboard behavior, accessibility,
  focus, and inactive-window semantics. Avoid custom chrome when a native pattern exists.
- The fixed 220-point sidebar and inspector have equal width and are not drag-collapsible.
- Sign Out belongs in the **Aural** application menu. Do not restore a profile/status card, manual
  Spotify refresh control, redundant app header/logo, playlist sidebar icons, or volume control.
- Transport order is Shuffle, Previous, Play/Pause, Next, Repeat. Use track-skip symbols with outer
  bars. With no current track, show disabled Play—not Pause.
- Mirror the active Spotify Connect device without silently transferring it. Smooth progress is an
  interpolation over authoritative state and must re-anchor on seek, pause, track, or owner changes.
- Queue provenance determines order. Metadata only enriches it. Avoid permanent `Unknown` labels
  when identifiers can be resolved.
- Playlist rows have no artwork; columns remain distinct and natively sortable. Clicking Date Added
  toggles its sort directly. Song count belongs beside the author, not in the table.
- Closing the main window must keep the app running in the Dock and reopenable through normal macOS
  behavior while releasing presentation caches.
- Validate custom accent colors in active/inactive windows, light/dark appearances, keyboard focus,
  and accessibility labels.

Treat a screenshot mismatch as a symptom. Check layout semantics, focus, hit targets, accessibility,
window activation, reduced motion, and system appearance—not only pixels.

## Live Spotify safety

**Default to no playback and no account mutation.** Aural controls a live Spotify Connect account;
a transport command can interrupt music on another computer.

Without explicit permission in the current request, agents may run deterministic checks and may,
when requested, launch/sign in/browse read-only UI. They must not:

- press Play/Pause, Previous, Next, Shuffle, Repeat, or Seek;
- transfer playback or change the active device;
- add to or modify the queue;
- edit the library, playlists, follows, or saved state;
- treat earlier permission in the thread as permanent permission.

Observing remote playback and queue state is read-only. Signing out is an account mutation and
should only be tested when it is in scope.

When playback is explicitly authorized for the current test, follow the bounded procedure in the
[acceptance contract](docs/product-and-acceptance-contract.md#explicit-playback-test): inspect the
active device first, mute macOS before local audio, use a named item and short interval, stop/pause
the tested device afterward, and report anything that could not be restored. Queue, transfer,
shuffle/repeat, sleep/wake, and output-device tests each need separately clear scope.

## Build and verification

All commands run from the repository root.

```bash
# Normal non-playback quality gate
./Scripts/check.sh

# Slow clean Debug + Release gate
./Scripts/check-clean.sh

# Build/package/sign/launch a local development app
./script/build_and_run.sh

# Package without launching
./Scripts/package-app.sh --debug
./Scripts/package-app.sh --release

# Privacy-filtered local telemetry bundle
./Scripts/export-diagnostics.sh
```

`check.sh` runs Rust fmt/Clippy/tests, rebuilds a stale generated archive, validates C exports,
builds Swift, runs both check executables, enforces architecture rules, and validates packaging. It
does not sign in or play music.

Minimum verification by change:

| Change | Required verification |
| --- | --- |
| Documentation only | Check links/commands, `git diff --check`, and inspect rendered Markdown when layout matters. |
| Pure domain/policy/parsing | Add/update `AuralChecks`; run `./Scripts/check.sh`. |
| Swift UI/store/API/boundary | Add the closest deterministic or boundary check; run `./Scripts/check.sh`; perform only authorized manual acceptance. |
| Rust/session/queue/FFI | Add Rust coverage, run `./Scripts/check-clean.sh`, and inspect C ownership/export parity. |
| Dependencies/build/signing/packaging/release | Run `./Scripts/check-clean.sh` plus the relevant package/validation path. Never publish merely to test. |
| App icon | Run `./Scripts/generate-icon.sh`; inspect small and large Finder representations; commit `Assets/AuralIcon.png` and `Assets/Aural.icns`. |
| Performance | Compare like-for-like Debug/Release, foreground/background, paused/playing states; record environment and methodology. Playback measurements require permission. |

Use `AURAL_CHECK_REPEATS=N ./Scripts/check.sh` (maximum 25) to stress deterministic ordering when a
concurrency or lifecycle change merits it. A green build alone is insufficient for behavior that can
be covered by a deterministic transition trace.

Do not launch Aural just to prove compilation. `build_and_run.sh` terminates an existing Aural
process before packaging; that can disturb another debugging or authenticated session.

## Generated files, signing, and recovery

Never commit `.build/`, `.swiftpm/`, `Aural.app/`, `dist/`, `diagnostics/`, `AuralArtwork/`, Rust
`target/`, static `.a` archives, signing keychains/certificates, or `.DS_Store` files.

`Backend/lib/libaural_playback.a` is architecture-specific generated output. Build/check scripts
recreate it. The development signing identity and keychain under `.build/aural-signing/` are local,
reproducible, and unsuitable for distribution. Do not install project development identities in the
login keychain or weaken signing to suppress prompts.

Prefer a fresh clone to copying generated state from an old checkout. Do not run destructive Git or
filesystem cleanup over user work. Diagnose first, preserve unrelated changes, and remove only
explicit, verified generated targets.

## Dependencies, security, and public-repository hygiene

- The public repository is `https://github.com/aladh/Aural` and uses Renovate for dependency update
  PRs. Do not add Dependabot alongside it.
- Pin GitHub Actions by full commit SHA and keep the readable version comment.
- Rust dependencies are locked. Review upstream/API/license impact together; librespot changes are
  protocol and behavior changes, not routine version bumps.
- Never commit Spotify credentials, tokens, OAuth callbacks, account exports, Keychain material,
  diagnostic bundles, crash reports with private data, response dumps, or screenshots of a private
  library/account.
- Preserve [LICENSE](LICENSE), [NOTICE](NOTICE),
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [PRIVACY.md](PRIVACY.md), and
  [SECURITY.md](SECURITY.md). Update attribution when adapted upstream code changes.
- Before distributing binaries, review the complete transitive license set. Repository notices are
  not by themselves a binary-distribution audit.
- Report vulnerabilities privately as documented in `SECURITY.md`.

## Versions and releases

`Packaging/Info.plist` is the version source of truth. For a release:

1. Update both `CFBundleShortVersionString` and monotonically increasing `CFBundleVersion`.
2. Run the clean gate and validate the release package.
3. Commit and push the version change.
4. Create an annotated `vMAJOR.MINOR.PATCH` tag exactly matching the short version.
5. Push the tag only with explicit release authorization, then inspect the GitHub workflow and
   prerelease artifacts/checksum.

The tag workflow is ARM64-only and currently produces an experimental hardened-runtime, ad-hoc
signed prerelease, not a notarized Developer ID build. State that limitation in release notes. Never
change tags, publish a release, create a remote, or mutate repository settings merely as a normal
implementation step.

## Definition of done and handoff

Before declaring work complete:

1. Re-read the request and the relevant product/architecture contract.
2. Inspect `git diff` and `git status --short`; preserve unrelated edits and remove accidental
   generated/private files.
3. Add deterministic coverage at the closest ownership boundary.
4. Run the proportional gate and report the exact commands/results. Do not claim manual acceptance
   that was not performed.
5. Check failure, empty, loading, stale-result, cancellation, inactive-window, and accessibility
   states when relevant—not just the happy path.
6. Update the canonical document when product behavior, architecture, setup, privacy, security,
   attribution, or release behavior changed.
7. Summarize the user-visible result, important design choice, verification, and any remaining risk.

Leave the repository so another agent can resume from a fresh clone using only checked-in source
and documentation. If knowledge is required to operate the project safely more than once, capture it
in the appropriate canonical document instead of relying on chat history.
