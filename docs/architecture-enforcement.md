# Architecture enforcement inventory

This file is a **registry**, not a second architecture manual. It maps each hard rule (or one
coherent group with a single owner) to a stable ID. Read the cited ADR, product, security, or
contributor document for the invariant; do not copy those documents here.

`#83` slice 1 (PR `#123`, `beca6c1`) recorded ownership. Slice 2 pruned obsolete `check.sh`
snapshots, kept durable shell rules, and moved `SRC-PROJ-001` into existing Swift checks. Slice 3
compresses the root `AGENTS.md` by linking product, setup, release, and mechanical detail to those
owners while retaining safety, high-consequence lifecycle/FFI rules, native-Mac judgment, commands,
and completion guidance. Do not add `check-source-contracts.sh`, a temp-tree harness, nested
`AGENTS.md`, or a byte-count gate. `#42` formatter/warning order is unchanged.

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

Slice 2 completed the net-deletion course in issue comment 5471143087.

## Language hygiene (`FMT`) — `#42` / `d1acd598`

| ID | Invariant | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| FMT-SWIFT-001 | Git-tracked `*.swift` (including `Package.swift`, `Sources/`, `Scripts/*.swift`) follows one toolchain `swift-format` contract. | `#42` / `d1acd598`; `CONTRIBUTING.md`; `AGENTS.md` | `Scripts/format-swift.sh` (`--check` → `lint --strict --parallel`; `--write` → `format --in-place`) using `.swift-format`; files from `git ls-files -z -- '*.swift'`; `xcrun --find` requires `swift` and `swift-format` in the same selected toolchain directory | Wrapper runs from `Scripts/check.sh` after the self-test and before Rust/Swift compile | mechanically enforced | Git tracking excludes untracked files; `*.swift` excludes non-Swift paths. A tracked generated `.swift` file would still be formatted. Missing formatter, missing `.swift-format`, non-Git checkout, toolchain mismatch, or an empty tracked set fail the wrapper. | keep |
| FMT-SWIFT-002 | Aural-owned `swift build` invocations fail on compiler warnings. | `#42` / `d1acd598`; `AGENTS.md` | `-Xswiftc -warnings-as-errors` via `aural_swiftc_warnings_as_errors` in `Scripts/swiftpm-env.sh` | Applied to `Aural`, `AuralChecks`, and `AuralBoundaryChecks` in `Scripts/check.sh`, and to `Scripts/compile-release-aural.sh`. Not `Package.swift` `unsafeFlags`. | mechanically enforced | Command-line flag only; does not prove every future `swift build` site. | keep |
| FMT-SWIFT-003 | Wrapper discovery/failure contracts cannot drift from the documented commands. | `#42` / `d1acd598`; `CONTRIBUTING.md` | `Scripts/format-swift-self-test.sh` (temp Git repo + fake toolchain; does not mutate the working tree) | Invoked first in `Scripts/check.sh` | mechanically enforced | Self-test does not run the real `swift-format` binary. | keep |
| FMT-RUST-001 | Rust formatting is `rustfmt`, not hand-edited style. | `#42`; `AGENTS.md`; `CONTRIBUTING.md` | `cargo fmt --all -- --check` | `Scripts/check.sh` (Rust block) | mechanically enforced | `#42` left the Rust baseline unchanged. | keep |
| FMT-RUST-002 | Clippy is warning-clean on all locked targets. | `#42`; `CONTRIBUTING.md` | `cargo clippy --locked --all-targets -- -D warnings` | `Scripts/check.sh` | mechanically enforced | Not `clippy::pedantic`. | keep |

## Compiler and package graph (`CMP`)

