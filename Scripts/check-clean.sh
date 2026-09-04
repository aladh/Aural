#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"

swift package --package-path "$project_root" clean
"$project_root/Backend/spotty-playback/build.sh"
"$project_root/Scripts/check.sh"
SPOTTY_BUILD_CONFIGURATION=release "$project_root/Scripts/check.sh"

print "Spotty clean Debug and Release quality gates passed"
