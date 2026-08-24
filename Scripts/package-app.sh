#!/bin/zsh
set -euo pipefail

package_mode="${1:---debug}"
case "$package_mode" in
    --debug|debug) build_configuration="debug" ;;
    --release|release) build_configuration="release" ;;
    *)
        print -u2 "usage: $0 [--debug|--release]"
        exit 2
        ;;
esac

project_root="${0:A:h:h}"
app_path="$project_root/Aural.app"
executable="$project_root/.build/$build_configuration/Aural"
icon="$project_root/Assets/Aural.icns"
info_template="$project_root/Packaging/Info.plist"
third_party_notices="$project_root/THIRD_PARTY_NOTICES.md"
# Version bump procedure: edit CFBundleShortVersionString and CFBundleVersion in
# Packaging/Info.plist (the source of truth); AURAL_VERSION/AURAL_BUILD_NUMBER are
# one-off overrides only and must not be relied on for releases.
app_version="${AURAL_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_template")}"
app_build_number="${AURAL_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_template")}"
distribution_identity="${AURAL_SIGNING_IDENTITY:-}"

export AURAL_BUILD_CONFIGURATION="$build_configuration"
"$project_root/Scripts/check.sh"

for required_file in "$executable" "$icon" "$info_template" "$third_party_notices"; do
    if [[ ! -f "$required_file" ]]; then
        print -u2 "Missing packaging input: $required_file"
        exit 1
    fi
done

if [[ ! "$app_version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]]; then
    print -u2 "AURAL_VERSION must be a numeric dotted version"
    exit 2
fi
if [[ ! "$app_build_number" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "AURAL_BUILD_NUMBER must be a positive integer"
    exit 2
fi

# This is a generated bundle at one exact path; recreate it so stale binaries and resources
# cannot survive a packaging run.
if [[ "$app_path" != "$project_root/Aural.app" ]]; then
    print -u2 "Refusing to replace an unexpected app path"
    exit 1
fi
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
printf 'APPL????' > "$app_path/Contents/PkgInfo"
cp "$executable" "$app_path/Contents/MacOS/Aural"
cp "$icon" "$app_path/Contents/Resources/Aural.icns"
cp "$third_party_notices" "$app_path/Contents/Resources/ThirdPartyNotices.md"
cp "$info_template" "$app_path/Contents/Info.plist"

plutil -replace CFBundleShortVersionString -string "$app_version" "$app_path/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$app_build_number" "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Info.plist"

sign_with_local_identity() {
    local signing_dir="$project_root/.build/aural-signing"
    local signing_keychain="$signing_dir/Aural.keychain-db"
    local password_file="$signing_dir/keychain-password"
    local identity_name="Aural Local Development"

    mkdir -p "$signing_dir"
    chmod 700 "$signing_dir"

    if [[ ! -f "$password_file" ]]; then
        openssl rand -hex -out "$password_file" 32
        chmod 600 "$password_file"
    fi
    local signing_password="$(tr -d '\n' < "$password_file")"

    if [[ ! -f "$signing_dir/certificate.pem" || ! -f "$signing_dir/private-key.pem" ]]; then
        openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
            -subj '/CN=Aural Local Development/O=Aural' \
            -addext 'keyUsage=critical,digitalSignature' \
            -addext 'extendedKeyUsage=codeSigning' \
            -keyout "$signing_dir/private-key.pem" \
            -out "$signing_dir/certificate.pem"
        chmod 600 "$signing_dir/private-key.pem"
    fi

    if [[ ! -f "$signing_dir/identity.p12" ]]; then
        local pkcs12_help
        local pkcs12_compatibility=()
        pkcs12_help="$(openssl pkcs12 -help 2>&1 || true)"
        if [[ "$pkcs12_help" == *"-legacy"* ]]; then
            pkcs12_compatibility=(-legacy)
        fi
        openssl pkcs12 -export "${pkcs12_compatibility[@]}" \
            -out "$signing_dir/identity.p12" \
            -inkey "$signing_dir/private-key.pem" \
            -in "$signing_dir/certificate.pem" \
            -passout "pass:$signing_password"
        chmod 600 "$signing_dir/identity.p12"
    fi

    if [[ ! -f "$signing_keychain" ]]; then
        security create-keychain -p "$signing_password" "$signing_keychain"
        security set-keychain-settings -lut 21600 "$signing_keychain"
    fi
    security unlock-keychain -p "$signing_password" "$signing_keychain"

    if ! security find-certificate -c "$identity_name" "$signing_keychain" >/dev/null 2>&1; then
        security import "$signing_dir/identity.p12" \
            -k "$signing_keychain" \
            -P "$signing_password" \
            -T /usr/bin/codesign
        security set-key-partition-list \
            -S apple-tool:,apple:,codesign: \
            -s -k "$signing_password" \
            "$signing_keychain"
    fi

    codesign --force --options runtime --timestamp=none \
        --keychain "$signing_keychain" \
        --sign "$identity_name" \
        "$app_path"
}

if [[ "$distribution_identity" == "-" ]]; then
    codesign --force --options runtime --timestamp=none \
        --sign - \
        "$app_path"
    signing_kind="ad hoc"
elif [[ -n "$distribution_identity" ]]; then
    codesign --force --options runtime --timestamp \
        --sign "$distribution_identity" \
        "$app_path"
    signing_kind="Developer ID"
else
    sign_with_local_identity
    signing_kind="local development"
fi

"$project_root/Scripts/validate-app.sh" --local "$app_path"

if [[ "$build_configuration" == "release" && -z "$distribution_identity" ]]; then
    print -u2 "Release bundle uses the local identity; set AURAL_SIGNING_IDENTITY to create a distributable Developer ID build."
elif [[ "$build_configuration" == "release" && "$distribution_identity" == "-" ]]; then
    print -u2 "Release bundle uses an ad-hoc signature; set AURAL_SIGNING_IDENTITY to a Developer ID identity for distribution."
fi

print "Packaged $app_path ($build_configuration, $signing_kind signature, version $app_version ($app_build_number))"
