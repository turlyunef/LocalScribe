#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION=8.0.1
ARCHIVE_SHA256=05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
mkdir -p Vendor Assets/tools build
ARCHIVE="Vendor/ffmpeg-$VERSION.tar.xz"
# Only remove the private directory created by this invocation. In particular,
# never reuse or delete a user's existing Vendor/ffmpeg-$VERSION tree.
STAGING="$(mktemp -d "$ROOT/build/ffmpeg-$VERSION.XXXXXX")"
DOWNLOAD=
trap 'rm -rf -- "$STAGING"; if [ -n "$DOWNLOAD" ]; then rm -f -- "$DOWNLOAD"; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Verify and extract the same private snapshot, even if the cached archive changes.
if [ -f "$ARCHIVE" ]; then
    cp "$ARCHIVE" "$STAGING/source.tar.xz"
else
    curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$STAGING/source.tar.xz"
fi
echo "$ARCHIVE_SHA256  $STAGING/source.tar.xz" | shasum -a 256 -c -
if [ ! -f "$ARCHIVE" ]; then
    DOWNLOAD="$(mktemp "$ARCHIVE.XXXXXX")"
    cp "$STAGING/source.tar.xz" "$DOWNLOAD"
    mv "$DOWNLOAD" "$ARCHIVE"
    DOWNLOAD=
fi
tar -xf "$STAGING/source.tar.xz" -C "$STAGING"
cd "$STAGING/ffmpeg-$VERSION"
./configure --prefix="$ROOT/Assets/ffmpeg" --arch=arm64 --target-os=darwin \
 --extra-cflags=-mmacosx-version-min=26.0 --extra-ldflags=-mmacosx-version-min=26.0 \
 --cc=clang --disable-autodetect --disable-shared --enable-static --disable-gpl --disable-nonfree \
 --disable-doc --disable-debug --disable-network --disable-avdevice \
 --disable-everything --enable-ffmpeg --enable-ffprobe --enable-avcodec --enable-avformat \
 --enable-avfilter --enable-swresample --enable-protocol=file,pipe \
 --enable-demuxer=aac,mov,mp3,wav,flac,ogg,caf \
 --enable-decoder=aac,alac,mp3,mp3float,flac,vorbis,opus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32be \
 --enable-parser=aac,mpegaudio,flac,opus,vorbis \
 --enable-encoder=pcm_s16le,pcm_f32le --enable-muxer=wav,caf,pcm_f32le \
 --enable-filter=aresample,aformat,anull,pan,astats,ametadata
make clean
make -j4
cp ffmpeg ffprobe "$ROOT/Assets/tools/"
cp config.h "$ROOT/build/ffmpeg-config.h"
cp ffbuild/config.log "$ROOT/build/ffmpeg-config.log"
# Packaging must also use licenses from the verified source tree.
mkdir -p "$ROOT/build/ffmpeg-licenses"
cp COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md "$ROOT/build/ffmpeg-licenses/"
cd "$ROOT"
{
    echo "$ARCHIVE_SHA256  $ARCHIVE"
    shasum -a 256 Assets/tools/ffmpeg Assets/tools/ffprobe
} > build/ffmpeg-sha256.txt
