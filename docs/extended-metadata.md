# Private extended-metadata protocol

Aural uses a reverse-engineered Spotify endpoint to populate the Popularity, BPM, and Key columns.
This is not a supported Spotify API; it may change without notice, and using it may violate
Spotify's Terms of Use. This document records the wire format so the integration can be maintained
without reverse-engineering it again from scratch.

## Discovery notes

To re-derive the protocol, unzip `Spotify.app/Contents/Resources/Apps/xpui.spa` and search its
JavaScript for `BPM`, `camelotKey`, and `AUDIO_ATTRIBUTES_V2`. Strings in the Spotify executable
name the protobuf messages (`spotify.playlistmixing.extensions.audio_attributes.v2.AudioAttributes`
and `com.spotify.extendedmetadata.*`) and show playlist requests using
`trackExtensions: [AUDIO_ATTRIBUTES_V2]`.

## Wire shape

`POST https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata`

Use `Content-Type: application/x-protobuf` and the same keymaster bearer, client token, and desktop
client headers as other private requests (see `SpotifyCredentials.sign`). A 401 means one of those
credentials may be stale; invalidate the exact bearer and client token that request carried, then
retry once if the shared attempt budget still allows it. A 401 that arrives after the budget is
spent, or after that named replay was already used, still invalidates the sent pair and then
returns. This POST is a metadata read, so HTTP 429, 500, 502, 503, and 504 plus interrupt-class
network errors also retry through the shared `SpotifyCredentials` policy. Those retries share a
three-attempt budget with the 401 retry, so earlier transients can consume the budget before a
later 401.

Request (`BatchedEntityRequest`) — one `EntityRequest` per track, each asking for two extensions:

```text
BatchedEntityRequest {
  repeated EntityRequest entity_request = 2;
}
EntityRequest {
  string entity_uri = 1;                 // "spotify:track:<base62>"
  repeated ExtensionQuery query = 2;
}
ExtensionQuery { ExtensionKind extension_kind = 1; }   // varint enum
```

Response (`BatchedExtensionResponse`) — one array per entity/extension pair, with partial entries
merged:

```text
BatchedExtensionResponse { repeated EntityExtensionDataArray extended_metadata = 2; }
EntityExtensionDataArray {
  ExtensionKind extension_kind = 2;              // varint
  repeated EntityExtensionData extension_data = 3;
}
EntityExtensionData {
  string entity_uri = 2;
  google.protobuf.Any extension_data = 3;        // Any { type_url = 1; bytes value = 2; }
}
```

The `Any` message's inner `value` bytes carry the payload named by the array's extension kind.

## Extension kinds

These values come from the pinned librespot `extension_kind.proto` plus newer values present in
the Spotify desktop bundle. Aural currently consumes the entries marked **used**.

| Kind | Name | Notes |
|---|---|---|
| 10 | `TRACK_V4` | **used** — full track message; `popularity` is field **8**, a `sint32` (zigzag-decode with `(v >> 1) ^ -(v & 1)`) |
| 222 | `AUDIO_ATTRIBUTES_V2` | **used** — tempo and musical key; newer than the pinned librespot proto, so carry it by raw value |
| 60 | `STREAM_COUNT` | Play count |
| 28 | `CUEPOINTS` | Fade-in/out and chorus points, including tempo (`automix.proto` ships in librespot) |
| 5 | `AUDIO_FILES` | Per-file bitrates and loudness normalization (`loudness_db`, `true_peak_db`) |
| 23 | `EXTRACTED_COLOR` | Dominant artwork color |
| 96 / 186 / 183 | Credits traits | Songwriter and producer credits |
| 1 / 16 | `CANVAZ` / `CANVAS_V1` | Looping visuals |
| 2 | `STORYLINES` | Artist commentary cards |
| 61 / 95 | Older audio attributes | Superseded by 222 |

Client-side-only newer values observed in the desktop bundle include 217 `BEATS`, 219
`MIXABILITY`, 225 `MIX_STATE`, 227 `SONG_DNA_ELIGIBILITY`, and 212 `PLAYBACK_TRAIT`. Lyrics are
served separately by the color-lyrics service.

## AudioAttributesV2 payload

```text
AudioAttributes { double bpm = 1; Key key = 2; }          // bpm: wire type 1, LE IEEE 754
Key             { string key = 1; int32 mode = 2; CamelotKey camelot_key = 3; }
CamelotKey      { string value = 1; string color = 2; }
```

Display the Camelot label (for example, `8B`) when present. Otherwise use `"<name> Major"` or
`"<name> Minor"` from `mode` (`1` is major). Round BPM to a whole number and discard non-positive
values.

## Client behavior

The codec/API and scheduling live in `TrackAttributes.swift` and
`CatalogMetadataRepository.loadTrackAttributes(for:)`, respectively.

- Batch 100 track URIs per request and cap each list load at 1,000 URIs.
- Cache attributes per URI for the session and collapse duplicate playlist occurrences.
- Treat enrichment as best-effort so track lists render before it finishes.
- Do not cache failures or absent attributes; a later list load can retry them.
