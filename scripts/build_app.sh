#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
IDENTITY="${LOCALSCRIBE_SIGN_IDENTITY:--}"
bash scripts/build_icon.sh
if [ ! -x Assets/tools/ffmpeg ] || [ ! -x Assets/tools/ffprobe ]; then bash scripts/build_ffmpeg.sh; fi
# Reject a stale tool compiled for the build machine's newer OS.
for tool in Assets/tools/ffmpeg Assets/tools/ffprobe; do
    xcrun vtool -show-build "$tool" | awk '$1 == "minos" { found=1; if ($2 != "26.0") exit 1 } END { if (!found) exit 1 }' || { echo "Rebuild bundled audio tools: bash scripts/build_ffmpeg.sh" >&2; exit 1; }
done
swift package resolve --force-resolved-versions
swift build -c release -j 4 --force-resolved-versions
BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/LocalScribe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/tools" "$APP/Contents/Resources/Licenses"
SERVICE="$APP/Contents/XPCServices/LocalScribeModelService.xpc"
mkdir -p "$SERVICE/Contents/MacOS" "$SERVICE/Contents/Resources"
cp "$BIN/LocalScribeModelService" "$SERVICE/Contents/MacOS/"
cp Resources/ModelService-Info.plist "$SERVICE/Contents/Info.plist"
cp Resources/models.lock.json "$SERVICE/Contents/Resources/"
cp "$BIN/LocalScribe" "$APP/Contents/MacOS/"
cp "$BIN/LocalScribeWorker" "$APP/Contents/Helpers/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/models.lock.json "$APP/Contents/Resources/"
cp Assets/tools/ffmpeg Assets/tools/ffprobe "$APP/Contents/Resources/tools/"
# SwiftPM resource bundles (including MLX Metal libraries) must travel with the executables.
for bundle in "$BIN"/*.bundle; do
    [ -d "$bundle" ] || continue
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
for library in "$BIN"/*.metallib; do
    [ -f "$library" ] || continue
    cp "$library" "$APP/Contents/Resources/"
done
# The CLI helper is outside Contents/MacOS. MLX's C++ loader first searches next
# to its own executable; Bundle.main is not the GUI bundle in this process.
METAL="$BIN/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [ ! -f "$METAL" ]; then METAL="$BIN/mlx-swift_Cmlx.bundle/default.metallib"; fi
test -f "$METAL"
cp "$METAL" "$APP/Contents/Helpers/mlx.metallib"
python3 scripts/licenses.py "$APP/Contents/Resources/Licenses"
cp build/ffmpeg-sha256.txt "$APP/Contents/Resources/Licenses/"
codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/Worker.entitlements "$APP/Contents/Helpers/LocalScribeWorker"
codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/Worker.entitlements "$APP/Contents/Resources/tools/ffmpeg"
codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/Worker.entitlements "$APP/Contents/Resources/tools/ffprobe"
codesign --force --sign "$IDENTITY" "$APP/Contents/Helpers/mlx.metallib"
codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/ModelService.entitlements "$SERVICE"
codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/App.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
# Updating files inside an existing bundle does not update its directory date.
# Finder and Launch Services use that date to detect changed app metadata/icons.
touch "$APP"
mkdir -p build
cp Package.resolved build/Package.resolved
{ xcodebuild -version; swift --version; sw_vers; shasum -a 256 Package.resolved Resources/models.lock.json; } > build/build-environment.txt
echo "$APP"
