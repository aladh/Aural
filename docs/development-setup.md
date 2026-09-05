# Development setup

This repository is the complete source of truth needed to resume Spotty development. A previous
checkout, generated static library, app bundle, signing certificate, Spotify response capture,
Spotifly checkout, or separate librespot checkout is neither required nor expected. Ordinary app builds
download the pinned playback binary; the Rust source remains available for engine development.

## Fresh clone

Development requires:

- An Apple Silicon Mac running macOS 26.2 or newer; the app's runtime target is macOS 15+.
- Xcode 26.6 with Swift 6.3.3.
- [ripgrep](https://github.com/BurntSushi/ripgrep) for repository verification.
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
rg --version
```

Build directly with SwiftPM, or run the app verification gate:

```bash
swift build --product Spotty
SPOTTY_CHECK_SCOPE=swift ./Scripts/check.sh
```

SwiftPM downloads the checksum-pinned macOS ARM64 playback XCFramework on first resolution and
caches it. The artifact includes the matching C headers and static library. App compilation, Swift
tests, and packaging do not require Cargo, rustc, or cbindgen. The Apple SDK and Clang remain necessary
for the C import and native link. No Spotify sign-in or playback occurs in the verification gate.

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

## Engine development

Install [Rustup](https://rustup.rs/) when changing the Rust engine or running its tests.
`rust-toolchain.toml` pins the components and ARM64 macOS target. Install cbindgen 0.29.4 for header
regeneration: `cargo install cbindgen --locked --version 0.29.4`.

The complete source verification gate remains `./Scripts/check.sh`; the Rust-only lane is
`SPOTTY_CHECK_SCOPE=rust ./Scripts/check.sh`. Artifact build and pin-update commands are documented
in [agent operations](../CONTRIBUTING.md). Use the explicit `SPOTTY_PLAYBACK_LOCAL_XCFRAMEWORK`
override when testing a source-built engine. Ordinary builds never fall back to compiling Rust.

The checked-in artifact manifest pins the published library and its headers together. Engine input
changes require a matching artifact; do not patch the published header separately or overwrite a
release asset. Keep Rust tooling for engine debugging, while Swift-only development can use the
published artifact throughout.

## Generated local state

The following are ignored local outputs. Remove them only when cleanup is authorized; do not treat
signing material as disposable build output:

- `.build/` and `Backend/spotty-playback/target/` — Swift and Rust build products;
- `Backend/lib/*.a` — intermediate static archives for explicit engine builds;
- `Spotty.app/` and `dist/` — local packages and archives;
- `diagnostics/` — local reports; review them before sharing;
- `SpottyArtwork/`, `.DS_Store`, and `.swiftpm/` — artwork cache and local tooling metadata.

When changing the master app artwork in `Assets/SpottyIcon.png`, regenerate every standard macOS
icon representation with `./Scripts/generate-icon.sh`. Every representation is derived from that
same source image, including the small sizes used in the Dock and Finder. Commit both the source
PNG and generated `Assets/Spotty.icns`.

To recover from an uncertain local state, a fresh clone is the preferred reset. Do not copy build
products or signing material from an older checkout. SwiftPM resolves the pinned playback artifact.
For source engine work, Cargo resolves the pinned librespot revision from `Cargo.lock`.
