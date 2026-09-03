#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="${SPOTTY_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_root/Packaging/Info.plist")}"
archive_dir="$project_root/dist"
archive_path="$archive_dir/Spotty-$version.zip"

"$project_root/Scripts/package-app.sh" --release
mkdir -p "$archive_dir"

if [[ -e "$archive_path" ]]; then
    rm -f "$archive_path"
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$project_root/Spotty.app" "$archive_path"

print "Archived $archive_path"
