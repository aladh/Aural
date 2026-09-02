#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_configuration="${AURAL_BUILD_CONFIGURATION:-debug}"
check_scope="${AURAL_CHECK_SCOPE:-full}"
source "$project_root/Scripts/swiftpm-env.sh"

case "$build_configuration" in
    debug|release) ;;
    *)
        print -u2 "AURAL_BUILD_CONFIGURATION must be debug or release"
        exit 2
        ;;
esac
case "$check_scope" in
    full|rust|swift) ;;
    *)
        print -u2 "AURAL_CHECK_SCOPE must be full, rust, or swift"
        exit 2
        ;;
esac

# Fail fast on Swift format drift before Rust or Swift compilation.
# The sibling self-test covers wrapper discovery/failure contracts without a Swift toolchain.
if [[ "$check_scope" != rust ]]; then
    "$project_root/Scripts/format-swift-self-test.sh"
    "$project_root/Scripts/format-swift.sh" --check
fi

# The Rust suite owns lifecycle, generation, queue conversion, JSON envelopes,
# and compile-time C signature checks. Prefer the developer's normal toolchain;
# the fallback is the project-local toolchain provisioned by the development
# bootstrap on this workspace.
if [[ "$check_scope" != swift ]]; then
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

    if [[ "$check_scope" == rust ]]; then
        print "Aural Rust checks passed: formatting, warning-clean clippy, and locked tests are green"
        exit 0
    fi
fi

# The archive is a generated, architecture-specific build product. Keep it out of Git and make
# every verification entry point self-contained by rebuilding when it is absent or stale.
backend_lib="$project_root/Backend/lib/libaural_playback.a"
stale_backend_input=""
if [[ -f "$backend_lib" ]]; then
    stale_backend_input="$(find "$project_root/Backend/aural-playback/src" \
        "$project_root/rust-toolchain.toml" \
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

if rg -n 'nonisolated\(unsafe\)' "$project_root/Sources" --glob '*.swift'; then
    print -u2 "Production Swift must not use nonisolated(unsafe)"
    exit 1
fi

# Authenticated development must never silently fall back to a self-signed identity. On current
# macOS that gives the Keychain item a per-build CDHash partition and recreates the password prompt
# after every rebuild. Packaging may remain self-signed for deterministic build verification, but
# the launch entry point must require the Apple anchor + Team ID validator.
if ! rg -q --fixed-strings 'AURAL_DEVELOPMENT_SIGNING_IDENTITY' \
    "$project_root/script/build_and_run.sh" \
    || ! rg -q --fixed-strings 'validate-app.sh" --keychain-stable' \
        "$project_root/script/build_and_run.sh" \
    || ! rg -q --fixed-strings 'AURAL_APP_PATH="$staged_app_bundle"' \
        "$project_root/script/build_and_run.sh" \
    || ! rg -q --fixed-strings 'mv "$staged_app_bundle" "$app_bundle"' \
        "$project_root/script/build_and_run.sh" \
    || ! rg -q --fixed-strings 'AURAL_DEVELOPMENT_SIGNING_IDENTITY' \
        "$project_root/Scripts/package-app.sh" \
    || ! rg -q --fixed-strings 'TeamIdentifier=' "$project_root/Scripts/validate-app.sh" \
    || ! rg -q --fixed-strings "codesign --verify --strict -R '=anchor apple generic'" \
        "$project_root/Scripts/validate-app.sh"; then
    print -u2 "Authenticated development signing policy is incomplete"
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

# The debug quality gate must keep using an existing runner rg, exact-input playback archives,
# job-local SwiftPM caches, and credential-free checkouts.
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
if rg -q 'brew install swift-format|brew install swiftlint' "$ci_workflow"; then
    print -u2 "CI must use the selected toolchain swift-format, not a Homebrew Swift linter"
    exit 1
