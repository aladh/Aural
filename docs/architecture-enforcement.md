# Architecture enforcement inventory

This is the routing table for Spotty's hard rules. It tells agents where a rule is decided, how it is
proved, and where enforcement is intentionally semantic rather than mechanical. It is not a second
architecture manual and it does not repeat complete requirements from ADRs, product contracts, or
agent instruction files.

Spotty has no human implementation or review path. In this document, **semantic agent review** means
inspection of the affected code, tests, diff, and canonical decisions by the implementing agent and
available automated reviewers. It is evidence, but it is weaker than compiler, deterministic test,
ABI, or focused source enforcement and must never be described as machine proof.

## Enforcement order

Use the strongest owner that can express the invariant without lying about what it proves:

1. compiler, package graph, or platform configuration;
2. deterministic behavior tests;
3. ABI/signature/cross-language fixtures;
4. a narrow source or topology check for genuinely lexical rules;
5. semantic agent review for product judgment, taste, scope, and failure-mode analysis.

Do not promote concurrency, epochs, queue provenance, lifecycle, optimistic rollback, or payload
correctness into regex snapshots. Conversely, do not rely on prose when the package graph or a small
source check can own an exact boundary.

Stable IDs below preserve searchability for existing issue and code history. They are navigation, not
an API and not a reason to create one row per implementation detail.

## Mechanically enforced families

### Toolchain, platform, and package graph

| IDs | Invariant | Canonical decision | Primary enforcement |
| --- | --- | --- | --- |
| `FMT-SWIFT-001`–`003` | One selected-toolchain `swift-format` contract; Spotty builds fail on warnings; wrapper discovery cannot drift | `CONTRIBUTING.md` | `Scripts/format-swift.sh`, its self-test, and warning flags in `Scripts/swiftpm-env.sh` / build scripts |
| `FMT-RUST-001`–`002` | Rust is rustfmt-clean and Clippy warning-clean on locked targets | `CONTRIBUTING.md` | `cargo fmt --all -- --check`; `cargo clippy --locked --all-targets -- -D warnings` in `Scripts/check.sh` |
| `CMP-PLT-001` | macOS 15+ on Apple Silicon is the supported runtime envelope | Product contract | `Package.swift`, pinned ARM64 Rust target/build, and ARM64 release workflow; support wording remains semantic |
| `CMP-DEP-001`, `CMP-FFI-001` | Target direction is `SpottyApp -> SpottyCore -> SpottyDomain`; only SpottyCore depends on the C module | ADR 001–002 | SwiftPM target graph plus focused import checks |
| `CMP-CHK-001`–`002` | Test targets never ship; pure tests do not depend on SpottyCore/Rust; boundary tests remain separate | ADR 002 | SwiftPM targets and `Scripts/check.sh` |
| `CMP-TCA-001` | No TCA or generic Effect framework | ADR 003 | Empty external Swift dependency graph plus semantic review of dependency additions |
| `CMP-LIVE-001` | Shipping code uses live integrations; fakes and synthetic hooks stay in checks | Product contract | Package separation, hygiene checks, deterministic fixture checks, and semantic review |
| `CMP-PKG-001` | Packaging metadata remains parseable | Agent operations | `plutil -lint Packaging/Info.plist` in `Scripts/check.sh` |

### Deterministic behavior

