#!/bin/zsh
set -euo pipefail

mode="${1:-run}"
app_name="Aural"
bundle_id="dev.aural.app"
root_dir="${0:A:h:h}"
app_bundle="$root_dir/Aural.app"
app_binary="$app_bundle/Contents/MacOS/Aural"

case "$mode" in
    --release|release|--verify-release|verify-release)
        package_mode="--release"
        ;;
    *)
        package_mode="--debug"
        ;;
esac

case "$mode" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--release|release|--verify-release|verify-release) ;;
    *)
        print -u2 "usage: $0 [run|--debug|--logs|--telemetry|--verify|--release|--verify-release]"
        exit 2
        ;;
esac

pkill -x "$app_name" >/dev/null 2>&1 || true
"$root_dir/Scripts/package-app.sh" "$package_mode"

open_app() {
    /usr/bin/open -n "$app_bundle"
}

case "$mode" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$app_binary"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$app_name\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\""
        ;;
    --verify|verify)
        open_app
        for _ in {1..20}; do
            pgrep -x "$app_name" >/dev/null && exit 0
            sleep 0.1
        done
        print -u2 "Aural did not launch"
        exit 1
        ;;
    --release|release)
        open_app
        ;;
    --verify-release|verify-release)
        open_app
        for _ in {1..20}; do
            pgrep -x "$app_name" >/dev/null && exit 0
            sleep 0.1
        done
        print -u2 "Aural release build did not launch"
        exit 1
        ;;
    *)
        print -u2 "usage: $0 [run|--debug|--logs|--telemetry|--verify|--release|--verify-release]"
        exit 2
        ;;
esac
