#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
COPYFILE_DISABLE=1 tar --exclude=.git --exclude=build --exclude=.build --exclude=.swiftpm --exclude=Assets --exclude=TestResults --exclude=dist \
 --exclude=Vendor \
 --exclude='*.log' --exclude='__pycache__' --exclude='.DS_Store' -czf dist/LocalScribe-source.tar.gz .
