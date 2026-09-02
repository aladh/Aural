# Contributing to Aural

Aural is an unofficial, personal-use macOS client built on private Spotify interfaces. Read the
warning in [README.md](README.md) before contributing. Focused bug fixes, tests, documentation, and
small maintainability improvements are welcome. Discuss large features before investing substantial
work: protocol risk and a deliberately small product surface are part of the design.

By submitting a contribution, you agree that it may be distributed under the repository's MIT
license and that you have the right to submit it.

## Development environment

- Apple-silicon Mac running macOS 26.2 or newer for development; Aural's runtime deployment target
  remains macOS 15 or newer
- Xcode 26.6 with Swift 6.3.3
- Rustup; `rust-toolchain.toml` pins Rust, components, and the ARM64 macOS target
- [ripgrep](https://github.com/BurntSushi/ripgrep) for the verification scripts
- Spotify Premium only for manual integration testing

No credentials or account exports belong in the repository. Never commit OAuth callbacks, tokens,
diagnostic reports, generated signing material, API response dumps, or screenshots containing
private library/account information. The relevant generated paths are ignored, but inspect the
staged diff before every commit.

The [development setup](docs/development-setup.md) guide covers a fresh clone, first-build flow,
generated local state, and clean recovery.

## Build and run

From a repository checkout:

```bash
./script/build_and_run.sh
```

The script compiles the Rust backend when needed, builds the SwiftPM executable, creates and signs a
local `Aural.app`, replaces any running development copy, and launches it. The first build downloads
the locked Rust dependencies and takes longer than subsequent builds.

Useful modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --release
./script/build_and_run.sh --verify-release
./script/build_and_run.sh --telemetry
```

Authenticated launches require an Apple Development identity. A free Xcode Personal Team is
sufficient for local personal use; paid Apple Developer Program membership is not required. When
exactly one identity is installed, `build_and_run.sh` selects it automatically; otherwise set
`AURAL_DEVELOPMENT_SIGNING_IDENTITY` to its exact `security find-identity -p codesigning -v` name.
The launch path validates both an Apple code-signing anchor and a non-empty Team ID before opening
Aural, because a self-signed identity falls back to a per-build CDHash Keychain partition and causes
recurring credential prompts.

The generated identity under the ignored `.build/aural-signing/` directory remains available only
for build/package verification. It is not system-trusted, is not a distribution identity, must not
be used to sign in, and never belongs in Git.

## Build and checks

Run the normal gate before opening a pull request:

```bash
./Scripts/check.sh
```

`check.sh` verifies Git-tracked Swift formatting, Rust formatting, warning-clean Clippy, the locked
Rust unit suite, the generated C ABI, Swift builds with Aural-owned compiler warnings as errors,
architecture constraints, and packaging metadata. It rebuilds a missing or stale playback archive,
compares the checked-in C header with the archive's exported symbols, and runs both non-shipping
Swift check products:

- `AuralChecks` exercises pure domain state, policies, parsing, and deterministic playback traces.
- `AuralBoundaryChecks` exercises concrete codecs, fixtures, and injected coordinator/queue flows.

Swift formatting uses the selected Swift 6.3 toolchain's bundled `swift-format`. Check or rewrite
the same Git-tracked `*.swift` set, including `Package.swift`, `Sources/`, and checked-in
`Scripts/*.swift`:

```bash
./Scripts/format-swift.sh --check
./Scripts/format-swift.sh --write
```

`check.sh` runs `Scripts/format-swift-self-test.sh` then `--check` so wrapper discovery and failure
behavior cannot drift from the documented commands.

GitHub's required `Debug quality gate` aggregates three parallel macos-26 lanes: Rust verification,
Swift/architecture verification, and the release compile. The Swift lanes use the explicitly
selected Xcode 26.6 / Swift 6.3.3 toolchain, matching the package's tools version. CI invokes the
two verification scopes of `check.sh` independently; the ordinary local command still runs both
scopes as one complete gate. The release lane compiles shipping `Aural` with
`-DAURAL_DISTRIBUTION`. The aggregate passes only when all three lanes pass, so parallelism changes
latency rather than coverage.

The Swift and release lanes reuse a content-keyed playback archive when the Rust toolchain and every
checked-in Rust input are unchanged. An exact cache miss rebuilds the archive normally. A cache hit
refreshes only the restored archive's timestamp so `check.sh` does not mistake a content-matched
artifact for a stale one after checkout. Debug and release SwiftPM products use separate `.build`
cache keys to prevent concurrent jobs from publishing incomplete configuration-specific caches.
Each key includes runner OS, architecture, the Swift toolchain, package manifests, and the commit
SHA; restore prefixes reuse the nearest compatible configuration. Signing material and paths
outside the checkout are not cached.

`AURAL_CHECK_SCOPE=rust ./Scripts/check.sh` and `AURAL_CHECK_SCOPE=swift ./Scripts/check.sh` are CI
partitioning controls, not substitutes for the normal local gate.
`./Scripts/compile-release-aural.sh` remains the local compile-only command, and
`./Scripts/check-clean.sh` remains the clean-room Debug and Release full gate. Rust-input changes
still pay the optimized archive build cost; ordinary Swift and documentation pull requests avoid
recompiling an identical archive.

`AuralChecks` depends only on `AuralDomain` and the tiny `AuralCheckSelection` helper. It does not
link `AuralCore` or the Rust playback archive. Domain-only iteration can use SwiftPM directly:

```bash
swift build --disable-sandbox --product AuralChecks
swift run --disable-sandbox --product AuralChecks
swift run --disable-sandbox --product AuralChecks -- --help
swift run --disable-sandbox --product AuralChecks -- --list
swift run --disable-sandbox --product AuralChecks -- protobuf playback-reducer
```

`--list` prints stable suite names in registration order. Unknown or empty names exit nonzero
before any check runs. Repeated names run once, in the first requested order. No-argument
invocation still runs every registered suite. `./Scripts/check.sh` does not pass suite filters.

`AuralBoundaryChecks` accepts the same `--help`, `--list`, and suite-name arguments, but it still
compiles against `AuralCore` and is not a Rust-free path:

```bash
swift run --disable-sandbox --product AuralBoundaryChecks -- --list
swift run --disable-sandbox --product AuralBoundaryChecks -- auth-flow workflow
```

For changes to build, packaging, dependency, FFI, or release behavior, also run the clean gate:

```bash
./Scripts/check-clean.sh
```

`check-clean.sh` removes Swift build products, rebuilds Rust, and verifies both Debug and Release
configurations.

Add deterministic coverage in the closest existing suite:

- `Backend/aural-playback/src/tests.rs` for Rust lifecycle, queue, and FFI behavior
- `Sources/AuralChecks/` for portable domain rules and state-transition traces
- `Sources/AuralChecks/DeferredBoundaryChecks/` for concrete codecs, fixtures, and injected app flows

Do not add The Composable Architecture or another effect framework to support a prototype;
see [ADR 003](docs/ADR-003-playback-command-effects.md).

The Swift checks use a small custom runner rather than XCTest/Swift Testing. Neither check
executable is included in the packaged app.

## Architecture

High-level ownership, kept short here so the [ADR index](docs/architecture-decisions.md) remains the
canonical list of accepted decisions:

- Swift owns windows, navigation, presentation, OAuth, catalog access, metadata, shuffle policy,
  progress interpolation, and native AVFoundation audio output.
- Rust/librespot owns the streaming session, Spotify Connect, decoding, reconnects, and queue truth.
  Build, reconnect cleanup+build, and exported cleanup serialize through one async lifecycle mutex
  so those operations cannot interleave writes to the engine globals.
- `AuralDomain` owns atomic playback state, the reducer, queue precedence, and pure policies.
- `AuralCore` owns the app implementation behind the thin shipping `AuralApp` executable.
- `PlaybackStore` publishes reducer state, `PlaybackCoordinator` serializes effects, and
  `PlaybackEnvironment.live` assembles production dependencies once.
- `TransientFeedbackPresenter` is the app-composed owner for transient mutation success,
  informational, and failure banners. It is not playback status and is not an event bus.
- `PlaybackCore.swift` alone imports the C module; `RustPlaybackEngine.swift` is its only caller.
- Playback commands cross into Rust; bounded PCM and immutable state snapshots cross back.
- Artwork is downsampled to rendered Retina size and retained in a cost-bounded cache that is
  purged when the app window closes.

Implementation notes that are not ADRs:

- [Product and acceptance contract](docs/product-and-acceptance-contract.md)
- [Private extended-metadata protocol](docs/extended-metadata.md)
- [Performance and acceptance baseline](docs/performance-baseline-2026-08-23.md)
- [Research notes](RESEARCH.md)

## Package, sign, and notarize

Local packages are for development only:

```bash
./Scripts/package-app.sh --release
./Scripts/validate-app.sh --local
```

To produce a hardened-runtime Developer ID archive, provide the exact identity name reported by
`security find-identity -p codesigning -v`:

```bash
AURAL_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./Scripts/archive-app.sh
```

The archive is written to `dist/`. To notarize it, first store credentials with Apple's
`notarytool store-credentials`, then run:

```bash
AURAL_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
AURAL_NOTARY_PROFILE="aural-notary" \
  ./Scripts/notarize-app.sh
```

`validate-app.sh --distribution` requires a Developer ID signature, a valid notarization ticket,
and Gatekeeper acceptance. Code signing and notarization establish artifact integrity; they do not
make the private Spotify integration supported or policy-compliant.

Before publishing a compiled binary, generate and review a complete license report for every crate
linked through `Cargo.lock`. The repository's notices cover Aural's adapted source and its primary
upstreams, but are not a substitute for binary-distribution license review.

### Tagged releases

Pushing a version tag such as `v0.0.1` runs the ARM64 release workflow on GitHub's Apple-silicon
`macos-26` runner. Tags are `v`-prefixed; the workflow strips the leading `v` and compares that
numeric suffix with `CFBundleShortVersionString` in `Packaging/Info.plist`. The workflow runs the
full quality gate, validates an ARM64-only app, creates a ZIP and SHA-256 checksum, and publishes
an experimental GitHub prerelease.

Until Developer ID and notarization credentials are configured, automated release artifacts use a
hardened-runtime, ad-hoc signature and are not automatically trusted by macOS.
Release notes must state that limitation. Source builds remain the preferred development path.

## Diagnostics

Release builds use Apple's Unified Logging. The intended contract excludes tokens, OAuth redirects,
and raw API payloads. `./Scripts/export-diagnostics.sh` exports a bounded local report into the
ignored `diagnostics/` directory. Review every report before sharing it, and do not share a report
that contains credentials, OAuth redirects, raw API responses or payloads, or private account data.

## Pull requests

- Keep the diff focused and explain user-visible behavior and failure modes.
- Preserve the dependency boundaries enforced by `Scripts/check.sh`.
- Add or update tests for behavior changes.
- Update public docs when requirements, supported behavior, storage, permissions, or release steps
  change.
- Do not use real Spotify payloads as fixtures. Reduce them to synthetic, non-identifying examples.
- State what you tested manually. Maintainers can perform account-backed acceptance testing when a
  contributor cannot safely do so.
- Do not use GitHub issue-closing keywords such as `Closes`, `Fixes`, or `Resolves` in commit
  messages or pull-request bodies. Refer to issues in plain wording, for example
  `Contributes to #13`. GitHub repository auto-close is disabled. After merge, the maintainer
  re-reads the issue acceptance criteria against `main` and closes the issue only when every
  criterion is genuinely satisfied.

### Automated review resolution

CodeRabbit performs incremental reviews and provides the required current-head approval. Cursor is
configured to review a pull request only once, so do not trigger another Cursor review merely to
clear review state after its findings have been addressed.

Before merging, reply to every actionable automated-review finding and resolve every associated
review thread. A stale Cursor `CHANGES_REQUESTED` review may be dismissed by a maintainer only when:

- the review targets an older commit than the pull request head;
- every Cursor finding is either fixed or explicitly declined with a documented reason;
- no Cursor review thread remains unresolved;
- CodeRabbit has approved the current head; and
- the required checks pass and the final maintainer review finds the diff ready to merge.

The dismissal message must identify why the review is stale and point to the fixing commit or the
commit that documents the declined findings. Never dismiss a current-head review, an unresolved
valid finding, or a review merely to bypass the conversation-resolution rule.

Follow the [product and acceptance contract](docs/product-and-acceptance-contract.md) for manual
testing. Live Spotify playback and account mutations are opt-in: launching or read-only acceptance
testing is not permission to alter playback on any Connect device.

Report vulnerabilities using [SECURITY.md](SECURITY.md), not a public issue.
