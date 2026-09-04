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

The script builds the Rust backend and SwiftPM executable, packages and signs `Spotty.app`, replaces
any running development copy, then launches it. It can disturb an authenticated session, so use it
only when launch or interactive acceptance is authorized; it is not a compile check. The path-specific
contract is [`script/AGENTS.md`](script/AGENTS.md).

Useful modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --release
./script/build_and_run.sh --verify-release
./script/build_and_run.sh --telemetry
```

Authenticated launches require an Apple Development identity with a stable Team ID. When exactly one
is available, the script selects it; otherwise set `SPOTTY_DEVELOPMENT_SIGNING_IDENTITY` to the exact
name reported by `security find-identity -p codesigning -v`. See the setup guide for creating an
identity and for Keychain recovery.

## Normal verification

Follow the local-verification policy in [AGENTS.md](AGENTS.md#local-verification). The complete non-playback
gate is:

```bash
./Scripts/check.sh
```

The gate checks formatting, warning-clean Clippy, locked Rust tests, pinned C-header generation,
ABI parity, warning-clean Swift builds and deterministic tests, architecture contracts, CI policy,
and packaging metadata. It does not sign in or initiate playback.

After changing a Rust ABI declaration, run `./Scripts/generate-c-header.sh` and commit the generated
header. `--check` verifies reproducibility without modifying it. cbindgen is pinned in the
[setup guide](docs/development-setup.md#fresh-clone); set `SPOTTY_CBINDGEN` when it is not on `PATH`.
The wrapper validates its version and export set without installing tools.

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

The required CI gate combines Rust verification, Swift and architecture verification, and a Release
compile. CI uses the documented toolchain; caches do not reduce coverage.

Use `SPOTTY_CHECK_REPEATS=N ./Scripts/check.sh` with `N` from 1 through 25 when concurrency or lifetime
work merits stress.

## Clean and risk-specific verification

The clean-room gate is:

```bash
./Scripts/check-clean.sh
```

It removes Swift build products, rebuilds Rust, then verifies Debug and Release. Do not use it to
clean unrelated work. `./Scripts/compile-release-spotty.sh` is the compile-only Release command.

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
integration supported or policy-compliant. Review and update
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) when distribution changes its dependency set. Before
distributing a binary, generate and inspect the complete transitive license set from `Cargo.lock`.

## Tagged releases

A matching `vX.Y.Z` tag runs the ARM64 release workflow. It checks the tag against
`CFBundleShortVersionString`, runs the full gate, validates an ARM64-only app, then publishes a ZIP
and SHA-256 checksum as an experimental prerelease. Until Developer ID and notarization credentials
are configured, artifacts use a hardened-runtime ad-hoc signature and macOS will not automatically
trust them; release notes must say so.

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
