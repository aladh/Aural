<p align="center">
  <img src="Assets/AuralIcon.png" width="112" height="112" alt="Aural">
</p>

# Aural

> [!CAUTION]
> **Experimental software:** Aural is an early-stage personal project built on unsupported,
> reverse-engineered Spotify interfaces. It may break without notice, lose functionality, or expose
> rough edges. Do not rely on it as your only Spotify client, and use it only with an account you
> control.

Aural is a native macOS music client for Spotify Premium. It is meant to feel like a focused Mac
app: SwiftUI and AppKit for the interface, AVFoundation for audio output, and a contained
Rust/librespot backend for Spotify Connect, streaming, and decoding. There is no WebView or
Chromium runtime.

Its visual direction uses a Spotify-familiar hierarchy—a near-black canvas in Dark Mode,
library-forward sidebar, artwork-led media headers, dense track tables, right-side queue rail, and
full-width bottom player shelf—implemented with system-adaptive native macOS surfaces. Familiarity
is a design reference, not a pixel copy or an indication of affiliation with Spotify.

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

## Capabilities

- Native macOS navigation, tables, menus, inspector, keyboard commands, and accessibility. Native
  selection and focus use the system accent; media actions and current-playback state use Aural's
  fixed green. There is no Settings scene or custom accent-color preference.
- Local 320 kbps playback with pause/resume, seek, previous/next, gapless transitions, repeat, and
  a persistent fewer-repeats shuffle mode.
- Spotify Connect device discovery, remote playback mirroring, device transfer, and queue display.
  Add to Queue uses selected tracks in visible order. Selectable upcoming rows can be removed with
  Delete/Backspace or Remove from Queue when another device owns playback and the current player
  permits queue edits, preserving duplicates; Spotify Connect confirms a successful removal before
  the displayed queue changes.
- Home, Search, profile, Liked Songs, playlists, albums, and artists from the signed-in account.
- Sortable playlist metadata including Date Added, Popularity, BPM, and Camelot Key.
- Add selected tracks to an owned library playlist, and remove selected occurrences from an open
  owned playlist, with shared transient success and failure feedback.
- Bounded artwork caching and local operational Unified Logging.

## Requirements

To run Aural:

- An Apple-silicon Mac running macOS 15 or newer.
- A Spotify Premium account.

To build it from this repository:

- An Apple-silicon Mac running macOS 26.2 or newer, as required by Xcode 26.6.
- Xcode 26.6 with Swift 6.3.3.
- [Rustup](https://rustup.rs/). The exact Rust toolchain and target are pinned in
  `rust-toolchain.toml` and install automatically on first use.
- [ripgrep](https://github.com/BurntSushi/ripgrep) when running the verification scripts.

The repository is source-only. Its architecture-specific Rust archive and app bundle are generated
locally and ignored by Git.

## Getting started

Clone the repository and launch a local development build:

```bash
git clone https://github.com/aladh/Aural.git
cd Aural
./script/build_and_run.sh
```

The script compiles the Rust backend when needed, builds the SwiftPM executable, creates and signs a
local `Aural.app`, replaces any running development copy, and launches it. The first build downloads
the locked Rust dependencies and takes longer than subsequent builds. On first launch, choose
Connect and complete Spotify authorization in the browser.

Version tags also publish experimental GitHub prereleases. Until Developer ID and notarization
credentials are configured, those artifacts use a hardened-runtime, ad-hoc signature and are not
automatically trusted by macOS. Building from source remains the intended way to run Aural.

For fresh-machine prerequisites, generated local state, and recovery, see
[Development setup](docs/development-setup.md). Build modes, checks, packaging, signing, and
release mechanics are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Limitations

Live local and remote playback, Spotify Home, profile, saved tracks, demand-loaded library
collections, search, and media detail pages are wired. Owned-playlist add and occurrence removal
are available. Upcoming queue rows cannot be removed when Aural owns playback.
Playlist creation, rename, reordering, cover editing, collaborative-permission
management, liked-library editing, and incremental on-screen pagination remain future work.

Aural currently targets Apple-silicon Macs on macOS 15 or newer. Compatibility with Spotify is
best-effort: because it depends on undocumented protocols, no stability commitment can be made for
Spotify-side changes.

## Privacy and security

Aural has no analytics, advertising, crash-reporting SDK, or Aural-operated server. Account data is
requested directly from Spotify and rendered locally. Distribution builds store OAuth credentials
in Keychain. Local development packaging reuses a stable project-local signing identity so
that Keychain access policy survives rebuilds; leftover plaintext from older development
builds is read once and then deleted.

Read [PRIVACY.md](PRIVACY.md) before signing in. Report security issues through the private process
in [SECURITY.md](SECURITY.md), not a public issue.

## License

The playback bridge, authentication flow, renderer, and Connect command shapes are adapted from
MIT-licensed Spotifly commits `35991ac25a04aa14f8839d88f46129da6c6b59c0` and
`bcb522675e9657599faa007c531c2159e506246f`. The Rust backend links librespot commit
`9c7d75615fc093bdcbdb29adbce3fed38c531852` plus the locked crates in `Cargo.lock`.

See [LICENSE](LICENSE), [NOTICE](NOTICE), and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Contributing

Focused bug fixes, tests, documentation, and small maintainability improvements are welcome. Start
with [CONTRIBUTING.md](CONTRIBUTING.md) and the [product and acceptance contract](docs/product-and-acceptance-contract.md).
Accepted architecture boundaries are indexed in
[architecture decision records](docs/architecture-decisions.md).
