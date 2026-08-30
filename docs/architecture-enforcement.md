# Architecture enforcement inventory

This file is a **registry**, not a second architecture manual. It maps each hard rule (or one
coherent group with a single owner) to a stable ID. Read the cited ADR, product, security, or
contributor document for the invariant; do not copy those documents here.

`#83` slice 1 records ownership only. It does not extract `Scripts/check-source-contracts.sh`,
shrink `AGENTS.md`, delete checks, or change the gate. **Do not merge this inventory until `#42`
lands** and the pending formatter/warning rows below are rewritten from that merge. Guessing
wrapper paths would freeze a stale owner.

## How to read a row

- **ID prefixes** are navigation only: `CMP` compiler or package graph, `TST` deterministic
  behavior, `ABI` ABI or cross-language fixtures, `SRC` lexical or topology search, `DOC`
  documented judgment, `FMT` language hygiene, `CI` workflow policy asserted from `check.sh`.
- **Status:** mechanically enforced, behavior-tested, ABI/fixture-tested, manually reviewed,
  deferred, obsolete.
- **Disposition:** keep, move to stronger owner, retain as judgment, generalize, delete.
- A **regex must not** be the primary owner of concurrency, epoch, queue provenance, lifecycle,
  optimistic rollback, or payload correctness.

## Rule lifecycle (later `#83` slices)

1. Record the decision in the canonical product, ADR, security, or repository-policy document.
2. Choose the strongest owner: compiler/graph, then behavior tests, then ABI/fixtures, then a
   focused source check, then human review.
3. Add deterministic coverage before a source rule when behavior is the concern.
4. Update this inventory and the nearest contributor guidance.
5. Remove superseded prose or checks so one invariant does not keep several partial owners.

## Pending `#42` (merge blocker)

Issue `#42` is open. PR `#121` is the active implementation on 2026-08-30; it is **not** merged
main. `#42` will name the Swift formatting and compiler-warning owner and will edit
`Scripts/check.sh`, `CONTRIBUTING.md`, and `AGENTS.md`. This inventory must not invent that
wrapper path.

| ID | Invariant | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| FMT-SWIFT-001 | Git-tracked Swift sources follow one toolchain `swift-format` contract. | `#42` | **Pending `#42`.** Refresh this row from merged main before `#83` merge. | Not on current `main`. Do not assume a script name. | deferred | Unknown wrapper, config path, and file-discovery rule until `#42` merges. | keep after `#42` names the owner |
| FMT-SWIFT-002 | Aural-owned Swift builds fail on compiler warnings. | `#42`; `AGENTS.md` Swift 6.1 diagnostics | **Pending `#42`.** | Current `swift build` in `Scripts/check.sh` does not pass a warnings-as-errors flag. | deferred | Concurrency diagnostics already matter; ordinary warnings are not yet a hard gate. | keep after `#42` |
| FMT-RUST-001 | Rust formatting is `rustfmt`, not hand-edited style. | `#42`; `AGENTS.md`; `CONTRIBUTING.md` | `cargo fmt --all -- --check` in `Scripts/check.sh` | `Scripts/check.sh` (Rust block) | mechanically enforced | Toolchain-owned; not a Swift or architecture rule. | keep (`#42` leaves Rust as-is) |
| FMT-RUST-002 | Clippy is warning-clean on all targets. | `#42`; `CONTRIBUTING.md` | `cargo clippy --all-targets -- -D warnings` | `Scripts/check.sh` | mechanically enforced | Not `clippy::pedantic`. | keep |

Post-`#42` refresh required: replace FMT-SWIFT-001/002 pending text with the merged command,
config file, `check.sh` insertion point, and contributor wording. Do not edit those files in
this slice to “prepare” for `#42`.

## Compiler and package graph (`CMP`)

| ID | Invariant | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CMP-PLT-001 | macOS 15+ is the only platform target. | Product contract; `AGENTS.md` | SwiftPM `platforms: [.macOS(.v15)]` | `Package.swift` | mechanically enforced | Linux is not a constraint; the compiler does not prove Apple silicon. | keep |
| CMP-DEP-001 | Swift target direction is `AuralApp → AuralCore → AuralDomain`. `AuralDomain` has no UI, audio, network, or FFI target dependencies. | ADR 001–002; `AGENTS.md` repository map | SwiftPM target graph | `Package.swift` (`AuralDomain` has no `dependencies:`) | mechanically enforced | Graph forbids target edges, not `import` statements; `SRC-DOM-001` covers imports. | keep |
| CMP-FFI-001 | Only `AuralCore` depends on `AuralPlaybackCore`. | ADR 001 | SwiftPM graph | `Package.swift` | mechanically enforced | Does not prove a single Swift *file* importer; that is `SRC-FFI-001`. | keep |
| CMP-CHK-001 | `AuralChecks` and `AuralBoundaryChecks` never ship in the app executable. | ADR 002; `AGENTS.md` map | Separate products; `AuralChecks` excludes `DeferredBoundaryChecks` | `Package.swift`; `Scripts/check.sh` builds those products only | mechanically enforced | Packaging scripts must continue omitting these products. | keep |
| CMP-CHK-002 | `AuralChecks` does not link `AuralCore` or the Rust archive. Boundary checks may, and stay Debug/`@testable`. | ADR 002; `CONTRIBUTING.md` | Package graph + `check.sh` forcing Debug for `AuralBoundaryChecks` | `Package.swift`; `Scripts/check.sh` | mechanically enforced | Release `check.sh` still builds shipping `Aural` in the requested configuration. | keep |
| CMP-TCA-001 | No TCA or generic Effect package. | ADR 003 | Empty `Package.swift` `dependencies` plus review | `Package.swift`; `CONTRIBUTING.md` | mechanically enforced (graph) + manually reviewed (new deps) | Absence of one package name is not a ban on every future library. | keep |
| CMP-LIVE-001 | Production code uses live integrations; fakes belong in checks. | Product contract; `AGENTS.md` | Package + `SRC-HYG-003` + review of shipping sources | `Package.swift`; `SRC-HYG-003` | mechanically enforced (hygiene tokens) + manually reviewed | Compiler cannot prove “no demo catalog.” | keep |

