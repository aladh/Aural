# Deterministic check guidance

These products are deterministic checks and never ship. Top-level
`Sources/SpottyChecks/` covers pure `SpottyDomain` behavior; `DeferredBoundaryChecks/` covers concrete
SpottyCore codecs, adapters, stores, and injected workflows.

- Use reduced, synthetic fixtures that follow [PRIVACY.md](../../PRIVACY.md).
- Preserve stable suite names and deterministic execution. Focused suite selection is for iteration;
  `./Scripts/check.sh` must continue to run every registered suite.
- A source/topology check is appropriate only for a truly lexical boundary. Do not replace semantic
  concurrency, lifetime, queue provenance, or rollback coverage with regex snapshots.
- Check code never moves into `Sources/Spotty`: test code must not ship in the application
  executable. `SpottyChecks` depends only on `SpottyDomain` and `SpottyCheckSelection` and is the
  Rust-free path; `SpottyBoundaryChecks` links `SpottyCore` and needs the playback archive at link
  time.
- Boundary suites wait with the shared `@MainActor` `waitUntil` helper (cooperative `Task.yield`
  polling under a `ContinuousClock` deadline, rechecked after cancellation), and settle negative
  assertions by awaiting `PlaybackEffectRegistry.settlement(of:)` rather than a fixed sleep.

## Project-specific authoring rules

- In `DeferredBoundaryChecks` (the `SpottyBoundaryChecks` product) `BoundaryCheckRunner` is `@MainActor`,
  so any helper that calls `check`/`equal` there must be `@MainActor` too, and async waits go through
  that directory's `waitUntil` rather than `Thread.sleep` or `DispatchSemaphore.wait`. Domain suites
  keep their existing cooperative waits; neither rule applies to them.
- Suite names are derived by `CheckSuiteRegistration.suiteName(fromRunFunction:)`, which kebab-cases
  the stem (`runPCMWriteSpaceChecks` → `pcm-write-space`); `check-suite-selection` enforces it.

Suite selection (`--list` and suite names after `--`) is documented in
[agent operations](../../CONTRIBUTING.md).
