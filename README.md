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
- **위치 입력**: 새 스캔 화면에서 '현재 위치(GPS)' 또는 '지도에서 선택'([MapPickerView.swift](StrayScanner/Kgeo/MapPickerView.swift), 탭으로 핀, 드래그,
  현재 위치로 옮기기, 방위 직접 입력). GPS 는 정확도(±m)와 '다시 잡기'. 선택한 위치는 `meta.json` 의 `manual_fix`/`fix` 에 저장되고 `lon`/`lat`/`heading` 으로 전송된다.
- **촬영 통계와 요약**: 녹화 중 거리·속도·깊이 신뢰도·선명도를 모아 `capture_stats` 로 저장하고, 기준에 못 미치면 종료 때 "촬영 품질 확인" 창에서
  '다시 찍기(삭제)' 를 제안한다. 기준은 2026-10-27 컵 녹화 분석(0.21 m 근접, 1.66 m/s, 흐림)에서 잡았다: 현장조사 0.4~1.5 m·0.5 m/s, 홈스캔 0.3~3 m·0.7 m/s.
- **물체 모드** ([ObjectTracker.swift](StrayScanner/Kgeo/ObjectTracker.swift), 현장조사에서 기본 켬): 녹화 화면에서 물체를 탭하면
  ARKit 레이캐스트(estimatedPlane → existingPlaneGeometry → 깊이맵 역투영)로 중심을 잡고 반투명 구(반경 0.05~0.6 m, 기본 0.15 m, 슬라이더)로 자를 영역을
  보여 준다. 카메라 방위각을 10° 36칸으로 나눠 지나간 칸을 링으로 채우고(한 바퀴 330° 이상이면 진동 + ✓), 고도 3단(<20°/20~45°/>45°)과
  "이제 위에서 한 바퀴" 안내, 거리 0.35~0.9 m·회전 속도 경고를 낸다. **녹화 전에 물체를 지정하면 그 순간 트래킹을 리셋해 월드 원점을 고정**하고
  녹화 시작 때는 다시 리셋하지 않으므로 물체 좌표와 `odometry.csv` 가 같은 좌표계다. `meta.json` 의
  `object: {center, radius, set_by, coverage_pct, elevation_bands}` 로 저장되고 종료 요약에 커버리지가 나오며 70% 미만이면 다시 찍기를 제안한다.
- **촬영 뒤 미리보기** ([PreviewView.swift](StrayScanner/Kgeo/PreviewView.swift), [PreviewMesh.swift](StrayScanner/Kgeo/PreviewMesh.swift)):
  촬영이 끝나면 바로 올리지 않고 3D 를 손가락으로 돌려 본 뒤 **[업로드] [다시 찍기 (이 녹화 삭제)] [나중에 올리기]** 를 고른다.
  영상 방식은 녹화 중 0.7초마다 색 키프레임(240 px RGB + LiDAR 깊이 + 자세)을 모으고, 끝에 ARKit 메시(ARMeshAnchor)를 월드 좌표로 합쳐
  정점 색(가림 검사 포함)을 입혀 `preview/preview_mesh.ply` 로 저장한다(물체 모드는 구 안만). Object Capture 방식은 폰에서 만든 `model/*.obj` 를 보여 준다.
  촬영 요약(시간·프레임·거리·속도·깊이 신뢰·커버리지·경고 시간), 업로드 크기, 셀룰러 경고를 함께 보여 준다. 목록의 녹화 상세에서도 '3D 미리보기' 로 연다.
  설정의 '녹화 뒤 미리보기 없이 바로 업로드' 를 켜면 건너뛴다. `preview/` 는 업로드 zip 에서 빠진다.
- **물체 모드 고화질 사진** ([ObjectCaptureFlow.swift](StrayScanner/Kgeo/ObjectCaptureFlow.swift), iOS 17+, `ObjectCaptureSession.isSupported` 기기):
  현장조사 + 물체 모드에서 촬영 방식 '고화질 사진'(기본)을 고르면 Apple `ObjectCaptureView` 로 물체 찾기 → 자동 촬영 → 바퀴 완료 시
  '위에서 한 바퀴 더 / 물체를 뒤집고 / 촬영 끝내기' 를 고른다(한국어 안내·피드백). 끝나면 `PhotogrammetrySession` 으로 폰에서
  `model/` 에 OBJ+MTL+텍스처를 만든다 — **iOS 는 detail `.reduced` 만 지원** (Apple 문서: "On iOS, only one detail level – .reduced – is currently supported";
  `.medium`/`.preview` 는 macOS 전용). 사진은 `images/*.jpg`(긴 변 최대 4032, 품질 0.85, 센서 방향 그대로, EXIF orientation 미적용)로 바꾸고,
  `.poses` 결과로 `poses.json`(사진별 4×4 열 우선 카메라→모델 변환, 내부 파라미터는 HEIC 깊이 보정값 또는 EXIF 35mm 환산, JPEG 해상도 기준)을 쓴다.
  업로드 필드 `mode=objcap`, `scan_type=survey`. zip 에는 `model/`, `images/`, `poses.json`, `thumb.jpg`, `meta.json` 만 들어가고 원본 HEIC(`heic/`)와 `checkpoint/` 는 폰에 남는다.