| IDs | Invariant | Canonical decision | Primary enforcement |
| --- | --- | --- | --- |
| `TST-STATE-001` | `PlaybackState` is one atomic snapshot and `PlaybackReducer` is its mutation entrance | ADR 002 | Reducer/writer/projection tests in `SpottyDomainTests` |
| `TST-CMD-001` | Store/coordinator/registry ownership, acceptance gating, same-lifetime reconciliation, and inert stale outcomes | ADR 003 | Command lifecycle, presentation, failure, parity, registry, and event-outcome suites |
| `TST-EPC-001`, `TST-ENV-001` | Generations, revisions, cancellation, stale-result protection, ordered callback delivery, and lock-safe fan-out | ADR 002 | Session/epoch/fan-out Swift checks plus Rust generation/listener tests |
| `TST-LIF-001` | Rust lifecycle writes serialize; reconnect and init revalidate generations under the owner mutex | ADR 001–002 | `lifecycle_serialization_tests.rs`, `session_lifecycle.rs` tests, and related Rust suites |
| `TST-FFI-001` | Every C export is panic-contained; nested runtime fails safely; Rust locks do not cross Swift callbacks | ADR 001 and scoped agent guidance | Rust export/runtime tests plus ABI signature coverage |
| `TST-QUE-001` | Swift owns queue presentation over authoritative unfiltered protocol state; the engine sends a typed C queue snapshot (protocol rows, slim current-track identity, `queue_revision`, replacement-disallow flags) | ADR 002 and ADR 005 | Domain suite for presentation; Rust C-snapshot layout/callback/getter coverage for the wire |
| `TST-DEV-001` | `ConnectDeviceProjection` owns device activity, sort, and empty-type fallback; the engine sends a typed C device-list snapshot (protocol members plus `active_device_id`) | ADR 005 | Domain suite for presentation; Rust C-snapshot layout/callback coverage for the wire |
| `TST-CON-001` | `ConnectionSnapshotProjection` owns session phase and empty-device-ID fallback; the engine sends a typed C connection snapshot (session flags, `credentials_rejected`, `device_id`, `last_error`) | ADR 005 | Domain suite for presentation; Rust C-snapshot layout/callback coverage for the wire |
| `TST-PBK-001` | `PlaybackSnapshotProjection` owns engine playback transport, empty-URI identity, timestamp correction, and omitted-repeat fallback; the engine sends a typed C playback snapshot (protocol playing/paused flags, track URI, context URI, timing, options, and active-device fact) | ADR 005 | Domain suite for presentation; Rust C-snapshot layout/callback coverage for the wire |
| `TST-RES-001` | User-resume and reconnect-rehydration load targets come from one Swift `ResumeLoadPlan` over sticky resume-load URIs issued through seek-capable `spotty_playback_load`; the engine holds readiness open behind `resume_pending` and Swift issues one load sequence per engine session generation | ADR 005 | `ResumeLoadPlanChecks.swift`, store capture vs presentation, `ResumeLoadSequence` for both callers in `ResumeLoadSequenceChecks.swift`, the once-per-generation and stale-window triggers in the workflow suite, and Rust identity / window / export-signature coverage |
| `TST-PCM-001` | PCM bypasses observable UI state and callbacks stay bounded | ADR 001–002 | PCM write-space/backpressure boundary checks plus semantic timing review |
| `TST-PLM-001`, `TST-FBK-001` | Playlist writes stay behind mutation owners; transient mutation feedback stays out of playback state | ADR 002 and product contract | Playlist/editability and transient-feedback suites |
| `TST-DEP-001` | Live dependencies are assembled at composition; views/stores use narrow injected boundaries | ADR 002 | Package/source topology plus injected workflow checks |
| `TST-FIX-001` | Fixtures are reduced, synthetic, and non-identifying | Product/privacy contract | Fixture contract suite plus semantic privacy review |
| `TST-RUST-001` | Locked Rust suite owns Connect recovery, protocol serialization, generations, export signatures, and the reconnect rehydration window; resume target order is Swift-owned under `TST-RES-001` | ADR 001 and ADR 005 | `cargo test --locked` in `Scripts/check.sh` |
| `TST-GATE-001` | The complete gate runs every discovered Swift test in both targets; repeat count is bounded to 1–25 | Agent operations | `Scripts/check.sh` test filtering/repeat behavior |

### ABI and cross-language contracts

| IDs | Invariant | Primary enforcement |
| --- | --- | --- |
| `ABI-SYM-001`, `ABI-USE-001` | Checked-in C declarations equal archive exports and every retained export is consumed by `PlaybackCore.swift` | Header/archive comparison and export-use checks in `Scripts/check.sh` |
| `ABI-SIG-001` | C signatures stay compile-time compatible with Rust exports | Clang-parsed header comparison against `abi-signatures.txt`, paired with Rust compile-time function assignments and fixture-parity tests |
| `ABI-ARC-001` | The static archive is generated, untracked, and rebuilt when missing or stale | Build script, stale detection, gitignore, and tracked-artifact check |

### Focused source and topology checks

These rules are intentionally lexical; they complement rather than replace semantic behavior tests.

| IDs | Exact boundary | Owner |
| --- | --- | --- |
| `SRC-DOM-001` | SpottyDomain has no AppKit, SwiftUI, AVFoundation, or C-module import | `Scripts/check.sh` |
| `SRC-FFI-001`–`002` | One C-module importer and one `PlaybackCore` caller | `Scripts/check.sh` |
| `SRC-DEP-001` | Views and named feature stores do not construct live auth/network/playback dependencies | `Scripts/check.sh`; new store paths require semantic scope review |
| `SRC-ISO-001` | Shipping Swift contains no `nonisolated(unsafe)` | `Scripts/check.sh` |
| `SRC-UI-001` | Fixed dark appearance has one owner and shipping code does not add appearance-mode branching | `Scripts/check.sh` plus product acceptance |
| `SRC-PROJ-001` | Playback projections expose no explicit setters | Swift projection contract checks |
| `SRC-INOUT-001` | Revision gates do not use `lastRevision: inout` | `Scripts/check.sh`; epoch correctness remains behavior-tested |
| `SRC-HYG-001`–`004` | No tracked generated/private artifacts, security placeholders, mock/demo tombstones, or shipping `LogicChecks` directory | `Scripts/check.sh`, gitignore, and privacy review |
| `SRC-DUP-004` | View code does not introduce the intentionally unsupported drag APIs | `Scripts/check.sh` and product contract |
| `SRC-SIGN-001` | Authenticated development launch requires the Apple anchor + Team ID validator and never silently falls back to a self-signed identity; packaging keeps the identity override and validation stays `--keychain-stable` | `Scripts/check.sh` signing-policy assertions over `script/build_and_run.sh`, `Scripts/package-app.sh`, and `Scripts/validate-app.sh`; behavior remains semantic review under `DOC-SEC-002` |

