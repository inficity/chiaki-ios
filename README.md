# ChiakiRemote

[chiaki-ng](https://github.com/streetpea/chiaki-ng)의 libchiaki를 쓰는 iPhone/iPad/Mac용 PS5 리모트 플레이 앱.
Tailscale subnet router 너머의 PS5 LAN IP로 직접 접속하는 환경을 전제로 한다.

## 빌드

```bash
./scripts/bootstrap.sh   # 서브모듈, OpenSSL/Opus, ChiakiCore.xcframework, Xcode 프로젝트 생성
open ChiakiRemote.xcodeproj
```

스킴 `ChiakiRemote`는 iPhone/iPad, `ChiakiRemoteMac`은 Mac(Apple Silicon) 앱이다.

서명 정보는 `Config/Local.xcconfig`(git 제외)에 둔다. 예시는 `Config/Local.xcconfig.example`.

## 구조

- `third_party/chiaki-ng` — 서브모듈 (v1.10.0 고정)
- `ChiakiCore/` — libchiaki를 iOS 정적 라이브러리로 빌드하는 CMake
  - PSN 홀펀칭(인터넷 원격 접속)은 `src/holepunch_stub.c`로 대체. Tailscale이 그 역할을 하므로
    curl/json-c/miniupnpc/libevent 의존성이 필요 없다.
  - `generated/takion.pb.{c,h}` — nanopb로 미리 생성한 프로토콜 코드
- `scripts/build-deps.sh` — OpenSSL 3.5(libcrypto), Opus 1.5 (iOS 기기·시뮬레이터, macOS. 모두 arm64)
- `scripts/build-chiaki.sh` — 위를 합쳐 `build/ChiakiCore.xcframework` 생성
- `Shared/` — 두 앱이 같이 쓰는 SwiftUI 코드 (`import ChiakiCore`)
- `iOS/`, `macOS/` — 플랫폼별 구현 (`PlatformSupport.swift`에 같은 이름의 API를 맞춘다)

## 데이터와 iCloud 동기화

| 데이터 | 저장소 | 공유 |
|---|---|---|
| 등록 키 (regist key, rp_key) | iCloud 키체인 (`ChiakiRemote.registration`) | iPhone/iPad/Mac |
| PS5 목록, PSN 계정 ID | iCloud 키-값 저장소 + UserDefaults | iPhone/iPad/Mac |
| 영상 설정 | UserDefaults | 기기별 |

등록은 기기에 묶이지 않아서 한 기기에서 등록하면 나머지 기기도 그대로 접속한다.
등록 키 동기화에는 각 기기에서 iCloud 키체인(암호 및 키체인)이 켜져 있어야 한다.
디버그 빌드는 `Chiaki.app/Contents/MacOS/Chiaki -cloudSelfTest`로 동작을 확인할 수 있다.

## 키보드 배치 (Mac, iPad 하드웨어 키보드)

| 키 | PS5 |
|---|---|
| WASD / IJKL | 왼쪽 / 오른쪽 스틱 |
| 방향키 | 방향 버튼 |
| Return·Space / Backspace / F / R | ✕ / ○ / □ / △ |
| Q / E / Z / C | L1 / R1 / L2 / R2 |
| 1 / 2 | L3 / R3 |
| O / Y / Tab / H | OPTIONS / 만들기 / 터치패드 / PS |

## 라이선스

chiaki-ng가 AGPL-3.0이므로 이 앱도 AGPL-3.0을 따른다. App Store 배포 대상이 아니며 개인 기기 설치용.