| ID | Invariant | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CMP-PLT-001 | macOS 15+ on Apple silicon is the only supported platform. Linux is outside the current support contract. | Product contract; `AGENTS.md`; `CONTRIBUTING.md` | SwiftPM `platforms: [.macOS(.v15)]` for the OS floor. Residual Apple-silicon owner: `rust-toolchain.toml` `targets = ["aarch64-apple-darwin"]`, `Backend/aural-playback/build.sh`, ARM64-only tagged-release packaging in `.github/workflows/release.yml`, and review of contributor/support claims. | `Package.swift`; `rust-toolchain.toml`; `Backend/aural-playback/build.sh`; `release.yml` | mechanically enforced (macOS 15 + ARM64 Rust/release artifacts) + manually reviewed (no Intel support path) | SwiftPM does not encode Apple silicon. Intel macOS is unsupported by packaging and toolchain pins, not by a SwiftPM `arch` flag. The compressed `AGENTS.md` states only the supported envelope. | keep |
| CMP-DEP-001 | Swift target direction is `AuralApp → AuralCore → AuralDomain`. `AuralDomain` has no UI, audio, network, or FFI target dependencies. | ADR 001–002; `AGENTS.md` repository map | SwiftPM target graph | `Package.swift` (`AuralDomain` has no `dependencies:`) | mechanically enforced | Graph forbids target edges, not `import` statements; `SRC-DOM-001` covers imports. | keep |
| CMP-FFI-001 | Only `AuralCore` depends on `AuralPlaybackCore`. | ADR 001 | SwiftPM graph | `Package.swift` | mechanically enforced | Does not prove a single Swift *file* importer; that is `SRC-FFI-001`. | keep |
| CMP-CHK-001 | `AuralChecks` and `AuralBoundaryChecks` never ship in the app executable. | ADR 002; `AGENTS.md` map | Separate products; `AuralChecks` excludes `DeferredBoundaryChecks` and `LegacyLogicChecks.swift` | `Package.swift`; `Scripts/check.sh` builds those products only | mechanically enforced | Packaging scripts must continue omitting these products. | keep |
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
| TST-STATE-001 | `PlaybackState` is the single atomic presentation snapshot; `PlaybackReducer` is the only mutation entrance. | ADR 002; `#84` / PR `#94` | `AuralChecks` reducer and writer-contract suites | `PlaybackReducerChecks.swift`; `PlaybackStoreStateWriterContractChecks.swift`; `PlaybackStoreProjectionContract.swift` | behavior-tested | Writer/projection contracts are line-oriented helpers, not a proof of every future file. Duplicate `check.sh` snapshots (`SRC-WRITER-001`) are removed; `SRC-PROJ-001` is this Swift owner. | keep |
| TST-CMD-001 | Store/coordinator/registry split; no TCA; reducer acceptance gates follow-ups; rejected transport finish may succeed only on same-lifetime reconciled snapshot; stale/superseded/teardown/epoch/non-transport stay inert. | ADR 003 | Domain traces + boundary command suites | `PlaybackCommandLifecycleChecks.swift`; `PlaybackCommandPresentationChecks.swift`; `PlaybackCommandEffectSpike.swift`; `CommandEffectRegistryChecks.swift`; `PlaybackCommandFailureChecks.swift`; `PlaybackCommandLifecycleParityChecks.swift`; `PlaybackEventOutcomeChecks.swift` | behavior-tested | Spike suite documents rejected runtimes; it is not a third architecture. | keep |
| TST-EPC-001 | Account/engine generations, revisions, stale-result protection, and cancellation. | ADR 002 | Domain session + boundary epoch suites | `SessionLifetimeChecks.swift`; `AccountEpochOwnershipChecks.swift`; Rust listener/generation tests in `Backend/aural-playback/src/tests.rs` | behavior-tested | Regex cannot prove capture-and-revalidate. | keep |
| TST-ENV-001 | Ordered callbacks; process-local envelope sequence on one drain; strictly increasing subscriber order; yield/onTermination not under the engine lock. | ADR 002 | Boundary fan-out + engine tests | `EngineEventFanoutChecks.swift`; Rust player-event tests | behavior-tested | | keep |
| TST-LIF-001 | Player-session lifecycle writes serialize on one async mutex; no `Mutex` across `await`; no inner re-entry; reconnect captures `SESSION_GENERATION` at trigger and must not tear down a newer generation; exported init re-checks initialized no-op inside the lock. | ADR 001–002; `AGENTS.md` | Rust lifecycle tests | `lifecycle_serialization_tests.rs`; `session_lifecycle.rs`; `tests.rs` | behavior-tested | Not the Swift session actor. | keep |
| TST-FFI-001 | Every `extern "C"` export uses panic-barrier helpers; nested runtime → `ERROR_GENERAL`; `block_on_export`; do not replace the process panic hook; locks not held across Swift. | `AGENTS.md`; FFI comments | Rust tests + review of new exports | `ffi.rs`; `runtime.rs`; `tests.rs` (`exported_c_function_signatures_are_stable`, `block_on_export_*`) | behavior-tested + ABI/fixture-tested | Tests cannot prove every future export without the signature suite. | keep |
| TST-QUE-001 | `QueueService` owns precedence and context identity; `QueueProtocolProjection` owns upcoming delimiter/playable-track filtering; metadata must not reorder or erase a newer authoritative queue. | ADR 002; ADR 004; product contract | Domain + boundary queue suites | `QueueMutationChecks.swift`; `QueueManagementChecks.swift`; protocol-track serialization in `Backend/aural-playback/src/queue_tests.rs` | behavior-tested | `SRC-OBS-002` is not this owner. | keep |
| TST-PCM-001 | PCM goes engine adapter → `AudioRenderer`, not observable UI state; callbacks stay bounded. | ADR 001–002 | Boundary PCM checks + review | `PCMWriteSpaceChecks.swift` | behavior-tested + manually reviewed (no-block-on-callback-thread) | “Do not block the Rust callback thread” is timing, not a regex. | keep |
| TST-PLM-001 | Playlist writes use `PlaylistMutating` / `PlaylistMutationController`; catalog stays read-only; views do not take Pathfinder mutation DTOs. | ADR 002; product contract | Boundary playlist mutation + domain editability | `PlaylistMutationChecks.swift`; `PlaylistEditabilityChecks.swift` | behavior-tested | The name-list `rg` (`SRC-DUP-003`) is removed; this suite forbids `func addToPlaylist` / `removeFromPlaylist` / `moveInPlaylist` on `CatalogProviding.swift`. | keep |
| TST-FBK-001 | Transient mutation feedback is `TransientFeedbackPresenter`, not `PlaybackState` or an event bus. | ADR 002; product contract | Boundary transient-feedback suite | `TransientFeedbackChecks.swift` | behavior-tested | | keep |
| TST-DEP-001 | Views render state and invoke narrow actions; production dependencies assembled in the composition root (`PlaybackEnvironment.live` / app scene). | ADR 002 | Graph + `SRC-DEP-001` + review | Composition root in `AuralCore`; `SRC-DEP-001` | behavior-tested (workflows) + mechanically enforced (construction sites) | | keep |
| TST-FIX-001 | Check fixtures are reduced, synthetic, non-identifying. | Product contract; `CONTRIBUTING.md` | Fixture contract suite + review | `FixtureContractChecks.swift`; `DeferredBoundaryChecks/Fixtures/` | ABI/fixture-tested + manually reviewed | Cannot prove a new file is non-identifying. | keep |
| TST-RUST-001 | Locked Rust unit suite owns Connect recovery, generations, protocol-track serialization, remaining JSON envelopes, and compile-time C signatures. | `Scripts/check.sh` comment; `CONTRIBUTING.md`; ADR 004 | `cargo test --locked` | `Backend/aural-playback` | behavior-tested | Queue presentation filtering is Swift-owned (`TST-QUE-001`). | keep |
| TST-GATE-001 | `check.sh` always runs every registered Swift suite; `AURAL_CHECK_REPEATS` is 1–25. | `AGENTS.md`; `CONTRIBUTING.md` | `Scripts/check.sh` | Repeat loop; suite filters not passed | mechanically enforced | Local `swift run … -- suite-name` is for iteration only. | keep |

