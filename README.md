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
- **좌표 규약** (서버 `process_scan.py` 와 맞춤): 녹화 버튼을 누르면 ARKit 트래킹을 리셋해 **월드 원점 = 녹화 시작 지점**,
  **-z = 그 순간 카메라 정면**이 되게 한다. 트래킹이 `normal` 로 돌아온 첫 프레임에서 GPS(lat/lon/alt)와 나침반 방위를 찍어
  `lon`/`lat`/`elev`/`heading` 으로 보낸다. 서버는 원점을 (lon, lat, elev) 에 놓고 -z 를 heading 방위로 돌린다
  (`e = x·cosθ − z·sinθ`, `n = −x·sinθ − z·cosθ`, `h = y`). heading 은 `CLHeading.trueHeading`(없으면 `magneticHeading`),
  폰을 세로로 든 상태의 값이며 정확도는 대략 ±10~20°.

## 서버 계약 (앱이 쓰는 것)

| 요청 | 내용 |
|---|---|
| `POST {서버}/upload.py` multipart | `title`, `note`, `mode=stray`, `scan_type=home|survey`(모드), `lon`, `lat`, `elev`(선택), `heading`(선택), `scan_zip`(zip). `app` 도 보내지만 서버는 무시한다. 응답 `{"job_id": "...", "mode": "stray", "scan_type": "home"}` 또는 `{"error": "..."}` |
| `GET {서버}/status.py?job_id=` | `{status, step 0..7, step_name, message, title, mode, scan_type, thumb_url, scene_item_id, glb_url}` — `done`/`failed` 가 될 때까지 3초마다 조회 |
| 진행 페이지 | `{서버}` 의 `3dupload` 를 `3dscan` 으로 바꾼 주소 + `?job=<job_id>` — 사이트가 7단계 진행과 결과를 이어서 보여 준다 ("웹에서 진행 보기" 버튼) |
| 결과 페이지 | 같은 주소 + `?select=<scene_item_id>` (없으면 `?job=`) |

`{서버}` 기본값은 `https://kgeodata.com/app/3dupload`, 설정 화면에서 바꿀 수 있다 (UserDefaults 에 저장).
zip 은 압축하지 않고 담기만 한다(mp4·png 는 이미 압축됨). 폴더 이름이 zip 의 최상위에 들어가며 서버는 `odometry.csv` 가 있는 폴더를 찾는다.
업로드는 백그라운드 `URLSession` 이라 전송 중 화면을 꺼도 이어지고, 앱이 꺼진 채 끝나면 `meta.json` 에 `job_id` 를 남긴다
(목록에서 스캔을 열어 "업로드 상태 보기"로 이어서 확인).

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
- 이 저장소는 Windows 에서 편집만 하고 컴파일은 CI 에 맡긴다. 러너 로그에서 오류를 읽고 고쳐 다시 push 한다.

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
