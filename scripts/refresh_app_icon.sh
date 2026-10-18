#!/bin/bash
set -euo pipefail

APP="${1:-/Applications/LocalScribe.app}"
if [ ! -d "$APP" ] || [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" != "local.localscribe.mac" ]; then
    echo "Expected a LocalScribe.app bundle: $APP" >&2
    exit 1
fi
ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")"
test -s "$APP/Contents/Resources/$ICON"
codesign --verify --deep --strict "$APP"

# Refresh only this app, preserving its signature and the system's other caches.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Updated LocalScribe icon registration: $APP"