## ABI and cross-language fixtures (`ABI`)

| ID | Invariant | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ABI-SYM-001 | Checked-in C header symbols equal `libaural_playback.a` Aural exports. | ADR 001; PR `#82` | ABI gate in `check.sh` | `Scripts/check.sh` (`nm` vs `aural_playback.h`) | ABI/fixture-tested | Apple `nm` warnings on compiler-builtins are ignored; the set comparison is the contract. | keep with ABI gate |
| ABI-USE-001 | Every remaining header export is called from `PlaybackCore.swift` (comment/string stripped). | PR `#82` | Same ABI block | `Scripts/check.sh` | ABI/fixture-tested | Call-token match is not a semantic FFI proof. | keep with ABI gate |
| ABI-SIG-001 | Exported C function signatures stay aligned with the header. | PR `#82`; `tests.rs` | Rust compile-time signature tests | `Backend/aural-playback/src/tests.rs` | ABI/fixture-tested | Complements `ABI-SYM-001`; do not replace with `rg`. | keep |
| ABI-JSON-001 | Rust-produced engine JSON matches Swift decode fixtures. | `#87` / PR `#97` | Rust serialize + Swift decode of one fixture directory | `json_contract_tests.rs`; `EnginePayloadContractChecks.swift`; `Fixtures/engine/` | ABI/fixture-tested | Source linters cannot prove payload semantics (`#87`). | keep |
| ABI-ARC-001 | `Backend/lib/libaural_playback.a` is generated, untracked, rebuilt when missing or stale. | `AGENTS.md`; `CONTRIBUTING.md` | `check.sh` stale rebuild + `SRC-HYG-001` (no tracked `.a`) | `Scripts/check.sh`; `Backend/aural-playback/build.sh` | mechanically enforced | Architecture-specific archive; not a source input. | keep |

