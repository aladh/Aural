#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="${SPOTTY_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/Packaging/Info.plist")}"
archive_path="$project_root/dist/Spotty-$version.zip"
notary_profile="${SPOTTY_NOTARY_PROFILE:-}"

if [[ -z "${SPOTTY_SIGNING_IDENTITY:-}" ]]; then
    print -u2 "Set SPOTTY_SIGNING_IDENTITY to a Developer ID Application identity"
    exit 2
fi
if [[ -z "$notary_profile" ]]; then
    print -u2 "Set SPOTTY_NOTARY_PROFILE to a notarytool keychain profile"
    exit 2
fi

"$project_root/Scripts/archive-app.sh"
xcrun notarytool submit "$archive_path" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$project_root/Spotty.app"
"$project_root/Scripts/validate-app.sh" --distribution "$project_root/Spotty.app"

# Restapling changes the app bundle, so produce the final distributable archive afterward.
rm -f "$archive_path"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$project_root/Spotty.app" "$archive_path"

print "Notarized and archived $archive_path"
