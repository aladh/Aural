# Agent operations for Spotty

This conventional filename is retained for repository tooling and links. Start with
[AGENTS.md](AGENTS.md), then load only the procedure needed for the task.

## Environment

See the canonical prerequisites and toolchain versions in the
[development setup guide](docs/development-setup.md#fresh-clone).

## Build and run

From the repository root:

```bash
./script/build_and_run.sh
```

The script compiles the Rust backend when needed, builds the SwiftPM executable, creates and signs a
local `Spotty.app`, terminates any running development copy, and launches the replacement. Because that
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
script selects it; otherwise set `SPOTTY_DEVELOPMENT_SIGNING_IDENTITY` to the exact name from
`security find-identity -p codesigning -v`.

The generated identity under ignored `.build/spotty-signing/` is for build/package verification only.
It is not trusted, is not a distribution identity, must not be used to sign in, and must never be
installed in the login keychain or committed.

## Normal verification

Follow the local-verification policy in [AGENTS.md](AGENTS.md#local-verification). The complete non-playback
gate is:

```bash
./Scripts/check.sh
```

The gate checks tracked Swift formatting, Rust formatting, warning-clean Clippy, locked Rust tests,
the pinned cbindgen output against the checked-in header,
Rust/C export and header parity, Swift builds with project-owned warnings as errors, deterministic
Swift tests, architecture contracts, CI policy, and packaging metadata. It does not sign in
or initiate playback.

After changing a generated ABI declaration, run `./Scripts/generate-c-header.sh` and commit the
result with the Rust change. `./Scripts/generate-c-header.sh --check` verifies reproducibility without
modifying the header. Install the version listed in the [setup guide](docs/development-setup.md#fresh-clone),
or set `SPOTTY_CBINDGEN` to that executable's path. The wrapper checks the version and ABI export
set and never installs tools; CI installs the pin explicitly. Generation does not replace the
C/Rust layout, signature, ownership, or callback-lifetime checks.

`Backend/spotty-playback/cbindgen.toml` generates all playback function declarations and snapshot
layouts from Rust into `Sources/SpottyPlaybackCore/include/spotty_playback_generated.h`. Edit the Rust
declarations and their ownership documentation, then regenerate; do not edit that artifact by hand.
The public `spotty_playback.h` remains the umbrella include.

The small handwritten `spotty_playback_annotations.h` owns Swift's open-enum and nullable-pointer
annotations. Rust uses matching primitive and typed-pointer aliases without runtime conversions.
The generated declarations retain the existing assumed-nonnull contract. Do not enable cbindgen's
global nullable-pointer annotation: it also marks required callback pointers nullable. Keep semantic
annotations separate from generated field lists and function signatures.

`Scripts/check-c-header-imports.sh` type-checks the Swift import contract and expected failures for
nullable pointers used without unwrapping. It never links or executes the fixtures. Extend these
probes when introducing another pointer shape. The C compiler independently checks the unchanged
`abi-signatures.txt` contract through typedef aliases; the Rust assignments and C layout checks
remain separate proof.

Swift formatting uses the selected Swift 6.3 toolchain's `swift-format`:

```bash
./Scripts/format-swift.sh --check
./Scripts/format-swift.sh --write
```

`Scripts/format-swift-self-test.sh` protects wrapper discovery and failure behavior and runs inside
`check.sh` before the real formatting check.

The two non-shipping Swift Testing targets are:

- `SpottyDomainTests`: pure `SpottyDomain` state, policy, parsing, and deterministic playback traces.
- `SpottyBoundaryTests`: concrete codecs, fixtures, stores, coordinators, queue flows, and other
  injected SpottyCore boundaries.

Their sources live under `Tests/SpottyDomainTests/` and `Tests/SpottyBoundaryTests/`. Each behavior
area is grouped in a named Swift Testing `@Suite`; parameterized suites are used for deterministic
input matrices where the expected result is independent for each case.

Use standard SwiftPM filtering for focused iteration:

```bash
swift test --disable-sandbox --filter ProtobufTests/testProtobuf
swift test --disable-sandbox --no-parallel --filter AuthFlowTests/testAuthFlow
```

`swift test list` shows the discovered test names. No-argument execution runs all tests, and
`check.sh` never passes a test-name filter beyond selecting its domain or boundary target.

CI may partition the gate with:

```bash
SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
```

The required `Debug quality gate` aggregates Rust verification, Swift/architecture verification, and
the release compile. CI uses the [documented toolchain](docs/development-setup.md#fresh-clone), a
content-keyed Rust archive, and configuration-safe SwiftPM caches; cache hits may reduce latency but
never coverage.

Use `SPOTTY_CHECK_REPEATS=N ./Scripts/check.sh` with `N` from 1 through 25 when concurrency or lifetime
work merits stress.

## Clean and risk-specific verification

The clean-room gate is:

```bash
./Scripts/check-clean.sh
```

It removes generated Swift build products, rebuilds Rust, then verifies Debug and Release. Do not run
destructive cleanup over unrelated work. `./Scripts/compile-release-spotty.sh` remains the local
compile-only release command.

Prefer behavior tests over source-text snapshots; regex is not the owner of concurrency, epochs, queue
provenance, lifecycle, rollback, or payload correctness.

## Package, sign, and notarize

Local packages are development artifacts:

```bash
./Scripts/package-app.sh --debug
./Scripts/package-app.sh --release
./Scripts/validate-app.sh --local
```

A hardened-runtime Developer ID archive requires an explicitly supplied identity:

```bash
SPOTTY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./Scripts/archive-app.sh
```

The archive is written to ignored `dist/`. Notarization additionally requires an existing Apple
`notarytool` profile:

```bash
SPOTTY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
SPOTTY_NOTARY_PROFILE="spotty-notary" \
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

Renovate owns dependency updates; GitHub Actions remain SHA-pinned with readable version comments;
librespot updates receive protocol and license review rather than routine bump treatment.

## Diagnostics

Release builds use Unified Logging. `./Scripts/export-diagnostics.sh` writes a bounded report under
ignored `diagnostics/`. Handle reports according to [PRIVACY.md](PRIVACY.md).

## Pull-request execution

A request to open a PR authorizes the agent to create a branch, commit the complete in-scope change,
push it, open the PR, monitor available checks/reviews during the run, and address automated findings.
It does not authorize merge, release, tag, repository-setting changes, or issue closure unless the
request says so.
