#!/bin/zsh
set -euo pipefail

backend_root="${0:A:h}"
output_root="${backend_root:h}/lib"
target="aarch64-apple-darwin"

cargo_bin="${AURAL_CARGO:-$(command -v cargo || true)}"
workspace_cargo="/private/tmp/aural-rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo"
if [[ -z "$cargo_bin" && -x "$workspace_cargo" ]]; then
    cargo_bin="$workspace_cargo"
    export CARGO_HOME="${CARGO_HOME:-/private/tmp/aural-cargo}"
    export RUSTUP_HOME="${RUSTUP_HOME:-/private/tmp/aural-rustup}"
    export PATH="${cargo_bin:h}:$PATH"
fi
if [[ -z "$cargo_bin" || ! -x "$cargo_bin" ]]; then
    print -u2 "Rust cargo was not found. Install Rust or set AURAL_CARGO."
    exit 1
fi

mkdir -p "$output_root"
export RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=apple-m1 --cfg aes_armv8"

cd "$backend_root"
"$cargo_bin" build --release --target "$target"
cp "target/$target/release/libaural_playback.a" "$output_root/libaural_playback.a"

echo "Built $output_root/libaural_playback.a"
