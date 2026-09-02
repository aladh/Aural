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

For authenticated development, sign in to Xcode with an Apple Account and select its free Personal
Team; paid Apple Developer Program membership is not required for local personal use. Create an
Apple Development certificate in Xcode's Accounts settings. If that control is unavailable for a
Personal Team, create a disposable macOS App project, select the Personal Team under **Signing &
Capabilities**, and let Xcode manage signing once; the disposable project can then be discarded.
`build_and_run.sh` automatically uses the identity when exactly one is available. If the machine has
multiple Apple Development identities, select one explicitly using the exact name printed by
`security find-identity -p codesigning -v`:

```bash
export AURAL_DEVELOPMENT_SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)'
```

Then build, package, sign, and launch the development app:

```bash
./script/build_and_run.sh
```

The launch script requires an Apple-issued signing identity with a Team ID. The stable Team ID is
the Keychain authorization boundary that survives changes to the app's per-build CDHash. A
self-signed certificate cannot provide that invariant on current macOS: Keychain records the
changing CDHash in the password item's partition ACL and prompts again after later rebuilds.

`Scripts/package-app.sh` can still create a build-only self-signed bundle using an isolated identity
and keychain under `.build/aural-signing/`. That path exists for deterministic packaging checks; it
is local-only, unsuitable for distribution, and must not be used to sign in. `build_and_run.sh`
fails before terminating or launching Aural when no Apple-issued team identity is available.

Sandboxed development tools may require permission for the packaging or launch script to invoke
macOS `security` and `codesign`. Grant the script as a unit instead of approving individual
commands. Signing with an Apple Development identity can require the identity's private-key access
once; it must not require Aural to reauthorize its stored Spotify credential after every rebuild.

If this checkout previously signed in using the self-signed build, the first team-signed launch may
ask once for permission to read the existing item. Enter the login-keychain password and choose
**Always Allow**. Later builds signed by the same Apple team must reuse that authorization without
prompting.

If the legacy item's authorization cannot be repaired that way, delete only that item as a fallback
(or sign out using the old build if it is still usable):

```bash
security delete-generic-password \
  -s dev.aural.app.keymaster \
  -a keymaster_tokens
```

Deleting the item removes the stored Spotify grant and requires browser authorization again. Do not
repeat it as a workaround for later builds; a later prompt means the app is not using the same Apple
team identity and should be diagnosed with `codesign -dvvv Aural.app`.

On first launch, choose Connect and complete Spotify authorization in the browser. The grant is
stored in the macOS Keychain; leftover plaintext from older development builds is migrated once
and then deleted. Authentication state is machine-local and intentionally not stored in Git.
Follow the
[product and acceptance contract](product-and-acceptance-contract.md) before exercising a live
Spotify account; playback is opt-in during acceptance testing.

## Everyday workflow

Update an existing checkout without rewriting local work:

```bash
git pull --ff-only
./Scripts/check.sh
./script/build_and_run.sh
```

Useful build modes are documented in [CONTRIBUTING.md](../CONTRIBUTING.md#build-and-run). The Codex
environment also tracks a **Run** action in `.codex/environments/environment.toml` that invokes the
normal build and launch script.

Plain `swift build` is not a complete build path for products that link `AuralCore`, notably `Aural`
and `AuralBoundaryChecks`. SwiftPM links `Backend/lib/libaural_playback.a` into those products, but
the generated archive is outside its dependency graph: a missing archive produces a linker error,
and Rust source changes do not rebuild it or necessarily relink an already-built Swift product.
Prefer `./Scripts/check.sh` or the build/package scripts, which handle the archive. For deliberate
direct SwiftPM iteration, run `./Backend/aural-playback/build.sh` after changing Rust sources or
dependencies, then run `swift package clean` before rebuilding so an existing Swift product cannot
retain the older linked archive.

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
[Tagged releases](../CONTRIBUTING.md#tagged-releases) for its signing status and validation
guarantees.

## Generated local state

The following are reproducible, ignored outputs and may be deleted at any time:

- `.build/` and `Backend/aural-playback/target/` — Swift and Rust build products;
- `Backend/lib/*.a` — the generated Rust static library consumed by SwiftPM;
- `Aural.app/` and `dist/` — local packages and archives;
- `diagnostics/` — local diagnostic exports that must be reviewed before sharing;
- `AuralArtwork/` — the bounded artwork cache;
- `.DS_Store` and `.swiftpm/` — local tooling metadata.

When changing the master app artwork in `Assets/AuralIcon.png`, regenerate every standard macOS
icon representation with `./Scripts/generate-icon.sh`. Commit both the source PNG and generated
`Assets/Aural.icns`.

To recover from an uncertain local state, a fresh clone is the preferred reset. Do not copy build
products or signing material from an older checkout. Cargo resolves the pinned librespot revision
from `Cargo.lock`, and the scripts rebuild every generated input.

## Where decisions live

- [README.md](../README.md) is the public landing page: identity, capabilities, requirements,
  getting started, limitations, and the experimental/unofficial warnings.
- [Product and acceptance contract](product-and-acceptance-contract.md) records UX invariants and
  safe live-account testing.
- [Architecture decision records](architecture-decisions.md) indexes accepted architecture
  boundaries, ownership decisions, and their status.
- [CONTRIBUTING.md](../CONTRIBUTING.md) defines verification, packaging, architecture overview, and
  public-repository hygiene.
- [PRIVACY.md](../PRIVACY.md), [SECURITY.md](../SECURITY.md), and
  [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) cover data handling, reporting, and
  attribution.
