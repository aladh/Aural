# Deterministic check guidance

These Swift Testing targets are deterministic and never ship. Top-level
`Tests/SpottyDomainTests/` covers pure `SpottyDomain` behavior; `Tests/SpottyBoundaryTests/` covers
concrete SpottyCore codecs, adapters, stores, and injected workflows.

- Use reduced, synthetic fixtures that follow [PRIVACY.md](../PRIVACY.md).
- Preserve stable test names and deterministic execution. Use standard SwiftPM test filtering for focused
  iteration; `./Scripts/check.sh` must continue to run every test target in full.
- A source/topology check is appropriate only for a truly lexical boundary. Do not replace semantic
  concurrency, lifetime, queue provenance, or rollback coverage with regex snapshots.
- Check code never moves into `Sources/Spotty`: test code must not ship in the application executable.
  `SpottyDomainTests` depends only on `SpottyDomain` and is the Rust-free path; `SpottyBoundaryTests`
  links `SpottyCore` and needs the playback archive at link time.
- Boundary suites wait with the shared `@MainActor` `waitUntil` helper (cooperative `Task.yield`
  polling under a `ContinuousClock` deadline, rechecked after cancellation), and settle negative
  assertions by awaiting `PlaybackEffectRegistry.settlement(of:)` rather than a fixed sleep.

## Project-specific authoring rules

- In `SpottyBoundaryTests`, tests are `@MainActor`, and the complete gate
  runs that target with `--no-parallel`; helpers that touch the same state must carry `@MainActor` too. Async waits go through that directory's
  `waitUntil` rather than `Thread.sleep` or `DispatchSemaphore.wait`. Domain tests keep their existing
  cooperative waits; neither rule applies to them.

SwiftPM filtering is documented in [agent operations](../CONTRIBUTING.md).
