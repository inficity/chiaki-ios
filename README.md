# ChiakiRemote

[chiaki-ng](https://github.com/streetpea/chiaki-ng)의 libchiaki를 쓰는 iOS/iPadOS용 PS5 리모트 플레이 앱.
Tailscale subnet router 너머의 PS5 LAN IP로 직접 접속하는 환경을 전제로 한다.

## 빌드

```bash
./scripts/bootstrap.sh   # 서브모듈, OpenSSL/Opus, ChiakiCore.xcframework, Xcode 프로젝트 생성
open ChiakiRemote.xcodeproj
```

서명 정보는 `Config/Local.xcconfig`(git 제외)에 둔다. 예시는 `Config/Local.xcconfig.example`.

## 구조

- `third_party/chiaki-ng` — 서브모듈 (v1.10.0 고정)
- `ChiakiCore/` — libchiaki를 iOS 정적 라이브러리로 빌드하는 CMake
  - PSN 홀펀칭(인터넷 원격 접속)은 `src/holepunch_stub.c`로 대체. Tailscale이 그 역할을 하므로
    curl/json-c/miniupnpc/libevent 의존성이 필요 없다.
  - `generated/takion.pb.{c,h}` — nanopb로 미리 생성한 프로토콜 코드
- `scripts/build-deps.sh` — OpenSSL 3.5(libcrypto), Opus 1.5 (기기 arm64 + 시뮬레이터 arm64)
- `scripts/build-chiaki.sh` — 위를 합쳐 `build/ChiakiCore.xcframework` 생성
- `App/` — SwiftUI 앱 (`import ChiakiCore`)

## 라이선스

chiaki-ng가 AGPL-3.0이므로 이 앱도 AGPL-3.0을 따른다. App Store 배포 대상이 아니며 개인 기기 설치용.
