#!/bin/bash
# 처음 받았을 때 한 번 실행: 서브모듈 → 의존성 → ChiakiCore.xcframework → Xcode 프로젝트
set -euo pipefail
cd "$(dirname "$0")/.."

git submodule update --init third_party/chiaki-ng
git -C third_party/chiaki-ng submodule update --init --depth 1 \
	third-party/nanopb third-party/jerasure third-party/gf-complete
[ -f Config/Local.xcconfig ] || cp Config/Local.xcconfig.example Config/Local.xcconfig

./scripts/build-deps.sh
./scripts/build-chiaki.sh
xcodegen generate