## Focused source and topology (`SRC`) — current owners after slice 2

Durable lexical rules stay in `check.sh`. `SRC-PROJ-001` is the existing Swift contract.
Drag APIs stay in `check.sh` (full `Views/` tree; the playlist suite only samples two files).

| ID | Invariant | Canonical source | Primary owner today | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SRC-DOM-001 | `AuralDomain` must not `import` AppKit, SwiftUI, AVFoundation, or `AuralPlaybackCore`. | ADR 002; `AGENTS.md` | `rg` on `Sources/AuralDomain` | forbidden `^import` in `Scripts/check.sh` | mechanically enforced | Line-start import only; does not prove “no network.” | keep in `check.sh` |
| SRC-FFI-001 | Only `Sources/Aural/Spotify/PlaybackCore.swift` imports `AuralPlaybackCore`. | ADR 001 | Exact `rg -l` path equality | `Scripts/check.sh` | mechanically enforced | Missing file reports as mismatch, not a dedicated missing-scope error. | keep in `check.sh` |
| SRC-FFI-002 | Only `RustPlaybackEngine.swift` contains `PlaybackCore.` call sites. | ADR 001 | Exact `rg -l` path equality under `Sources/Aural` | `Scripts/check.sh` | mechanically enforced | Token `PlaybackCore.` is not a typed call graph. | keep in `check.sh` |
| SRC-DEP-001 | Views and listed feature stores must not construct `PartnerAPI(`, `SpotifyConnectAPI(`, `WebPlayer` API, Keymaster auth/session, `RustPlaybackEngine.shared`, or `PlaybackCore.`. | ADR 002 | Explicit path list + `rg` | `feature_dependencies` array | mechanically enforced | Current list is `Views/` plus named `PlaybackStore*` files, `AccountStore`, `HomeLibraryStore`, `SearchStore`, `PlaylistStore`, `PlaylistMutationController`, and `CatalogStore`. **Already out of scope:** `Sources/Aural/Spotify/MediaDetailStores.swift` (album/artist stores in the AGENTS store split). New store files can also escape. `KeymasterTokenStore.swift` is a token-storage port, not that feature-store list. | keep existing allowlist |
| SRC-ISO-001 | Production Swift must not use `nonisolated(unsafe)`. | `AGENTS.md` | `rg` on `Sources/**/*.swift` | `Scripts/check.sh` (split from `SRC-OBS-001`) | mechanically enforced | Comment/string matches; does not prove other unsafe globals. Does **not** own unstructured `Task`, mutable globals, singletons, or in-place presentation (`DOC-ESCAPE-001`). | keep in `check.sh` |
| SRC-PROJ-001 | `PlaybackStore+Projections.swift` has no explicit setters. | ADR 002; `#84` | Comment-safe lexical match in `PlaybackStoreProjectionContract` | `PlaybackStoreProjectionContract.swift`; `PlaybackProjectionContractChecks.swift` (synthetic + production file) | mechanically enforced | `explicitSetterLines` runs PR `#129` `uncommentedSource` on the whole buffer (`//`, nested `/* */` and ordinary `"""` interiors keep newlines, quoted `"` strings with escapes). Not a Swift lexer: `#"""..."""#` and escaped interior `"""` are out of scope. Setters in other files are out of scope. Semantic reducer ownership stays `TST-STATE-001`. | keep in existing Swift checks |
| SRC-INOUT-001 | Playback revision gates must not take `lastRevision: inout`. | Swift exclusivity; store comments | `rg` in `Sources/Aural/Spotify` | `Scripts/check.sh` | mechanically enforced | Lexical exclusivity aid, not epoch correctness (`TST-EPC-001`). No remaining production `lastRevision` token; the shape is still uniquely owned here. | keep |
| SRC-HYG-001 | Generated/private artifacts are not Git-tracked (`.DS_Store`, `Aural.app/`, `diagnostics/`, `dist/`, `*.a`). | `AGENTS.md`; `CONTRIBUTING.md` | `git ls-files` | `Scripts/check.sh` | mechanically enforced | Does not list `.build/`, `.swiftpm/`, `target/`, Keychain, or `AuralArtwork/` (gitignore + review). | keep in `check.sh` |
| SRC-HYG-002 | Public security-contact placeholders must not remain. | `SECURITY.md`; `CONTRIBUTING.md` | `rg` placeholder strings | README, SECURITY, CONTRIBUTING | mechanically enforced | Token list, not a proof of a working contact. | keep |
| SRC-HYG-003 | Shipping tree and README have no `MockCatalog`, `PlaybackController`, or `demo catalog`. | `AGENTS.md` | `rg` | `Sources/` + `README.md` | mechanically enforced | Tombstone tokens; not a general “no fixtures in app.” | keep as hygiene tokens |
| SRC-HYG-004 | `LogicChecks` directories must not live under shipping `Sources/Aural`. | `AGENTS.md` map | `find` | `Scripts/check.sh` | mechanically enforced | Name tombstone. | keep |
| SRC-DUP-004 | Views must not use `.draggable(`, `.dropDestination(`, `onDrop(`. | Product contract (drag omitted) | `rg` on `Sources/Aural/Views` | `Scripts/check.sh` | mechanically enforced | Uniquely owns the full Views tree. Boundary checks sample table and controller only. Product reason remains `DOC-UI-001`. | keep in `check.sh` |

