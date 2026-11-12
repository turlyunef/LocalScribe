#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --static ]; }; then
    echo "Usage: bash scripts/verify.sh [--static]" >&2
    exit 64
fi
plutil -lint Resources/Info.plist Resources/ModelService-Info.plist
python3 -m unittest discover -s scripts/tests -v
if [ "$#" -eq 0 ]; then
    xcrun metal --version
    swift test -c release -j 4 --force-resolved-versions
fi
