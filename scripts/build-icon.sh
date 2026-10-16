#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
iconset="$staging/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
# Store PNG representations directly in the standard ICNS container.
python3 - "$iconset" Resources/AppIcon.icns <<'PY'
from pathlib import Path
import struct
import sys

iconset = Path(sys.argv[1])
representations = {
    "icp4": "16x16", "ic11": "16x16@2x",
    "icp5": "32x32", "ic12": "32x32@2x",
    "ic07": "128x128", "ic13": "128x128@2x",
    "ic08": "256x256", "ic14": "256x256@2x",
    "ic09": "512x512", "ic10": "512x512@2x",
}
chunks = []
for kind, name in representations.items():
    data = (iconset / f"icon_{name}.png").read_bytes()
    chunks.append(kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data)
payload = b"".join(chunks)
Path(sys.argv[2]).write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
PY