### Pruned in slice 2 (IDs retained so they are not re-added)

| ID | Why it left `check.sh` | Residual owner |
| --- | --- | --- |
| SRC-OBS-001 | Deleted type-name tombstone (`LiveSpotifyController`) | none; `SRC-ISO-001` kept separately |
| SRC-OBS-002 | QueueService test-gate token list | none (intentional tombstone; `TST-QUE-001` is not a residual scanner) |
| SRC-OBS-003 | Exact projections-file existence tombstone | production-file read in `SRC-PROJ-001` |
| SRC-WRITER-001 | Exact `state =` / `state.member =` snapshots | `TST-STATE-001` |
| SRC-DUP-003 | `CatalogProviding` mutation method-name `rg` | `TST-PLM-001` (`func addToPlaylist` / `removeFromPlaylist` / `moveInPlaylist`) |
| CI-OBS-001 | `brew untap aws/tap` tombstone | none |
| CI-SWIFT-001 | Exact SwiftPM cache YAML snapshot | `CONTRIBUTING.md`; `DOC-CI-001` |

## CI workflow policy asserted by `check.sh` (`CI`)

| ID | Invariant | Canonical source | Primary owner | Current location | Status | Accepted limitation | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- |
| CI-WF-001 | `.github/workflows/ci.yml` exists. | Repository policy | `check.sh` | `Scripts/check.sh` | mechanically enforced | | keep |
| CI-RG-001 | CI prefers an existing runner `rg`, else Homebrew ripgrep. | `CONTRIBUTING.md` | Two `rg -q` checks | `ci.yml` | mechanically enforced | Exact substring, not a parsed workflow AST. | keep |
| CI-RUST-001 | The dedicated Rust lane caches dependency state and native Debug verification products, keyed by runner architecture, `rust-toolchain.toml`, and `Cargo.lock`. | `CONTRIBUTING.md` | Job-scoped exact key assertion | `Scripts/check.sh` vs `.github/workflows/ci.yml` | mechanically enforced | Cache contents remain a workflow review concern. | keep |
| CI-FMT-001 | CI must not Homebrew-install `swift-format` or SwiftLint. | `#42` / `d1acd598` | `rg` denylist in `check.sh` | `Scripts/check.sh` vs `.github/workflows/ci.yml` | mechanically enforced | `ci.yml` prints toolchain `swift-format` version; it does not install a second formatter. | keep |
| CI-REL-001 | macos-26 PR lanes run Rust verification, Swift/architecture verification, and the release `Aural` compile in parallel; the required `Debug quality gate` aggregates all three results. The two scoped `check.sh` invocations preserve the complete ordinary local gate. Content-keyed playback-archive reuse and separate Debug/Release SwiftPM caches may reduce latency but not coverage. | PR `#111` (release compile); `CONTRIBUTING.md` | `.github/workflows/ci.yml` + `Scripts/check.sh` + `Scripts/compile-release-aural.sh` | Workflow lanes and aggregate job; `check.sh` asserts each job-local command, cache key, and aggregate dependency/result check | mechanically enforced | The source check matches selected workflow fragments rather than parsing YAML; action pins remain manual review under `DOC-CI-001`. | keep |

