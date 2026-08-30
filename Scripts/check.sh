#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_configuration="${AURAL_BUILD_CONFIGURATION:-debug}"
source "$project_root/Scripts/swiftpm-env.sh"

case "$build_configuration" in
    debug|release) ;;
    *)
        print -u2 "AURAL_BUILD_CONFIGURATION must be debug or release"
        exit 2
        ;;
esac

# Fail fast on Swift format drift before Rust or Swift compilation.
"$project_root/Scripts/format-swift.sh" --self-test
"$project_root/Scripts/format-swift.sh" --check

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
consumed_symbols="$(mktemp /tmp/aural-consumed-symbols.XXXXXX)"
trap 'rm -f "$header_symbols" "$library_symbols" "$consumed_symbols"' EXIT
rg -o --pcre2 'aural_playback_[a-z0-9_]+(?=\s*\()' \
    "$project_root/Sources/AuralPlaybackCore/aural_playback.h" | sort -u > "$header_symbols"
(nm -gU "$backend_lib" 2>/dev/null || true) \
    | sed -nE 's/.*_(aural_playback_[a-z0-9_]+)$/\1/p' \
    | sort -u > "$library_symbols"
if ! diff -u "$header_symbols" "$library_symbols"; then
    print -u2 "The C header and libaural_playback.a export different Aural symbols"
    exit 1
fi

# Dead C exports cannot regrow silently: every remaining header symbol must be
# called from the sole AuralPlaybackCore adapter. Reuses the header extractor's
# call-site token pattern rather than a second parser or generated binding.
# Line comments and quoted strings are dropped first so a mention is not a call.
playback_core="$project_root/Sources/Aural/Spotify/PlaybackCore.swift"
sed -e 's://.*::' -e 's/"[^"]*"//g' "$playback_core" \
    | rg -o --pcre2 'aural_playback_[a-z0-9_]+(?=\s*\()' \
    | sort -u > "$consumed_symbols"
unused_header_exports="$(comm -23 "$header_symbols" "$consumed_symbols")"
if [[ -n "$unused_header_exports" ]]; then
    print -u2 "Header exports not called from PlaybackCore.swift:"
    print -u2 "$unused_header_exports"
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
swift_arguments+=("${aural_swiftc_warnings_as_errors[@]}")

swift build "${swift_arguments[@]}"

# Pure domain and deterministic scenario checks are a separate product so the
# assertion harness and fixtures never ship in the application executable.
# The gate always runs every registered suite. Suite-name arguments exist for
# local iteration only and are not passed here.
check_arguments=(
    --disable-sandbox
    --package-path "$project_root"
    --configuration "$build_configuration"
    --product AuralChecks
    "${aural_swiftc_warnings_as_errors[@]}"
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
    "${aural_swiftc_warnings_as_errors[@]}"
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

# Read-only presentation projections live in PlaybackStore+Projections.swift. An explicit
# setter there recreates partial-presentation states; setters in other files are out of scope.
projections_file="$project_root/Sources/Aural/Spotify/PlaybackStore+Projections.swift"
if [[ ! -f "$projections_file" ]]; then
    print -u2 "PlaybackStore projections must live in PlaybackStore+Projections.swift"
    exit 1
fi
if rg -n '(^|[^[:alnum:]_])set[[:space:]]*(\([^)]*\)[[:space:]]*)?\{' "$projections_file"; then
    print -u2 "PlaybackStore state projections must remain read-only; use an explicit atomic action"
    exit 1
fi

# PlaybackStore.state may be assigned only at declaration and at the accepted reducer
# commit in send. Direct member mutation remains confined to PlaybackReducer.
playback_store_sources=(
    "$project_root/Sources/Aural/Spotify/PlaybackStore.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+Commands.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+EngineEvents.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+History.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+Projections.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+Queue.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+Session.swift"
    "$project_root/Sources/Aural/Spotify/PlaybackStore+Transport.swift"
)
store_state_assignments="$(
    rg -N '(^|[^[:alnum:]_.])(self\.)?state[[:space:]]*=' "${playback_store_sources[@]}" \
        | rg -v 'let state' \
        | rg -v 'state[[:space:]]*==' \
        | rg -v ':[^:]*//' \
        || true
)"
expected_store_state_assignments="$(printf '%s\n' \
    "$project_root/Sources/Aural/Spotify/PlaybackStore.swift:    private(set) var state = PlaybackState(accountEpoch: 1)" \
    "$project_root/Sources/Aural/Spotify/PlaybackStore.swift:            state = next")"
if [[ "$store_state_assignments" != "$expected_store_state_assignments" ]]; then
    print -u2 "PlaybackStore.state may be assigned only at declaration and the accepted reducer commit in send:"
    print -u2 "${store_state_assignments:-<none>}"
    exit 1
