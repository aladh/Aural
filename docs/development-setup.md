# Development setup

A fresh checkout contains all source inputs. No old build products, captures, Spotifly checkout, or
separate librespot checkout is required.

## Fresh clone

Development requires:

- An Apple Silicon Mac running macOS 26.2 or newer; the app's runtime target is macOS 15+.
- Xcode 26.6 with Swift 6.3.3.
- [Rustup](https://rustup.rs/); `rust-toolchain.toml` pins the components and ARM64 macOS target.
- [ripgrep](https://github.com/BurntSushi/ripgrep) for repository verification.
- cbindgen 0.29.4 for header regeneration and the complete verification gate:
  `cargo install cbindgen --locked --version 0.29.4`. It is a development tool; ordinary app
  compilation consumes the checked-in header and does not invoke or download cbindgen.
- Spotify Premium only for live integration testing authorized under the
  [product contract](product-and-acceptance-contract.md#safe-acceptance-testing).

Then clone the public repository:

```bash
git clone https://github.com/aladh/Spotty.git
cd Spotty
```

Confirm the local toolchains before a long first build:

```bash
xcode-select -p
swift --version
cargo --version
rg --version
```

Run the complete non-playback quality gate:

```bash
./Scripts/check.sh
```

The first run downloads the pinned Rust toolchain and locked Cargo dependencies, builds
`Backend/lib/libspotty_playback.a` and the Swift products, and runs deterministic checks. It does not
sign in or start playback.

For an authenticated launch, sign in to Xcode with an Apple Account and create an Apple Development
certificate under its free Personal Team; paid membership is unnecessary for local personal use. If
Xcode does not offer that control, create a disposable macOS App project, select the Personal Team
under **Signing & Capabilities**, and let Xcode manage signing once.

`build_and_run.sh` selects the only available Apple Development identity. When several are available,
choose one with its exact name from `security find-identity -p codesigning -v`:

```bash
export SPOTTY_DEVELOPMENT_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)'
```

Then build, package, sign, and launch the development app. This replaces a running development copy,
so use it only for an authorized launch or interactive acceptance:

```bash
./script/build_and_run.sh
```

The launch script requires an Apple-issued identity with a Team ID. That stable identity preserves
the Keychain authorization boundary across rebuilds; self-signed certificates do not.

`Scripts/package-app.sh` can create a build-only self-signed bundle with an isolated identity and
keychain under `.build/spotty-signing/`. It is local-only, unsuitable for distribution or sign-in.
`build_and_run.sh` fails before terminating or launching Spotty when no Apple-issued Team identity
is available. Never install the generated identity in the login keychain or commit it.

Sandboxed development tools may need permission for the packaging or launch script to invoke
`security` and `codesign`. Apple Development signing can require private-key access once; Spotty
should not reauthorize its stored Spotify credential after later rebuilds.

If the current item's authorization cannot be repaired, delete only that item as a fallback:

```bash
security delete-generic-password \
  -s dev.spotty.app.keymaster \
  -a keymaster_tokens
```

Deleting the item removes the stored Spotify grant and requires browser authorization again. Do not
repeat it for later prompts; diagnose those with `codesign -dvvv Spotty.app` and the selected Team
identity.

On first launch, choose Connect and authorize Spotify in the browser. The grant stays in the macOS
Keychain and is never stored in Git. Before exercising a live account, follow the
[product and acceptance contract](product-and-acceptance-contract.md); playback is opt-in during
acceptance testing.

## SwiftPM archive caveat

`swift build` does not create or track `Backend/lib/libspotty_playback.a`, which `Spotty` and
`SpottyBoundaryTests` link. Use the build and package commands in [CONTRIBUTING.md](../CONTRIBUTING.md).
For direct SwiftPM iteration after a Rust change, run `./Backend/spotty-playback/build.sh`, then
`swift package clean` before rebuilding so SwiftPM relinks the archive.

## Generated local state

The following are ignored local outputs. Remove them only when cleanup is authorized; do not treat
signing material as disposable build output:

- `.build/`, `Backend/spotty-playback/target/`, and `Backend/lib/*.a` — Swift/Rust build products
  and the generated static library;
- `Spotty.app/` and `dist/` — local packages and archives;
- `diagnostics/` — local reports; review them before sharing;
- `SpottyArtwork/`, `.DS_Store`, and `.swiftpm/` — artwork cache and local tooling metadata.

When changing the master app artwork in `Assets/SpottyIcon.png`, regenerate every standard macOS
icon representation with `./Scripts/generate-icon.sh`. Every representation is derived from that
same source image, including the small sizes used in the Dock and Finder. Commit both the source
PNG and generated `Assets/Spotty.icns`.

For an uncertain local state, start with a fresh clone. Cargo resolves the pinned librespot revision
from `Cargo.lock`, and the scripts rebuild generated inputs.
