<p align="center">
  <img src="Assets/SpottyIcon.png" width="112" height="112" alt="Spotty">
</p>

# Spotty

> [!CAUTION]
> **Experimental, unofficial software:** Spotty is an early-stage, independent personal project
> built on unsupported, reverse-engineered Spotify interfaces. It is not affiliated with, endorsed
> by, sponsored by, or otherwise connected to Spotify AB. It may break without notice, lose
> functionality, or expose rough edges. Do not rely on it as your only Spotify client, and use it
> only with an account you control.

Spotty is a native macOS music client for Spotify Premium. It is meant to feel like a focused Mac
app: SwiftUI and AppKit for the interface, AVFoundation for audio output, and a contained
Rust/librespot backend for Spotify Connect, streaming, and decoding. There is no WebView or
Chromium runtime.

Spotty's visual direction uses a Spotify-familiar hierarchy in a fixed dark appearance—a near-black
canvas, library-forward sidebar, artwork-led media headers, dense track tables, right-side queue
rail, and full-width bottom player shelf—implemented with native macOS surfaces. Familiarity is a
design reference, not a pixel copy or an indication of affiliation with Spotify.

> [!WARNING]
> Spotty is an unofficial, independent project with no affiliation to Spotify AB. It is not
> endorsed, sponsored, or supported by Spotify. Spotty uses private, reverse-engineered Spotify
> interfaces and Spotify's desktop-client authorization flow, not a supported public API. This may
> violate Spotify's [Developer Terms](https://developer.spotify.com/terms) or other terms and can
> stop working at any time. Use it only with an account you control and at your own risk.

> **Naming note:** Spotty is the product and technical identity throughout the repository, app
> bundle, executable, Swift and Rust modules, C ABI, local storage, diagnostics, build tooling, and
> release artifacts. A one-way first-launch migration carries forward state from installations that
> predate the complete rename. The name does not imply affiliation with Spotify.

The MIT license covers this repository's code; it does not grant rights to Spotify's service,
content, trademarks, or private interfaces. Spotty is intended for personal, non-commercial
experimentation. Spotify's current policy restricts commercial streaming applications and permits
music streaming only for Premium subscribers; review the current
[Developer Policy](https://developer.spotify.com/policy) before distributing anything.

## Capabilities

- Native macOS navigation, tables, menus, inspector, keyboard commands, and accessibility. Native
  selection and focus use the system accent; media actions and current-playback state use Spotty's
  fixed green. There is no Settings scene or custom accent-color preference.
- Local 320 kbps playback with pause/resume, seek, previous/next, gapless transitions, repeat, and
  a persistent fewer-repeats shuffle mode.
- Spotify Connect device discovery, remote playback mirroring, device transfer, and queue display.
  Add to Queue uses selected tracks in visible order. Selectable upcoming rows can be removed with
  Delete/Backspace or Remove from Queue when another device owns playback and the current player
  permits queue edits, preserving duplicates; Spotify Connect confirms a successful removal before
  the displayed queue changes.
- Home, Search, profile, Liked Songs, playlists, albums, and artists from the signed-in account.
- Sortable track metadata: playlist detail exposes Date Added, while shared catalog tables expose
  Popularity, BPM, and Camelot Key where applicable.
- Add selected tracks to an owned library playlist, and remove selected occurrences from an open
  owned playlist, with shared transient success and failure feedback.
- Bounded artwork caching and local operational Unified Logging.

## Requirements

To run Spotty:

- An Apple Silicon Mac running macOS 15 or newer.
- A Spotify Premium account.

To build it from this repository:

- An Apple Silicon Mac running macOS 26.2 or newer, as required by Xcode 26.6.
- Xcode 26.6 with Swift 6.3.3.
- [Rustup](https://rustup.rs/). The exact Rust toolchain and target are pinned in
  `rust-toolchain.toml` and install automatically on first use.
- [ripgrep](https://github.com/BurntSushi/ripgrep) when running the verification scripts.

The repository is source-only. Its architecture-specific Rust archive and app bundle are generated
locally and ignored by Git.

## Getting started

Clone the repository and launch a local development build:

```bash
git clone https://github.com/aladh/Spotty.git
cd Spotty
./script/build_and_run.sh
```

The script compiles the Rust backend when needed, builds the SwiftPM executable, creates and signs a
local `Spotty.app`, replaces any running development copy, and launches it. The first build downloads
the locked Rust dependencies and takes longer than subsequent builds. On first launch, choose
Connect and complete Spotify authorization in the browser.

Version tags also publish experimental GitHub prereleases. Until Developer ID and notarization
credentials are configured, those artifacts use a hardened-runtime, ad-hoc signature and are not
automatically trusted by macOS. Building from source remains the intended way to run Spotty.

For fresh-machine prerequisites, generated local state, and recovery, see
[Development setup](docs/development-setup.md). Build modes, checks, packaging, signing, and
release mechanics are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Limitations

Live local and remote playback, Spotify Home, profile, saved tracks, demand-loaded library
collections, search, and media detail pages are wired. Owned-playlist add and occurrence removal
are available. Upcoming queue rows cannot be removed when Spotty owns playback.
Playlist creation, rename, reordering, cover editing, collaborative-permission
management, liked-library editing, and incremental on-screen pagination remain future work.

Spotty currently targets Apple Silicon Macs on macOS 15 or newer. Compatibility with Spotify is
best-effort: because it depends on undocumented protocols, no stability commitment can be made for
Spotify-side changes.

## Privacy and security

Spotty has no analytics, advertising, crash-reporting SDK, or Spotty-operated server. Account data is
requested directly from Spotify and rendered locally. OAuth credentials are stored in Keychain.
Authenticated development launches require an Apple-issued signing identity with a stable Team ID;
self-signed packages are build-only because their per-build CDHash does not provide durable
Keychain authorization. Leftover plaintext from older development builds is read once and then
deleted.

Read [PRIVACY.md](PRIVACY.md) before signing in. Report security issues through the private process
in [SECURITY.md](SECURITY.md), not a public issue.

## License

The playback bridge, authentication flow, renderer, and Connect command shapes are adapted from
MIT-licensed Spotifly commits `35991ac25a04aa14f8839d88f46129da6c6b59c0` and
`bcb522675e9657599faa007c531c2159e506246f`. The Rust backend links librespot commit
`9c7d75615fc093bdcbdb29adbce3fed38c531852` plus the locked crates in `Cargo.lock`.

See [LICENSE](LICENSE), [NOTICE](NOTICE), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Agent-first maintenance

Spotty is developed, reviewed, tested, and maintained exclusively by autonomous coding agents; the
repository does not rely on a human contribution or review path. [AGENTS.md](AGENTS.md) is the sole
repository instruction format, with scoped `AGENTS.md` files beside specialized code. Reusable
commands and pull-request/release procedures live in [CONTRIBUTING.md](CONTRIBUTING.md), while
accepted architecture and supporting technical context are indexed in the
[architecture decision records](docs/architecture-decisions.md).

Changes are expected to leave machine-verifiable evidence, an explicit risk account, and no invented
human handoff. External issue reports may describe observed behavior, but implementation, semantic
review, automated-review resolution, and repository mutation remain agent-owned.
