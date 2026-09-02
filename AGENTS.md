# AGENTS.md

This is the fast operating manual for coding agents working on Aural. Read it before changing the
repository. It captures the judgment and safety constraints needed during implementation and routes
mechanical detail to its canonical owner.

## Mission and priorities

Aural is an **experimental, personal-use, native macOS client for Spotify Premium**. It should feel
like a focused Mac app: polished, fast, resource-conscious, accessible, and unsurprising. It uses
unsupported, reverse-engineered Spotify interfaces, so reliability and containment matter more than
feature count.

When priorities compete:

1. Do not disrupt the user's live Spotify account or expose private data.
2. Preserve playback, account, queue, and concurrency correctness.
3. Prefer idiomatic macOS behavior and a deliberately small product surface.
4. Keep ownership and architecture boundaries explicit and testable.
5. Optimize measured high-impact paths without speculative complexity.

The supported envelope is macOS 15+ on Apple silicon with Spotify Premium. The shipping app is
SwiftUI/AppKit, not a WebView, Chromium shell, or cross-platform UI. Rust/librespot remains a
contained playback leaf under [ADR 001](docs/ADR-001-playback-engine.md). Production uses live
integrations; fakes and synthetic fixtures belong only in checks. Keep the experimental and
unofficial-project warnings prominent in public material.

## Working judgment

- **DRY:** keep knowledge and policy with one canonical owner, but do not force responsibilities
  with different lifetimes through a shared abstraction.
- **KISS:** prefer the smallest direct design that makes ownership, state, and failure behavior
  obvious. Fewer concepts, dependencies, and execution paths are easier to verify.
- **YAGNI:** do not add portability, configuration, frameworks, extension points, or generalized
  infrastructure for hypothetical needs.
- **Make the change easy, then make the easy change:** when behavior fights the structure, first
  create the smallest behavior-preserving seam, then implement through it. Keep both reviewable.
- Remove work before adding machinery. Fix the class of bug at its owner rather than patching a
  symptom, and add the closest deterministic regression check.

These are decision aids, not slogans. DRY does not justify premature abstraction, KISS does not hide
edge cases, and YAGNI does not excuse a known correctness or operability gap.

## Native-Mac taste

Aural should have **quiet confidence**: native, visually calm, information-dense without feeling
cramped, and capable without advertising every capability.

- Start with established macOS behavior. Prefer system structure, materials, typography, controls,
  menus, focus, keyboard behavior, accessibility, and inactive-window semantics over custom chrome.
- Use a Spotify-familiar hierarchy—artwork-led media headers, dense tables, a queue rail, and a
  full-width player shelf—through system-adaptive macOS surfaces. Dark appearance may use a
  near-black canvas; do not force an appearance or build a second theme system. Keep sidebar
  playlist artwork to a bounded shortcut list rather than duplicating the library browser.
- Remove before adding. Every persistent control must earn its space through frequent use or
  essential state. Capability alone does not justify UI.
- Keep one clear hierarchy. At a glance the user should see where they are, what is playing, and the
  primary action. Spend space on content, not decorative containers or repeated labels.
- Make state honest. Loading, empty, stale, disabled, error, reconnecting, and remote-owner states
  are part of the design. Never advertise an action that cannot succeed or display speculation as
  authoritative playback state.
- Preserve spatial anchors and useful content across refresh, metadata arrival, tab changes, and
  window focus. Motion should explain continuity, not delay input or draw attention to chrome.
- Use semantic, restrained color and verify light/dark, active/inactive, selected, disabled,
  keyboard-focused, reduced-motion, and VoiceOver states.
- Fast is a feeling built from details: keep the main thread free, cancel obsolete work, downsample
  artwork, bound caches, avoid gratuitous polling, and prefer deleting work to elaborate machinery.
- Keep architecture cognitively cheap. One explicit owner, a typed transition, and a deterministic
  check beat a clever abstraction or a protocol without a real boundary.
- Judge the whole loop: launch, sign-in, loading, browsing, resizing, keyboard navigation,
  close/reopen, offline recovery, sign-out, and fresh-clone development—not only steady-state UI.

For UI and architecture decisions, make a quick pass over: **glance, delete, native behavior,
truthfulness, stability, edge states, cost, and coherence**. When two options remain, prefer fewer
concepts and controls, clearer ownership, more native behavior, and the better failure mode. The
canonical UX rules and acceptance procedure live in the
[product and acceptance contract](docs/product-and-acceptance-contract.md).

