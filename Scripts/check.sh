#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_configuration="${AURAL_BUILD_CONFIGURATION:-debug}"
sdk_path="$(xcrun --show-sdk-path)"
compatible_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ -d "$compatible_sdk" ]]; then
    sdk_path="$compatible_sdk"
fi

mkdir -p "$project_root/.build/module-cache"
export SDKROOT="$sdk_path"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"

case "$build_configuration" in
    debug|release) ;;
    *)
        print -u2 "AURAL_BUILD_CONFIGURATION must be debug or release"
        exit 2
        ;;
esac

# The Rust suite owns lifecycle, generation, queue conversion, JSON envelopes,
# and compile-time C signature checks. Prefer the developer's normal toolchain;
# the fallback is the project-local toolchain provisioned by the development
# bootstrap on this workspace.
cargo_bin="${AURAL_CARGO:-}"
if [[ -z "$cargo_bin" ]]; then
    cargo_bin="$(command -v cargo || true)"
fi
workspace_cargo="/private/tmp/aural-rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo"
if [[ -z "$cargo_bin" && -x "$workspace_cargo" ]]; then
    cargo_bin="$workspace_cargo"
    export CARGO_HOME="${CARGO_HOME:-/private/tmp/aural-cargo}"
    export RUSTUP_HOME="${RUSTUP_HOME:-/private/tmp/aural-rustup}"
    export PATH="${cargo_bin:h}:$PATH"
fi
if [[ -z "$cargo_bin" || ! -x "$cargo_bin" ]]; then
    print -u2 "Rust cargo was not found. Install Rust or set AURAL_CARGO to an executable cargo path."
    exit 1
fi
"$cargo_bin" fmt --all --manifest-path "$project_root/Backend/aural-playback/Cargo.toml" -- --check
"$cargo_bin" clippy --locked --manifest-path "$project_root/Backend/aural-playback/Cargo.toml" \
    --all-targets -- -D warnings
"$cargo_bin" test --locked --manifest-path "$project_root/Backend/aural-playback/Cargo.toml"

# The archive is a generated, architecture-specific build product. Keep it out of Git and make
# every verification entry point self-contained by rebuilding when it is absent or stale.
backend_lib="$project_root/Backend/lib/libaural_playback.a"
stale_backend_input=""
if [[ -f "$backend_lib" ]]; then
    stale_backend_input="$(find "$project_root/Backend/aural-playback/src" \
        "$project_root/Backend/aural-playback/Cargo.toml" \
        "$project_root/Backend/aural-playback/Cargo.lock" \
        "$project_root/Backend/aural-playback/build.sh" \
        -type f -newer "$backend_lib" -print -quit)"
fi
if [[ ! -f "$backend_lib" || -n "$stale_backend_input" ]]; then
    "$project_root/Backend/aural-playback/build.sh"
fi

# Keep the checked-in C header and the actual static-library exports in exact
# agreement. Apple's nm can warn on newer Rust LLVM attributes in unrelated
# compiler-builtins objects, but it still emits the defined Aural symbols; the
# exact set comparison below is the contract check.
header_symbols="$(mktemp /tmp/aural-header-symbols.XXXXXX)"
library_symbols="$(mktemp /tmp/aural-library-symbols.XXXXXX)"
trap 'rm -f "$header_symbols" "$library_symbols"' EXIT
rg -o --pcre2 'aural_playback_[a-z0-9_]+(?=\s*\()' \
    "$project_root/Sources/AuralPlaybackCore/aural_playback.h" | sort -u > "$header_symbols"
(nm -gU "$backend_lib" 2>/dev/null || true) \
    | sed -nE 's/.*_(aural_playback_[a-z0-9_]+)$/\1/p' \
    | sort -u > "$library_symbols"
if ! diff -u "$header_symbols" "$library_symbols"; then
    print -u2 "The C header and libaural_playback.a export different Aural symbols"
    exit 1
fi

swift_arguments=(
    --disable-sandbox
    --package-path "$project_root"
    --configuration "$build_configuration"
    --product Aural
)
# A library newer than the linked executable means SwiftPM would skip the link step;
# drop the executable so the build below relinks against the current library.
built_binary="$project_root/.build/$build_configuration/Aural"
if [[ -f "$built_binary" && "$backend_lib" -nt "$built_binary" ]]; then
    rm -f "$built_binary"
fi
if [[ -n "${AURAL_SIGNING_IDENTITY:-}" ]]; then
    swift_arguments+=(-Xswiftc -DAURAL_DISTRIBUTION)
fi

swift build "${swift_arguments[@]}"

# Pure domain and deterministic scenario checks are a separate product so the
# assertion harness and fixtures never ship in the application executable.
check_arguments=(
    --disable-sandbox
    --package-path "$project_root"
    --configuration "$build_configuration"
    --product AuralChecks
)
swift build "${check_arguments[@]}"
checks_path="$(swift build "${check_arguments[@]}" --show-bin-path)/AuralChecks"
repeat_count="${AURAL_CHECK_REPEATS:-1}"
if ! [[ "$repeat_count" =~ '^[1-9][0-9]*$' ]] || (( repeat_count > 25 )); then
    print -u2 "AURAL_CHECK_REPEATS must be between 1 and 25"
    exit 2
fi
for (( run = 1; run <= repeat_count; run++ )); do
    "$checks_path"
done

