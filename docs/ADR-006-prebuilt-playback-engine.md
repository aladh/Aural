# ADR 006: Consume a prebuilt playback engine through SwiftPM

Status: Accepted

## Context

ADR 005 retains Rust/librespot behind the C playback boundary. Building that leaf from source on
every development machine makes ordinary Swift work depend on Cargo, Rust, and header-generation
tools. The previous archive also lived outside SwiftPM's dependency graph, so callers had to manage
its freshness and relinking themselves.

## Decision

Ship the existing static playback library as a macOS ARM64 XCFramework consumed by a SwiftPM binary
target. The artifact contains its matching C headers, module map, build provenance, and dependency
notices. The Swift adapter stays in source and the runtime ownership boundary is unchanged.

Ordinary app compilation and packaging consume an immutable HTTPS artifact pinned by SHA-256.
The pin updater maintains matching literal URL/checksum declarations in `Package.swift` so changes
invalidate SwiftPM manifest caching. Content-addressed library filenames change the linker command
when the engine changes; replacing a same-named archive alone is insufficient in the tested toolchain.
Ordinary app builds do not invoke or install Rust tools. A missing or incompatible artifact fails with a diagnostic;
it never silently switches to source compilation. Apple's SDK, compiler, linker, and existing app
signing requirements still apply.

Engine development has an explicit local XCFramework override. Rust sources and the locked
dependency graph remain in this repository. CI verifies the source engine, generated ABI, and
artifact before publication; source changes require a matching rebuilt artifact. Published headers
and the library are one versioned unit, and generated binaries stay out of Git history.

The complete verification gate retains Rust and Swift checks. The app-only gate proves Swift
compilation, deterministic tests, and Swift/C import compatibility without access to Rust executables.
The complete gate also proves C/Rust layouts and signatures. CI retains Debug, Release, and
source-engine coverage.

## Consequences

App developers download and link the engine without maintaining a Rust installation. SwiftPM owns
the binary dependency. Supporting macOS ARM64 alone keeps the artifact to one platform slice.

Engine changes require an artifact build and pin update. Artifact availability, provenance, checksum
validation, and retained license material become part of the build contract. Rust debugging still
requires the source toolchain. A C ABI avoids embedding a compiled Swift adapter and its Swift module
compatibility requirements in the artifact.

This changes build distribution, not ADR 005's playback implementation or ownership. Procedures and
verification commands live in [agent operations](../CONTRIBUTING.md) and
[development setup](development-setup.md).
