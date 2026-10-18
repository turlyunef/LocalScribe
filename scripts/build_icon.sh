#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="Resources/AppIcon.png"
WIDTH="$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth:/ { print $2 }')"
HEIGHT="$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight:/ { print $2 }')"
if [ "$WIDTH" != "$HEIGHT" ] || [ "$WIDTH" -lt 1024 ]; then
    echo "AppIcon.png must be square and at least 1024 × 1024 pixels." >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/localscribe-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"
cp "$WORK/AppIcon.icns" Resources/AppIcon.icns
