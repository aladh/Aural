#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
crate_root="$project_root/Backend/spotty-playback"
config_path="$crate_root/cbindgen.toml"
generated_header="$project_root/Sources/SpottyPlaybackCore/include/spotty_playback_connection_state_generated.h"
required_cbindgen_version="0.29.4"

mode="write"
if (( $# > 1 )); then
    print -u2 "usage: $0 [--check|--write]"
    exit 2
elif (( $# == 1 )); then
    case "$1" in
        --check) mode="check" ;;
        --write) mode="write" ;;
        *)
            print -u2 "usage: $0 [--check|--write]"
            exit 2
            ;;
    esac
fi

if [[ ! -f "$config_path" ]]; then
    print -u2 "cbindgen configuration is missing: $config_path"
    exit 1
fi

cbindgen_bin="${SPOTTY_CBINDGEN:-}"
if [[ -z "$cbindgen_bin" ]]; then
    cbindgen_bin="$(command -v cbindgen || true)"
fi
if [[ -z "$cbindgen_bin" || ! -x "$cbindgen_bin" ]]; then
    print -u2 "cbindgen $required_cbindgen_version is required; install it with:"
    print -u2 "  cargo install cbindgen --locked --version $required_cbindgen_version"
    print -u2 "or set SPOTTY_CBINDGEN to that executable's path"
    exit 1
fi

actual_cbindgen_version="$("$cbindgen_bin" --version 2>/dev/null || true)"
if [[ "$actual_cbindgen_version" != "cbindgen $required_cbindgen_version" ]]; then
    print -u2 "Expected cbindgen $required_cbindgen_version, found: ${actual_cbindgen_version:-<unknown>}"
    print -u2 "Install the pinned tool with:"
    print -u2 "  cargo install cbindgen --locked --version $required_cbindgen_version"
    print -u2 "or set SPOTTY_CBINDGEN to that executable's path"
    exit 1
fi

temporary_header="$(mktemp /tmp/spotty-cbindgen-header.XXXXXX)"
trap 'rm -f "$temporary_header"' EXIT

"$cbindgen_bin" \
    --quiet \
    --config "$config_path" \
    --lockfile "$crate_root/Cargo.lock" \
    --output "$temporary_header" \
    "$crate_root"

if [[ "$mode" == "write" ]]; then
    mv "$temporary_header" "$generated_header"
    chmod 644 "$generated_header"
    trap - EXIT
    print "Generated $generated_header"
    exit 0
fi

if [[ ! -f "$generated_header" ]]; then
    print -u2 "Checked-in cbindgen header is missing: $generated_header"
    print -u2 "Run ./Scripts/generate-c-header.sh to generate it"
    exit 1
fi

if ! cmp -s "$temporary_header" "$generated_header"; then
    diff -u "$generated_header" "$temporary_header" || true
    print -u2 "Checked-in cbindgen output differs from generated output"
    print -u2 "Run ./Scripts/generate-c-header.sh and commit the regenerated header"
    exit 1
fi

print "cbindgen output is up to date: $generated_header"