`Scripts/check-clean.sh` has no extra architecture `rg` checks. It encodes one gate policy:
clean Swift products, rebuild Rust, then `check.sh` Debug and Release. Disposition: **keep** as
the clean-room owner; not a source-contract script.

## Deterministic behavior (`TST`)

Semantic concurrency, epoch, queue, lifecycle, optimistic rollback, and payload rules live here.
Do not promote them to `SRC`.

| ID | Invariant | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| TST-STATE-001 | `PlaybackState` is the single atomic presentation snapshot; `PlaybackReducer` is the only mutation entrance. | ADR 002; `#84` / PR `#94` | `AuralChecks` reducer and writer-contract suites | `PlaybackReducerChecks.swift`; `PlaybackStoreStateWriterContractChecks.swift`; `PlaybackStoreProjectionContract.swift` | behavior-tested | Writer/projection contracts are line-oriented helpers, not a proof of every future file. | keep; later `#83` may drop duplicate `check.sh` snapshots |
| TST-CMD-001 | Store/coordinator/registry split; no TCA; reducer acceptance gates follow-ups; rejected transport finish may succeed only on same-lifetime reconciled snapshot; stale/superseded/teardown/epoch/non-transport stay inert. | ADR 003 | Domain traces + boundary command suites | `PlaybackCommandLifecycleChecks.swift`; `PlaybackCommandPresentationChecks.swift`; `PlaybackCommandEffectSpike.swift`; `CommandEffectRegistryChecks.swift`; `PlaybackCommandFailureChecks.swift`; `PlaybackCommandLifecycleParityChecks.swift`; `PlaybackEventOutcomeChecks.swift` | behavior-tested | Spike suite documents rejected runtimes; it is not a third architecture. | keep |
| TST-EPC-001 | Account/engine generations, revisions, stale-result protection, and cancellation. | ADR 002 | Domain session + boundary epoch suites | `SessionLifetimeChecks.swift`; `AccountEpochOwnershipChecks.swift`; Rust listener/generation tests in `Backend/aural-playback/src/tests.rs` | behavior-tested | Regex cannot prove capture-and-revalidate. | keep |
| TST-ENV-001 | Ordered callbacks; process-local envelope sequence on one drain; strictly increasing subscriber order; yield/onTermination not under the engine lock. | ADR 002 | Boundary fan-out + engine tests | `EngineEventFanoutChecks.swift`; Rust player-event tests | behavior-tested | | keep |
| TST-LIF-001 | Player-session lifecycle writes serialize on one async mutex; no `Mutex` across `await`; no inner re-entry; reconnect captures `SESSION_GENERATION` at trigger and must not tear down a newer generation; exported init re-checks initialized no-op inside the lock. | ADR 001–002; `AGENTS.md` | Rust lifecycle tests | `lifecycle_serialization_tests.rs`; `session_lifecycle.rs`; `tests.rs` | behavior-tested | Not the Swift session actor. | keep |
| TST-FFI-001 | Every `extern "C"` export uses panic-barrier helpers; nested runtime → `ERROR_GENERAL`; `block_on_export`; do not replace the process panic hook; locks not held across Swift. | `AGENTS.md`; FFI comments | Rust tests + review of new exports | `ffi.rs`; `runtime.rs`; `tests.rs` (`exported_c_function_signatures_are_stable`, `block_on_export_*`) | behavior-tested + ABI/fixture-tested | Tests cannot prove every future export without the signature suite. | keep |
| TST-QUE-001 | `QueueService` owns precedence and context identity; metadata must not reorder or erase a newer authoritative queue. | ADR 002; product contract | Domain + boundary queue suites | `QueueMutationChecks.swift`; `QueueManagementChecks.swift`; `Backend/aural-playback/src/queue_tests.rs` | behavior-tested | `SRC-OBS-002` is not this owner. | keep |
| TST-PCM-001 | PCM goes engine adapter → `AudioRenderer`, not observable UI state; callbacks stay bounded. | ADR 001–002 | Boundary PCM checks + review | `PCMWriteSpaceChecks.swift` | behavior-tested + manually reviewed (no-block-on-callback-thread) | “Do not block the Rust callback thread” is timing, not a regex. | keep |
| TST-PLM-001 | Playlist writes use `PlaylistMutating` / `PlaylistMutationController`; catalog stays read-only; views do not take Pathfinder mutation DTOs. | ADR 002; product contract | Boundary playlist mutation + domain editability | `PlaylistMutationChecks.swift`; `PlaylistEditabilityChecks.swift` | behavior-tested | `SRC-DUP-003` only matches three method names. | keep; delete the name-list `rg` later |
| TST-FBK-001 | Transient mutation feedback is `TransientFeedbackPresenter`, not `PlaybackState` or an event bus. | ADR 002; product contract | Boundary transient-feedback suite | `TransientFeedbackChecks.swift` | behavior-tested | | keep |
| TST-DEP-001 | Views render state and invoke narrow actions; production dependencies assembled in the composition root (`PlaybackEnvironment.live` / app scene). | ADR 002 | Graph + `SRC-DEP-001` + review | Composition root in `AuralCore`; `SRC-DEP-001` | behavior-tested (workflows) + mechanically enforced (construction sites) | | keep |
| TST-FIX-001 | Check fixtures are reduced, synthetic, non-identifying. | Product contract; `CONTRIBUTING.md` | Fixture contract suite + review | `FixtureContractChecks.swift`; `DeferredBoundaryChecks/Fixtures/` | ABI/fixture-tested + manually reviewed | Cannot prove a new file is non-identifying. | keep |
| TST-RUST-001 | Locked Rust unit suite owns Connect recovery, generations, queue conversion, JSON envelopes, and compile-time C signatures. | `Scripts/check.sh` comment; `CONTRIBUTING.md` | `cargo test --locked` | `Backend/aural-playback` | behavior-tested | | keep |
| TST-GATE-001 | `check.sh` always runs every registered Swift suite; `AURAL_CHECK_REPEATS` is 1–25. | `AGENTS.md`; `CONTRIBUTING.md` | `Scripts/check.sh` | Repeat loop; suite filters not passed | mechanically enforced | Local `swift run … -- suite-name` is for iteration only. | keep |