Pin GitHub Actions by full commit SHA (`AGENTS.md`) is **manually reviewed** on workflow-changing PRs (`DOC-CI-001`). `check.sh` does not parse every pin. SwiftPM cache shape is documented in `CONTRIBUTING.md` and reviewed on workflow-changing PRs (`CI-SWIFT-001` removed).

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
| DOC-IMPL-001 | Declarative UI; existing store split (including media-detail stores); protocols only at real boundaries; typed state and exhaustive switches; comments for invariants, not narration. | ADR 002; production store files; `AGENTS.md` summary | Review | Store types under `Sources/Aural/Spotify/`; `AGENTS.md` implementation conventions | manually reviewed | Store-split is not a filename linter. Swift 6.3 diagnostics are `DOC-CONC-001`. Formatting is `FMT-*`. Logging/caches/fixtures are `DOC-LOG-001` / `DOC-CACHE-001` / `CMP-LIVE-001`. | retain as judgment |
| DOC-CONC-001 | Swift 6.3 concurrency diagnostics are part of correctness. Prefer actor isolation and immutable `Sendable` values over suppression. | `AGENTS.md` high-consequence architecture | Package tools version 6.3 and CI's pinned Swift 6.3.3 compiler; remaining warnings fail via `FMT-SWIFT-002` | `swift build` in `Scripts/check.sh` / `compile-release-aural.sh` | mechanically enforced (diagnostics/warnings) + manually reviewed (suppression) | Isolation errors are compiler errors; this is not a ban on every `@preconcurrency` import. | keep |
| DOC-ESCAPE-001 | Avoid unstructured `Task` lifetimes, mutable global state, broad singletons, and in-place partial playback presentation updates. | `AGENTS.md` high-consequence architecture | Review; in-place presentation also `TST-STATE-001` | Domain/store checks + review | manually reviewed + behavior-tested (presentation writes) | Not a regex. `SRC-ISO-001` owns only `nonisolated(unsafe)`. | retain as judgment |
| DOC-LOG-001 | User-facing failure must be actionable and privacy-safe. Never log tokens, OAuth redirects, raw API payloads, or private library/account identifiers. | `AGENTS.md` implementation conventions; `PRIVACY.md`; `SECURITY.md` | Review owns actionable user-facing copy. Privacy sanitization suite owns log/payload hygiene. | `PrivacySanitizationChecks.swift`; Unified Logging; review of notices/alerts | behavior-tested (sanitizers) + manually reviewed (actionable copy) | Cannot prove every `Logger` call or every alert string. `TST-FBK-001` owns transient-feedback *architecture*, not actionability. | keep tests; retain residual as judgment |
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
| DOC-CI-001 | Workflow pins, permissions, and cache policy beyond the `check.sh` substrings. | `CONTRIBUTING.md` | PR review | `.github/workflows/` | manually reviewed | | retain as judgment; SwiftPM cache YAML is no longer snapshotted (`CI-SWIFT-001` pruned) |

