# ADR 001: Keep librespot as a contained playback leaf

Status: accepted on 2026-08-18

Like all of Aural, this decision concerns an unofficial, educational client built on
reverse-engineered Spotify interfaces; using it may violate Spotify's Terms of Use.

## Goal

Keep Aural native, responsive, Premium-only, and easy to reason about while providing local
playback that does not depend on the Spotify desktop app.

## Options considered

### Pure Swift playback engine

There is no maintained Swift library that implements local Spotify audio playback and Spotify
Connect. Building one would mean owning the private session, Connect, queue, media delivery,
decryption, codec, and reconnection behavior currently supplied by librespot. That increases both
code volume and protocol-maintenance risk without improving the product.

### Spotify iOS SDK

[Spotify's iOS SDK](https://developer.spotify.com/documentation/ios) is an App Remote SDK for iOS.
It requires the Spotify app to perform playback and does not provide a macOS local playback engine.
It therefore does not meet Aural's requirements.

### Swift Web API packages

[SpotifyAPI](https://github.com/Peter-Schorn/SpotifyAPI) is a capable Swift wrapper around the
Spotify Web API. Its player methods control an existing Spotify Connect device; the package does
not decode or render audio locally. Aural already has a smaller API layer tailored to its UI, so
adding it would duplicate working code without replacing the playback engine.

### Web Playback SDK in WKWebView

Spotify's [Web Playback SDK](https://developer.spotify.com/documentation/web-playback-sdk) supports
local playback in desktop browsers. A macOS app can host it in a hidden `WKWebView`; the open-source
[Spotiglass](https://github.com/isaaclins/spotiglass) project demonstrates that architecture.

This removes Rust but introduces a JavaScript bridge, WebKit playback lifecycle, an additional
developer-app client ID and setup flow, REST device transfer, and WebKit helper processes. It is a
reasonable fallback if Spotify stops supporting the librespot protocol, but it is not a simpler or
more native implementation for Aural today. It also needs dedicated background-window, resource,
AirPlay, and reconnection benchmarks before it could replace a working engine.

### Embedded librespot

[librespot](https://github.com/librespot-org/librespot) is maintained, Premium-only, supports local
audio playback, and acts as a Spotify Connect receiver. Aural statically links the required Rust
components and sends decoded PCM to its native AVFoundation renderer.

## Decision

Keep the embedded Rust/librespot core, but treat it as a replaceable leaf:

- `PlaybackCore.swift` is the only Swift file allowed to import the C module or call its symbols.
- `PlaybackStore` owns the atomic reducer-backed playback presentation, while injected adapters
  keep Rust, Spotify APIs, authorization, preferences, and lifecycle events at the boundary.
- `AudioRenderer` remains native AVFoundation code.
- Catalog, OAuth, persistence, UI, shuffle policy, queue presentation (delimiter hiding and
  playable-track filtering via `QueueProtocolProjection`), device-list presentation
  (`ConnectDeviceProjection`), connection-snapshot presentation (`ConnectionSnapshotProjection`),
  playback-snapshot presentation (`PlaybackSnapshotProjection`), and error policy remain Swift.
- The earlier unused playback-abstraction target remains removed. The current `AuralCore` target
  is the testable Swift application implementation, not another playback abstraction; the C leaf
  is still reached only through `PlaybackCore.swift` and `RustPlaybackEngine`.

Revisit this decision if Spotify ships a supported macOS playback SDK or if a measured WKWebView
experiment improves reliability and total resource use without adding user setup.