fi
if rg -N '(^|[^[:alnum:]_.])(self\.)?state\.[A-Za-z0-9_.\[\]]+[[:space:]]*=' "${playback_store_sources[@]}" \
    | rg -v 'let state' \
    | rg -v '==' \
    | rg -v ':[^:]*//'; then
    print -u2 "PlaybackStore.state members must not be mutated outside PlaybackReducer"
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
    "$project_root/Sources/Aural/Spotify/PlaybackStore+Projections.swift"
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
    "$project_root/Sources/Aural/Spotify/PlaylistMutationController.swift"
    "$project_root/Sources/Aural/Spotify/CatalogStore.swift"
)
if rg -n 'PartnerAPI\(|SpotifyConnectAPI\(|SpotifyWebPlayerAPI\(|KeymasterAuth\.authorize|KeymasterSession\.shared|RustPlaybackEngine\.shared|PlaybackCore\.' \
    "${feature_dependencies[@]}"; then
    print -u2 "A store or view bypasses the injected production environment"
    exit 1
fi

if rg -n 'func addToPlaylist|func removeFromPlaylist|func moveInPlaylist' \
    "$project_root/Sources/Aural/Spotify/CatalogProviding.swift"; then
    print -u2 "CatalogProviding must remain a read-only catalog surface"
    exit 1
fi

if rg -n 'parkNextConnectAccept|parkNextCommittedReplacement|waitForTestConnectAcceptGate|waitForTestCommittedReplacementGate|CheckedContinuation|pendingConnectAcceptGate|pendingCommittedReplacementGate' \
    "$project_root/Sources/Aural/Spotify/QueueService.swift"; then
    print -u2 "QueueService must not own test-only continuation gates"
    exit 1
fi

if rg -n '\.draggable\(|\.dropDestination\(|onDrop\(' \
    "$project_root/Sources/Aural/Views" --glob '*.swift'; then
    print -u2 "Playlist drag-and-drop was omitted; do not reintroduce unverified SwiftUI drag UI"
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

# The debug quality gate must keep using an existing runner rg, cache only repo-local
# SwiftPM products (including the redirected module cache), and leave Rust caching alone.
ci_workflow="$project_root/.github/workflows/ci.yml"
if [[ ! -f "$ci_workflow" ]]; then
    print -u2 "CI workflow is missing"
    exit 1
fi
if ! rg -q 'command -v rg' "$ci_workflow"; then
    print -u2 "CI must use an existing rg before Homebrew ripgrep"
    exit 1
fi
if ! rg -q 'brew install ripgrep' "$ci_workflow"; then
    print -u2 "CI must still install ripgrep when the runner has no rg"
    exit 1
fi
if rg -q 'brew untap aws/tap' "$ci_workflow"; then
    print -u2 "CI must not keep the aws/tap Homebrew workaround"
    exit 1
fi
if rg -q 'brew install swift-format|brew install swiftlint' "$ci_workflow"; then
    print -u2 "CI must use the selected toolchain swift-format, not a Homebrew Swift linter"
    exit 1
fi
if ! rg -q 'key: macos-rust-\$\{\{ hashFiles\(' "$ci_workflow"; then
    print -u2 "CI must keep the existing Rust cache key"
    exit 1
fi
if ! rg -U -q --fixed-strings $'          echo "SWIFT_TOOLCHAIN_KEY=$(shasum -a 256 "$RUNNER_TEMP/swift-toolchain.txt" | awk \'{print $1}\')" >> "$GITHUB_ENV"\n\n      - name: Cache SwiftPM build directory\n        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: |\n            .build/*\n            !.build/aural-signing\n          key: macos-swiftpm-${{ runner.os }}-${{ runner.arch }}-${{ env.SWIFT_TOOLCHAIN_KEY }}-${{ hashFiles(\'Package.swift\', \'Package.resolved\') }}-${{ github.sha }}\n          restore-keys: |\n            macos-swiftpm-${{ runner.os }}-${{ runner.arch }}-${{ env.SWIFT_TOOLCHAIN_KEY }}-' "$ci_workflow"; then
    print -u2 "CI must hash the Swift toolchain, then cache .build with a per-commit key and compatible restore prefix"
    exit 1
fi
if ! rg -U -q --fixed-strings $'      - name: Run checks\n        run: ./Scripts/check.sh\n\n      - name: Compile release Aural with AURAL_DISTRIBUTION\n        run: ./Scripts/compile-release-aural.sh' "$ci_workflow"; then
    print -u2 "CI must compile release Aural with AURAL_DISTRIBUTION after the unfiltered debug gate"
    exit 1
fi

plutil -lint "$project_root/Packaging/Info.plist"

print "Aural checks passed ($build_configuration): format, Rust, ABI, native app, domain, concrete boundary, architecture, and packaging checks are green"
