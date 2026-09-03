# Research notes (2026-08-18)

## Recommendation

Build the full client as **SwiftUI/AppKit → narrow C ABI → Rust/librespot → CoreAudio**.

This is the best match for a polished macOS feel, low idle overhead, real Spotify Connect playback,
and a Premium-only product. It preserves native controls, accessibility, text behavior, and
windowing integration without introducing another UI runtime.

## Current constraints

- Upstream librespot is maintained, Premium-only, MIT licensed, and explicitly warns that use may
  violate Spotify's terms.
- Spotify's supported Web API can read playback and control an active device. Start/resume playback
  is Premium-only, but the API does not provide native decoded audio.
- The Web Playback SDK provides audio only inside a web runtime and requires Premium, which defeats
  the no-WebView/no-Chromium goal.
- Spotify's current [Development Mode rules](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
  require the app owner to have Premium and cap a dashboard application at five allowlisted users.
  Those rules do not legitimize Spotty's reused desktop-client identity or private endpoints.
- Spotify's [Developer Policy](https://developer.spotify.com/policy) permits music streaming through
  the supported platform only for Premium subscribers, restricts commercial streaming applications,
  and requires a clear privacy policy.
- Spotify's [Developer Terms](https://developer.spotify.com/terms) restrict reverse engineering and
  distribution of the Spotify Platform. Spotty's private protocols and reused Spotify-owned client
  identity are therefore policy and enforcement risks even when the source is free and non-commercial.

## Spotifly findings

Spotifly's current implementation is more ambitious than its older public description:

- one PKCE grant using Spotify's desktop-client ID;
- SwiftUI presentation and state services;
- Rust static library around official librespot via C FFI;
- Swift/CoreAudio rendering of PCM forwarded from Rust;
- internal Spotify desktop-client APIs for catalog/library data;
- a substantial set of fixes around reconnects, stale state, queue authority and FFI reentrancy.

The lesson is not to clone the whole implementation. The high-value shape is one authoritative Rust
lifecycle and one revisioned snapshot stream. Internal APIs and a reused Spotify-owned client ID are
the largest product risks.

## First-slice success criteria

The first UI slice proved:

1. The native shell feels coherent at a realistic desktop density.
2. One observable playback state can drive the main window, queue and keyboard commands.
3. The playback transport boundary is small enough to replace without restructuring the UI.
4. The app builds with SwiftPM and has deterministic state-transition tests.

The live backend now implements Premium sign-in, Connect registration, local and remote playback
state, URI playback, pause/resume, seek, skip, PCM rendering, credential caching, reconnects, and
callback-driven atomic state. Deterministic tests cover sleep/wake recovery, stale callback ordering,
queue precedence, teardown, and session replacement. Technical hardening does not remove the policy
and compatibility risks of an undocumented service integration.
