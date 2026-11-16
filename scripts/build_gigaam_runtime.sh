#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="$PWD/Assets/gigaam-runtime"
RELEASE="sherpa-onnx-v1.13.0-osx-arm64-static-no-tts-lib"
ARCHIVE="$RUNTIME/$RELEASE.tar.bz2"
OUTPUT="$RUNTIME/libLocalScribeGigaAMRuntime.a"
ARCHIVE_SHA="faba2fdf65033b1136589d284ddcd559ef6b62aade720ccbcab90a3eede4d2d0"

matches_sha() {
    [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" = "$ARCHIVE_SHA" ]
}

mkdir -p "$RUNTIME"
WORK="$(mktemp -d "$RUNTIME/.extract.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
if ! matches_sha "$ARCHIVE"; then
    curl --fail --silent --show-error --location --connect-timeout 15 --max-time 600 --retry 2 \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.0/$RELEASE.tar.bz2" \
        -o "$WORK/runtime.tar.bz2"
    matches_sha "$WORK/runtime.tar.bz2" || { echo "Invalid GigaAM runtime archive SHA-256" >&2; exit 1; }
    mv "$WORK/runtime.tar.bz2" "$ARCHIVE"
fi
tar -xjf "$ARCHIVE" -C "$WORK"
ZERO_AR_DATE=1 xcrun libtool -static -o "$WORK/runtime.a" "$WORK/$RELEASE/lib/"*.a
if ! cmp -s "$WORK/runtime.a" "$OUTPUT"; then
    mv "$WORK/runtime.a" "$OUTPUT"
fi
printf '%s\n' "$OUTPUT"
