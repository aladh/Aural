# Performance and acceptance baseline — 2026-08-23

This baseline closes the production-plan acceptance gate after the atomic playback, progressive
queue, demand-loaded catalog, diagnostics, audio-boundary, quality-gate, and native-browsing work.

## Environment

- App: Aural 0.4.0 (4), optimized signed Release bundle
- Commit under test: working tree immediately before the production-plan commit
- macOS: 27.0 (26A5416b), ARM64
- Hardware: 16-inch MacBook Pro (MacBookPro18,2), Apple M1 Max, 10 CPU cores, 32 GB memory
- Spotify playback: local Aural Connect device, system output volume set to zero
- Resource sampling: five `ps` samples at one-second intervals after the state stabilized
- Memory value: resident set size (RSS); foreground/background are window open/closed while the
  same process remains running

## Resource measurements

| State | Window | Mean CPU | Mean RSS |
| --- | --- | ---: | ---: |
| Paused | Foreground | 0.0% | 256.20 MiB |
| Paused | Background | 0.0% | 254.83 MiB |
| Playing | Foreground | 28.58% | 262.65 MiB |
| Playing | Background | 20.80% | 262.39 MiB |

These are conservative warm-state numbers captured after browsing Home, Search, playlist, album,
artist, Settings, and the queue, so they include populated catalog and artwork caches. Closing the
window kept the process available from the Dock and reduced, rather than increased, resident
memory.

The playing sample contained 1,971 one-millisecond observations. The Rust playback callback spent
1,935 observations in the renderer's deliberate producer backpressure sleep. The renderer dispatch
queue appeared in 12 observations and there was no meaningful allocator hotspot. A speculative
Core Media sample-buffer pool is therefore not warranted; the tested cursor-based renderer is the
lower-risk design.

## Acceptance results

The following passed in the signed Release bundle:

- restored the signed-in account and existing paused playback state without a crash;
- loaded Home and the playlist sidebar independently;
- searched for a term and populated artist, album, playlist, and track sections;
- opened album and artist detail pages without triggering playback;
- opened a playlist, toggled Date Added between ascending, descending, and playlist order without
  showing a picker, and retained the expected track rows;
- opened Settings and changed no account or playback data;
- verified the native Aural menu contains Sign Out;
- showed and hid the queue inspector;
- closed the main window, confirmed the process remained running, and reopened the window;
- started the first track in Rotation for a controlled muted interval, then paused it;
- confirmed queue metadata progressively resolved to real names with no remaining `Unknown` rows;
- toggled shuffle on/off, cycled repeat through queue/track/off, and sought forward/back while
  paused; and
- opened the device menu and confirmed both the local Aural device and the available remote device
  were represented.

The app was left paused after testing. A physical machine sleep and an actual transfer to the
remote device were intentionally not forced: doing either would make this local acceptance run
depend on external device state. Their lifecycle and stale-callback paths are covered by the
deterministic full-store workflow checks.

## Automated gates

- Rust: formatting, warning-clean Clippy, and 41 unit checks
- Swift domain checks: 239
- Swift boundary/workflow/fixture checks: 213
- Clean Debug and Release rebuild, ABI/header comparison, architectural guards, and app-bundle
  validation

Run `./Scripts/check.sh` for the normal gate, `./Scripts/check-clean.sh` for the clean gate, and
`./Scripts/export-diagnostics.sh 15m` for a bounded privacy-safe Unified Logging report.