fi
rust_job="$(sed -n '/^  rust:/,/^  checks:/p' "$ci_workflow")"
checks_job="$(sed -n '/^  checks:/,/^  release:/p' "$ci_workflow")"
release_job="$(sed -n '/^  release:/,/^  gate:/p' "$ci_workflow")"
gate_job="$(sed -n '/^  gate:/,$p' "$ci_workflow")"
playback_cache_key='key: macos-playback-archive-${{ runner.arch }}-${{ env.RUST_TOOLCHAIN_KEY }}-${{ hashFiles('\''rust-toolchain.toml'\'', '\''Backend/aural-playback/Cargo.toml'\'', '\''Backend/aural-playback/Cargo.lock'\'', '\''Backend/aural-playback/build.sh'\'', '\''Backend/aural-playback/src/**'\'') }}'
rust_cache_key='key: macos-rust-debug-${{ runner.arch }}-${{ hashFiles('\''rust-toolchain.toml'\'', '\''Backend/aural-playback/Cargo.lock'\'') }}'
debug_cache_key='key: macos-swiftpm-debug-${{ runner.os }}-${{ runner.arch }}-${{ env.SWIFT_TOOLCHAIN_KEY }}-${{ hashFiles('\''Package.swift'\'', '\''Package.resolved'\'') }}-${{ github.sha }}'
release_cache_key='key: macos-swiftpm-release-${{ runner.os }}-${{ runner.arch }}-${{ env.SWIFT_TOOLCHAIN_KEY }}-${{ hashFiles('\''Package.swift'\'', '\''Package.resolved'\'') }}-${{ github.sha }}'
checkout_without_credentials=$'uses: actions/checkout@[0-9a-f]{40} # v[^\n]+\n        with:\n          persist-credentials: false'
if ! rg -q --fixed-strings 'runs-on: macos-26' <<< "$rust_job" \
    || ! rg -U -q "$checkout_without_credentials" <<< "$rust_job" \
    || ! rg -q --fixed-strings "$rust_cache_key" <<< "$rust_job" \
    || ! rg -q --fixed-strings 'run: AURAL_CHECK_SCOPE=rust ./Scripts/check.sh' <<< "$rust_job" \
    || ! rg -q --fixed-strings 'runs-on: macos-26' <<< "$checks_job" \
    || ! rg -q --fixed-strings 'xcode-select -s /Applications/Xcode_26.6.app' <<< "$checks_job" \
    || ! rg -q --fixed-strings "grep -q 'Apple Swift version 6.3.3'" <<< "$checks_job" \
    || ! rg -U -q "$checkout_without_credentials" <<< "$checks_job" \
    || ! rg -q --fixed-strings "$playback_cache_key" <<< "$checks_job" \
    || ! rg -q --fixed-strings "$debug_cache_key" <<< "$checks_job" \
    || ! rg -U -q --fixed-strings -- $'- name: Run checks\n        run: AURAL_CHECK_SCOPE=swift ./Scripts/check.sh' <<< "$checks_job" \
    || ! rg -q --fixed-strings 'runs-on: macos-26' <<< "$release_job" \
    || ! rg -q --fixed-strings 'xcode-select -s /Applications/Xcode_26.6.app' <<< "$release_job" \
    || ! rg -q --fixed-strings "grep -q 'Apple Swift version 6.3.3'" <<< "$release_job" \
    || ! rg -U -q "$checkout_without_credentials" <<< "$release_job" \
    || ! rg -q --fixed-strings "$playback_cache_key" <<< "$release_job" \
    || ! rg -q --fixed-strings "$release_cache_key" <<< "$release_job" \
    || ! rg -U -q --fixed-strings -- $'- name: Compile release Aural with AURAL_DISTRIBUTION\n        run: ./Scripts/compile-release-aural.sh' <<< "$release_job" \
    || ! rg -q --fixed-strings 'if: always()' <<< "$gate_job" \
    || ! rg -q --fixed-strings 'needs: [rust, checks, release]' <<< "$gate_job" \
    || ! rg -U -q --fixed-strings -- $'test "$RUST_RESULT" = success\n          test "$CHECKS_RESULT" = success\n          test "$RELEASE_RESULT" = success' <<< "$gate_job"; then
    print -u2 "CI must cache exact inputs and aggregate parallel Rust, Swift, and release lanes"
    exit 1
fi

plutil -lint "$project_root/Packaging/Info.plist"

if [[ "$check_scope" == swift ]]; then
    print "Aural Swift checks passed ($build_configuration): format, ABI, native app, domain, concrete boundary, architecture, and packaging checks are green"
else
    print "Aural checks passed ($build_configuration): format, Rust, ABI, native app, domain, concrete boundary, architecture, and packaging checks are green"
fi
