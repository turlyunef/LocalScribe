#!/bin/bash
set -euo pipefail

APP="$1"
BIN="$2"
SYMBOLS="$3"
mkdir -p "$SYMBOLS"
STAGING="$(mktemp -d "$SYMBOLS/.staging.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT

uuid() {
    xcrun dwarfdump --uuid "$1" | awk '$1 == "UUID:" && $3 == "(arm64)" {print toupper($2)}'
}

archive() {
    local executable="$1" name id source destination
    name="$(basename "$executable")"
    id="$(uuid "$executable")"
    if [[ ! "$id" =~ ^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$ ]]; then
        echo "Expected one arm64 UUID for $name." >&2
        return 1
    fi
    source="$BIN/$name.dSYM"
    destination="$SYMBOLS/$id"
    if [ -d "$destination" ]; then
        test "$(uuid "$destination/$name.dSYM")" = "$id"
        return
    fi
    if [ ! -d "$source" ] || [ "$(uuid "$source")" != "$id" ]; then
        echo "Missing matching dSYM for $name ($id)." >&2
        return 1
    fi
    mkdir "$STAGING/$id"
    ditto "$source" "$STAGING/$id/$name.dSYM"
    mv "$STAGING/$id" "$destination"
}

archive "$APP/Contents/MacOS/LocalScribe"
archive "$APP/Contents/Helpers/LocalScribeWorker"
archive "$APP/Contents/XPCServices/LocalScribeModelService.xpc/Contents/MacOS/LocalScribeModelService"