## ABI and cross-language fixtures (`ABI`)

| ID | Invariant | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ABI-SYM-001 | Checked-in C header symbols equal `libaural_playback.a` Aural exports. | ADR 001; PR `#82` | ABI gate in `check.sh` | `Scripts/check.sh` (`nm` vs `aural_playback.h`) | ABI/fixture-tested | Apple `nm` warnings on compiler-builtins are ignored; the set comparison is the contract. | keep with ABI gate |
| ABI-USE-001 | Every remaining header export is called from `PlaybackCore.swift` (comment/string stripped). | PR `#82` | Same ABI block | `Scripts/check.sh` | ABI/fixture-tested | Call-token match is not a semantic FFI proof. | keep with ABI gate |
| ABI-SIG-001 | Exported C function signatures stay aligned with the header. | PR `#82`; `tests.rs` | Rust compile-time signature tests | `Backend/aural-playback/src/tests.rs` | ABI/fixture-tested | Complements `ABI-SYM-001`; do not replace with `rg`. | keep |
| ABI-JSON-001 | Rust-produced engine JSON matches Swift decode fixtures. | `#87` / PR `#97` | Rust serialize + Swift decode of one fixture directory | `json_contract_tests.rs`; `EnginePayloadContractChecks.swift`; `Fixtures/engine/` | ABI/fixture-tested | Source linters cannot prove payload semantics (`#87`). | keep |
| ABI-ARC-001 | `Backend/lib/libaural_playback.a` is generated, untracked, rebuilt when missing or stale. | `AGENTS.md`; `CONTRIBUTING.md` | `check.sh` stale rebuild + `SRC-HYG-001` (no tracked `.a`) | `Scripts/check.sh`; `Backend/aural-playback/build.sh` | mechanically enforced | Architecture-specific archive; not a source input. | keep |

## Focused source and topology (`SRC`) — current `check.sh` sites

These are the only class that belongs in a later `check-source-contracts.sh`. Current owner is
still the omnibus `Scripts/check.sh` until a later `#83` slice.