# Concrete codecs/parsers and injected coordinator/queue workflows compile against the real app
# core in a second non-shipping executable. It deliberately stays a debug build because it uses
# `@testable import AuralCore`; the shipping Aural and pure-domain products above still honor a
# requested release configuration without enabling testability in production code.
boundary_arguments=(
    --disable-sandbox
    --package-path "$project_root"
    --configuration debug
    --product AuralBoundaryChecks
)
swift build "${boundary_arguments[@]}"
boundary_checks_path="$(swift build "${boundary_arguments[@]}" --show-bin-path)/AuralBoundaryChecks"
for (( run = 1; run <= repeat_count; run++ )); do
    "$boundary_checks_path"
done

# Architectural dependency rules. The domain must stay portable and deterministic,
# and the C ABI remains isolated behind the playback adapter boundary.
forbidden_domain_imports="$(rg -n '^import (AppKit|SwiftUI|AVFoundation|AuralPlaybackCore)$' \
    "$project_root/Sources/AuralDomain" || true)"
if [[ -n "$forbidden_domain_imports" ]]; then
    print -u2 "AuralDomain imports a UI, audio, or FFI framework:"
    print -u2 "$forbidden_domain_imports"
    exit 1
fi

ffi_imports="$(rg -l '^import AuralPlaybackCore$' "$project_root/Sources" --glob '*.swift' || true)"
expected_ffi_import="$project_root/Sources/Aural/Spotify/PlaybackCore.swift"
if [[ "$ffi_imports" != "$expected_ffi_import" ]]; then
    print -u2 "AuralPlaybackCore must be imported only by PlaybackCore.swift; found:"
    print -u2 "${ffi_imports:-<none>}"
    exit 1
fi

direct_core_calls="$(rg -l 'PlaybackCore\.' "$project_root/Sources/Aural" --glob '*.swift' || true)"
expected_core_caller="$project_root/Sources/Aural/Spotify/RustPlaybackEngine.swift"
if [[ "$direct_core_calls" != "$expected_core_caller" ]]; then
    print -u2 "PlaybackCore calls must remain inside RustPlaybackEngine.swift; found:"
    print -u2 "${direct_core_calls:-<none>}"
    exit 1
fi

if rg -n 'LiveSpotifyController|nonisolated\(unsafe\)' "$project_root/Sources" --glob '*.swift'; then
    print -u2 "A deleted controller or unsafe global state re-entered the Swift architecture"
    exit 1
fi

# Playback state projections are intentionally read-only. Reintroducing a setter recreates the
# partial-presentation states that the reducer boundary exists to prevent.
if sed -n '104,320p' "$project_root/Sources/Aural/Spotify/PlaybackStore.swift" \
    | rg -n '^[[:space:]]*set[[:space:]]*\{'; then
    print -u2 "PlaybackStore state projections must remain read-only; use an explicit atomic action"
    exit 1
fi

# Passing one PlaybackStore field as inout while the callee touches another field on the same
# store traps at runtime under Swift's exclusivity enforcement. Keep engine revision gates keyed
# by source instead of accepting a stored revision through inout.
if rg -n 'lastRevision:[[:space:]]*inout' \
    "$project_root/Sources/Aural/Spotify" --glob '*.swift'; then
    print -u2 "Playback revision gates must not borrow store fields through inout"
    exit 1
fi

feature_dependencies=(
    "$project_root/Sources/Aural/Views"
    "$project_root/Sources/Aural/Spotify/PlaybackStore.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+Commands.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+EngineEvents.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+History.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+Queue.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+Transport.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+Session.swift"
    "$project_root/Sources/Aural/Spotify/AccountStore.swift"
    "$project_root/Sources/Aural/Spotify/HomeLibraryStore.swift"
    "$project_root/Sources/Aural/Spotify/SearchStore.swift"
    "$project_root/Sources/Aural/Spotify/PlaylistStore.swift"
)
if rg -n 'PartnerAPI\(|SpotifyConnectAPI\(|SpotifyWebPlayerAPI\(|KeymasterAuth\.authorize|KeymasterSession\.shared|RustPlaybackEngine\.shared|PlaybackCore\.' \
    "${feature_dependencies[@]}"; then
    print -u2 "A store or view bypasses the injected production environment"
    exit 1
fi

if find "$project_root/Sources/Aural" -type d -name LogicChecks -print -quit | rg -q .; then
    print -u2 "Logic checks must live in AuralChecks, not the shipping app target"
    exit 1
fi

if rg -n "MockCatalog|PlaybackController|demo catalog" \
    "$project_root/Sources" "$project_root/README.md"; then
    print -u2 "Mock catalog references remain"
    exit 1
fi

# Public-repository hygiene. Generated bundles, archives, diagnostics, and finder metadata must
# never become source inputs or silently return in a later commit.
if git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked_artifacts="$(git -C "$project_root" ls-files \
        | rg '(^|/)(\.DS_Store|Aural\.app/|diagnostics/|dist/)|\.a$' || true)"
    if [[ -n "$tracked_artifacts" ]]; then
        print -u2 "Generated or private artifacts are tracked:"
        print -u2 "$tracked_artifacts"
        exit 1
    fi
fi

if rg -n 'security@example\.com|replace this placeholder' \
    "$project_root/README.md" \
    "$project_root/SECURITY.md" \
    "$project_root/CONTRIBUTING.md"; then
    print -u2 "A public-facing security-contact placeholder remains"
    exit 1
fi

plutil -lint "$project_root/Packaging/Info.plist"

print "Aural checks passed ($build_configuration): Rust, ABI, native app, domain, concrete boundary, architecture, and packaging checks are green"
