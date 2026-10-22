#!/bin/bash
# libchiaki + OpenSSL(libcrypto) + Opus를 하나로 합쳐 build/ChiakiCore.xcframework를 만든다.
# 먼저 scripts/build-deps.sh를 실행해야 한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
IOS_MIN="${IOS_MIN:-17.0}"
CHIAKI="$ROOT/third_party/chiaki-ng"
OUT="$BUILD/ChiakiCore.xcframework"

# xcframework에 들어갈 공개 헤더: chiaki 헤더 + 모듈맵
HEADERS="$BUILD/chiaki-headers"
rm -rf "$HEADERS" && mkdir -p "$HEADERS"
cp -R "$CHIAKI/lib/include/chiaki" "$HEADERS/"
rm "$HEADERS/chiaki/"{ffmpegdecoder,pidecoder}.h
cp "$ROOT/ChiakiCore/include/"* "$HEADERS/"

args=()
for platform in iphoneos iphonesimulator; do
	work="$BUILD/$platform/chiaki"
	prefix="$BUILD/$platform/prefix"
	cmake -S "$ROOT/ChiakiCore" -B "$work" -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$platform" -DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" -DDEPS_PREFIX="$prefix" >/dev/null
	cmake --build "$work" -j"$(sysctl -n hw.ncpu)"
	cp "$work/include/chiaki/config.h" "$HEADERS/chiaki/config.h"
	libtool -static -o "$work/libChiakiCore.a" \
		"$work/libchiaki.a" "$prefix/lib/libcrypto.a" "$prefix/lib/libopus.a" 2>/dev/null
	args+=(-library "$work/libChiakiCore.a" -headers "$HEADERS")
done

rm -rf "$OUT"
xcodebuild -create-xcframework "${args[@]}" -output "$OUT"
