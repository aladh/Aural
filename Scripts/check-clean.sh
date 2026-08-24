#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"

swift package --package-path "$project_root" clean
"$project_root/Backend/aural-playback/build.sh"
"$project_root/Scripts/check.sh"
AURAL_BUILD_CONFIGURATION=release "$project_root/Scripts/check.sh"

print "Aural clean Debug and Release quality gates passed"