| ID | Invariant | Canonical source | Primary owner today | `check.sh` site | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SRC-DOM-001 | `AuralDomain` must not `import` AppKit, SwiftUI, AVFoundation, or `AuralPlaybackCore`. | ADR 002; `AGENTS.md` | `rg` on `Sources/AuralDomain` | forbidden `^import` | mechanically enforced | Line-start import only; does not prove “no network.” | keep; extract later |
| SRC-FFI-001 | Only `Sources/Aural/Spotify/PlaybackCore.swift` imports `AuralPlaybackCore`. | ADR 001 | Exact `rg -l` path equality | `Scripts/check.sh` | mechanically enforced | Missing file reports as mismatch, not a dedicated missing-scope error. | keep; extract later |
| SRC-FFI-002 | Only `RustPlaybackEngine.swift` contains `PlaybackCore.` call sites. | ADR 001 | Exact `rg -l` path equality under `Sources/Aural` | `Scripts/check.sh` | mechanically enforced | Token `PlaybackCore.` is not a typed call graph. | keep; extract later |
| SRC-DEP-001 | Views and listed feature stores must not construct `PartnerAPI(`, `SpotifyConnectAPI(`, `WebPlayer` API, Keymaster auth/session, `RustPlaybackEngine.shared`, or `PlaybackCore.`. | ADR 002 | Explicit path list + `rg` | `feature_dependencies` array | mechanically enforced | **Brittle path list.** New store files can escape. Later: directory discovery + composition-root allowlist. | generalize then extract |
| SRC-ISO-001 | Production Swift must not use `nonisolated(unsafe)`. | `AGENTS.md` | Combined `rg` with deleted type name | same check as `SRC-OBS-001` | mechanically enforced | Comment/string matches; does not prove other unsafe globals. | keep (split from tombstone); extract later |
| SRC-PROJ-001 | `PlaybackStore+Projections.swift` has no explicit setters (comment-stripped lexical). | ADR 002; `#84` | `rg` setter pattern on that file | `Scripts/check.sh` | mechanically enforced | Semantic reducer ownership stays `TST-STATE-001`. | keep as narrow lexical only |
| SRC-WRITER-001 | `PlaybackStore.state` assigned only at declaration and `send` commit; no `state.member =`. | ADR 002; `#84` | Exact full-line snapshot + member `rg` on eight store files | `Scripts/check.sh` | mechanically enforced | **Exact source-shape snapshot.** Duplicates `TST-STATE-001`. | delete or move to stronger owner (tests) in a later slice |
| SRC-INOUT-001 | Playback revision gates must not take `lastRevision: inout`. | Swift exclusivity; store comments | `rg` in `Sources/Aural/Spotify` | `Scripts/check.sh` | mechanically enforced | Lexical exclusivity aid, not epoch correctness (`TST-EPC-001`). | keep if still the documented shape; else generalize |
| SRC-HYG-001 | Generated/private artifacts are not Git-tracked (`.DS_Store`, `Aural.app/`, `diagnostics/`, `dist/`, `*.a`). | `AGENTS.md`; `CONTRIBUTING.md` | `git ls-files` | `Scripts/check.sh` | mechanically enforced | Does not list `.build/`, `.swiftpm/`, `target/`, Keychain, or `AuralArtwork/` (gitignore + review). | keep; extract later |
| SRC-HYG-002 | Public security-contact placeholders must not remain. | `SECURITY.md`; `CONTRIBUTING.md` | `rg` placeholder strings | README, SECURITY, CONTRIBUTING | mechanically enforced | Token list, not a proof of a working contact. | keep |
| SRC-HYG-003 | Shipping tree and README have no `MockCatalog`, `PlaybackController`, or `demo catalog`. | `AGENTS.md` | `rg` | `Sources/` + `README.md` | mechanically enforced | Tombstone tokens; not a general “no fixtures in app.” | generalize or keep as hygiene tokens |
| SRC-HYG-004 | `LogicChecks` directories must not live under shipping `Sources/Aural`. | `AGENTS.md` map | `find` | `Scripts/check.sh` | mechanically enforced | Name tombstone. | keep or generalize to “no check harness in app target” |
| SRC-OBS-001 | Deleted `LiveSpotifyController` must not re-enter. | Historical cleanup | Combined `rg` with `SRC-ISO-001` | `Scripts/check.sh` | obsolete | Deleted type name. | delete (keep `SRC-ISO-001` separately) |
| SRC-OBS-002 | `QueueService` must not own test-only continuation gates. | Historical move to boundary harness | `rg` gate symbols on `QueueService.swift` | `Scripts/check.sh` | obsolete | Semantic queue rules are `TST-QUE-001`. | delete |
| SRC-OBS-003 | `PlaybackStore+Projections.swift` must exist at that exact path. | Historical split | `[[ ! -f ]]` | `Scripts/check.sh` | obsolete as a file-existence tombstone | Existence is not the read-only invariant (`SRC-PROJ-001`). | delete |
| SRC-DUP-003 | `CatalogProviding` must not declare `addToPlaylist` / `removeFromPlaylist` / `moveInPlaylist`. | ADR 002 | `rg` on one file | `Scripts/check.sh` | mechanically enforced | Duplicates `TST-PLM-001`. | delete after tests remain the owner |
| SRC-DUP-004 | Views must not use `.draggable(`, `.dropDestination(`, `onDrop(`. | Product contract (drag omitted) | `rg` on `Sources/Aural/Views` | `Scripts/check.sh` | mechanically enforced | API tombstone; product reason is occurrence-safe selection, not these tokens. | generalize or delete; product remains `DOC-UI-001` |

## CI workflow policy asserted by `check.sh` (`CI`)

