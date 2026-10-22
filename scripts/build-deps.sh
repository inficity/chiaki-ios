#!/bin/bash
# OpenSSL(libcrypto)과 Opus를 iOS 기기/시뮬레이터, macOS용 정적 라이브러리로 빌드한다.
# 결과: build/<platform>/prefix/{include,lib}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SRC="$BUILD/src"
JOBS="$(sysctl -n hw.ncpu)"
source "$ROOT/scripts/platforms.sh"

OPENSSL_VER=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
OPUS_VER=1.5.2
OPUS_SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1

fetch() { # url sha256 file
	local url="$1" sha="$2" file="$SRC/$3"
	if [ ! -f "$file" ]; then
		curl -fsSL -o "$file.part" "$url"
		mv "$file.part" "$file"
	fi
	echo "$sha  $file" | shasum -a 256 -c - >/dev/null
}

mkdir -p "$SRC"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz" \
	"$OPENSSL_SHA256" "openssl-$OPENSSL_VER.tar.gz"
fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS_VER.tar.gz" \
	"$OPUS_SHA256" "opus-$OPUS_VER.tar.gz"

build_openssl() { # platform
	local platform="$1"
	local prefix="$BUILD/$platform/prefix"
	[ -f "$prefix/lib/libcrypto.a" ] && return
	local work="$BUILD/$platform/openssl"
	rm -rf "$work" && mkdir -p "$work"
	tar xzf "$SRC/openssl-$OPENSSL_VER.tar.gz" -C "$work" --strip-components 1
	(
		cd "$work"
		./Configure "$(openssl_target "$platform")" no-shared no-tests no-apps no-docs no-engine no-dso no-ui-console \
			"$(min_version_flag "$platform")" --prefix="$prefix" >/dev/null
		make -j"$JOBS" build_libs >/dev/null
		make install_dev >/dev/null
	)
}

build_opus() { # platform
	local platform="$1"
	local prefix="$BUILD/$platform/prefix"
	[ -f "$prefix/lib/libopus.a" ] && return
	local work="$BUILD/$platform/opus"
	rm -rf "$work" && mkdir -p "$work"
	tar xzf "$SRC/opus-$OPUS_VER.tar.gz" -C "$work" --strip-components 1
	cmake -S "$work" -B "$work/build" -DCMAKE_BUILD_TYPE=Release \
		$(cmake_platform_args "$platform") -DCMAKE_INSTALL_PREFIX="$prefix" \
		-DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_SHARED_LIBRARY=OFF >/dev/null
	cmake --build "$work/build" -j"$JOBS" >/dev/null
	cmake --install "$work/build" >/dev/null
}

for p in "${PLATFORMS[@]}"; do
	build_openssl "$p"
	build_opus "$p"
done

for p in "${PLATFORMS[@]}"; do
	echo "$p:"; lipo -info "$BUILD/$p/prefix/lib/"lib{crypto,opus}.a
done
