#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/TestResults/LocalScribeProbe.app"
mkdir -p TestResults
ditto dist/LocalScribe.app "$APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.localscribe.mac.probe' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName LocalScribeProbe' "$APP/Contents/Info.plist"
if [ ! -d "$APP/Contents/Resources/ProbeModels" ]; then cp -cR Assets/models "$APP/Contents/Resources/ProbeModels"; fi
cp Assets/probe/mixed.wav "$APP/Contents/Resources/probe.wav"
codesign --force --sign - --options runtime --entitlements Resources/App.entitlements "$APP"
codesign --verify --deep --strict "$APP"
open -n "$APP" --args --self-check --self-check-full
