# build-deps.sh / build-chiaki.sh가 같이 쓰는 플랫폼 설정. 모두 arm64만 빌드한다.
IOS_MIN="${IOS_MIN:-17.0}"
MACOS_MIN="${MACOS_MIN:-14.0}"
PLATFORMS=(iphoneos iphonesimulator macosx)

# 컴파일러 최소 버전 플래그
min_version_flag() {
	case "$1" in
		iphoneos) echo "-mios-version-min=$IOS_MIN" ;;
		iphonesimulator) echo "-mios-simulator-version-min=$IOS_MIN" ;;
		macosx) echo "-mmacosx-version-min=$MACOS_MIN" ;;
	esac
}

# CMake 크로스 컴파일 인자
cmake_platform_args() {
	case "$1" in
		macosx) echo "-DCMAKE_OSX_SYSROOT=macosx -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN" ;;
		*) echo "-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$1 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_MIN" ;;
	esac
}

openssl_target() {
	case "$1" in
		iphoneos) echo ios64-xcrun ;;
		iphonesimulator) echo iossimulator-arm64-xcrun ;;
		macosx) echo darwin64-arm64 ;;
	esac
}
