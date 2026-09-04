# C ABI surface agent guidance

This directory is the checked-in Swift-facing description of the Rust playback ABI, not an
independent implementation. Read [ADR 001](../../docs/ADR-001-playback-engine.md) before changing it.

- `spotty_playback.h` must match the exported `spotty-playback` symbol set and signatures exactly.
  Never add, remove, rename, or reinterpret a declaration as a header-only change.
- `PlaybackCore.swift` under `Sources/Spotty/Spotify/` is the only Swift importer of this module, and
  `RustPlaybackEngine.swift` is its only caller. Keep the surface narrow rather than exposing
  librespot internals for convenience.
- Make ownership explicit for every pointer, buffer, callback, and returned allocation. Pair every
  Rust allocation with the documented release path; do not assume the panic barrier validates
  foreign pointers or extends callback lifetimes.
- Review ABI changes for threading, reentrancy, nullability, sentinel errors, and pointer lifetime.
