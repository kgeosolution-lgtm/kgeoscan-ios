# kgeoScan iOS (시제품)

LiDAR 아이폰으로 **녹화 → 제목 입력 → 자동 업로드**까지 한 앱에서 끝내는 kgeodata.com 3D 스캔용 앱입니다.
[Stray Scanner](https://github.com/strayrobots/scanner) (Stray Robots, MIT) 를 포크해 녹화 코어는 그대로 두고,
설정 화면·위치/방위 기록·서버 업로드를 더했습니다. 결과는 https://kgeodata.com/app/3dscan/ 지도에서 봅니다.

Mac 과 Apple Developer Program 없이 돌아가는 **무과금 경로**로 만듭니다:
공개 GitHub 저장소 + GitHub Actions macOS 러너로 서명 없는 IPA 를 만들고, Windows 의 Sideloadly 와 무료 Apple ID 로 아이폰에 넣습니다
(7일마다 재서명). 설치 방법은 [INSTALL_WINDOWS.md](INSTALL_WINDOWS.md).

## 흐름

```
스캔 목록 ─ 새 스캔 ─▶ 설정 화면 ─▶ 녹화 화면 ─▶ 업로드 화면 ─▶ 결과 보기 (Safari)
                     제목·비고       빨간 버튼:      1 zip (저장만)       https://kgeodata.com/app/3dscan/?select=<scene_item_id>
                     모드(홈/현장)   트래킹 리셋      2 POST upload.py (진행률)
                     서버 주소       GPS·방위 스냅샷  3 GET status.py 폴링 (단계 0..7)
                     GPS 확인        → 녹화
```

- **녹화 코어**: Stray Scanner 그대로. ARKit `sceneDepth` 로 `rgb.mp4`(HEVC 1920×1440), `depth/NNNNNN.png`(256×192, 16-bit mm),
  `confidence/NNNNNN.png`, `odometry.csv`(헤더 포함, 자세는 OpenCV 카메라 규약), `imu.csv`, `camera_matrix.csv`, `distortion/`.
  파일 이름·규약은 바꾸지 않았다 — 서버가 그대로 읽는다. [docs/format.md](docs/format.md)
- **추가된 것**: 녹화 폴더에 `meta.json` 하나가 더 들어간다 (제목·모드·위치·방위·업로드 결과).
- **녹화 화면** (2026-10-27): Stray 의 Metal 깊이/RGB 미리보기 대신 `ARSCNView` 가 실제 카메라 화면을 그리고, ARKit
  `sceneReconstruction = .mesh` 의 `ARMeshAnchor` 를 파란 반투명 면 + 흰 윤곽선으로 덮어 "어디를 찍었는지" 보여 준다
  ([StrayScanner/Kgeo/MeshOverlay.swift](StrayScanner/Kgeo/MeshOverlay.swift), 탭 또는 '메시' 버튼으로 끄고 켬). 녹화 시작의 트래킹 리셋 때 메시도 비워져
  이번 녹화분만 보인다. 표시용일 뿐 녹화 파일에는 아무 영향이 없다.
- **촬영 안내** ([CaptureGuide.swift](StrayScanner/Kgeo/CaptureGuide.swift)): 위 오른쪽에 트래킹 상태와 중앙 거리, 아래에 경고(트래킹 초기화·특징 부족·
  0.3 m 미만·3 m 초과·너무 빠른 움직임 1 m/s·60°/s)와 모드별 힌트(현장조사: 물체를 중앙에 두고 천천히 한 바퀴 / 홈스캔: 벽·바닥 훑기).
- **노출 옵션** ([ExposureController.swift](StrayScanner/Kgeo/ExposureController.swift)): 설정 화면 '빠른 셔터 1/250' 을 고르면 iOS 16 의
  `configurableCaptureDeviceForPrimaryCamera` 로 셔터를 고정하고 ISO 로 밝기를 맞춰 모션블러를 줄인다 (사진 기반 복원용 키프레임 품질).
- **좌표 규약** (서버 `process_scan.py` 와 맞춤): 녹화 버튼을 누르면 ARKit 트래킹을 리셋해 **월드 원점 = 녹화 시작 지점**,
  **-z = 그 순간 카메라 정면**이 되게 한다. 트래킹이 `normal` 로 돌아온 첫 프레임에서 GPS(lat/lon/alt)와 나침반 방위를 찍어
  `lon`/`lat`/`elev`/`heading` 으로 보낸다. 서버는 원점을 (lon, lat, elev) 에 놓고 -z 를 heading 방위로 돌린다
  (`e = x·cosθ − z·sinθ`, `n = −x·sinθ − z·cosθ`, `h = y`). heading 은 `CLHeading.trueHeading`(없으면 `magneticHeading`),
  폰을 세로로 든 상태의 값이며 정확도는 대략 ±10~20°.

## 서버 계약 (앱이 쓰는 것)

| 요청 | 내용 |
|---|---|
| `POST {서버}/upload.py` multipart | `title`, `note`, `mode=stray`, `scan_type=home|survey`(모드), `lon`, `lat`, `elev`(선택), `heading`(선택), `scan_zip`(zip), `client_id`(녹화마다 한 번 만든 UUID, 재시도해도 같음), `app`. 응답 `{"job_id": "...", "mode": "stray", "scan_type": "home"}` 또는 `{"error": "..."}`. 같은 제목·같은 zip 이름으로 24시간 안에 만든 작업이 있으면 서버가 새로 만들지 않고 그 `job_id` 를 `"duplicate": true` 와 함께 돌려준다 |
| `GET {서버}/status.py?job_id=` | `{status, step 0..7, step_name, message, title, mode, scan_type, thumb_url, scene_item_id, glb_url}` — `done`/`failed` 가 될 때까지 3초마다 조회 |
| 진행 페이지 | `{서버}` 의 `3dupload` 를 `3dscan` 으로 바꾼 주소 + `?job=<job_id>` — 사이트가 7단계 진행과 결과를 이어서 보여 준다 ("웹에서 진행 보기" 버튼) |
| 결과 페이지 | 같은 주소 + `?select=<scene_item_id>` (없으면 `?job=`) |

`{서버}` 기본값은 `https://kgeodata.com/app/3dupload`, 설정 화면에서 바꿀 수 있다 (UserDefaults 에 저장).
zip 은 압축하지 않고 담기만 한다(mp4·png 는 이미 압축됨). 폴더 이름이 zip 의 최상위에 들어가며 서버는 `odometry.csv` 가 있는 폴더를 찾는다.

**전송 방식**: 기본은 앱을 열어 둔 채 보내는 foreground `URLSession` 이다 (전송 중 화면 자동 잠금을 끈다). 연결이 끊기면 바로 오류가
표시되고 자동 재전송은 없다. 설정 화면의 "백그라운드로 전송 (실험)" 을 켜면 백그라운드 `URLSession` 으로 보내 화면을 꺼도 이어지지만,
iOS 가 응답을 받지 못하면 본문을 **처음부터 다시** 보낼 수 있다 (2026-10-27 실기기에서 진행 막대가 100% → 0% 를 반복한 현상의 유력한 원인).

**중복 방지**: `job_id` 를 한 번 받은 녹화는 다시 올리지 않고 상태만 조회한다. 녹화마다 `client_id` 를 한 번 만들어 보내고, 서버는 같은
제목·zip 이름의 24시간 내 작업을 `duplicate: true` 로 돌려주므로 재시도해도 작업이 늘지 않는다.

**로그**: 업로드 화면 아래 "로그" 섹션에 압축·전송(10% 단위, 재시작 감지)·응답·네트워크 지표(HTTP 버전, 연결 재사용, 본문 전송 후
응답까지 걸린 시간)·상태 조회가 시각과 함께 쌓이고 "로그 복사" 로 붙여 넣을 수 있다. 같은 내용이 녹화 폴더의 `upload.log` 와
`meta.json` 의 `last_attempt`(시작·종료·HTTP 상태·재시작 횟수·job_id·오류) / `upload_log` 에 남는다.

## meta.json

```json
{
  "app": "kgeoScan", "app_version": "0.1.0 (1)", "format": "stray",
  "title": "거실", "note": "", "mode": "home", "server_base": "https://kgeodata.com/app/3dupload",
  "created_at": "2026-10-27T09:12:33Z", "duration_seconds": 41.2, "fps_divider": 1, "saved_frames": 2470,
  "device": "iPhone16,1", "system_version": "18.6",
  "ar_world_alignment": "gravity", "tracking_reset_at_record_start": true,
  "fix": { "lat": 37.28731, "lon": 127.05992, "alt": 58.7, "ellipsoidal_alt": 83.1, "h_acc": 5.0, "v_acc": 3.2,
           "fix_time": "2026-10-27T09:12:33Z", "true_heading": 123.4, "magnetic_heading": 115.9,
           "heading_accuracy": 15.0, "heading_time": "2026-10-27T09:12:33Z" },
  "upload": { "server": "https://kgeodata.com/app/3dupload", "job_id": "c23b2c73", "uploaded_at": "...",
              "status": "done", "step": 7, "step_name": "완료", "message": "", "scene_item_id": "...", "glb_url": "...",
              "thumb_url": "...", "result_url": "https://kgeodata.com/app/3dscan/?select=..." }
}
```

## 빌드

- **GitHub Actions** ([.github/workflows/build-ipa.yml](.github/workflows/build-ipa.yml)): push 마다 `macos-15` 러너에서
  `brew install xcodegen` → `xcodegen generate` → `xcodebuild … CODE_SIGNING_ALLOWED=NO` → `Payload/kgeoScan.app` 을 zip 한
  `kgeoScan.ipa` 를 아티팩트로 올리고, 기본 브랜치면 프리릴리스 **latest** 에, `v*` 태그면 정식 릴리스에 붙인다.
- **Mac 에서 직접**: `brew install xcodegen && xcodegen generate && open kgeoScan.xcodeproj`. 프로젝트 원본은
  [project.yml](project.yml) 이고 `.xcodeproj` 는 커밋하지 않는다. 배포 타깃 iOS 16, 패키지는 ZIPFoundation (SPM) 하나.
- 이 저장소는 Windows 에서 편집만 하고 컴파일은 CI 에 맡긴다. GitHub 는 로그인해야 러너 로그를 보여 주므로, 빌드가 실패하면
  워크플로가 오류 줄을 check-run annotation(API 로 공개 조회 가능)과 프리릴리스 **ci-logs** 의 `errors.txt` / `xcodebuild.log`
  (로그인 없이 내려받기 가능)로 올린다. 문서(`*.md`, `docs/`, `scripts/`)만 바뀐 push 는 빌드하지 않는다.
- 첫 성공 빌드(2026-10-27)는 Xcode 26.3 / iOS 26.2 SDK 로 만들어졌고, 결과 앱은 iOS 16 이상에서 돈다.

## 폴더

```
project.yml                      XcodeGen 프로젝트 정의 (타깃 kgeoScan, 번들 com.kgeosolution.kgeoscan)
StrayScanner/                    앱 소스 (폴더 이름은 원본 그대로 두어 upstream 과 비교하기 쉽게)
  Controllers/RecordSessionViewController.swift   녹화 화면 — 트래킹 리셋·위치 스냅샷·meta.json 추가
  Helpers/*Encoder.swift         Stray 녹화 코어 (변경 없음, DatasetEncoder 에 접근자 2개만 추가)
  Kgeo/                          kgeoScan 추가분
    ScanSetupView.swift          제목·비고·모드·서버·GPS 확인
    UploadView.swift             zip → 업로드 → 상태 폴링 → 결과 보기
    UploadClient.swift           백그라운드 URLSession, upload.py / status.py
    ZipPackager.swift, MultipartBody.swift, LocationService.swift, ScanMeta.swift, ServerEndpoints.swift, KgeoDefaults.swift
  Views/                         목록·상세·안내 (NavigationStack 으로 흐름 연결)
scripts/make_icon.py             앱 아이콘 재생성 (Pillow)
docs/format.md                   녹화 데이터 형식 (원본 문서 + meta.json)
INSTALL_WINDOWS.md               Sideloadly 설치 안내
```

## 다음 단계 (이 시제품 범위 밖)

- 키프레임만 올려 용량 1/10 로 줄이기, 끊김 대비 분할 업로드
- 홈스캔 / 현장조사 모드별 처리 분기 (지금은 라벨만 저장), 현장(site) 묶음
- RoomPlan 평면도, 키프레임 선명도 선별을 앱에서
- 결과 페이지를 앱 안에서 보기, 업로드 이력 목록

## 라이선스

MIT. 원본 저작권은 Stray Robots, Inc. ([LICENSE.md](LICENSE.md)) 에 있으며 변경분도 같은 조건으로 둡니다.
