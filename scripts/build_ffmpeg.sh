#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION=8.0.1
mkdir -p Vendor Assets/tools build
ARCHIVE="Vendor/ffmpeg-$VERSION.tar.xz"
if [ ! -f "$ARCHIVE" ]; then curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$ARCHIVE"; fi
echo "05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41  $ARCHIVE" | shasum -a 256 -c -
if [ ! -d "Vendor/ffmpeg-$VERSION" ]; then tar -xf "$ARCHIVE" -C Vendor; fi
cd "Vendor/ffmpeg-$VERSION"
./configure --prefix="$ROOT/Assets/ffmpeg" --arch=arm64 --target-os=darwin \
 --extra-cflags=-mmacosx-version-min=26.0 --extra-ldflags=-mmacosx-version-min=26.0 \
 --cc=clang --disable-autodetect --disable-shared --enable-static --disable-gpl --disable-nonfree \
 --disable-doc --disable-debug --disable-network --disable-avdevice \
 --disable-everything --enable-ffmpeg --enable-ffprobe --enable-avcodec --enable-avformat \
 --enable-avfilter --enable-swresample --enable-protocol=file,pipe \
 --enable-demuxer=mov,mp3,wav,flac,ogg,caf \
 --enable-decoder=aac,alac,mp3,mp3float,flac,vorbis,opus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_s16be,pcm_s24be,pcm_s32be,pcm_f32be \
 --enable-parser=aac,mpegaudio,flac,opus,vorbis \
 --enable-encoder=pcm_s16le,pcm_f32le --enable-muxer=wav,caf,pcm_f32le \
 --enable-filter=aresample,aformat,anull,pan,astats,ametadata
make clean
make -j4
cp ffmpeg ffprobe "$ROOT/Assets/tools/"
cp config.h "$ROOT/build/ffmpeg-config.h"
cp ffbuild/config.log "$ROOT/build/ffmpeg-config.log"
cd "$ROOT"
shasum -a 256 "$ARCHIVE" Assets/tools/ffmpeg Assets/tools/ffprobe > build/ffmpeg-sha256.txt