| ID | Invariant | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CI-WF-001 | `.github/workflows/ci.yml` exists. | Repository policy | `check.sh` | `Scripts/check.sh` | mechanically enforced | | keep |
| CI-RG-001 | CI prefers an existing runner `rg`, else Homebrew ripgrep. | `CONTRIBUTING.md` | Two `rg -q` checks | `ci.yml` | mechanically enforced | Exact substring, not a parsed workflow AST. | keep or generalize to “rg available before brew” |
| CI-OBS-001 | CI must not keep the `aws/tap` Homebrew workaround. | Historical CI fix | `rg -q 'brew untap aws/tap'` | `Scripts/check.sh` | obsolete | Tombstone. | delete |
| CI-RUST-001 | Rust cache key remains `macos-rust-${{ hashFiles(`. | `CONTRIBUTING.md` | substring `rg` | `Scripts/check.sh` | mechanically enforced | Exact key fragment. | keep or generalize |
| CI-SWIFT-001 | Swift toolchain hash then `.build` cache with per-commit key and compatible restore prefix; exclude signing dir. | `CONTRIBUTING.md` | **Exact multi-line YAML snapshot** (`rg -U --fixed-strings`) | `Scripts/check.sh` | mechanically enforced | **Brittle whole-block match.** Action SHA and indentation are the check. | delete exact snapshot; retain as CONTRIBUTING + PR review, or generalize |
| CI-REL-001 | macos-15 PR job compiles release `Aural` with `AURAL_DISTRIBUTION` immediately after the unfiltered debug `./Scripts/check.sh`. | PR `#111` (merged `2c4084d` on `main`); `CONTRIBUTING.md` | `.github/workflows/ci.yml` + `Scripts/compile-release-aural.sh` | Workflow steps; `check.sh` asserts the two-step run block | mechanically enforced | `check.sh` snapshots the two step names/commands, not the compile script body. `#111` did not change `check-clean.sh` or `release.yml`. | keep; later generalize the YAML snapshot if it becomes brittle |

Pin GitHub Actions by full commit SHA (`AGENTS.md`) is **manually reviewed** on workflow-changing PRs (`DOC-CI-001`). `check.sh` does not parse every pin.

## Packaging

| ID | Invariant | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CMP-PKG-001 | `Packaging/Info.plist` is well-formed. | `AGENTS.md` versions; `CONTRIBUTING.md` | `plutil -lint` | `Scripts/check.sh` | mechanically enforced | Does not prove version/tag equality (`DOC-REL-001`). | keep with packaging |

## Documented judgment (`DOC`)

Engineering taste, native-Mac restraint, and agent workflow are **not** source-contract
candidates.

