# Deterministic check guidance

These products are the repository's machine-verifiable behavior evidence and never ship. Top-level
`Sources/AuralChecks/` covers pure `AuralDomain` behavior; `DeferredBoundaryChecks/` covers concrete
AuralCore codecs, adapters, stores, and injected workflows.

- Put each regression in the closest existing suite and assert observable behavior, ownership, or
  contract rather than reproducing implementation text.
- Use reduced, synthetic, non-identifying fixtures. Never copy real Spotify payloads, account IDs,
  library data, tokens, redirects, or private screenshots.
- Preserve stable suite names and deterministic execution. Focused suite selection is for iteration;
  `./Scripts/check.sh` must continue to run every registered suite.
- Cover stale, cancellation, failure, empty, duplicate/occurrence, ordering, teardown, and generation
  behavior when relevant, not only the happy path.
- A source/topology check is appropriate only for a truly lexical boundary. Do not replace semantic
  concurrency, lifetime, queue provenance, or rollback coverage with regex snapshots.
- Check code never moves into `Sources/Aural`: test code must not ship in the application
  executable. `AuralChecks` depends only on `AuralDomain` and `AuralCheckSelection` and is the
  Rust-free path; `AuralBoundaryChecks` links `AuralCore` and needs the playback archive at link
  time.
- Boundary suites wait with the shared `@MainActor` `waitUntil` helper (cooperative `Task.yield`
  polling under a `ContinuousClock` deadline, rechecked after cancellation), and settle negative
  assertions by awaiting `PlaybackEffectRegistry.settlement(of:)` rather than a fixed sleep.

Run the focused check product while iterating, then `./Scripts/check.sh` from the repository root.
Suite selection (`--list` and suite names after `--`) is documented in
[agent operations](../../CONTRIBUTING.md).
Rust/FFI contract changes also require Rust coverage and `./Scripts/check-clean.sh`.
