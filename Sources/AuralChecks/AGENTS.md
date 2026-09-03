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

Run the focused check product while iterating, then `./Scripts/check.sh` from the repository root.
Rust/FFI contract changes also require Rust coverage and `./Scripts/check-clean.sh`.