| ID | Invariant (group) | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DOC-PRI-001 | Priority order: live-account safety, then correctness, native small surface, explicit architecture, measured performance. | `AGENTS.md` | Human review | `AGENTS.md`; product contract | manually reviewed | | retain as judgment |
| DOC-PROD-001 | Experimental unofficial client; Premium required; no WebView/Chromium; keep public warnings; Rust leaf stays until ADR 001 changes. | README; ADR 001; product contract | Review + `CMP-PLT-001` / `CMP-TCA-001` | README, ADRs | manually reviewed | | retain as judgment (ADR 001 is the leaf decision) |
| DOC-ENG-001 | DRY, KISS, YAGNI, Beck seam-then-change; do not apply them mechanically. | `AGENTS.md` | Review | `AGENTS.md` | manually reviewed | | retain as judgment |
| DOC-TASTE-001 | Taste principles, taste pass (glance/delete/native/truth/stability/edges/cost/coherence), and “prefer fewer concepts.” | `AGENTS.md`; product contract | Human review before UI/architecture changes | `AGENTS.md`; product contract | manually reviewed | Overlaps product UX; product document wins on conflict. | retain as judgment |
| DOC-AGENT-001 | First-five-minutes workflow; never reset unrelated work; follow the more specific canonical doc and update `AGENTS.md` in the same change. | `AGENTS.md` | Review | `AGENTS.md` | manually reviewed | | retain as judgment |
| DOC-MAP-001 | Repository map responsibilities (thin `AuralApp`, domain/portable checks never ship, scripts vs packaging). | `AGENTS.md`; ADR 002 | `CMP-*` + review | map table | manually reviewed + `CMP-CHK-001` | | retain as judgment; graph owns shipping |
| DOC-IMPL-001 | Declarative UI; store split; protocols only at real boundaries; typed state; comment policy; rustfmt not hand-format (Rust owned by `FMT-RUST-001`). | `AGENTS.md` | Review | `AGENTS.md` | manually reviewed | Store-split is not a filename linter. | retain as judgment |
| DOC-LOG-001 | Never log tokens, OAuth redirects, raw API payloads, or private library/account identifiers. | `PRIVACY.md`; `SECURITY.md`; `CONTRIBUTING.md` | Privacy sanitization suite + review | `PrivacySanitizationChecks.swift`; Unified Logging | behavior-tested (sanitizers) + manually reviewed | Cannot prove every `Logger` call. | keep tests; retain residual as judgment |
| DOC-CACHE-001 | Cost-bounded caches; purge presentation caches when the main window closes; measure before adding timers. | Product contract; `PRIVACY.md` | Review + some boundary coverage | product contract | manually reviewed | | retain as judgment |
| DOC-UI-001 | Native controls; 220-pt equal sidebars; Sign Out in app menu; transport order and skip glyphs; disabled Play with no track; no silent transfer; progress re-anchor; queue provenance vs Unknown; playlist table rules; window-close keeps Dock app. | Product contract (canonical); `AGENTS.md` summary | Product contract + authorized manual acceptance | `docs/product-and-acceptance-contract.md`; some panel/workflow checks | behavior-tested (narrow) + manually reviewed | Screenshot mismatch is a symptom. | retain as judgment except where a suite already covers a slice |
| DOC-SAFE-001 | Default no playback and no account mutation; listed transport/queue/library edits require explicit current-request permission; sign-out is a mutation; bounded explicit-playback procedure. | Product contract § safe acceptance; `AGENTS.md` | Agent/maintainer procedure | product contract | manually reviewed | Not mechanically enforceable in CI. | retain as judgment |
| DOC-VER-001 | Commands from repo root; proportional verification matrix; do not launch the app only to prove compile; `build_and_run.sh` kills an existing Aural; green build ≠ covered behavior. | `AGENTS.md`; `CONTRIBUTING.md` | Review | `AGENTS.md` | manually reviewed | | retain as judgment |
| DOC-PR-001 | Plain `Contributes to #N`; no closing keywords. | `CONTRIBUTING.md` § Pull requests | Review | `CONTRIBUTING.md` | manually reviewed | Auto-close is disabled on the repo; wording is still the contract. | retain as judgment |
| DOC-GEN-001 | Never commit `.build/`, `.swiftpm/`, `Aural.app/`, `dist/`, `diagnostics/`, `AuralArtwork/`, Rust `target/`, static `.a`, signing material, `.DS_Store`. Do not install project identities in the login keychain. Prefer fresh clone; no destructive cleanup of user work. | `AGENTS.md`; `CONTRIBUTING.md` | `SRC-HYG-001` + gitignore + review | gitignore; `check.sh` | mechanically enforced (subset) + manually reviewed | Tracked-file `rg` is a subset of the commit ban. | keep subset; retain rest as judgment |
| DOC-DEP-001 | Renovate only (no Dependabot); pin Actions by SHA + version comment; locked Rust deps; review librespot as protocol change. | `AGENTS.md`; `CONTRIBUTING.md` | Review | workflows; `Cargo.lock` | manually reviewed | | retain as judgment |
| DOC-SEC-001 | Never commit credentials, tokens, OAuth, account exports, Keychain, diagnostics, private screenshots; preserve license/privacy/security files; binary license review before distribution; report vulns via `SECURITY.md`. | `SECURITY.md`; `PRIVACY.md`; `CONTRIBUTING.md` | Review + `SRC-HYG-*` | those files | manually reviewed | | retain as judgment |
| DOC-REL-001 | `Packaging/Info.plist` versions; annotated matching tag; push tag only with authorization; ARM64 ad-hoc prerelease limitation in notes; never change tags/remotes/settings as a normal step. | `AGENTS.md`; `CONTRIBUTING.md` tagged releases | Release workflow + maintainer | `Packaging/Info.plist`; `.github/workflows/release.yml` | manually reviewed + workflow | `plutil` does not prove tag match. | retain as judgment |
| DOC-DOD-001 | Definition of done and handoff (coverage, report exact commands, no claimed unperformed acceptance, update canonical docs, resume from a fresh clone). | `AGENTS.md` | Review | `AGENTS.md` | manually reviewed | | retain as judgment |
| DOC-ARCH-001 | When adding a callback, account request, queue provider, or optimistic command, define owner, lifetime, cancellation, epoch, ordering, stale-result, error policy, and coverage. | ADR 002; `AGENTS.md` | Review + requiring a `TST` suite in the same change | ADRs | manually reviewed | | retain as judgment |
| DOC-COMBINE-001 | Prefer structured concurrency / `AsyncStream` / Observation; Combine only at a publisher-native boundary. | Product contract; `AGENTS.md` | Review | those docs | manually reviewed | Not a ban-`import Combine` linter in this slice. | retain as judgment |
| DOC-CI-001 | Workflow pins, permissions, and cache policy beyond the `check.sh` substrings. | `CONTRIBUTING.md` | PR review | `.github/workflows/` | manually reviewed | | retain as judgment; `CI-SWIFT-001` is the brittle mechanical twin |

## `Scripts/check.sh` assertion inventory

Every fail-the-gate policy site on current `main` (`2c4084d`). Gate mechanics (toolchain present,
configuration enum, relink if archive newer) are included so none are silent.

