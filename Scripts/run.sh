#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
exec "$project_root/script/build_and_run.sh" "$@"
