#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Usage: scripts/build-app.sh [debug|release]' >&2; exit 2 ;; esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
cargo_profile="$configuration"
if [[ "$configuration" = debug ]]; then cargo_profile=dev; fi
cargo build --manifest-path core/Cargo.toml --locked --profile "$cargo_profile"
swift build -c "$configuration" --disable-sandbox
bin_path="$(swift build -c "$configuration" --show-bin-path --disable-sandbox)"
app="build/Wontun.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/Wontun" "$app/Contents/MacOS/Wontun"
# Cargo calls its debug profile `dev`, while artifacts are written to target/debug.
cp "core/target/$configuration/wontun-core" "$app/Contents/MacOS/wontun-core"
cp Resources/Info.plist "$app/Contents/Info.plist"
bash scripts/build-icon.sh
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
./scripts/bundle-sing-box.sh "$app"
codesign --force --sign - "$app/Contents/MacOS/sing-box"
codesign --force --deep --sign - "$app"
echo "Built $PWD/$app"
