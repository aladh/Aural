#!/bin/zsh
set -euo pipefail

# Compile-only release path for the shipping Aural executable. Reuses an already-built
# playback archive and the repository SwiftPM/.build cache. Does not run the Rust suite,
# Swift checks, packaging, or signing.
project_root="${0:A:h:h}"
source "$project_root/Scripts/swiftpm-env.sh"

backend_lib="$project_root/Backend/lib/libaural_playback.a"
if [[ ! -f "$backend_lib" ]]; then
    print -u2 "libaural_playback.a is missing. Run ./Scripts/check.sh first so this compile can reuse the archive."
    exit 1
fi

release_binary="$project_root/.build/release/Aural"
if [[ -f "$release_binary" && "$backend_lib" -nt "$release_binary" ]]; then
    rm -f "$release_binary"
fi

swift_arguments=(
    --disable-sandbox
    --package-path "$project_root"
    --configuration release
    --product Aural
    -Xswiftc -DAURAL_DISTRIBUTION
    "${aural_swiftc_warnings_as_errors[@]}"
)

swift build "${swift_arguments[@]}"

bin_path="$(swift build "${swift_arguments[@]}" --show-bin-path)"
case "$bin_path" in
    */release)
        ;;
    *)
        print -u2 "Release compile must use the release configuration, not $bin_path"
        exit 1
        ;;
esac

built_binary="$bin_path/Aural"
if [[ ! -x "$built_binary" ]]; then
    print -u2 "Release compile did not produce an executable at $built_binary"
    exit 1
fi

debug_binary="$project_root/.build/debug/Aural"
if [[ -e "$debug_binary" ]]; then
    if [[ "$(realpath "$built_binary")" == "$(realpath "$debug_binary")" ]]; then
        print -u2 "Release compile reused the debug executable"
        exit 1
    fi
    if [[ "$(stat -f '%d:%i' "$built_binary")" == "$(stat -f '%d:%i' "$debug_binary")" ]]; then
        print -u2 "Release compile reused the debug executable"
        exit 1
    fi
fi

print "Compiled release Aural with AURAL_DISTRIBUTION at $built_binary"
