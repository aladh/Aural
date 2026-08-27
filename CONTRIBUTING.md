# Contributing to Aural

Aural is an unofficial, personal-use macOS client built on private Spotify interfaces. Read the
warning in [README.md](README.md) before contributing. Focused bug fixes, tests, documentation, and
small maintainability improvements are welcome. Discuss large features before investing substantial
work: protocol risk and a deliberately small product surface are part of the design.

By submitting a contribution, you agree that it may be distributed under the repository's MIT
license and that you have the right to submit it.

## Development environment

- Apple-silicon Mac with macOS 15 or newer
- Xcode Command Line Tools with Swift 6.1 or newer
- Rustup; `rust-toolchain.toml` pins Rust, components, and the ARM64 macOS target
- Spotify Premium only for manual integration testing

No credentials or account exports belong in the repository. Never commit OAuth callbacks, tokens,
diagnostic reports, generated signing material, API response dumps, or screenshots containing
private library/account information. The relevant generated paths are ignored, but inspect the
staged diff before every commit.

## Build and checks

Run the normal gate before opening a pull request:

```bash
./Scripts/check.sh
```

The script verifies Rust formatting, Clippy, Rust unit tests, the generated C ABI, Swift builds,
pure domain checks, concrete boundary/workflow checks, architecture constraints, and packaging
metadata. It builds the ignored Rust archive automatically when the archive is absent or stale.

For changes to build, packaging, dependency, FFI, or release behavior, also run the clean gate:

```bash
./Scripts/check-clean.sh
```

Add deterministic coverage in the closest existing suite:

- `Backend/aural-playback/src/tests.rs` for Rust lifecycle, queue, and FFI behavior
- `Sources/AuralChecks/` for portable domain rules and state-transition traces
- `Sources/AuralChecks/DeferredBoundaryChecks/` for concrete codecs, fixtures, and injected app flows

Do not add The Composable Architecture or another effect framework to support a prototype;
see [ADR 003](docs/ADR-003-playback-command-effects.md).

The Swift checks use a small custom runner rather than XCTest/Swift Testing so the full gate works
with Command Line Tools alone. Neither check executable is included in the packaged app.

## Pull requests

- Keep the diff focused and explain user-visible behavior and failure modes.
- Preserve the dependency boundaries enforced by `Scripts/check.sh`.
- Add or update tests for behavior changes.
- Update public docs when requirements, supported behavior, storage, permissions, or release steps
  change.
- Do not use real Spotify payloads as fixtures. Reduce them to synthetic, non-identifying examples.
- State what you tested manually. Maintainers can perform account-backed acceptance testing when a
  contributor cannot safely do so.

Follow the [product and acceptance contract](docs/product-and-acceptance-contract.md) for manual
testing. Live Spotify playback and account mutations are opt-in: launching or read-only acceptance
testing is not permission to alter playback on any Connect device.

Report vulnerabilities using [SECURITY.md](SECURITY.md), not a public issue.
