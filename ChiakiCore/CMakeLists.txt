# chiaki-ng의 lib/를 iOS용 정적 라이브러리로 빌드한다.
# 원본 CMake는 데스크톱용 의존성(curl, json-c, miniupnpc, libevent)을 강제로 찾기 때문에
# 필요한 소스만 직접 나열한다. scripts/build-chiaki.sh에서 호출한다.
cmake_minimum_required(VERSION 3.20)
project(ChiakiCore C)

set(CHIAKI "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/chiaki-ng")
set(DEPS_PREFIX "" CACHE PATH "build-deps.sh가 만든 prefix (OpenSSL, Opus)")

set(CHIAKI_LIB_ENABLE_OPUS 1)
set(CHIAKI_LIB_ENABLE_PI_DECODER 0)
set(CHIAKI_LIB_ENABLE_FFMPEG_DECODER 0)
configure_file("${CHIAKI}/lib/config.h.in" "${CMAKE_CURRENT_BINARY_DIR}/include/chiaki/config.h")

file(GLOB CHIAKI_SOURCES "${CHIAKI}/lib/src/*.c")
list(APPEND CHIAKI_SOURCES
	"${CHIAKI}/lib/src/remote/rudp.c"
	"${CHIAKI}/lib/src/remote/rudpsendbuffer.c"
	src/holepunch_stub.c
	generated/takion.pb.c)
# 하드웨어 전용 디코더는 쓰지 않음 (VideoToolbox를 앱에서 직접 사용)
list(FILTER CHIAKI_SOURCES EXCLUDE REGEX "(ffmpegdecoder|pidecoder)\\.c$")

set(NANOPB_SOURCES
	"${CHIAKI}/third-party/nanopb/pb_common.c"
	"${CHIAKI}/third-party/nanopb/pb_decode.c"
	"${CHIAKI}/third-party/nanopb/pb_encode.c")

set(FEC_SOURCES
	"${CHIAKI}/third-party/gf-complete/src/gf.c"
	"${CHIAKI}/third-party/gf-complete/src/gf_wgen.c"
	"${CHIAKI}/third-party/gf-complete/src/gf_w4.c"
	"${CHIAKI}/third-party/gf-complete/src/gf_w8.c"
	"${CHIAKI}/third-party/gf-complete/src/gf_w16.c"
	"${CHIAKI}/third-party/gf-complete/src/gf_w32.c"
	"${CHIAKI}/third-party/gf-complete/src/gf_w64.c"
	"${CHIAKI}/third-party/gf-complete/src/gf_w128.c"
	"${CHIAKI}/third-party/gf-complete/src/gf_rand.c"
	"${CHIAKI}/third-party/gf-complete/src/gf_general.c"
	"${CHIAKI}/third-party/gf-complete/src/gf_cpu.c"
	"${CHIAKI}/third-party/jerasure/src/galois.c"
	"${CHIAKI}/third-party/jerasure/src/jerasure.c"
	"${CHIAKI}/third-party/jerasure/src/reed_sol.c"
	"${CHIAKI}/third-party/jerasure/src/cauchy.c"
	"${CHIAKI}/third-party/jerasure/src/liberation.c")

add_library(chiaki STATIC ${CHIAKI_SOURCES} ${NANOPB_SOURCES} ${FEC_SOURCES})
target_include_directories(chiaki PRIVATE
	"${CMAKE_CURRENT_BINARY_DIR}/include"
	"${CHIAKI}/lib/include"
	"${CMAKE_CURRENT_SOURCE_DIR}/generated"
	"${CHIAKI}/third-party/nanopb"
	"${CHIAKI}/third-party/gf-complete/include"
	"${CHIAKI}/third-party/jerasure/include"
	"${DEPS_PREFIX}/include")
target_compile_definitions(chiaki PRIVATE PB_C99_STATIC_ASSERT)
target_compile_options(chiaki PRIVATE -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations)
