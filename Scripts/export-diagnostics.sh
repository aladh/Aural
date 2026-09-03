#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
lookback="${1:-15m}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_dir="$project_root/diagnostics"
output="$output_dir/aural-$timestamp.log"

mkdir -p "$output_dir"
{
    print "Spotty local diagnostics"
    print "Captured: $timestamp"
    print "Lookback: $lookback"
    print "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    print "Hardware: $(uname -m)"
    print "Commit: $(git -C "$project_root" rev-parse --short HEAD 2>/dev/null || print unknown)"
    print
    /usr/bin/log show --info --style compact --last "$lookback" \
        --predicate 'process == "Aural" && subsystem == "dev.aural.app"'
} > "$output"

print "$output"
