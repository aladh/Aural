#!/bin/zsh
set -euo pipefail

# Compile-only access-control contract for the testable SpottyCore module. The fixtures are never
# linked or run: the compiler must accept reads of the store snapshot/projections and reject each
# attempted write. Keep this next to the C-header compiler contract rather than making a source
# spelling snapshot of PlaybackStore's implementation.
project_root="${0:A:h:h}"
fixtures_root="$project_root/Tests/Compiler/PlaybackStoreAccess"
positive_fixture="$fixtures_root/positive.swift"
negative_fixture="$fixtures_root/negative.swift"

if (( $# > 1 )); then
    print -u2 "usage: $0 [SWIFT_BUILD_BIN_PATH]"
    exit 2
fi
if [[ ! -f "$positive_fixture" || ! -f "$negative_fixture" ]]; then
    print -u2 "PlaybackStore compiler access fixtures are missing"
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    print -u2 "swift is required to locate the built SpottyCore module"
    exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
    print -u2 "xcrun is required to type-check the PlaybackStore compiler fixtures"
    exit 1
fi

swiftc_path="$(xcrun --find swiftc 2>/dev/null || true)"
if [[ -z "$swiftc_path" || ! -x "$swiftc_path" ]]; then
    print -u2 "swiftc was not found in the selected Xcode/Swift toolchain"
    exit 1
fi
sdk_path="${SDKROOT:-}"
if [[ -z "$sdk_path" || ! -d "$sdk_path" ]]; then
    sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi
if [[ -z "$sdk_path" || ! -d "$sdk_path" ]]; then
    print -u2 "macOS SDK was not found in the selected Xcode/Swift toolchain"
    exit 1
fi

swift_bin_path="${1:-${SPOTTY_SWIFT_BUILD_BIN_PATH:-}}"
if [[ -z "$swift_bin_path" ]]; then
    swift_bin_path="$(swift build \
        --disable-sandbox \
        --package-path "$project_root" \
        --configuration debug \
        --show-bin-path 2>/dev/null)"
fi
if [[ ! -d "$swift_bin_path" ]]; then
    print -u2 "SwiftPM Debug build output directory is missing: ${swift_bin_path:-<none>}"
    print -u2 "Run the boundary test target before checking PlaybackStore access"
    exit 1
fi

# SwiftPM's output layout differs between the command-line and Xcode build systems. The Debug
# boundary test always builds a testable SpottyCore module; include both known Swift module
# locations, then select exactly one C module-map location. Passing the generated and checked-in
# module maps together produces a Clang redefinition diagnostic.
swift_module_paths=()
for candidate in "$swift_bin_path" "$swift_bin_path/Modules"; do
    if [[ -d "$candidate" ]]; then
        swift_module_paths+=(-I "$candidate")
    fi
done
if (( ${#swift_module_paths[@]} == 0 )); then
    print -u2 "No Swift module search paths were found under: $swift_bin_path"
    exit 1
fi
c_module_path=""
for candidate in "$swift_bin_path/include" "$swift_bin_path/SpottyPlaybackCore.build"; do
    if [[ -f "$candidate/module.modulemap" ]]; then
        c_module_path="$candidate"
        break
    fi
done
if [[ -z "$c_module_path" && -f "$project_root/Sources/SpottyPlaybackCore/include/module.modulemap" ]]; then
    c_module_path="$project_root/Sources/SpottyPlaybackCore/include"
fi
if [[ -z "$c_module_path" ]]; then
    print -u2 "SpottyPlaybackCore's module map is missing from SwiftPM output: $swift_bin_path"
    exit 1
fi

module_cache="$(mktemp -d /tmp/spotty-playback-projection-access.XXXXXX)"
trap 'rm -rf "$module_cache"' EXIT

swift_arguments=(
    -typecheck
    -parse-as-library
    -swift-version 6
    -warnings-as-errors
    -target arm64-apple-macos15.0
    -sdk "$sdk_path"
    -module-cache-path "$module_cache"
    "${swift_module_paths[@]}"
    -I "$c_module_path"
)

"$swiftc_path" "${swift_arguments[@]}" "$positive_fixture"

# Keep one probe per access surface. A single fixture containing all writes could still fail if a
# new writable projection were added next to an existing invalid write; independent diagnostics
# make each access-control promise observable. The compiler's diagnostic wording is intentionally
# the only assertion here: no production source or generated interface is parsed by the script.
negative_probes=(
    "NEG_STATE:state private setter"
    "NEG_STATE_MEMBER:nested state member mutation"
    "NEG_REQUIRES_REAUTHENTICATION:requiresReauthentication private setter"
    "NEG_ACCOUNT_EPOCH:accountEpoch projection"
    "NEG_PLAYBACK_LIFETIME:playbackLifetime projection"
    "NEG_PHASE:phase projection"
    "NEG_TRACK_URI:trackURI projection"
    "NEG_TRACK_TITLE:trackTitle projection"
    "NEG_ARTIST_NAME:artistName projection"
    "NEG_ARTWORK_URL:artworkURL projection"
    "NEG_IS_PLAYING:isPlaying projection"
    "NEG_IS_SHUFFLE_ENABLED:isShuffleEnabled projection"
    "NEG_REPEAT_MODE:repeatMode projection"
    "NEG_IS_ACTIVE_DEVICE:isActiveDevice projection"
    "NEG_POSITION:position projection"
    "NEG_DURATION:duration projection"
    "NEG_POSITION_ANCHOR_DATE:positionAnchorDate projection"
    "NEG_QUEUE_NEXT_ENTRIES:queueNextEntries projection"
    "NEG_CONNECT_DEVICES:connectDevices projection"
    "NEG_LOCAL_DEVICE_ID:localDeviceID projection"
    "NEG_IS_PLAYBACK_COMMAND_PENDING:isPlaybackCommandPending projection"
    "NEG_HAS_CURRENT_TRACK_METADATA:hasCurrentTrackMetadata projection"
    "NEG_TRANSIENT_COMMAND_ERROR:transientCommandError projection"
    "NEG_IS_CONNECTED:isConnected projection"
    "NEG_CATALOG_CURRENT_TRACK:catalogCurrentTrack projection"
    "NEG_DISPLAYED_TRACK_TITLE:displayedTrackTitle projection"
    "NEG_DISPLAYED_ARTIST_NAME:displayedArtistName projection"
    "NEG_DISPLAYED_ARTWORK_URL:displayedArtworkURL projection"
    "NEG_HAS_CURRENT_TRACK:hasCurrentTrack projection"
    "NEG_SHOWS_PAUSE_CONTROL:showsPauseControl projection"
    "NEG_CAN_START_PLAYBACK:canStartPlayback projection"
    "NEG_CAN_TOGGLE_PLAYBACK:canTogglePlayback projection"
    "NEG_CAN_SKIP_TRACK:canSkipTrack projection"
    "NEG_STATUS_TEXT:statusText projection"
    "NEG_ACTIVE_REMOTE_DEVICE:activeRemoteDevice projection"
    "NEG_REMOTE_PLAYBACK_BANNER:remotePlaybackBanner projection"
    "NEG_COMMAND_ROUTE:commandRoute projection"
)

for probe in "${negative_probes[@]}"; do
    flag="${probe%%:*}"
    label="${probe#*:}"
    negative_log="$module_cache/$flag.err"
    if "$swiftc_path" "${swift_arguments[@]}" "-D$flag" "$negative_fixture" \
        > /dev/null 2> "$negative_log"; then
        print -u2 "negative $label probe unexpectedly compiled"
        exit 1
    fi
    if ! rg -q 'setter is inaccessible|get-only property' "$negative_log"; then
        print -u2 "negative $label probe failed for an unexpected reason"
        cat "$negative_log" >&2
        exit 1
    fi
done

print "PlaybackStore compiler access contract passed: positive reads and ${#negative_probes} access-control negatives"
