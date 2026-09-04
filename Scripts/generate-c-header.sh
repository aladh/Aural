#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
crate_root="$project_root/Backend/spotty-playback"
config_path="$crate_root/cbindgen.toml"
generated_header="$project_root/Sources/SpottyPlaybackCore/include/spotty_playback_generated.h"
abi_signature_fixture="$crate_root/abi-signatures.txt"
required_cbindgen_version="0.29.4"
source "$project_root/Scripts/abi-signature-fixture.sh"

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
temporary_ast="$(mktemp /tmp/spotty-cbindgen-ast.XXXXXX)"
temporary_fixture_symbols="$(mktemp /tmp/spotty-cbindgen-fixture-symbols.XXXXXX)"
temporary_header_symbols="$(mktemp /tmp/spotty-cbindgen-header-symbols.XXXXXX)"
trap 'rm -f "$temporary_header" "$temporary_ast" "$temporary_fixture_symbols" "$temporary_header_symbols"' EXIT

if ! spotty_abi_fixture_symbols "$abi_signature_fixture" > "$temporary_fixture_symbols"; then
    exit 1
fi

"$cbindgen_bin" \
    --quiet \
    --config "$config_path" \
    --lockfile "$crate_root/Cargo.lock" \
    --output "$temporary_header" \
    "$crate_root"

# Parse the generated fragment before it can replace the checked-in header. The full ABI fixture
# is the scope contract, so an extra, missing, or duplicate Spotty export fails closed. Use the real
# include directory so Clang resolves any local headers exactly as the Swift target does, and keep
# Clang's diagnostics visible on parse failure.
clang_bin="$(command -v clang || true)"
if [[ -z "$clang_bin" || ! -x "$clang_bin" ]]; then
    print -u2 "Clang is required to validate the generated cbindgen header"
    exit 1
fi
if ! "$clang_bin" \
    -I "$project_root/Sources/SpottyPlaybackCore/include" \
    -x c-header \
    -fsyntax-only \
    -Xclang -ast-dump \
    "$temporary_header" > "$temporary_ast"; then
    print -u2 "Clang could not parse the generated cbindgen header"
    exit 1
fi
sed -nE "s/.*FunctionDecl .* (spotty_playback_[a-z0-9_]+) '([^']+)'$/\\1/p" \
    "$temporary_ast" > "$temporary_header_symbols"
if ! diff -u "$temporary_fixture_symbols" <(sort "$temporary_header_symbols"); then
    print -u2 "Generated cbindgen exports differ from the C ABI signature fixture"
    exit 1
fi

if [[ "$mode" == "write" ]]; then
    mv "$temporary_header" "$generated_header"
    chmod 644 "$generated_header"
    rm -f "$temporary_ast" "$temporary_fixture_symbols" "$temporary_header_symbols"
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
