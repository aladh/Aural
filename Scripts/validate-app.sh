#!/bin/zsh
set -euo pipefail

validation_mode="${1:---local}"
app_path="${2:-${0:A:h:h}/Aural.app}"

case "$validation_mode" in
    --local|local) require_distribution=false ;;
    --distribution|distribution) require_distribution=true ;;
    *)
        print -u2 "usage: $0 [--local|--distribution] [path-to-app]"
        exit 2
        ;;
esac

if [[ ! -d "$app_path" ]]; then
    print -u2 "Missing app bundle: $app_path"
    exit 1
fi

info_plist="$app_path/Contents/Info.plist"
app_binary="$app_path/Contents/MacOS/Aural"
third_party_notices="$app_path/Contents/Resources/ThirdPartyNotices.md"

plutil -lint "$info_plist"
if [[ ! -f "$app_path/Contents/PkgInfo" ]]; then
    print -u2 "Missing app bundle PkgInfo: $app_path/Contents/PkgInfo"
    exit 1
fi
for required_key in \
    CFBundleIdentifier \
    CFBundleExecutable \
    CFBundleShortVersionString \
    CFBundleVersion \
    LSMinimumSystemVersion; do
    /usr/libexec/PlistBuddy -c "Print :$required_key" "$info_plist" >/dev/null
done

if [[ ! -x "$app_binary" ]]; then
    print -u2 "Missing executable app binary: $app_binary"
    exit 1
fi
if [[ ! -s "$third_party_notices" ]]; then
    print -u2 "Missing third-party license notices: $third_party_notices"
    exit 1
fi

codesign --verify --strict --verbose=2 "$app_path"
signing_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
if ! grep -Eq 'flags=0x[0-9a-fA-F]+\([^)]*runtime' <<< "$signing_details"; then
    print -u2 "The app is signed without hardened runtime"
    exit 1
fi

if [[ "$require_distribution" == true ]]; then
    if [[ "$signing_details" != *"Authority=Developer ID Application:"* ]]; then
        print -u2 "Distribution validation requires a Developer ID Application signature"
        exit 1
    fi
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=2 "$app_path"
fi

print "Validated $app_path ($validation_mode)"
