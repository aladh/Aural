#!/bin/zsh
set -euo pipefail

mode="${1:-run}"
app_name="Aural"
bundle_id="dev.aural.app"
root_dir="${0:A:h:h}"
app_bundle="$root_dir/Aural.app"
app_binary="$app_bundle/Contents/MacOS/Aural"
staged_app_bundle="$root_dir/.build/aural-launch/Aural.app"

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

if [[ -z "${AURAL_SIGNING_IDENTITY:-}" && -z "${AURAL_DEVELOPMENT_SIGNING_IDENTITY:-}" ]]; then
    apple_development_identities="$(
        security find-identity -p codesigning -v 2>/dev/null \
            | sed -nE 's/^[[:space:]]*[0-9]+\) [[:xdigit:]]+ "(Apple Development:[^"]+)"$/\1/p'
    )"
    identity_count="$(print -r -- "$apple_development_identities" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$identity_count" == "1" ]]; then
        export AURAL_DEVELOPMENT_SIGNING_IDENTITY="$(print -r -- "$apple_development_identities" | head -n 1)"
    elif [[ "$identity_count" == "0" ]]; then
        print -u2 "Authenticated Aural development requires an Apple Development signing identity."
        print -u2 "Create one in Xcode Accounts, or package without launching via ./Scripts/package-app.sh."
        exit 1
    else
        print -u2 "Multiple Apple Development identities are available."
        print -u2 "Set AURAL_DEVELOPMENT_SIGNING_IDENTITY to the exact identity to use."
        exit 1
    fi
fi

AURAL_APP_PATH="$staged_app_bundle" "$root_dir/Scripts/package-app.sh" "$package_mode"
"$root_dir/Scripts/validate-app.sh" --keychain-stable "$staged_app_bundle"
pkill -x "$app_name" >/dev/null 2>&1 || true
for _ in {1..20}; do
    pgrep -x "$app_name" >/dev/null || break
    sleep 0.1
done
if pgrep -x "$app_name" >/dev/null; then
    print -u2 "Aural did not terminate; leaving the existing app bundle in place"
    exit 1
fi
rm -rf "$app_bundle"
mv "$staged_app_bundle" "$app_bundle"
rmdir "$root_dir/.build/aural-launch" 2>/dev/null || true

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
