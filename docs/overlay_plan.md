# 녹화 화면 고도화 계획 — 실제 카메라 화면 + 스캔된 표면 겹쳐 보기 (Scaniverse 식)

작성 2026-10-27. 사용자 요청: (1) 녹화 중 실제 카메라 화면이 그대로 보이고, (2) 어디를 스캔했는지가 화면 위에 겹쳐 보이게.
이 문서는 계획과 난이도 정리이며 코드는 아직 바꾸지 않았다.

## 1. 지금 녹화 화면이 그리는 것 (Stray Scanner 원본 그대로)

`Helpers/CameraRenderer.swift` + `Shaders/Shaders.metal`:

- `CAMetalLayer` 두 장(xib 의 **DepthView**, **RGBView**)에 각각 화면을 꽉 채우는 사각형 하나를 그린다.
  - RGB: `frame.capturedImage`(YCbCr 두 평면)를 셰이더에서 RGB 로 바꿔 그대로 표시 (`displayTexture`).
  - Depth: `frame.sceneDepth.depthMap`(256×192)을 로그 스케일 **회색조**로 표시 (`depthFragment`, 가까울수록 밝음).
- 둘 중 **하나만** 보인다. 화면을 탭하면 전환. 기본값은 Depth (`renderMode = .depth`, xib 에서 RGBView 가 hidden).
- 겹쳐 그리기 없음, 메시 없음, 깊이 버퍼 없음. 지금 사용자가 보는 회색 화면은 이 깊이 뷰다.

→ 요구 (1) "실제 카메라 화면 그대로" 는 기본값을 RGB 로 바꾸는 **한 줄**(`renderMode` 기본값 + xib 의 hidden 플래그) 이다.

## 2. "어디를 스캔했는지" 의 데이터원

- **ARKit `sceneReconstruction = .mesh`** (LiDAR 기기 전용, `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)` 로 확인).
  ARKit 이 자체 재구성을 돌려 `ARMeshAnchor`(대략 1 m 블록 단위)를 만들고 1~2 Hz 로 갱신한다. 정점·법선·삼각형 인덱스가
  이미 `MTLBuffer` 로 제공되고(`ARMeshGeometry`), 면 분류(바닥·벽·천장·문·창·테이블…)도 옵션으로 받을 수 있다.
- 녹화 시작 때 이미 `session.run(config, options: [.resetTracking, .removeExistingAnchors])` 로 리셋하므로 메시 앵커도 비워져
  **"이번 녹화에서 찍은 곳"만** 보인다. 원하는 동작과 맞는다.
- 비권장 대안: 현재 프레임 깊이만 색칠(지금 시야만 보이고 누적이 안 됨), 자체 복셀 누적(작업량 큼, ARKit 이 이미 해 주는 일).

## 3. 구현 방식 비교

| | A. RealityKit `ARView` + `.showSceneUnderstanding` | B. SceneKit `ARSCNView` + `ARMeshAnchor`→`SCNGeometry` | C. 기존 Metal 렌더러 확장 |
|---|---|---|---|
| 내용 | Metal 뷰 자리에 `ARView` 를 넣고 `debugOptions.insert(.showSceneUnderstanding)`. 카메라 배경은 ARView 가 그린다. 세션은 `arView.session` 을 쓰고 `session.delegate` 를 지금 컨트롤러로 두어 녹화는 그대로 | 메시 앵커가 추가·갱신될 때마다 정점/인덱스 버퍼로 `SCNGeometry` 를 만들어 반투명 재질 + `fillMode = .lines` 윤곽으로 표시 | RGB 사각형 위에 메시 앵커의 `MTLBuffer` 를 직접 그림: 모델·뷰·투영 행렬(`camera.viewMatrix`, `projectionMatrix`), 깊이 첨부, 알파 블렌딩, `setTriangleFillMode(.lines)` 윤곽, 분류별 색 |
| 장점 | 코드 수십 줄, Apple 이 그려 주는 검증된 오버레이. (1)도 자동 해결 | 룩을 마음대로(파란 반투명 면 + 흰 선 = Scaniverse 와 비슷). `sceneView.session` 에 기존 세션을 넣을 수 있음 | 가장 가볍고 완전한 제어. 깊이 미리보기 뷰 유지 쉬움 |
| 단점 | 룩을 못 바꿈(Apple 디버그 룩: 색 와이어프레임). RealityKit 오버헤드. 깊이 미리보기는 따로 PiP 로 | 앵커 갱신마다 지오메트리 재생성(수십 ms, 백그라운드 큐로 완화). SceneKit 은 유지보수 모드 | 작업량 최대. 카메라 화면 회전·종횡비·뷰포트를 직접 처리 |
| 작업량 | **0.5~1일** (CI 2~4회 + 실기기 1회) | **1~2일** | **2~3일** |

