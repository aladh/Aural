# Aural

> [!CAUTION]
> **Experimental software:** Aural is an early-stage personal project built on unsupported,
> reverse-engineered Spotify interfaces. It may break without notice, lose functionality, or expose
> rough edges. Do not rely on it as your only Spotify client, and use it only with an account you
> control.

Aural is a native macOS music client for Spotify Premium. SwiftUI provides the interface,
Swift/AVFoundation renders audio, and a contained Rust/librespot backend owns Spotify Connect,
streaming, and decoding. There is no WebView or Chromium runtime.

> [!WARNING]
> Aural is an unofficial, independent project. It is not affiliated with, endorsed by, or
> sponsored by Spotify AB. It uses private, reverse-engineered Spotify interfaces and Spotify's
> desktop-client authorization flow, not a supported public API. This may violate Spotify's
> [Developer Terms](https://developer.spotify.com/terms) or other terms and can stop working at any
> time. Use it only with an account you control and at your own risk.

The MIT license covers this repository's code; it does not grant rights to Spotify's service,
content, trademarks, or private interfaces. Aural is intended for personal, non-commercial
experimentation. Spotify's current policy restricts commercial streaming applications and permits
music streaming only for Premium subscribers; review the current
[Developer Policy](https://developer.spotify.com/policy) before distributing anything.

## Features

- Native macOS navigation, tables, menus, settings, inspector, keyboard commands, and accessibility.
- Local 320 kbps playback with pause/resume, seek, previous/next, gapless transitions, repeat, and
  a persistent fewer-repeats shuffle mode.
- Spotify Connect device discovery, remote playback mirroring, device transfer, and queue display.
- Home, Search, profile, Liked Songs, playlists, albums, and artists from the signed-in account.
- Sortable playlist metadata including Date Added, Popularity, BPM, and Camelot Key.
- Bounded artwork caching and privacy-safe Unified Logging.

## Requirements

- An Apple-silicon Mac running macOS 15 or newer.
- A Spotify Premium account.
- Xcode Command Line Tools with Swift 6.1 or newer.
- [Rustup](https://rustup.rs/). The exact Rust toolchain and target are pinned in
  `rust-toolchain.toml` and install automatically on first use.
- [ripgrep](https://github.com/BurntSushi/ripgrep) when running the verification scripts.

The repository is source-only. Its architecture-specific Rust archive and app bundle are generated
locally and ignored by Git.

## Build and run

Start from a fresh clone:

```bash
git clone https://github.com/aladh/Aural.git
cd Aural
```

Then build, package, sign, and launch the app:

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

The generated local signing identity lives under the ignored `.build/aural-signing/` directory. It
is not system-trusted, is not a distribution identity, and never needs to be committed.

See [Development setup](docs/development-setup.md) for fresh-machine prerequisites, the first-build
flow, everyday commands, generated local state, and clean recovery instructions.

## Verify

```bash
./Scripts/check.sh
./Scripts/check-clean.sh
```

`check.sh` is the normal quality gate. It runs Rust formatting, warning-clean Clippy, the locked Rust
unit suite, rebuilds a missing or stale playback archive, compares the checked-in C header with the
archive's exported symbols, builds the native app, and runs both non-shipping Swift check products:

- `AuralChecks` exercises pure domain state, policies, parsing, and deterministic playback traces.
- `AuralBoundaryChecks` exercises concrete codecs, fixtures, and injected coordinator/queue flows.

It also validates architecture rules and packaging metadata. `check-clean.sh` removes Swift build
products, rebuilds Rust, and verifies both Debug and Release configurations.

Release builds use Apple's Unified Logging. To export a bounded local report without tokens, OAuth
redirects, or raw API payloads, run `./Scripts/export-diagnostics.sh`; reports are written under the
ignored `diagnostics/` directory.

## Privacy and security

Aural has no analytics, advertising, crash-reporting SDK, or Aural-operated server. Account data is
requested directly from Spotify and rendered locally. Distribution builds store OAuth credentials
in Keychain; self-signed development builds use local application preferences because changing
development signatures cannot retain a stable Keychain ACL.

Read [PRIVACY.md](PRIVACY.md) before signing in. Report security issues through the private process
in [SECURITY.md](SECURITY.md), not a public issue.

## Package and notarize

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
`macos-15` runner. The tag must exactly match `CFBundleShortVersionString` in
`Packaging/Info.plist`. The workflow runs the full quality gate, validates an ARM64-only app,
creates a ZIP and SHA-256 checksum, and publishes an experimental GitHub prerelease.

Until Developer ID and notarization credentials are configured, automated release artifacts use a
hardened-runtime, ad-hoc signature and are not automatically trusted by macOS.
Release notes must state that limitation. Source builds remain the preferred development path.

## Architecture

- Swift owns windows, navigation, presentation, OAuth, catalog access, metadata, shuffle policy,
  progress interpolation, and native AVFoundation audio output.
- Rust/librespot owns the streaming session, Spotify Connect, decoding, reconnects, and queue truth.
- `AuralDomain` owns atomic playback state, the reducer, queue precedence, and pure policies.
- `AuralCore` owns the app implementation behind the thin shipping `AuralApp` executable.
- `PlaybackStore` publishes reducer state, `PlaybackCoordinator` serializes effects, and
  `PlaybackEnvironment.live` assembles production dependencies once.
- `PlaybackCore.swift` alone imports the C module; `RustPlaybackEngine.swift` is its only caller.
- Playback commands cross into Rust; bounded PCM and immutable state snapshots cross back.
- Artwork is downsampled to rendered Retina size and retained in a cost-bounded cache that is
  purged when the app window closes.

Design records and implementation notes:

- [Development setup and clean recovery](docs/development-setup.md)
- [Product and acceptance contract](docs/product-and-acceptance-contract.md)
- [Architecture decision records](docs/architecture-decisions.md)
- [Private extended-metadata protocol](docs/extended-metadata.md)
- [Performance and acceptance baseline](docs/performance-baseline-2026-08-23.md)
- [Research notes](RESEARCH.md)

## Current boundary

Live local and remote playback, Spotify Home, profile, saved tracks, demand-loaded library
collections, search, and media detail pages are wired. Library editing and incremental on-screen
pagination remain future work. Because Aural depends on undocumented protocols, compatibility is
best-effort and no stability commitment can be made for Spotify-side changes.

## Attribution and license

The playback bridge, authentication flow, renderer, and Connect command shapes are adapted from
MIT-licensed Spotifly commits `35991ac25a04aa14f8839d88f46129da6c6b59c0` and
`bcb522675e9657599faa007c531c2159e506246f`. The Rust backend links librespot commit
`9c7d75615fc093bdcbdb29adbce3fed38c531852` plus the locked crates in `Cargo.lock`.

See [LICENSE](LICENSE), [NOTICE](NOTICE), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Contributions are described in [CONTRIBUTING.md](CONTRIBUTING.md).