## First five minutes

1. Run `git status --short` and preserve unrelated user changes. Never reset or overwrite them.
2. Read the documents relevant to the task:
   - [README.md](README.md): identity, capabilities, requirements, and limitations.
   - [Product and acceptance contract](docs/product-and-acceptance-contract.md): product behavior
     and safe live-account testing.
   - [Development setup](docs/development-setup.md): fresh clone, generated state, and recovery.
   - [Architecture decision records](docs/architecture-decisions.md): accepted boundaries.
   - [Architecture enforcement inventory](docs/architecture-enforcement.md): each hard rule's
     canonical source, primary enforcement owner, location, and limitation.
   - [CONTRIBUTING.md](CONTRIBUTING.md): commands, fixtures, packaging, releases, repository
     hygiene, and pull-request policy.
3. Inspect the implementation and its nearest checks before editing. Search with `rg`/`rg --files`.
4. Make the smallest cohesive change that fixes the underlying behavior.
5. Verify in proportion to risk, inspect the diff, and update the owning document when an
   intentional product or architecture decision changes.

If this manual conflicts with a more specific canonical document, follow the specific document and
repair the stale link or summary rather than creating another owner.

## Repository and ownership map

| Area | Responsibility |
| --- | --- |
| `Sources/AuralApp/` | Thin executable launcher. |
| `Sources/Aural/` | `AuralCore`: composition root, native UI, feature stores, Spotify/auth adapters, audio renderer, and playback adapter. |
| `Sources/AuralDomain/` | Portable models, reducer, lifetime rules, parsing, sorting, and policies. No UI, audio, network, or FFI imports. |
| `Sources/AuralPlaybackCore/` | Checked-in C header/module map for the Rust ABI. |
| `Backend/aural-playback/` | Rust/librespot session, Connect, streaming, decoding, recovery, queue truth, and C exports. |
| `Sources/AuralChecks/` | Pure domain checks and deterministic playback traces; never ships. |
| `Sources/AuralChecks/DeferredBoundaryChecks/` | Concrete codecs, fixtures, coordinator, and queue checks; never ships. |
| `Scripts/`, `script/`, `Packaging/`, `Assets/` | Verification, build, signing, diagnostics, packaging metadata, privacy manifest, and icon sources. |
| `docs/` | Product contract, accepted decisions, enforcement ownership, protocol notes, and measured baselines. |

Swift target direction is `AuralApp -> AuralCore -> AuralDomain`, with `AuralCore` reaching the C
leaf through the narrow playback adapter. Do not add reverse dependencies for convenience.

## High-consequence architecture

The [enforcement inventory](docs/architecture-enforcement.md) records the compiler, behavior suite,
ABI fixture, source check, or human review that owns each rule. Do not duplicate those mechanisms.
The following constraints remain here because violating them can cause subtle live-account,
lifetime, or foreign-boundary failures:

- `AuralDomain.PlaybackState` is the single atomic playback-presentation snapshot and
  `PlaybackReducer` is its only mutation entrance. `PlaybackStore` is the `@MainActor`
  compatibility/action surface, `PlaybackCoordinator` serializes side effects, and
  `PlaybackEffectRegistry` owns store-level task lifetimes. Reducer acceptance normally gates
  follow-ups. A rejected transport finish may report success only after a same-lifetime
  authoritative snapshot reconciles the expected transport; rejected non-transport, stale,
  superseded, teardown, and epoch-invalidated results stay inert. Do not add TCA, a generic
  `Effect`, or in-place partial playback presentation updates. See
  [ADR 002](docs/ADR-002-playback-state-and-dependencies.md) and
  [ADR 003](docs/ADR-003-playback-command-effects.md).
- Production dependencies are assembled once in `PlaybackEnvironment.live`. Views and feature
  stores render state and invoke narrow actions; they do not construct Spotify APIs, auth
  singletons, or the Rust engine. `TransientFeedbackPresenter` owns transient mutation feedback;
  it is not playback state or a generic event bus.
- Every suspended account-, engine-, selection-, or request-scoped operation must capture and
  revalidate its identity before applying a result. Ordered callback sources carry revisions;
  account and engine generations prevent stale callbacks or teardown from mutating replacements.
  `RustPlaybackEngine` assigns process-local envelope sequence on one drain. Never call
  `AsyncStream.Continuation.yield` or `onTermination` while its fan-out lock is held.