- **면 촬영 (정사영상)** ([HiresRecorder.swift](StrayScanner/Kgeo/HiresRecorder.swift)): 현장조사의 촬영 대상 '면 (정사영상)', 대상 면 '바닥·트렌치 / 벽 / 자동'.
  매설관 트렌치(되메우기 전), 벽 균열, 바닥을 위·정면에서 본 실측 사진으로 남기기 위한 것이다. 녹화는 Stray 형식 그대로 하면서
  `ARSession.captureHighResolutionFrame` 로 마지막 사진보다 12 cm 이상 움직이거나 10° 이상 돌았을 때(흔들리면 건너뜀, 최대 200장)
  고해상도 정지 사진을 `hires/000001.jpg …`(품질 0.9, 긴 변 최대 4032, 센서 방향 그대로)로 저장하고, 끝에 `hires/poses.json` 을 쓴다:
  `{"frame":"odometry","images":[{"file","timestamp","transform"(열 우선 4×4 카메라→월드),"fx","fy","cx","cy","width","height","exif_orientation":6}]}`.
  **transform 은 odometry.csv 행과 같은 함수**(`OdometryEncoder.pose(of:)` / `cameraToWorld`, ARKit 자세 × x축 180° = OpenCV 카메라)로 만들고,
  timestamp 도 같은 ARFrame 시간축이다. 녹화 해상도·fps 가 같은 경우에만 고해상도 정지 사진용 영상 형식으로 바꾼다(rgb.mp4 1920×1440 유지).
  안내: 대상 면까지 0.4~1.2 m, 0.4 m/s 이하, '천천히 지그재그로 겹치게', 바닥 모드는 폰이 아래를 보도록(정면 방향과 연직 37° 이내),
  벽 모드는 수평으로 보도록. 화면에 고해상도 장수 표시. `meta.json`: `capture:"area"`, `area:{surface, hires, hires_skipped, hires_format_recommended}`.
  업로드 필드: `mode=stray` + `area_mode=1` + `area_surface=floor|wall|auto`.
- **목록·설정**: 썸네일(녹화 중 가장 선명한 프레임 `thumb.jpg`), 용량, 배지(미업로드/업로드 중/처리 중/완료/실패), 스와이프 삭제.
  설정(톱니): 서버 주소, 기본 스캔 유형·위치 입력, 녹화 뒤 자동 업로드, Wi-Fi 에서만 업로드, 백그라운드 전송(실험), 노출.
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
| 물체 모드 필드 | 현장조사 + 물체 모드일 때 `object_mode=1`. 물체를 지정했으면 `obj_center="x,y,z"`(미터, ARKit 월드 좌표 = `odometry.csv` 좌표계, 소수 4자리), `obj_radius="0.15"`(미터, 기본 0.15), `obj_coverage="0..100"`(방위 커버리지 %). 지정하지 않았으면 `obj_center` 없이 `object_mode=1` 만 (서버가 카메라 시선 교점으로 자동 계산). 서버는 구 안에서 받침면 위로 솟은 덩어리를 물체로 보고 더 좁혀 자른다 |
| 진행 페이지 | `{서버}` 의 `3dupload` 를 `3dscan` 으로 바꾼 주소 + `?job=<job_id>` — 사이트가 7단계 진행과 결과를 이어서 보여 준다 ("웹에서 진행 보기" 버튼) |
| 결과 페이지 | 같은 주소 + `?select=<scene_item_id>` (없으면 `?job=`) |

`{서버}` 기본값은 `https://kgeodata.com/app/3dupload`, 설정 화면에서 바꿀 수 있다 (UserDefaults 에 저장).
zip 은 압축하지 않고 담기만 한다(mp4·png 는 이미 압축됨). 폴더 이름이 zip 의 최상위에 들어가며 서버는 `odometry.csv` 가 있는 폴더를 찾는다.

**전송 방식** (설정 → 업로드): 기본은 iOS 의 **`URLSession`** (서버가 HTTP/2 를 협상하면 HTTP/2). 2026-10-27 실기기에서
서버가 본문을 다 받고도 클라이언트에 "네트워크 연결이 끊어졌습니다"(-1005)가 나던 문제는 서버 쪽 원인이었다
(IIS CGI 가 Python 3.14 의 SyntaxWarning 을 응답 헤더에 섞어 HTTP/2 스트림만 RST). 서버에서 고쳐졌으므로 기본은 URLSession 으로
두고, 같은 증상이 재발하면 **HTTP/1.1 직접 연결** ([Http1Uploader.swift](StrayScanner/Kgeo/Http1Uploader.swift), Network.framework, TLS 에
ALPN 을 넣지 않아 서버가 HTTP/2 를 고르지 못함)로 바꿀 수 있다. "백그라운드 (실험)" 은 화면을 꺼도 이어지지만 응답을 못 받으면
본문을 처음부터 다시 보내려 하므로 앱이 전송을 끊고 알린다.

**끊김 복구**: 연결 오류(-1005, 타임아웃, 502/503/504 등)가 나면 바로 다시 올리지 않고 `GET {서버}/find_job.py?client_id=` 를
3초 간격으로 최대 60초 물어 이 녹화의 작업이 만들어졌는지 확인한다 (IIS 는 HTTP/2 에서 본문을 다 받고 작업을 만든 뒤 응답 없이
스트림을 끊는다 — 2026-10-27 재현). 있으면 "서버가 접수했습니다" 로 그 `job_id` 의 상태 조회만 이어가고, 60초 동안 없을 때만
3·10·30초 뒤 같은 `client_id` 로 다시 보낸다 (최대 3회, 서버는 제목·zip 이름으로도 중복을 걸러 `duplicate: true` 를 돌려준다).
업로드 전에 제목·위치 좌표 등 서버가 400 을 낼 조건은 앱에서 먼저 거른다.

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
