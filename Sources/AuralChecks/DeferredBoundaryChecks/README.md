# Concrete boundary checks

These source files preserve the pre-refactor assertions that still reach concrete authentication,
network, Rust-decoding, catalog-store, and app-coordinator implementations. They compile as the
non-shipping `AuralBoundaryChecks` executable against `AuralCore`; they are excluded only from the
pure `AuralChecks` product and the shipping `AuralApp` executable.

The executable pure suites cover protobuf, shuffle, playlist ordering, playback support policy,
URI/pagination/loopback parsing, and deterministic playback reducer traces. The concrete suite
covers auth parsing and PKCE, wire codecs, catalog resolution, formatting, and injected
coordinator/queue invalidation workflows. Do not move check code back into `Sources/Aural`: test
code must not ship in the application executable.

These checks intentionally use the custom runner rather than XCTest/Swift Testing so the complete
verification path remains available with the supported Command Line Tools installation.