The removed IDs `SRC-OBS-001`–`003`, `SRC-WRITER-001`, `SRC-DUP-003`, `CI-OBS-001`,
`CI-SWIFT-001`, and `ABI-JSON-001` stay retired. Do not recreate them as duplicate snapshots; their behavior is owned by
the package graph, deterministic suites, current focused checks, or semantic review above.

### CI and release workflow

| IDs | Invariant | Primary enforcement |
| --- | --- | --- |
| `CI-WF-001`, `CI-RG-001` | CI workflow exists and acquires ripgrep only when absent | `Scripts/check.sh` workflow assertions |
| `CI-RUST-001` | Rust cache key/content stays tied to runner architecture, toolchain, and lockfile | `Scripts/check.sh` plus semantic workflow review |
| `CI-FMT-001` | CI uses the selected toolchain formatter, not Homebrew Swift formatting/lint tools | `Scripts/check.sh` |
| `CI-REL-001` | Rust, Swift/architecture, and release compile lanes all feed the required aggregate without reducing coverage | workflow commands/dependencies asserted from `Scripts/check.sh` |
| `CI-TOOL-001` | CI lanes select the documented toolchain, run on the pinned macOS runner, check out without persisted credentials, and restore caches by the exact content keys | literal workflow fragments asserted from `Scripts/check.sh`; the pin values are owned by the development setup guide and change together |

Action SHA pins, least permissions, cache contents beyond asserted fragments, tag/version agreement,
release-note warnings, notarization credentials, and publication authorization remain semantic agent
review under `DOC-CI-001` and `DOC-REL-001`.

## Semantic agent-review families

| IDs | Decision or judgment | Canonical owner |
| --- | --- | --- |
| `DOC-PRI-001`, `DOC-PROD-001` | Safety/correctness/native-small-surface priority; experimental, unofficial, independent, no-affiliation product envelope | Root `AGENTS.md`, README, product contract, ADR 001 and ADR 005 |
| `DOC-TASTE-001`, `DOC-UI-001`, `DOC-CACHE-001` | Native-Mac restraint, truthful edge states, stable layout, accessibility, and bounded presentation cost | Product contract and `Sources/Spotty/Views/AGENTS.md` |
| `DOC-AGENT-001`, `DOC-DOD-001` | Progressive context loading and no invented human handoff | Root `AGENTS.md` |
| `DOC-MAP-001` | Repository ownership and path-specific instruction placement | Root `AGENTS.md` |
| `DOC-IMPL-001` | Declarative composition/views, existing store split, real protocols only at boundaries, typed state | `Sources/Spotty/AGENTS.md`, `Sources/Spotty/Spotify/AGENTS.md`, and `Sources/Spotty/Views/AGENTS.md` |
| `DOC-CONC-001`, `DOC-ESCAPE-001` | Treat Swift concurrency diagnostics as correctness and avoid ownership escapes | Root and scoped Spotify guidance |
| `DOC-LOG-001` | User-facing errors are actionable and logs are privacy-safe | Scoped Spotify guidance, PRIVACY, SECURITY, sanitization checks |
| `DOC-SAFE-001` | Live playback/account mutation is explicit-current-request opt-in and bounded | Product contract |
| `DOC-VER-001`, `DOC-PR-001` | Local verification scope and pull-request authorization | Root `AGENTS.md` and `CONTRIBUTING.md` |
| `DOC-GEN-001`, `DOC-DEP-001` | Generated/private state stays untracked; Actions/dependencies remain pinned and deliberately reviewed | Development setup and operations guide |
| `DOC-SEC-001`–`002` | Credentials/private data never enter Git; authenticated launch uses a stable Apple-issued Team ID | PRIVACY, SECURITY, development setup, `script/AGENTS.md`, signature checks |
| `DOC-ARCH-001` | New async/callback/provider/optimistic flows define owner, lifetime, cancellation, ordering, stale behavior, failure policy, and coverage | ADR 002 and scoped Spotify guidance |
