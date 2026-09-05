#!/bin/zsh
set -euo pipefail

backend_root="${0:A:h}"
project_root="${backend_root:h:h}"
manifest_path="$backend_root/artifact-manifest.json"
archive_path=""
artifact_url=""

usage() {
    print -u2 "usage: $0 --archive ZIP [--url HTTPS] [--manifest PATH]"
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        --archive)
            (( $# >= 2 )) || usage
            archive_path="$2"
            shift 2
            ;;
        --url)
            (( $# >= 2 )) || usage
            artifact_url="$2"
            shift 2
            ;;
        --manifest)
            (( $# >= 2 )) || usage
            manifest_path="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n "$archive_path" ]] || usage
archive_path="${archive_path:A}"
manifest_path="${manifest_path:A}"
[[ -f "$archive_path" ]] || { print -u2 "Archive is missing: $archive_path"; exit 1; }
[[ -f "$manifest_path" ]] || { print -u2 "Manifest is missing: $manifest_path"; exit 1; }
plutil -convert xml1 -o /dev/null "$manifest_path" >/dev/null 2>&1 || { print -u2 "Manifest is invalid: $manifest_path"; exit 1; }

fail() {
    print -u2 "update-artifact-manifest.sh: $*"
    exit 1
}
plist_value() {
    local key="$1"
    local plist="$2"
    plutil -extract "$key" raw -o - "$plist" 2>/dev/null
}
require_value() {
    local key="$1"
    local plist="$2"
    plist_value "$key" "$plist" || fail "missing $key in $plist"
}
require_https_url() {
    local url="$1"
    local url_pattern="^https://github[.]com/aladh/Spotty/releases/download/spotty-playback-core-[0-9a-f]{64}/SpottyPlaybackCore[.]xcframework[.]zip$"
    [[ "$url" =~ "$url_pattern" ]] || \
        fail "artifact URL must be the canonical immutable SpottyPlaybackCore GitHub release asset"
}

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/spotty-playback-pin.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
if ! unzip -q "$archive_path" -d "$temporary_root"; then
    fail "could not extract archive: $archive_path"
fi
xcframework_candidates=("$temporary_root"/**/*.xcframework(N/))
if (( ${#xcframework_candidates[@]} != 1 )); then
    fail "archive must contain exactly one XCFramework"
fi
xcframework_path="$xcframework_candidates[1]"
provenance_path="$xcframework_path/spotty_playback_provenance.json"
[[ -f "$provenance_path" ]] || fail "downloaded artifact has no embedded provenance"
plutil -convert xml1 -o /dev/null "$provenance_path" >/dev/null 2>&1 || fail "downloaded artifact provenance is invalid"

source_digest="$("$backend_root/source-input-digest.sh")"
provenance_digest="$(require_value source.engineInputDigest "$provenance_path")"
[[ "$provenance_digest" == "$source_digest" ]] || \
    fail "downloaded artifact source input digest does not match this checkout"
source_dirty="$(require_value source.sourceDirty "$provenance_path")"
if [[ "$source_dirty" == true ]]; then
    fail "refusing to pin an artifact built from a dirty source tree"
fi

canonical_include="$project_root/Sources/SpottyPlaybackCore/include"
header_digest="$({
    for header_name in spotty_playback.h spotty_playback_generated.h spotty_playback_annotations.h module.modulemap; do
        print -r -- "$header_name $(shasum -a 256 "$canonical_include/$header_name" | awk '{print $1}')"
    done
} | shasum -a 256 | awk '{print $1}')"
require_value source.canonicalHeadersSHA256 "$provenance_path" | \
    grep -Fx "$header_digest" >/dev/null || fail "downloaded artifact canonical header digest differs"
library_name="$(require_value AvailableLibraries.0.LibraryPath "$xcframework_path/Info.plist")"

if [[ -z "$artifact_url" ]]; then
    artifact_url="$(require_value artifact.url "$manifest_path")"
fi
require_https_url "$artifact_url"
[[ "$artifact_url" == *"$provenance_digest"* ]] || \
    fail "artifact URL must be keyed by the embedded engine input digest"

archive_digest="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
temporary_manifest="$temporary_root/artifact-manifest.json"
cp "$manifest_path" "$temporary_manifest"
plutil -replace artifact.url -string "$artifact_url" "$temporary_manifest"
plutil -replace artifact.archive -string "${artifact_url##*/}" "$temporary_manifest"
plutil -replace artifact.checksum -string "$archive_digest" "$temporary_manifest"
plutil -replace source.engineInputDigest -string "$provenance_digest" "$temporary_manifest"
plutil -replace source.sourceRevision -string "$(require_value source.sourceRevision "$provenance_path")" "$temporary_manifest"
plutil -replace source.sourceDirty -bool "$source_dirty" "$temporary_manifest"
plutil -replace source.rustToolchain -string "$(require_value source.rustToolchain "$provenance_path")" "$temporary_manifest"
plutil -replace source.target -string "$(require_value target "$provenance_path")" "$temporary_manifest"
plutil -replace source.librespotRevision -string "$(require_value source.librespotRevision "$provenance_path")" "$temporary_manifest"
plutil -replace source.cargoLockSHA256 -string "$(require_value source.cargoLockSHA256 "$provenance_path")" "$temporary_manifest"
plutil -replace source.canonicalHeadersSHA256 -string "$(require_value source.canonicalHeadersSHA256 "$provenance_path")" "$temporary_manifest"
plutil -replace module.library -string "$library_name" "$temporary_manifest"

"$backend_root/validate-xcframework.sh" "$xcframework_path" \
    --archive "$archive_path" \
    --manifest "$temporary_manifest" \
    --for-publish >/dev/null

if [[ "$manifest_path" == "$backend_root/artifact-manifest.json" ]]; then
    package_path="$project_root/Package.swift"
    temporary_package="$temporary_root/Package.swift"
    cp "$package_path" "$temporary_package"
    PIN_URL="$artifact_url" PIN_CHECKSUM="$archive_digest" \
        perl -0pi -e '
            my $url_count = s{(private\s+let\s+generatedPlaybackArtifactURL\s*=\s*)("[^"]*")}{$1 . q{"} . $ENV{PIN_URL} . q{"}}eg;
            my $checksum_count = s{(private\s+let\s+generatedPlaybackArtifactChecksum\s*=\s*)("[^"]*")}{$1 . q{"} . $ENV{PIN_CHECKSUM} . q{"}}eg;
            die "generated playback URL declaration count is $url_count\n" unless $url_count == 1;
            die "generated playback checksum declaration count is $checksum_count\n" unless $checksum_count == 1;
        ' \
        "$temporary_package"
    grep -F "\"$artifact_url\"" "$temporary_package" >/dev/null || \
        fail "could not update generated Package.swift artifact URL"
    grep -F "\"$archive_digest\"" "$temporary_package" >/dev/null || \
        fail "could not update generated Package.swift artifact checksum"
    mv "$temporary_package" "$package_path"
fi
plutil -convert json -r "$temporary_manifest"
mv "$temporary_manifest" "$manifest_path"

print "Pinned $manifest_path"
print "Engine input digest: $provenance_digest"
print "Archive checksum: $archive_digest"
print "Source revision: $(require_value source.sourceRevision "$provenance_path")"
