#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?Usage: scripts/bundle-sing-box.sh APP_PATH}"
version=1.14.3
case "$(uname -m)" in
  arm64) arch=arm64; checksum=0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5 ;;
  x86_64) arch=amd64; checksum=6d002b74d03b478547349cc10af89e007868596e5aa931816d45da9f544715a9 ;;
  *) echo 'Unsupported macOS architecture' >&2; exit 1 ;;
esac
name="sing-box-$version-darwin-$arch"
cache="$PWD/.build/downloads"
archive="$cache/$name.tar.gz"
mkdir -p "$cache"
staging="$(mktemp -d "$cache/extract.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
if [[ ! -f "$archive" ]]; then
  echo "Downloading bundled sing-box $version ($arch)…"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 300 --retry 2 \
    "https://github.com/SagerNet/sing-box/releases/download/v$version/$name.tar.gz" \
    -o "$staging/download.tar.gz"
  archive="$staging/download.tar.gz"
fi
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual" != "$checksum" ]]; then
  echo "sing-box archive checksum mismatch; refusing to package $archive" >&2
  exit 1
fi
if [[ "$archive" = "$staging/download.tar.gz" ]]; then
  mv "$archive" "$cache/$name.tar.gz"
  archive="$cache/$name.tar.gz"
fi
tar -xzf "$archive" -C "$staging" "$name/sing-box" "$name/LICENSE"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
cp "$staging/$name/sing-box" "$app/Contents/MacOS/sing-box"
chmod 755 "$app/Contents/MacOS/sing-box"
cp "$staging/$name/LICENSE" "$app/Contents/Resources/Licenses/sing-box.txt"
cp LICENSE "$app/Contents/Resources/Licenses/GPL-3.0.txt"
cp Resources/ThirdPartyNotices.txt "$app/Contents/Resources/ThirdPartyNotices.txt"
echo "Bundled verified sing-box $version ($arch)"
