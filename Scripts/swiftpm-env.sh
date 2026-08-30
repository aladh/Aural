# Shared SDKROOT and repo-local Swift module cache. Sourced by check.sh and
# compile-release-aural.sh. Not a check runner and not an entry point.
if [[ -z "${project_root:-}" ]]; then
    print -u2 "project_root must be set before sourcing Scripts/swiftpm-env.sh"
    return 1 2>/dev/null || exit 1
fi

sdk_path="$(xcrun --show-sdk-path)"
compatible_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ -d "$compatible_sdk" ]]; then
    sdk_path="$compatible_sdk"
fi

mkdir -p "$project_root/.build/module-cache"
export SDKROOT="$sdk_path"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"

# Aural-owned `swift build` invocations treat compiler warnings as errors.
# Command-line -Xswiftc only; do not put this in Package.swift unsafeFlags.
aural_swiftc_warnings_as_errors=(-Xswiftc -warnings-as-errors)