| # | Kind | Inventory ID | Disposition |
| --- | --- | --- | --- |
| 1 | `AURAL_BUILD_CONFIGURATION` must be debug or release | (gate mechanic) | keep |
| 2 | `cargo` executable found | (gate mechanic) | keep |
| 3 | `cargo fmt --check` | FMT-RUST-001 | keep |
| 4 | Clippy `-D warnings` | FMT-RUST-002 | keep |
| 5 | `cargo test --locked` | TST-RUST-001 | keep |
| 6 | Rebuild archive if missing/stale | ABI-ARC-001 | keep |
| 7 | Header vs archive symbol set | ABI-SYM-001 | keep |
| 8 | Header exports consumed by `PlaybackCore.swift` | ABI-USE-001 | keep |
| 9 | Relink `Aural` if archive newer than binary | (gate mechanic) | keep |
| 10 | `swift build` shipping `Aural` (optional `-DAURAL_DISTRIBUTION`) | CMP-CHK-002 / PR `#111` local compile script | keep |
| 11 | `AURAL_CHECK_REPEATS` in 1…25 | TST-GATE-001 | keep |
| 12 | Build and run `AuralChecks` (all suites) | CMP-CHK-001; TST-GATE-001 | keep |
| 13 | Build Debug and run `AuralBoundaryChecks` | CMP-CHK-002 | keep |
| 14 | Domain forbidden imports | SRC-DOM-001 | keep |
| 15 | Single `AuralPlaybackCore` importer | SRC-FFI-001 | keep |
| 16 | Single `PlaybackCore.` caller | SRC-FFI-002 | keep |
| 17 | `LiveSpotifyController` or `nonisolated(unsafe)` | SRC-OBS-001 + SRC-ISO-001 | delete tombstone; keep unsafe |
| 18 | Projections file exists | SRC-OBS-003 | delete |
| 19 | No setters in projections file | SRC-PROJ-001 | keep (lexical) |
| 20 | Exact `state =` lines in store files | SRC-WRITER-001 | delete / move to TST |
| 21 | No `state.member =` in store files | SRC-WRITER-001 | delete / move to TST |
| 22 | No `lastRevision: inout` | SRC-INOUT-001 | keep or generalize |
| 23 | Feature/view live-dependency construction | SRC-DEP-001 | generalize |
| 24 | `CatalogProviding` mutation func names | SRC-DUP-003 | delete |
| 25 | `QueueService` test gates | SRC-OBS-002 | delete |
| 26 | SwiftUI drag APIs in Views | SRC-DUP-004 | generalize or delete |
| 27 | No `LogicChecks` dir under `Sources/Aural` | SRC-HYG-004 | keep or generalize |
| 28 | Mock/demo catalog tokens | SRC-HYG-003 | keep or generalize |
| 29 | Tracked generated artifacts | SRC-HYG-001 | keep |
| 30 | Security placeholder strings | SRC-HYG-002 | keep |
| 31 | `ci.yml` exists | CI-WF-001 | keep |
| 32 | `command -v rg` in workflow | CI-RG-001 | keep or generalize |
| 33 | `brew install ripgrep` in workflow | CI-RG-001 | keep or generalize |
| 34 | No `brew untap aws/tap` | CI-OBS-001 | delete |
| 35 | Rust cache key fragment | CI-RUST-001 | keep or generalize |
| 36 | Exact SwiftPM cache YAML block | CI-SWIFT-001 | delete snapshot / generalize |
| 37 | Release `AURAL_DISTRIBUTION` step after debug gate | CI-REL-001 (PR `#111`) | keep |
| 38 | `plutil -lint Packaging/Info.plist` | CMP-PKG-001 | keep |

**Totals:** 38 `check.sh` assertion sites. Dispositions: **keep** 22 (1–16, 19, 29–31, 37–38);
**keep or generalize** 6 (22, 27–28, 32–33, 35); **generalize** 1 (23); **generalize or
delete** 1 (26); **delete or move to tests** 2 (20–21); **delete** 5 (18, 24, 25, 34, and the
`LiveSpotifyController` token); **mixed** 1 (17: delete tombstone, keep `SRC-ISO-001`).
22+6+1+1+2+5+1 = 38.

`Scripts/check-clean.sh`: 4 steps, **1** composite policy (clean Debug+Release). Disposition:
keep. No additional `rg` architecture assertions.

## Coverage appendix: `AGENTS.md` on current `main`

**File identity:** `AGENTS.md` is **26,821 bytes** and **409 lines** (`wc -c` / `wc -l`, UTF-8,
newline-terminated). Same as issue comment 5470746515 on this `main`.

### Counting method

1. **Surface rows (122).** Parse markdown list items by joining wrapped continuation lines
   (**104** items). Add repository-map and verification-matrix **data** rows (**10 + 7 = 17**).
   Add the non-list hard-architecture paragraph “When adding a callback…” (**1**).
   104 + 17 + 1 = **122** surface units. Nested first-five-minutes document links are included in
   the 104 so they are not silent; they map to `DOC-AGENT-001`, not to new mechanical IDs.
2. **Normative vs judgment.** A surface unit is **normative** if it states a must / must-not /
   only / never / do-not / required / equivalent constraint (including “is the only”,
   “never ships”, “avoid `nonisolated(unsafe)`”, live-safety children under “they must not”,
   and required release/DoD steps). Taste-pass **questions** and DRY/KISS/YAGNI slogans are
   still inventoried (`DOC-TASTE-001`, `DOC-ENG-001`) so they are not omitted; they are not
   source-contract candidates.