## `Scripts/check.sh` assertion inventory

Every fail-the-gate policy site after slice 2, plus one non-failing relink side effect so the
`check.sh` control flow is not silent. Formatter/warning sites 1–3 and 5–6, 12 are unchanged
from `#42`. Remaining architecture sites keep their relative order.

| # | Kind | Inventory ID | Disposition |
| --- | --- | --- | --- |
| 1 | `AURAL_BUILD_CONFIGURATION` must be debug or release | (gate mechanic) | keep |
| 2 | `Scripts/format-swift-self-test.sh` | FMT-SWIFT-003 | keep |
| 3 | `Scripts/format-swift.sh --check` | FMT-SWIFT-001 | keep |
| 4 | `cargo` executable found | (gate mechanic) | keep |
| 5 | `cargo fmt --check` | FMT-RUST-001 | keep |
| 6 | Clippy `--locked --all-targets -- -D warnings` | FMT-RUST-002 | keep |
| 7 | `cargo test --locked` | TST-RUST-001 | keep |
| 8 | Rebuild archive if missing/stale | ABI-ARC-001 | keep |
| 9 | Header vs archive symbol set | ABI-SYM-001 | keep |
| 10 | Header exports consumed by `PlaybackCore.swift` | ABI-USE-001 | keep |
| 11 | Relink `Aural` if archive newer than binary | (side effect) | not a failing policy; keep as build mechanic |
| 12 | `swift build` shipping `Aural` with `-warnings-as-errors` (optional `-DAURAL_DISTRIBUTION`) | FMT-SWIFT-002; CMP-CHK-002 | keep |
| 13 | `AURAL_CHECK_REPEATS` in 1…25 | TST-GATE-001 | keep |
| 14 | Build and run `AuralChecks` (all suites, warnings-as-errors) | CMP-CHK-001; TST-GATE-001; FMT-SWIFT-002 | keep |
| 15 | Build Debug and run `AuralBoundaryChecks` (warnings-as-errors) | CMP-CHK-002; FMT-SWIFT-002 | keep |
| 16 | Domain forbidden imports | SRC-DOM-001 | keep |
| 17 | Single `AuralPlaybackCore` importer | SRC-FFI-001 | keep |
| 18 | Single `PlaybackCore.` caller | SRC-FFI-002 | keep |
| 19 | `nonisolated(unsafe)` | SRC-ISO-001 | keep |
| 20 | No `lastRevision: inout` | SRC-INOUT-001 | keep |
| 21 | Feature/view live-dependency construction | SRC-DEP-001 | keep existing allowlist |
| 22 | SwiftUI drag APIs in Views | SRC-DUP-004 | keep (full Views tree) |
| 23 | No `LogicChecks` dir under `Sources/Aural` | SRC-HYG-004 | keep |
| 24 | Mock/demo catalog tokens | SRC-HYG-003 | keep |
| 25 | Tracked generated artifacts | SRC-HYG-001 | keep |
| 26 | Security placeholder strings | SRC-HYG-002 | keep |
| 27 | `ci.yml` exists | CI-WF-001 | keep |
| 28 | `command -v rg` in workflow | CI-RG-001 | keep |
| 29 | `brew install ripgrep` in workflow | CI-RG-001 | keep |
| 30 | No Homebrew `swift-format` / SwiftLint | CI-FMT-001 | keep |
| 31 | Rust cache key fragment | CI-RUST-001 | keep |
| 32 | Cached parallel Rust/Swift/release lanes aggregate into `Debug quality gate` | CI-REL-001 (PR `#111` release origin) | keep |
| 33 | `plutil -lint Packaging/Info.plist` | CMP-PKG-001 | keep |