- Rust lifecycle operations that write `SESSION`, `SPIRC`, `PLAYER`, `MIXER`, or
  `PLAYER_EVENT_TX` serialize through one async lifecycle mutex. Do not hold a per-global guard
  across `await` or re-enter the lifecycle lock from an inner helper. Reconnect captures
  `SESSION_GENERATION` at trigger time, revalidates after acquiring the lock, and must not clean up
  or rebuild a newer generation. Exported init re-checks its already-initialized no-op inside the
  lock.
- `QueueService` owns queue precedence and context identity. Metadata may enrich labels but must not
  reorder or erase newer authoritative state. Playlist writes use `PlaylistMutating` and
  `PlaylistMutationController`; keep read-only catalog access separate and mutation DTOs out of
  views.
- `Sources/Aural/Spotify/PlaybackCore.swift` is the only Swift importer of `AuralPlaybackCore`, and
  `RustPlaybackEngine.swift` is its only caller. Keep the checked-in C header and Rust exports
  exactly aligned. FFI ownership, pointer lifetime, allocation, callback, or threading changes need
  Rust coverage and the clean gate.
- Every `aural-playback` `extern "C"` export enters through the panic-barrier helpers in `ffi.rs`.
  Use `block_on_export`, and call `refuse_if_nested_runtime` before mutating lifecycle flags that a
  nested `block_on` would have reached. Nested runtime re-entry returns `ERROR_GENERAL` and is not
  grant supersession. Map panics to the defined sentinel; do not replace the process panic hook,
  hold Rust locks while invoking Swift, or assume the barrier makes invalid foreign pointers safe.
- PCM travels directly from the engine adapter to `AudioRenderer`, never through observable UI
  state. Keep callbacks bounded and do not block the Rust callback thread.
- Swift 6.4 concurrency diagnostics are correctness; CI pins Xcode 26.5 so the same diagnostics
  gate every pull request. Prefer structured concurrency, `AsyncStream`, Observation,
  immutable `Sendable` values, and explicit actor isolation. Combine belongs only at a
  publisher-native system boundary where it is materially simpler. Avoid `nonisolated(unsafe)`,
  mutable global state, broad singletons, and unstructured `Task` lifetimes.

For every new callback, account request, queue provider, or optimistic command, define its owner,
lifetime, cancellation, generation/epoch, ordering/revision, stale-result behavior, error policy,
and deterministic coverage before implementation.

## Implementation conventions

- Keep UI declarative and small. Move orchestration to the owning store/coordinator, pure
  transformations to `AuralDomain`, and transport detail to boundary adapters.
- Preserve the existing feature-store split rather than rebuilding a god controller. Introduce a
  protocol only at a real substitution or system boundary.
- Prefer typed state and exhaustive switches over loosely related booleans and sentinel strings.
- User-facing failures must be actionable and privacy-safe. Use the existing Unified Logging
  facilities; never log tokens, OAuth redirects, raw API payloads, or private account/library IDs.
- Keep caches cost-bounded and clear presentation caches when the window closes. Measure before
  adding caching, polling, timers, or retained artwork.
- Do not add mocks, demo data, placeholder catalog content, or captured Spotify payloads to the
  shipping app. Fixtures are reduced, synthetic, and non-identifying.
- Follow the checked-in Swift formatter and Rust formatter. Comment invariants and non-obvious
  lifetime/order constraints, not line-by-line narration.

## Live Spotify safety

**Default to no playback and no account mutation.** Aural controls a live Spotify Connect account;
a transport command can interrupt music on another computer.

Without explicit permission in the current request, agents may run deterministic checks and may,
when requested, launch, sign in, and browse read-only UI. They must not:

- press Play/Pause, Previous, Next, Shuffle, Repeat, or Seek;
- transfer playback or change the active device;
- add to or modify the queue;
- edit the library, playlists, follows, or saved state;
- sign out, or treat earlier permission in the thread as permanent permission.

