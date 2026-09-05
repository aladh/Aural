# Agent operations for Spotty

This conventional filename is retained for repository tooling and links. Start with
[AGENTS.md](AGENTS.md), then load only the procedure needed for the task.

Prerequisites, toolchain pins, signing setup, and generated local state are in the
[development setup guide](docs/development-setup.md#fresh-clone).

## Build and run

From the repository root:

```bash
./script/build_and_run.sh
```

The script resolves the pinned playback XCFramework, runs the Swift verification gate, builds the
SwiftPM executable, creates and signs a local `Spotty.app`, terminates any running development copy,
and launches the replacement. It does not require Rust tools. Because this can disturb an
authenticated session, use it only when the request authorizes launch or interactive
acceptance; do not use it as a compile check. The path-specific contract is
[`script/AGENTS.md`](script/AGENTS.md).

Useful modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --release
./script/build_and_run.sh --verify-release
./script/build_and_run.sh --telemetry
```

Authenticated launches require an Apple Development identity with a stable Team ID. When exactly one
is available, the script selects it; otherwise set `SPOTTY_DEVELOPMENT_SIGNING_IDENTITY` to the
exact name reported by `security find-identity -p codesigning -v`. See the setup guide for creating
an identity and for Keychain recovery.

## Normal verification

Follow the local-verification policy in [AGENTS.md](AGENTS.md#local-verification). The complete
verification gate is:

```bash
./Scripts/check.sh
```

The complete gate requires the engine toolchain. App-only development uses
`SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh`, which resolves the binary dependency and never invokes
Cargo, rustc, or cbindgen. Packaging uses this app-only gate.

The complete gate checks tracked Swift formatting, Rust formatting, warning-clean Clippy, locked
Rust tests, the pinned cbindgen output against the checked-in header, Rust/C export and header
parity, Swift builds with project-owned warnings as errors, deterministic Swift tests, architecture
contracts, CI policy, and packaging metadata. It does not sign in or initiate playback.

After changing a Rust ABI declaration, run `./Scripts/generate-c-header.sh` and commit the generated
header. `--check` verifies reproducibility without modifying it. cbindgen is pinned in the
[engine setup guide](docs/development-setup.md#engine-development); set `SPOTTY_CBINDGEN` when it is not on `PATH`. The
wrapper validates its version and export set without installing tools.

`Backend/spotty-playback/cbindgen.toml` generates
`Sources/SpottyPlaybackCore/include/spotty_playback_generated.h`. Edit the Rust declarations and
their ownership documentation, then regenerate; never edit the generated header. Keep Swift-specific
nullable-pointer and open-enum annotations in `spotty_playback_annotations.h`. Do not enable
cbindgen's global nullable-pointer annotation: it would make required callback pointers nullable.
The umbrella include remains `spotty_playback.h`.

`Scripts/check-c-header-imports.sh` compile-checks Swift imports, including nullable-pointer failures,
without linking or running playback. Extend it for a new pointer shape. The full gate separately
checks C/Rust layouts, signatures, exports, and callback lifetimes.

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

Their sources live under `Tests/SpottyDomainTests/` and `Tests/SpottyBoundaryTests/`.

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
the release compile. CI uses the [documented toolchain](docs/development-setup.md#fresh-clone),
content-keyed engine artifacts, and configuration-safe SwiftPM caches; cache hits may reduce latency
but never coverage. App lanes deliberately block Rust executables to detect accidental source-build
fallbacks.

After building the Debug boundary target, `Scripts/check-playback-projection-access.sh` type-checks
reads and expected-failing writes against the actual `SpottyCore` module. The full/Swift gate runs
it after boundary tests; it does not link or launch playback. The [enforcement inventory](docs/architecture-enforcement.md#source-reading-proof-audit-issues-187188)
records which former source/prose assertions are now compiler checks, behavior tests, or semantic
review obligations.

Use `SPOTTY_CHECK_REPEATS=N ./Scripts/check.sh` with `N` from 1 through 25 when concurrency or
lifetime work merits stress.

## Playback binary artifacts

The artifact pin lives in `Backend/spotty-playback/artifact-manifest.json` and a generated
declaration in `Package.swift`. The pin updater changes both together. Literal package declarations
make pin changes visible to SwiftPM's manifest cache. They pin an immutable engine ZIP by URL and
SHA-256. The artifact contains one macOS ARM64 static-library slice, its matching C headers/module
map, provenance, and dependency notices. Ordinary SwiftPM builds resolve that dependency without
Cargo or cbindgen. Never overwrite an existing published asset.

For engine development, install the pinned Rust and cbindgen tools and build an explicit local
artifact:

```bash
./Backend/spotty-playback/build-xcframework.sh
engine_digest="$(./Backend/spotty-playback/source-input-digest.sh)"
export SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK="$PWD/.build/playback-engine/$engine_digest/SpottyPlaybackCore.xcframework"
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
./Scripts/compile-release-spotty.sh
```

Rebuild that artifact and refresh the override after changing any engine input. Its default
directory carries the engine digest, and the library filename carries both engine-input and binary
digests. This changes the linker input when the engine changes; replacing a same-named static
archive alone can leave a cached executable linked to old code in SwiftPM. The local override
selects a binary; it does not arrange an implicit Cargo build. Unset it to return to the published
dependency. Full Rust verification remains `SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh`.

Artifact production requires the additional tools in the
[engine setup guide](docs/development-setup.md#engine-development). Embedded notices travel into
packaged apps without regeneration.

The artifact publication workflow builds the selected source revision with read-only repository
permissions. The workflow itself runs from main, but `source_ref` can select a reviewed, unmerged
engine PR commit; publish its artifact and update that PR’s pin before merging. A separate publisher
uploads versioned assets without running candidate build code with release credentials. The
resulting pin is updated in a reviewed source change; app and engine releases have separate
identities. Verify the downloaded artifact with its checksum and source input digest before updating
the manifest. Keep source revision, Cargo lock identity, headers, library, and required
license/source material traceable together.

To publish an explicitly authorized, reviewed engine commit:

```bash
gh workflow run playback-artifact.yml --ref main -f source_ref="$reviewed_source_sha"
```

Download the resulting release ZIP, then update both pin declarations from its embedded provenance:

```bash
./Backend/spotty-playback/update-artifact-manifest.sh \
  --archive /absolute/path/SpottyPlaybackCore.xcframework.zip \
  --url "$published_artifact_url"
unset SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
./Scripts/compile-release-spotty.sh
```

Commit the pin update in a PR. Publication rejects dirty source and existing release identities;
normal app builds fail clearly when the pinned artifact is unavailable rather than compiling Rust.

## Clean and risk-specific verification

The clean-room gate is:

```bash
./Scripts/check-clean.sh
```

It removes generated Swift build products, rebuilds the local engine artifact, then verifies Debug
and Release. Do not run
destructive cleanup over unrelated work. `./Scripts/compile-release-spotty.sh` remains the local
compile-only release command.

Prefer behavior tests over source-text snapshots; regex is not the owner of concurrency, epochs,
queue provenance, lifecycle, rollback, or payload correctness.

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
integration supported or policy-compliant. Engine artifact publication generates and inspects the complete transitive license set from
`Cargo.lock`; app packaging copies that material from the pinned artifact.

## Tagged releases

A matching `vX.Y.Z` tag runs the ARM64 release workflow. It compares the numeric tag with
`CFBundleShortVersionString` in `Packaging/Info.plist`, runs the app verification gate against the pinned engine, validates an ARM64-only
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
push it, open the PR, monitor available checks/reviews during the run, and address automated
findings. It does not authorize merge, release, tag, repository-setting changes, or issue closure
unless the request says so.

### Automated PR acceptance

PR acceptance is fully automated. A PR is ready when all three conditions hold for its latest
changes:

1. CodeRabbit has approved the PR.
2. All review threads are resolved, including findings from Cursor and other reviewers.
3. Checks are green: every applicable check has passed, with only intentional conditional skips.

Address valid findings, explain findings that do not apply, and resolve threads only after their
disposition is documented. After pushing fixes, wait for checks and CodeRabbit review to cover the
updated head. Cursor findings must be addressed, but a separate Cursor approval is not an acceptance
criterion. A stale blocking review state must be cleared through the reviewer’s normal workflow;
do not bypass repository protections.

Manual app testing and human review are not PR acceptance gates. Report any limits of automated
coverage honestly; separately requested manual verification may happen after merge. Live-account
work still follows the [safe acceptance contract](docs/product-and-acceptance-contract.md#safe-acceptance-testing).
Meeting these criteria establishes readiness, not permission to merge: merge authorization remains
separate as described above.