**Totals:** 33 numbered `check.sh` sites; **32** fail-the-gate policies and **1** relink side
effect (11). All 32 policies are **keep**. Slice 2 removed 8 failing sites from the prior 40
(projections existence, projections setters, two writer snapshots, catalog method names,
QueueService gates, aws/tap, exact SwiftPM YAML) and split the mixed LiveSpotify/unsafe site
down to unsafe only.

`Scripts/check-clean.sh`: 4 steps, **1** composite policy (clean Debug+Release). Disposition:
keep. No additional `rg` architecture assertions.

## Coverage appendix: `AGENTS.md` compression map

The pre-compression audit established **27,042 bytes**, **414 lines**, **122 surface units**, and
**165 atomic rules**. It counted joined Markdown list items, repository/verification table rows, and
the callback-ownership paragraph, then split packed hard-architecture bullets into distinct
invariants. That baseline proved every normative rule had a disposition before prose was removed.

The link-and-compress slice is **18,679 bytes** and **293 lines**. It does not delete product,
release, generated-state, or mechanical contracts: it links their canonical documents and retains
only the operating summary. Human judgment remains here; compiler/test/ABI/source enforcement
remains with the owner listed above.

| Current `AGENTS.md` section | Inventory ownership (none omitted) |
| --- | --- |
| Mission and priorities | DOC-PRI-001, DOC-PROD-001, CMP-PLT-001, CMP-LIVE-001, SRC-HYG-003 |
| Working judgment | DOC-ENG-001 |
| Native-Mac taste | DOC-TASTE-001, DOC-UI-001, DOC-CACHE-001 |
| First five minutes | DOC-AGENT-001 |
| Repository and ownership map | DOC-MAP-001, CMP-DEP-001, CMP-CHK-001, SRC-DOM-001 |
| High-consequence architecture | TST-STATE-001, TST-CMD-001, TST-DEP-001, TST-FBK-001, TST-EPC-001, TST-ENV-001, TST-LIF-001, TST-QUE-001, TST-PLM-001, TST-PCM-001, TST-FFI-001, ABI-SYM-001, SRC-FFI-001, SRC-FFI-002, SRC-ISO-001, CMP-TCA-001 / ADR 003, DOC-CONC-001, DOC-COMBINE-001, DOC-ESCAPE-001, DOC-ARCH-001 |
| Implementation conventions | DOC-IMPL-001, DOC-LOG-001, DOC-CACHE-001, CMP-LIVE-001, TST-FIX-001, FMT-RUST-001, FMT-SWIFT-001 |
| Live Spotify safety | DOC-SAFE-001 |
| Commands and proportional verification | DOC-VER-001, TST-GATE-001, FMT-*, ABI-*, CMP-*, SRC-*, DOC-PR-001 |
| Generated state, security, and releases | DOC-GEN-001, ABI-ARC-001, DOC-DEP-001, DOC-SEC-001, DOC-CI-001, DOC-REL-001, CMP-PKG-001 |
| Definition of done and handoff | DOC-DOD-001 |

## Adjacent issues (do not reimplement here)

| Work | Owns | Must not be re-owned by regex |
| --- | --- | --- |
| `#42` / `d1acd598` (merged) | Swift format wrapper/config/self-test + warnings-as-errors; existing Rust fmt/clippy | Architecture rules |
| `#84` / PR `#94` (merged) | Reducer-only `PlaybackState` mutation behavior | `SRC-WRITER-001` is deleted; tests remain the owner |
| `#87` / PR `#97` (merged) | Engine JSON payload semantics | `ABI-JSON-001` is the contract, not `rg` |
| PR `#82` (merged) | Header/archive equality and remaining-export consumption | Keep `ABI-SYM-001` / `ABI-USE-001` |
| PR `#111` (merged on `main`) | PR CI release compile with `AURAL_DISTRIBUTION` | `CI-REL-001` |

## Out of slice / verification

No source-contract harness, byte-count gate, nested `AGENTS.md`, runtime dependency, code change, or
policy expansion. `Scripts/check.sh` remains at 33 sites (32 failing + 1 relink); the registry remains
72 active IDs + 7 pruned. Proportional verification is link/path checks, `git diff --stat` /
`--check`, and macos-26 CI.
