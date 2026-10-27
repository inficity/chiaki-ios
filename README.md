# ChiakiRemote

A personal PS5 Remote Play client for iPhone, iPad and Mac, built on
[chiaki-ng](https://github.com/streetpea/chiaki-ng)'s libchiaki. It connects directly to the console's LAN IP
(for example through a Tailscale subnet router) and is not affiliated with Sony.

[chiaki-ng](https://github.com/streetpea/chiaki-ng)의 libchiaki를 쓰는 iPhone/iPad/Mac용 PS5 리모트 플레이 앱.
Tailscale subnet router 너머의 PS5 LAN IP로 직접 접속하는 환경을 전제로 한다.

> 비공식 프로젝트로 Sony Interactive Entertainment와 관계가 없다.
> PlayStation, PS5, DualSense는 Sony Interactive Entertainment의 상표다.

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
- `Design/icon-candidates/` — 앱 아이콘 후보 원본. 바꾸려면
  `swift scripts/make-app-icon.swift Design/icon-candidates/icon-b.png Shared/Assets.xcassets/AppIcon.appiconset`

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

## PS 버튼이 안 될 때 (macOS)

macOS 26은 컨트롤러의 PS(홈) 버튼을 앱보다 먼저 가져가 게임 센터를 띄운다.
**시스템 설정 › 게임 컨트롤러**에서 홈 버튼 단축키를 끄면 앱으로 들어온다.
끄지 않아도 **터치패드 + OPTIONS**를 같이 누르거나, 스트리밍 화면을 클릭하면 나오는 PS 버튼, 키보드 **H**로 보낼 수 있다.

## 라이선스

[GNU AGPL-3.0](LICENSE)에 [OpenSSL 링크 예외](LICENSE-OpenSSL-exception)를 더한 조건이다. chiaki-ng의 libchiaki를 링크하므로 같은 라이선스를 따른다.
App Store 배포 대상이 아니며 개인 기기 설치용이다. 빌드한 앱을 다른 사람에게 배포하면 AGPL에 따라 소스도 함께 제공해야 한다.

함께 쓰는 서드파티 코드 (빌드할 때 받거나 서브모듈로 가져오며, 각자의 라이선스를 따른다):

| 구성 요소 | 라이선스 | 위치 |
|---|---|---|
| [chiaki-ng](https://github.com/streetpea/chiaki-ng) (libchiaki) | AGPL-3.0 + OpenSSL 예외 | `third_party/chiaki-ng` |
| [OpenSSL](https://www.openssl.org) 3.5 (libcrypto) | Apache-2.0 | `scripts/build-deps.sh`가 받음 |
| [Opus](https://opus-codec.org) 1.5 | BSD-3-Clause | `scripts/build-deps.sh`가 받음 |
| [nanopb](https://github.com/nanopb/nanopb) | zlib | chiaki-ng 서브모듈 |
| [Jerasure](https://github.com/tsuraan/Jerasure), [GF-Complete](https://github.com/ceph/gf-complete) | BSD-3-Clause | chiaki-ng 서브모듈 |

`ChiakiCore/generated/takion.pb.{c,h}`는 chiaki-ng의 `takion.proto`에서 nanopb로 생성했다.
앱 아이콘은 이 저장소용으로 생성한 이미지다 (`Design/icon-candidates/`).
