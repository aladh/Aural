# AGENTS.md

Spotty is developed, reviewed, and maintained exclusively by autonomous coding agents. This file is
the always-loaded repository contract. Keep it small: global constraints live here, path-specific
gotchas live in the nearest `AGENTS.md`, and detailed procedures live in their canonical documents.

## Outcome

Spotty is an experimental, unofficial, independent, personal-use, native macOS client for Spotify
Premium. It should be a polished, fast, resource-conscious Mac app with a deliberately small
surface. The shipping app is SwiftUI/AppKit plus AVFoundation; Rust/librespot is a contained
playback and Spotify Connect leaf.
There is no WebView, Chromium shell, cross-platform UI, or supported Spotify API fallback.

When goals compete, use this order:

1. Protect the live Spotify account, credentials, private data, and current playback session.
2. Preserve playback, queue, account-lifetime, concurrency, and foreign-boundary correctness.
3. Prefer idiomatic macOS behavior and truthful product state over feature breadth.
4. Keep ownership explicit, changes cohesive, and behavior deterministic to verify.
5. Optimize only measured, user-visible costs.

The supported envelope is macOS 15+ on Apple Silicon with Spotify Premium. Keep Spotty's
experimental, unofficial, independent-project, and no-affiliation warnings prominent in public
material.

## Autonomy and approval

- For requests to review, explain, diagnose, or plan, inspect the relevant code, history, checks, and
  documents, then report the result. Do not edit unless the request also asks for a change.
- For requests to change, fix, or build, make the smallest complete in-scope change and run
  non-destructive validation without pausing for routine approval.
- A request to open a pull request authorizes creating a branch, committing, pushing, opening the PR,
  and addressing automated review for that PR. It does not authorize merging, tagging, publishing a
  release, changing repository settings, or mutating unrelated issues.
- Follow the [live Spotify safety contract](docs/product-and-acceptance-contract.md#safe-acceptance-testing).
  Signing/keychain changes, destructive cleanup, new production dependencies, external publication,
  or material scope expansion require explicit current-request authorization.
- Do not invent a human handoff. There is no human maintainer, reviewer, tester, or release operator.
  Do not defer work to a person or claim an acceptance step passed when it was not performed.

## Load context progressively

1. Run `git status --short` and preserve unrelated work. Never reset, discard, or overwrite it.
2. Discover repository instructions with
   `git -C "$(git rev-parse --show-toplevel)" ls-files | rg '(^|/)AGENTS\.md$'`.
   Before editing a path, read the `AGENTS.md` chain from the repository root through the path's
   nearest ancestor, even when the agent was launched from the root.
3. Read only the canonical documents relevant to the task:

| Need | Canonical owner |
| --- | --- |
| Product identity, capabilities, requirements, limitations | [README.md](README.md) |
| UX rules and safe live-account acceptance | [Product and acceptance contract](docs/product-and-acceptance-contract.md) |
| Accepted architecture | [ADR index](docs/architecture-decisions.md) |
| Protocol notes, engine ownership, and measured baselines | [Related technical context](docs/architecture-decisions.md#related-technical-context) |
| Rule owners and enforcement gaps | [Architecture enforcement inventory](docs/architecture-enforcement.md) |
| Fresh-clone setup, generated state, signing recovery | [Development setup](docs/development-setup.md) |
| Commands, verification, PR/review, packaging, release | [Agent operations](CONTRIBUTING.md) |

4. Inspect the implementation, nearest checks, and recent history for the affected behavior before
   editing. Prefer code and tests as high-fidelity references; use prose for intent and constraints.
5. If documents disagree, follow the most specific accepted owner, then repair the stale summary or
   link in the same change. Do not create another partial owner.

## Repository shape

| Path | Ownership |
| --- | --- |
| `Sources/SpottyApp/` | Thin executable launcher. |
| `Sources/Spotty/` | `SpottyCore`: composition, native UI, feature stores, Spotify/auth adapters, audio renderer, playback adapter. |
| `Sources/SpottyDomain/` | Portable models, reducer, lifetime rules, parsing, sorting, and policies. |
| `Sources/SpottyPlaybackCore/` | Checked-in C header and module map for the Rust ABI. |
| `Backend/spotty-playback/` | Rust/librespot session, Connect, streaming, decoding, recovery, protocol rows, and C exports. |
| `Backend/vendor/` | Vendored, patched third-party crates (see each crate's `PATCHES.md`); not routine dependency bumps. |
| `Sources/SpottyChecks/` | Deterministic domain and boundary evidence; never ships. |
| `Scripts/` | Verification, packaging, signing, diagnostics, and release helpers. |
| `script/` | Development build/sign/launch entry point. |
| `.github/` | CI, pull-request metadata, and release workflows. |
| `Packaging/` | App metadata and privacy manifest. |
| `docs/` | Product contract, decisions, enforcement inventory, protocol notes, and measured baselines. |

Swift target direction is `SpottyApp -> SpottyCore -> SpottyDomain`; `SpottyCore` reaches the C/Rust leaf
through one narrow adapter. Do not add a reverse edge for convenience.

## Global engineering constraints

- Production dependencies are assembled once at the composition root. Production uses live
  integrations; fakes, synthetic fixtures, and test-only hooks stay in checks.
- Swift 6.3 concurrency diagnostics are correctness. Prefer structured concurrency, explicit actor
  isolation, immutable `Sendable` values, and owned cancellation. Do not suppress an ownership bug
  with `nonisolated(unsafe)`, mutable globals, broad singletons, or detached task lifetimes.
- User-facing failures must be actionable and privacy-safe. Follow [PRIVACY.md](PRIVACY.md) and
  [SECURITY.md](SECURITY.md) for data handling and disclosure.
- Follow the [development setup guide](docs/development-setup.md#generated-local-state) for generated
  local state.
- Preserve `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`, `PRIVACY.md`, and `SECURITY.md`. Pin GitHub
  Actions by full commit SHA with a readable version comment. Treat librespot updates as protocol
  changes, not routine dependency bumps.

## Live Spotify safety

The [product contract](docs/product-and-acceptance-contract.md#safe-acceptance-testing) is the sole
owner of live-account authorization and acceptance procedure.

Do not launch the Spotty executable merely to prove compilation: `./script/build_and_run.sh`
terminates an existing process and can disturb an authenticated session.

## Local verification

Run the smallest focused check that exercises the change. PR CI covers partitioned Rust, Swift/Debug,
and Release compilation, but does not run `./Scripts/check-clean.sh`; reserve that local clean-room
gate for changes to clean-build behavior or diagnosis that depends on a clean rebuild.

## Maintaining these instructions

`AGENTS.md` is the only repository instruction format. Add a root rule only when it applies to most
tasks and a capable agent cannot reliably infer it from code. Put path-specific review rules and
gotchas in the nearest `AGENTS.md`; put multi-step procedures in `CONTRIBUTING.md` or the owning
document. State each rule once, link rather than repeat, and remove stale guidance when behavior
changes. Instruction changes should reduce ambiguity or correct an observed failure mode, not
memorialize a one-off preference.
