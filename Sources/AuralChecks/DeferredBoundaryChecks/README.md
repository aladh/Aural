# Concrete boundary checks

These source files preserve the pre-refactor assertions that still reach concrete authentication,
network, Rust-decoding, catalog-store, and app-coordinator implementations. They compile as the
non-shipping `AuralBoundaryChecks` executable against `AuralCore`; they are excluded only from the
pure `AuralChecks` product and the shipping `AuralApp` executable.

The executable pure suites cover protobuf, shuffle, playlist ordering, playback support policy,
URI/pagination/loopback parsing, deterministic playback reducer traces, and the command-effect
spike in [ADR 003](../../../docs/ADR-003-playback-command-effects.md). The concrete suite covers
auth parsing and PKCE, bearer 401 retry and grant-load single-flight, wire codecs, catalog resolution, formatting, privacy-safe API failure
surfaces, injected coordinator/queue invalidation workflows, typed playback-command failures,
`PlaybackEffectRegistry` task cancellation, transient mutation feedback, native playlist
add/remove, native queue add/remove, PCM writer wake/bypass, and serialized engine event
fan-out ordering. Do not move check code back into `Sources/Aural`: test code must not ship
in the application executable.

These checks intentionally use the custom runner rather than XCTest/Swift Testing so the complete
verification path remains available with the supported Command Line Tools installation.