Observing remote playback and queue state is read-only. When playback is explicitly authorized for
the current test, follow the bounded procedure in the
[acceptance contract](docs/product-and-acceptance-contract.md#explicit-playback-test): inspect the
active device first, mute macOS before local audio, use a named item and short interval, stop or
pause afterward, and report anything that could not be restored. Queue, transfer, shuffle/repeat,
sleep/wake, and output-device tests each need separately clear scope.

## Commands and proportional verification

Run commands from the repository root:

```bash
# Normal non-playback quality gate
./Scripts/check.sh

# Slow clean Debug + Release gate
./Scripts/check-clean.sh

# Check or rewrite all tracked Swift files
./Scripts/format-swift.sh --check
./Scripts/format-swift.sh --write

# Build/package/sign/launch a development app (only when launch is authorized)
./script/build_and_run.sh

# Package without launching
./Scripts/package-app.sh --debug
./Scripts/package-app.sh --release

# Export a bounded local diagnostic report; review it before sharing
./Scripts/export-diagnostics.sh
```

`check.sh` covers formatting, warning-clean Rust and Swift builds, locked tests, ABI parity,
deterministic check products, architecture contracts, and packaging without signing in or playing
music. `check-clean.sh` owns clean-room Debug and Release verification. The detailed gate,
iteration, packaging, signing, and tagged-release commands live in
[CONTRIBUTING.md](CONTRIBUTING.md).

Minimum verification:

| Change | Required verification |
| --- | --- |
| Documentation only | Check links and commands, run `git diff --check`, and inspect rendered Markdown when layout matters. |
| Pure domain/policy/parsing | Add or update `AuralChecks`; run `./Scripts/check.sh`. |
| Swift UI/store/API/boundary | Add the closest deterministic or boundary check; run `./Scripts/check.sh`; perform only authorized manual acceptance. |
| Rust/session/queue/FFI | Add Rust coverage, run `./Scripts/check-clean.sh`, and inspect ABI ownership/export parity. |
| Dependencies/build/signing/packaging/release | Run the clean gate and relevant package/validation path. Never publish merely to test. |
| Performance | Compare like-for-like configurations and record environment/methodology. Playback measurements require permission. |

Use `AURAL_CHECK_REPEATS=N ./Scripts/check.sh` (maximum 25) when a concurrency or lifecycle change
merits stress. A green build is not enough for behavior that can be covered by a deterministic
transition. Do not launch Aural merely to prove compilation: `build_and_run.sh` terminates an
existing process and can disturb an authenticated session.

Follow [CONTRIBUTING.md](CONTRIBUTING.md#pull-requests) for issue references, PR contents, and manual
testing disclosure. Do not duplicate that policy here.

## Generated state, security, and releases

Generated archives, packages, diagnostics, signing material, private payloads, and account data do
not belong in Git. In particular, never commit `.build/`, `.swiftpm/`, `Aural.app/`, `dist/`,
`diagnostics/`, `AuralArtwork/`, Rust `target/`, static `.a` archives, signing keychains or
certificates, `.DS_Store`, tokens, OAuth callbacks, raw responses, or private screenshots. Inspect
the staged diff. Never install project development identities in the login keychain or weaken
signing to suppress prompts. Prefer fresh-clone recovery and never run destructive cleanup over
user work. See [development setup](docs/development-setup.md),
[CONTRIBUTING.md](CONTRIBUTING.md), [PRIVACY.md](PRIVACY.md), and
[SECURITY.md](SECURITY.md) for the owning procedures.

Preserve `LICENSE`, `NOTICE`, and `THIRD_PARTY_NOTICES.md`; review the full transitive license set
before distributing binaries. GitHub Actions stay SHA-pinned with readable version comments,
Renovate owns dependency updates, and librespot updates are protocol changes rather than routine
bumps. `Packaging/Info.plist` and the tagged-release section of `CONTRIBUTING.md` own version and
release steps. Tags, releases, remotes, and repository settings require explicit authorization;
never mutate them as ordinary verification.

## Definition of done and handoff

Before declaring work complete:

1. Re-read the request and relevant product/architecture contract.
2. Inspect `git diff` and `git status --short`; preserve unrelated edits and remove accidental
   generated or private files.
3. Add deterministic coverage at the closest ownership boundary.
4. Run the proportional gate and report exact commands and results. Do not claim acceptance that
   was not performed.
5. Check relevant failure, empty, loading, stale, cancellation, inactive-window, and accessibility
   states—not only the happy path.
6. Update the canonical owner when product behavior, architecture, setup, privacy, security,
   attribution, or release behavior changes.
7. Summarize the user-visible result, important design choice, verification, and remaining risk.

Leave the repository resumable from a fresh clone using checked-in source and canonical documents.
If knowledge is needed more than once, record it at the proper owner instead of relying on chat.
