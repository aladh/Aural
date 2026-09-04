# ADR 001: Playback engine boundary

Status: accepted on 2026-08-18.

Under staged review per #201. The decision below stands until a later record supersedes it;
the replacement stages and their gates live in [playback engine ownership](playback-engine-ownership.md).

Like all of Spotty, this decision concerns an unofficial, independent, educational client with no
affiliation with Spotify AB, built on reverse-engineered Spotify interfaces; using it may violate
Spotify's Terms of Use.

## Context

Spotty needs local Spotify Premium playback and Spotify Connect without the Spotify desktop app, a
WebView, or a Chromium shell. When the engine was chosen there was no maintained Swift library for
the private session, Connect, media delivery, decryption, codec, and reconnection work. librespot
supplied all of it, so it was embedded as a statically linked Rust leaf that hands decoded PCM to
the native AVFoundation renderer.

Two constraints from the original research still hold. Spotify's developer policy and terms
restrict reverse engineering and permit streaming only for Premium subscribers, so the private
protocol is a policy and enforcement risk in any implementation language. Spotifly's experience
showed that the durable shape is one lifecycle owner and one revisioned snapshot stream, not a
clone of any particular implementation.

## Decision

Keep the embedded Rust/librespot core, but treat it as a replaceable leaf:

- Swift reaches it only through `Sources/AuralPlaybackCore`, `PlaybackCore.swift`, and
  `RustPlaybackEngine`.
- Swift owns application logic: state, queue policy, presentation, resume policy, catalog, OAuth,
  persistence, and error policy. `AudioRenderer` stays native AVFoundation.
- `AuralCore` is the testable Swift application implementation, not another playback
  abstraction; no second engine-abstraction target is reintroduced.

The live boundary is [playback engine ownership](playback-engine-ownership.md).

## Options rejected

- Pure Swift engine now: verification cost and protocol churn outweigh the gain.
- Spotify iOS SDK: an App Remote SDK that needs the Spotify app and offers no macOS engine.
- Web Playback SDK in `WKWebView`: removes Rust but adds a JavaScript bridge, WebKit helper
  processes, a second client ID and setup flow, and REST device transfer.

## Consequences

- One adapter file and one C header are the whole review surface for foreign-boundary changes.
- librespot updates are protocol migrations, not routine dependency bumps.
- Any staged replacement must keep the boundary narrow while responsibility moves across it.

## Revisit trigger

A supported macOS playback SDK, a measured WKWebView experiment that improves reliability and
total resource use without adding user setup, or a passed gate in the staged review named above.