추천: **A 로 먼저** 만들어 체감하고, 룩이 아쉬우면 B 로 바꾼다. 어느 쪽이든 녹화 코어(`DatasetEncoder` 와 그 아래 인코더)는 손대지 않는다.

## 4. 녹화 데이터에 미치는 영향

- **없음.** `sceneReconstruction` 을 켜도 `frame.sceneDepth`(깊이·confidence), `capturedImage`, `camera.transform/intrinsics` 는 그대로다.
  파일 구조·이름·`odometry.csv` 규약 그대로이고 서버는 아무것도 바꿀 필요가 없다.
- ARKit 메시는 녹화 파일에 넣지 않는다(서버가 자체 TSDF 융합을 한다). 나중에 원하면 `mesh.obj` 를 **추가 파일**로 선택 저장할 수 있다(서버 비교용).

## 5. 배터리·프레임 드롭

- 추가되는 비용: ARKit 메시 재구성(CPU/뉴럴엔진, 1~2 Hz) + 오버레이 렌더링(GPU, 매 프레임).
  지금 부하: HEVC 하드웨어 인코딩(가벼움), **깊이 PNG 인코딩(lodepng, CPU — 60 fps 에서 가장 무거움)**, confidence PNG, 메탈 미리보기.
- 예상: 발열·배터리 소모 **10~25% 증가**(Scaniverse 와 비슷한 체감). 60 fps 전 프레임 저장 설정에서는 CPU 가 포화돼
  `DatasetEncoder` 가 프레임을 더 자주 버릴 수 있다(인코딩 큐 세마포어 3 → 꽉 차면 드롭). 드롭은 데이터 일관성을 깨지 않는다
  (저장된 프레임만 번호를 매기고, 비디오 시간은 전체 프레임 기준).
- 완화책: (a) 녹화 fps 기본값을 30 으로(`FpsDividers` 의 2) — 서버 융합에는 충분(2~3프레임 간격도 검증됨),
  (b) 오버레이 갱신 30 Hz 제한, (c) 분류 없는 `.mesh`(`.meshWithClassification` 아님), (d) 녹화 중이 아닐 때 메시 끄기 옵션,
  (e) `ProcessInfo.thermalState` 가 `.serious` 이상이면 화면에 경고.
- 실측이 필요하다: iPhone 17 Pro 에서 5분 녹화의 배터리 % 변화와 `meta.json` 의 `saved_frames` ÷ (60 × 초) 비율.
  **지금 앱으로도 이 기준값을 잴 수 있다** — 오버레이를 넣기 전에 한 번 재 두면 비교가 된다.

## 6. 작업 단계 (A 안 기준)

1. 기본 화면을 RGB 로, 깊이 뷰는 탭 전환 유지. [0.5시간]
2. `config.sceneReconstruction = .mesh` (지원 확인 포함). [0.5시간]
3. xib 의 DepthView/RGBView 자리에 RealityKit `ARView` 추가. `arView.session` 을 녹화 세션으로 쓰고 `delegate` 를 지금 컨트롤러로.
   `debugOptions = [.showSceneUnderstanding]`, `renderOptions` 로 그림자·모션블러·HDR 끄기. 깊이 미리보기는 작은 PiP 로 축소. [반나절]
4. 녹화 시작 리셋 때 메시가 비워지는지 확인, 오버레이 on/off 버튼, 열 상태 경고. [1시간]
5. CI 빌드 → 실기기: 발열, 저장 프레임 수, 오버레이가 실제 스캔 범위와 맞는지. [반나절]

## 7. 위험

- `ARView` 가 세션을 소유한다. 지금 컨트롤러의 `ARSession()` 대신 `arView.session` 을 써야 하므로 `startSession`/`startRecording` 의
  `session` 참조를 바꾼다(작업은 작지만 녹화 흐름의 핵심이라 실기기 확인 필수).
- `.showSceneUnderstanding` 은 디버그 옵션이라 iOS 버전에 따라 룩이 달라질 수 있다. 룩이 중요하면 B.
- 메시를 켜면 ARKit 메모리가 수백 MB 늘 수 있다. 집 전체를 한 번에 길게 녹화하면 메모리 경고 가능 → 방 단위 녹화 권장(로드맵과 같음).
- 이미 설치된 앱을 새 IPA 로 덮어쓸 때 Bundle ID 가 같아야 녹화 데이터가 유지된다(INSTALL_WINDOWS.md).
