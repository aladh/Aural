# Agent operations for Aural

Aural is maintained exclusively by autonomous coding agents. This conventional filename is retained
for repository tooling and links; it is an execution manual, not a human-contribution workflow.
Start with [AGENTS.md](AGENTS.md), then load only the sections and path-specific guidance needed for
the task. Never defer implementation, review, testing, issue validation, or release work to a
hypothetical maintainer.

Aural is an unofficial personal-use client built on private Spotify interfaces. Read the warning in
[README.md](README.md). Keep changes inside the requested outcome and the deliberately small product
surface; unsupported protocol risk is a design constraint, not an excuse for speculative machinery.

## Environment

- Apple Silicon Mac running macOS 26.2 or newer for development; runtime target macOS 15+
- Xcode 26.6 with Swift 6.3.3
- Rustup; `rust-toolchain.toml` pins the toolchain, components, and ARM64 macOS target
- [ripgrep](https://github.com/BurntSushi/ripgrep) for repository verification
- Spotify Premium only for explicitly authorized live integration testing

No credentials or account exports belong in the repository. Never commit OAuth callbacks, tokens,
diagnostics, generated signing material, raw API responses, real-account fixtures, or screenshots
containing private library/account information. The
[development setup](docs/development-setup.md) guide owns fresh-clone setup, generated local state,
signing recovery, and non-destructive cleanup.

## Build and run

From the repository root:

```bash
./script/build_and_run.sh
```

The script compiles the Rust backend when needed, builds the SwiftPM executable, creates and signs a
local `Aural.app`, terminates any running development copy, and launches the replacement. Because that
can disturb an authenticated session, use it only when the request authorizes launch or interactive
acceptance; do not use it as a compile check. The path-specific contract is
[`script/AGENTS.md`](script/AGENTS.md).

Useful modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --release
./script/build_and_run.sh --verify-release
./script/build_and_run.sh --telemetry
```

Authenticated launches require an Apple Development identity with a stable Team ID. A free Xcode
Personal Team is sufficient for local personal use. When exactly one identity is installed, the
script selects it; otherwise set `AURAL_DEVELOPMENT_SIGNING_IDENTITY` to the exact name from
`security find-identity -p codesigning -v`.

The generated identity under ignored `.build/aural-signing/` is for build/package verification only.
It is not trusted, is not a distribution identity, must not be used to sign in, and must never be
installed in the login keychain or committed.

## Normal verification

For source, runtime, integration, build, or release changes, run the complete non-playback gate before
opening a pull request. Documentation-only changes use the documentation evidence listed under
[Clean and risk-specific verification](#clean-and-risk-specific-verification).

```bash
./Scripts/check.sh
```

The gate checks tracked Swift formatting, Rust formatting, warning-clean Clippy, locked Rust tests,
Rust/C export and header parity, Swift builds with Aural-owned warnings as errors, deterministic
Swift check products, architecture contracts, CI policy, and packaging metadata. It does not sign in
or initiate playback.

Swift formatting uses the selected Swift 6.3 toolchain's `swift-format`:

```bash
./Scripts/format-swift.sh --check
./Scripts/format-swift.sh --write
```

`Scripts/format-swift-self-test.sh` protects wrapper discovery and failure behavior and runs inside
`check.sh` before the real formatting check.

The two non-shipping check products are:

- `AuralChecks`: pure `AuralDomain` state, policy, parsing, and deterministic playback traces.
- `AuralBoundaryChecks`: concrete codecs, fixtures, stores, coordinators, queue flows, and other
  injected AuralCore boundaries.

Use focused suites for iteration, never as the completion gate:

```bash
swift run --disable-sandbox --product AuralChecks -- --list
swift run --disable-sandbox --product AuralChecks -- protobuf playback-reducer
swift run --disable-sandbox --product AuralBoundaryChecks -- --list
swift run --disable-sandbox --product AuralBoundaryChecks -- auth-flow workflow
```

`--list` prints stable suite names in registration order. Unknown or empty names fail before any
check runs; repeated names run once in first-requested order. No-argument execution runs all suites,
and `check.sh` never passes suite filters.

CI may partition the gate with:

```bash
AURAL_CHECK_SCOPE=rust ./Scripts/check.sh
AURAL_CHECK_SCOPE=swift ./Scripts/check.sh
```

Those scopes are CI/iteration controls, not substitutes for the ordinary local gate. The required
`Debug quality gate` aggregates Rust verification, Swift/architecture verification, and the release
compile. CI pins Xcode 26.6 / Swift 6.3.3 and uses content-keyed Rust archive plus configuration-safe
SwiftPM caches; cache hits may reduce latency but never coverage.

Use `AURAL_CHECK_REPEATS=N ./Scripts/check.sh` with `N` from 1 through 25 when concurrency or lifetime
work merits stress.

## Clean and risk-specific verification

For Rust, lifecycle, FFI, dependency, build, signing, packaging, CI, or release changes, run:

```bash
./Scripts/check-clean.sh
```

The clean gate removes generated Swift build products, rebuilds Rust, then verifies Debug and Release.
Do not run destructive cleanup over unrelated work. `./Scripts/compile-release-aural.sh` remains the
local compile-only release command.

Add deterministic evidence at the closest owner:

| Change | Evidence |
| --- | --- |
| Portable state, parsing, sorting, queue/device policy | `Sources/AuralChecks/` |
| Concrete Swift adapters, stores, codecs, workflows | `Sources/AuralChecks/DeferredBoundaryChecks/` |
| Rust lifecycle, Connect, queue serialization, FFI | `Backend/aural-playback/src/` tests |
| Cross-language payload or ABI | Paired Rust serialization/signature coverage and Swift boundary fixture |
| Documentation only | Link/command validation, rendered Markdown when relevant, stage the intended files, then `git diff --check HEAD` |
| Performance | Like-for-like measurements with environment and methodology recorded |

Fixtures are reduced, synthetic, and non-identifying. Do not use real Spotify payloads. Prefer
behavior tests over source-text snapshots; regex is not the owner of concurrency, epochs, queue
provenance, lifecycle, rollback, or payload correctness.

## Architecture and technical context

Accepted architecture is indexed in the
[architecture decision records](docs/architecture-decisions.md), and hard-rule enforcement is routed
through the [architecture enforcement inventory](docs/architecture-enforcement.md). Supporting
protocol notes, research, and measured baselines are linked once from the ADR index's
[related technical context](docs/architecture-decisions.md#related-technical-context). Do not
duplicate those documents into this operations guide.

## Safe live acceptance

The default is no playback and no account mutation. Launch, sign-in, and read-only observation do not
authorize transport, seek, device transfer, queue edits, library/playlist/follow mutation, or sign-out.
Each live action needs explicit current-request scope. Follow the bounded procedures in the
[product and acceptance contract](docs/product-and-acceptance-contract.md), including active-device
inspection, local mute before local audio, named content, a short interval, cleanup/restoration, and
an exact activity report.

If the environment or authorization cannot support live acceptance, do not block safe completion or
invent a human fallback. Run the strongest deterministic evidence available and record precisely what
was not observed and why.

## Package, sign, and notarize

Local packages are development artifacts:

```bash
./Scripts/package-app.sh --debug
./Scripts/package-app.sh --release
./Scripts/validate-app.sh --local
```

A hardened-runtime Developer ID archive requires an explicitly supplied identity:

```bash
AURAL_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./Scripts/archive-app.sh
```

The archive is written to ignored `dist/`. Notarization additionally requires an existing Apple
`notarytool` profile:

```bash
AURAL_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
AURAL_NOTARY_PROFILE="aural-notary" \
  ./Scripts/notarize-app.sh
```

`validate-app.sh --distribution` requires a Developer ID signature, a valid notarization ticket, and
Gatekeeper acceptance. Signing proves artifact integrity; it does not make the private Spotify
integration supported or policy-compliant. Before distributing a binary, generate and inspect the
complete transitive license set from `Cargo.lock`.

## Tagged releases

A matching `vX.Y.Z` tag runs the ARM64 release workflow. It compares the numeric tag with
`CFBundleShortVersionString` in `Packaging/Info.plist`, runs the full gate, validates an ARM64-only
app, creates a ZIP and SHA-256 checksum, and publishes an experimental prerelease. Until Developer ID
and notarization credentials are configured, artifacts use a hardened-runtime ad-hoc signature and
release notes must state that macOS will not automatically trust them.

Tags, releases, version changes, remotes, repository settings, credentials, and publication require
explicit authorization. Never publish merely to test a workflow. Renovate owns dependency updates;
GitHub Actions remain SHA-pinned with readable version comments; librespot updates receive protocol
and license review rather than routine bump treatment.

## Diagnostics

Release builds use Unified Logging. `./Scripts/export-diagnostics.sh` writes a bounded report under
ignored `diagnostics/`. Inspect it before sharing and discard any report containing credentials,
OAuth redirects, raw payloads, or private account/library data.

## Pull-request execution

A request to open a PR authorizes the agent to create a branch, commit the complete in-scope change,
push it, open the PR, monitor available checks/reviews during the run, and address automated findings.
It does not authorize merge, release, tag, repository-setting changes, or issue closure unless the
request says so.

The PR must state:

- the user-visible or repository outcome and why it is needed;
- the canonical owner and important design choice;
- exact commands and results, including any unavailable gate;
- all launch/live-account activity, including none;
- known remaining risk and deliberately unverified behavior.

Keep the diff cohesive. Update public or canonical documents when requirements, behavior, storage,
permissions, architecture, setup, security, attribution, or release mechanics change. Inspect the
final staged diff for generated/private files.

Do not use issue-closing keywords such as `Closes`, `Fixes`, or `Resolves` in commits or PR bodies.
Use plain wording such as `Contributes to #13`. Auto-close is disabled. After an authorized merge, an
agent must re-read the issue acceptance criteria against `main`; close the issue only when every
criterion is satisfied and issue mutation is authorized.

### Automated review resolution

CodeRabbit performs incremental reviews and provides the required current-head approval. Cursor is
configured to review a PR once, so do not retrigger it merely to clear stale review state.

Reply to every actionable automated finding and resolve its thread. Fix valid findings at the owning
boundary; explicitly decline invalid or out-of-scope findings with evidence. An agent with repository
admin scope may dismiss a stale Cursor `CHANGES_REQUESTED` review only when:

- it targets an older commit than the PR head;
- every finding is fixed or explicitly declined with a documented reason;
- no Cursor review thread remains unresolved;
- CodeRabbit approves the current head;
- required checks pass and a final semantic agent review finds the diff ready.

The dismissal message identifies why the review is stale and points to the fixing commit or documented
decline. Never dismiss a current-head review, an unresolved valid finding, or a review merely to bypass
conversation resolution.

## Maintaining repository guidance

Repository-wide instruction policy is canonical in
[Maintaining these instructions](AGENTS.md#maintaining-these-instructions). This operations guide owns
only the validation procedure below.

Do not add a byte-count gate or a second source-contract harness. Validate instruction discovery from
the repository root and representative nested scopes, including `script/`, and let CI own formatting
and mechanically checkable policy.
