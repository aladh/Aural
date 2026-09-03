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
- Require explicit current-request authorization before live Spotify playback or account mutation,
  signing/keychain changes, destructive cleanup, new production dependencies, external publication,
  or material scope expansion.
- Do not invent a human handoff. There is no human maintainer, reviewer, tester, or release operator.
  When authorized acceptance cannot be performed, strengthen deterministic evidence where practical
  and state the exact unverified risk instead of deferring it to a person or claiming it passed.

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
| Protocol notes, research, and measured baselines | [Related technical context](docs/architecture-decisions.md#related-technical-context) |
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
| `Sources/AuralApp/` | Thin executable launcher. |
| `Sources/Aural/` | `AuralCore`: composition, native UI, feature stores, Spotify/auth adapters, audio renderer, playback adapter. |
| `Sources/AuralDomain/` | Portable models, reducer, lifetime rules, parsing, sorting, and policies. |
| `Sources/AuralPlaybackCore/` | Checked-in C header and module map for the Rust ABI. |
| `Backend/aural-playback/` | Rust/librespot session, Connect, streaming, decoding, recovery, protocol rows, and C exports. |
| `Sources/AuralChecks/` | Deterministic domain and boundary evidence; never ships. |
| `Scripts/` | Verification, packaging, signing, diagnostics, and release helpers. |
| `script/` | Development build/sign/launch entry point. |
| `.github/` | CI, pull-request metadata, and release workflows. |
| `Packaging/` | App metadata and privacy manifest. |
| `docs/` | Product contract, decisions, enforcement inventory, protocol notes, and measured baselines. |

Swift target direction is `AuralApp -> AuralCore -> AuralDomain`; `AuralCore` reaches the C/Rust leaf
through one narrow adapter. Do not add a reverse edge for convenience.

## Global engineering constraints

- Match surrounding code: naming, comment density, idiom, isolation, error handling, and abstraction
  level. Comment invariants and non-obvious lifetime/order constraints, not line-by-line narration.
- Fix behavior at its owner. Prefer the smallest cohesive change; introduce a seam first only when it
  makes the behavior change materially safer or easier to verify. Do not add speculative portability,
  configuration, extension points, or frameworks.
- Production dependencies are assembled once at the composition root. Production uses live
  integrations; fakes, synthetic fixtures, and test-only hooks stay in checks. Never commit real
  Spotify payloads or account-derived fixtures.
- Swift 6.3 concurrency diagnostics are correctness. Prefer structured concurrency, explicit actor
  isolation, immutable `Sendable` values, and owned cancellation. Do not suppress an ownership bug
  with `nonisolated(unsafe)`, mutable globals, broad singletons, or detached task lifetimes.
- User-facing failures must be actionable and privacy-safe. Never log tokens, OAuth redirects, raw API
  payloads, or private account/library identifiers.
- Generated archives, app bundles, diagnostics, caches, signing material, tokens, account data, and
  private screenshots do not belong in Git. Inspect the staged diff before every commit.
- Preserve `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md`, `PRIVACY.md`, and `SECURITY.md`. Pin GitHub
  Actions by full commit SHA with a readable version comment. Treat librespot updates as protocol
  changes, not routine dependency bumps.

## Live Spotify safety

Default to **no playback and no account mutation**. Deterministic checks and builds are safe. A launch
or read-only UI inspection is not permission to press transport controls, seek, transfer devices,
modify queue/library/playlists/follows, or sign out. Permission is scoped to the current request and
the specific action. For authorized live tests, follow the bounded procedure in the
[product contract](docs/product-and-acceptance-contract.md#safe-acceptance-testing) and report any
state that could not be restored.

Do not launch the Aural executable merely to prove compilation: `./script/build_and_run.sh`
terminates an existing process and can disturb an authenticated session.

## Work loop and evidence

1. Restate the requested outcome internally, identify the canonical owner and failure modes, and
   inspect the nearest coverage.
2. Implement the complete behavior, including relevant error, empty, stale, cancellation,
   inactive-window, and accessibility states. Avoid unrelated cleanup.
3. Add or update deterministic coverage at the closest ownership boundary. A green build alone is not
   evidence for behavior that can be expressed as a transition or boundary check.
4. Run proportional verification from the repository root:
   - Documentation only: follow the
     [documentation-only procedure](CONTRIBUTING.md#clean-and-risk-specific-verification).
   - Normal Swift/domain/UI behavior: run the nearest focused suites while iterating, then
     `./Scripts/check.sh`.
   - Rust, lifecycle, FFI, dependencies, build, signing, packaging, CI, or release mechanics: run
     `./Scripts/check-clean.sh` plus any task-specific path.
   - Performance: compare like-for-like configurations and record environment and methodology.
5. Inspect `git diff` and `git status --short`; remove accidental generated/private files and preserve
   unrelated edits.
6. Update the canonical document when product behavior, architecture, setup, privacy, security,
   attribution, or release behavior changes.

Completion evidence must name the user-visible outcome, important design choice, exact commands and
results, live/manual activity (including none), and any remaining risk. Never claim a test or
acceptance step that was not performed.

## Maintaining these instructions

`AGENTS.md` is the only repository instruction format. Add a root rule only when it applies to most
tasks and a capable agent cannot reliably infer it from code. Put path-specific review rules and
gotchas in the nearest `AGENTS.md`; put multi-step procedures in `CONTRIBUTING.md` or the owning
document. State each rule once, link rather than repeat, and remove stale guidance when behavior
changes. Instruction changes should reduce ambiguity or correct an observed failure mode, not
memorialize a one-off preference.
