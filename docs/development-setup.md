# Development setup

This repository is the complete source of truth needed to resume Aural development. A previous
checkout, generated static library, app bundle, signing certificate, Spotify response capture,
Spotifly checkout, or separate librespot checkout is neither required nor expected.

## Fresh clone

Install the prerequisites listed in [README.md](../README.md#requirements), then clone the public
repository:

```bash
git clone https://github.com/aladh/Aural.git
cd Aural
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

The first run downloads the exact Rust toolchain and locked Cargo dependencies, compiles the
contained Rust/librespot backend, generates `Backend/lib/libaural_playback.a`, builds the Swift
products, and runs all deterministic checks. No Spotify sign-in or playback occurs.

Build, package, sign, and launch the development app:

```bash
./script/build_and_run.sh
```

The packaging script creates an isolated self-signed development identity and keychain under
`.build/aural-signing/`. It does not install a permanent identity in the login keychain and should
not require repeated login-keychain approvals. The generated identity is local-only and unsuitable
for distribution.

Sandboxed development tools may require one permission grant for `./Scripts/package-app.sh` (or the
calling `./script/build_and_run.sh`) to invoke macOS `security` and `codesign` when that isolated
keychain is first created. Grant the packaging script as a unit instead of approving individual
`security` commands. Later builds reuse the project-local keychain until `.build/` is deleted; no
login-keychain password is part of the workflow.

On first launch, choose Connect and complete Spotify authorization in the browser. Authentication
state is machine-local and intentionally not stored in Git. Follow the
[product and acceptance contract](product-and-acceptance-contract.md) before exercising a live
Spotify account; playback is opt-in during acceptance testing.

## Everyday workflow

Update an existing checkout without rewriting local work:

```bash
git pull --ff-only
./Scripts/check.sh
./script/build_and_run.sh
```

Useful build modes are documented in [README.md](../README.md#build-and-run). The Codex environment
also tracks a **Run** action in `.codex/environments/environment.toml` that invokes the normal build
and launch script.

Before a pull request, inspect the staged changes and run:

```bash
./Scripts/check.sh
git status --short
```

Use `./Scripts/check-clean.sh` as the slower clean-room gate for changes to dependencies, FFI,
build, packaging, or releases.

For a tagged release, first update both version fields in `Packaging/Info.plist`, commit and push
the change, then create an annotated `vMAJOR.MINOR.PATCH` tag matching
`CFBundleShortVersionString`. CI uses an ad-hoc signature so the build does not depend on an
interactive development keychain. The tag workflow builds and publishes the ARM64 artifact; see
[Tagged releases](../README.md#tagged-releases) for its signing status and validation guarantees.

## Generated local state

The following are reproducible, ignored outputs and may be deleted at any time:

- `.build/` and `Backend/aural-playback/target/` — Swift and Rust build products;
- `Backend/lib/*.a` — the generated Rust static library consumed by SwiftPM;
- `Aural.app/` and `dist/` — local packages and archives;
- `diagnostics/` — privacy-filtered local diagnostic exports;
- `AuralArtwork/` — the bounded artwork cache;
- `.DS_Store` and `.swiftpm/` — local tooling metadata.

When changing the master app artwork in `Assets/AuralIcon.png`, regenerate every standard macOS
icon representation with `./Scripts/generate-icon.sh`. Commit both the source PNG and generated
`Assets/Aural.icns`.

To recover from an uncertain local state, a fresh clone is the preferred reset. Do not copy build
products or signing material from an older checkout. Cargo resolves the pinned librespot revision
from `Cargo.lock`, and the scripts rebuild every generated input.

## Where decisions live

- [README.md](../README.md) describes features, requirements, architecture, packaging, and project
  boundaries.
- [Product and acceptance contract](product-and-acceptance-contract.md) records UX invariants and
  safe live-account testing.
- [Architecture decision records](architecture-decisions.md) indexes accepted architecture
  boundaries, ownership decisions, and their status.
- [CONTRIBUTING.md](../CONTRIBUTING.md) defines verification and public-repository hygiene.
- [PRIVACY.md](../PRIVACY.md), [SECURITY.md](../SECURITY.md), and
  [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) cover data handling, reporting, and
  attribution.