3. **Atomic split (165).** Split packed **Hard architecture** bullets on sentence boundaries
   (**43** sentences from **16** `-` bullets plus the callback paragraph). Further split
   conjunctions that are distinct invariants (for example `nonisolated(unsafe)` vs unstructured
   `Task`; Pathfinder DTOs vs catalog add/remove; panic-barrier vs process hook). Product and
   implementation packed bullets that share one owner stay **grouped** (this index). The
   resulting atomic count is **165**, matching the prior audit’s “about 165” after the same
   split. Taste principles that restate product UX are not double-counted as extra mechanical
   rules.

Judgment-sized share: **21** surface units in taste/principles/taste-pass that stay human
(`DOC-ENG-001`, `DOC-TASTE-001`) — aligned with the prior “about 21.” Stronger-owner share:
hard-architecture and map/FFI/check-shipping units already owned by ADR/compiler/tests/ABI
(**about 45** surface units). This registry does not treat those counts as a second spec.

| `AGENTS.md` section | Surface units | Inventory IDs (none omitted) |
| --- | --- | --- |
| Mission and priorities (5 numbered + 6 constraints) | 11 list | DOC-PRI-001, DOC-PROD-001, CMP-PLT-001, CMP-LIVE-001, CMP-TCA-001 / ADR 001, SRC-HYG-003 |
| Engineering principles | 4 list + reinforcing paragraph | DOC-ENG-001 |
| Taste and judgment (12 principles + 8-pass + preference) | 20 list | DOC-TASTE-001 (product overlaps DOC-UI-001) |
| First five minutes | 10 list (incl. 5 nested doc links) | DOC-AGENT-001 |
| Repository map table | 10 rows + 1 reverse-dep sentence | DOC-MAP-001, CMP-DEP-001, CMP-CHK-001, SRC-DOM-001 |
| Hard architecture | 16 bullets + 1 paragraph → 43+ atomic | TST-STATE-001, TST-CMD-001, TST-DEP-001, TST-FBK-001, TST-EPC-001, TST-ENV-001, TST-LIF-001, TST-QUE-001, SRC-FFI-001, SRC-FFI-002, TST-PLM-001, TST-PCM-001, ABI-SYM-001, TST-FFI-001, DOC-COMBINE-001, SRC-ISO-001, DOC-ARCH-001 |
| Implementation conventions | 10 list | FMT-SWIFT-002 (pending), DOC-IMPL-001, DOC-LOG-001, DOC-CACHE-001, CMP-LIVE-001, TST-FIX-001, FMT-RUST-001 |
| macOS product and UI | 9 list + screenshot sentence | DOC-UI-001, TST-QUE-001 |
| Live Spotify safety | 5 forbidden + surrounding prose | DOC-SAFE-001 |
| Build and verification | 7 table rows + command prose | DOC-VER-001, TST-GATE-001, FMT-RUST-*, ABI-*, CMP-*, SRC-* (gate description), DOC-PR-001 |
| Generated files, signing, recovery | 3 prose blocks | DOC-GEN-001, ABI-ARC-001 |
| Dependencies, security, hygiene | 7 list | DOC-DEP-001, DOC-SEC-001, DOC-CI-001 |
| Versions and releases | 5 numbered + tag-workflow paragraph | DOC-REL-001, CMP-PKG-001 |
| Definition of done and handoff | 7 numbered + resume paragraph | DOC-DOD-001 |

## Adjacent issues (do not reimplement here)

| Work | Owns | Must not be re-owned by regex |
| --- | --- | --- |
| `#42` / PR `#121` (open) | Swift format + warning-as-error; existing Rust fmt/clippy | Architecture rules |
| `#84` / PR `#94` (merged) | Reducer-only `PlaybackState` mutation behavior | `SRC-WRITER-001` is a duplicate snapshot |
| `#87` / PR `#97` (merged) | Engine JSON payload semantics | `ABI-JSON-001` is the contract, not `rg` |
| PR `#82` (merged) | Header/archive equality and remaining-export consumption | Keep `ABI-SYM-001` / `ABI-USE-001` |
| PR `#111` (merged on this `main`) | PR CI release compile with `AURAL_DISTRIBUTION` | `CI-REL-001` |

## Explicitly out of this slice

No scripts, fixtures, tests, CI rules, byte-count gates, nested `AGENTS.md`, dependencies,
parser/lint frameworks, production or check source edits, runtime behavior, app launch, sign-in,
account access, or Spotify playback.

## Verification snapshot (this docs slice)

Recorded when this file was written against `origin/main` `2c4084d`:

- `AGENTS.md`: 26,821 bytes, 409 lines; 122 surface units; 165 atomic after packed-hard-rule
  split (methods above).
- `Scripts/check.sh`: 38 assertion sites; dispositions in the assertion table.
- `Scripts/check-clean.sh`: 1 composite clean-gate policy.
- This registry: 75 stable IDs (4 FMT, 8 CMP, 14 TST, 5 ABI, 17 SRC, 6 CI, 21 DOC) plus 38
  numbered `check.sh` sites and 1 `check-clean.sh` policy. `docs/architecture-enforcement.md` is
  37,693 bytes and 303 lines at write time (`wc -c` / `wc -l`).
- Proportional docs verification: path existence, `git diff --check`. No `./Scripts/check.sh`
  (macOS/Swift) required for this slice.
