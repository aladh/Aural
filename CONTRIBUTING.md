# Agent operations for Spotty

Start with [AGENTS.md](AGENTS.md). Prerequisites, toolchain pins, signing, and local state are in
[development setup](docs/development-setup.md).

## Build and run

For an authorized launch, from the repository root:

```bash
./script/build_and_run.sh
```

This verifies, builds, signs, and replaces the running app; do not use it as a compile check.
Modes include `--verify`, `--release`, `--verify-release`, and `--telemetry`.
See [launch constraints](script/AGENTS.md) and
[signing setup](docs/development-setup.md#fresh-clone) before authenticated launches.

## Normal verification

Use the smallest focused check per [AGENTS.md](AGENTS.md#local-verification). Available gate scopes:

```bash
./Scripts/check.sh
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh
```

The full and Rust scopes require the [engine toolchain](docs/development-setup.md#engine-development).
The Swift scope and packaging use the pinned binary without Rust tools. Checks do not sign in or
initiate playback. See the [enforcement inventory](docs/architecture-enforcement.md) for coverage.

After changing a Rust ABI declaration, run `./Scripts/generate-c-header.sh` and commit the generated
header. `--check` verifies reproducibility; set `SPOTTY_CBINDGEN` if the pinned tool is not on `PATH`.

`Backend/spotty-playback/cbindgen.toml` generates
`Sources/SpottyPlaybackCore/include/spotty_playback_generated.h`. Edit the Rust declarations and
their ownership documentation, then regenerate; never edit the generated header. Keep Swift-specific
nullable-pointer and open-enum annotations in `spotty_playback_annotations.h`. Do not enable
cbindgen's global nullable-pointer annotation: it would make required callback pointers nullable.

Extend `Scripts/check-c-header-imports.sh` when adding a pointer shape; it compile-checks Swift
imports and nullability without running playback.

Swift formatting:

```bash
./Scripts/format-swift.sh --check
./Scripts/format-swift.sh --write
```

Tests live in `Tests/SpottyDomainTests/` and `Tests/SpottyBoundaryTests/`. Discover names with
`swift test list`, then filter for focused iteration:

```bash
swift test --disable-sandbox --filter ProtobufTests/testProtobuf
swift test --disable-sandbox --no-parallel --filter AuthFlowTests/testAuthFlow
```

CI's required `Debug quality gate` aggregates Rust, Swift/architecture, Release compilation, and
review-automation boundary tests. Run the latter with
`python3 -B -m unittest discover -s .github/review -p 'test_*.py'`.

Use `SPOTTY_CHECK_REPEATS=N ./Scripts/check.sh` with `N` from 1 through 25 when concurrency or
lifetime work merits stress.

## Playback binary artifacts

`Backend/spotty-playback/artifact-manifest.json` and `Package.swift` pin the engine ZIP by URL and
SHA-256; update both with the pin updater below. The artifact bundles the ARM64 library, matching
headers/module map, provenance, and dependency notices. Never overwrite a published asset.

For engine development, install the [artifact tools](docs/development-setup.md#engine-development)
and build a local artifact:

```bash
./Backend/spotty-playback/build-xcframework.sh
engine_digest="$(./Backend/spotty-playback/source-input-digest.sh)"
export SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK="$PWD/.build/playback-engine/$engine_digest/SpottyPlaybackCore.xcframework"
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
./Scripts/compile-release-spotty.sh
```

Rebuild and refresh the override after every engine-input change. Preserve digest-bearing paths
and library names so SwiftPM relinks changed engines. The override selects a binary without building
Rust; unset it to return to the published dependency. Run the Rust gate separately.

The publication workflow runs from main; `source_ref` can select a reviewed, unmerged engine commit.
Publish its artifact and update the PR's pin before merging. Candidate build code runs with read-only
permissions, separately from the publisher's release credentials. Keep app and engine release
identities separate and source, Cargo lock, headers, library, and license material traceable together.

To publish an explicitly authorized, reviewed engine commit:

```bash
gh workflow run playback-artifact.yml --ref main -f source_ref="$reviewed_source_sha"
```

Download the release ZIP, verify its checksum and source input digest, then update both pins:

```bash
./Backend/spotty-playback/update-artifact-manifest.sh \
  --archive /absolute/path/SpottyPlaybackCore.xcframework.zip \
  --url "$published_artifact_url"
unset SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
./Scripts/compile-release-spotty.sh
```

Commit the pin update in a PR. Publication rejects dirty source and existing release identities.

## Clean and risk-specific verification

For clean-build changes or diagnosis requiring a rebuild:

```bash
./Scripts/check-clean.sh
```

This removes generated Swift build products, rebuilds the engine artifact, and verifies Debug and
Release. Preserve unrelated work. Use `./Scripts/compile-release-spotty.sh` for compile-only Release
verification.

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
integration supported or policy-compliant. Engine publication generates and inspects transitive
licenses from `Cargo.lock`; app packaging copies them from the pinned artifact.

## Tagged releases

An authorized `vX.Y.Z` tag must match `CFBundleShortVersionString` in `Packaging/Info.plist`. The
release workflow verifies the app against the pinned engine and publishes an ARM64 experimental
prerelease ZIP and SHA-256 checksum. Until Developer ID and notarization credentials are configured,
artifacts use hardened-runtime ad-hoc signing; release notes must state that macOS will not
automatically trust them. Renovate owns dependency updates.

## Diagnostics

Release builds use Unified Logging. `./Scripts/export-diagnostics.sh` writes a bounded report under
ignored `diagnostics/`. Handle reports according to [PRIVACY.md](PRIVACY.md).

## Pull-request execution

A request to open a PR authorizes the agent to create a branch, commit the complete in-scope change,
push it, open the PR, monitor available checks/reviews during the run, and address automated
findings. It does not authorize merge, release, tag, repository-setting changes, or issue closure
unless the request says so.

The [OpenCode reviewer](docs/opencode-review.md) performs one advisory full review per eligible PR;
subsequent pushes do not trigger incremental reviews.

### PR acceptance

A PR is ready when all three conditions hold for its latest changes:

1. All review findings have a documented disposition and all review threads are resolved.
2. Required approvals are satisfied according to repository settings.
3. Checks are green: every applicable check has passed, with only intentional conditional skips.

Evaluate review feedback using engineering judgment. Addressing feedback does not require agreeing
with or implementing every suggestion. Fix valid issues; when declining a suggestion, explain the
reasoning, tradeoff, or scope boundary in the thread. Resolve threads only after documenting their
disposition.

After pushing fixes, wait for checks and required reviews to cover the updated head. A stale
blocking review state must be cleared through the reviewer’s normal workflow; do not bypass
repository protections.

Manual app testing is not a PR acceptance gate, and no human review is required beyond repository
settings. Report automated coverage limits honestly; separately requested manual verification may
happen after merge. Live-account work still follows the
[safe acceptance contract](docs/product-and-acceptance-contract.md#safe-acceptance-testing).
Meeting these criteria establishes readiness, not permission to merge: merge authorization remains
separate as described above.
