#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
COPYFILE_DISABLE=1 tar --exclude=.git --exclude=build --exclude=.build --exclude=.swiftpm --exclude=Assets --exclude=TestResults --exclude=dist \
 --exclude='Vendor/argmax-oss-swift' --exclude='Vendor/mlx-swift-lm' --exclude='Vendor/ffmpeg-8.0.1' \
 --exclude='*.log' --exclude='__pycache__' --exclude='.DS_Store' -czf dist/LocalScribe-source.tar.gz .
