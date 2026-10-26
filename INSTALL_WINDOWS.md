# Windows 에서 kgeoScan 설치하기 (Sideloadly + 무료 Apple ID)

Mac 없이, Apple Developer Program 결제 없이 아이폰에 넣는 방법입니다. 무료 Apple ID 서명은 **7일**만 유효해서
일주일마다 같은 방법으로 다시 넣어야 합니다 (앱 데이터는 유지됩니다).

## 준비물

| 항목 | 비고 |
|---|---|
| 아이폰 | LiDAR 모델 (iPhone 12 Pro 이후의 Pro/Pro Max), iOS 16 이상 |
| USB 케이블 | 데이터 전송 되는 케이블 (충전 전용 케이블은 안 됨) |
| Apple ID | 무료 계정이면 됨. 2단계 인증이 켜져 있어야 함. 아이폰에 로그인된 그 계정을 써도 됨 |
| Sideloadly | https://sideloadly.io → Windows 64-bit 설치 |
| Apple Devices 앱 또는 iTunes | 아이폰 USB 드라이버용. Microsoft Store 의 **Apple Devices** 앱이 가장 간단. Sideloadly 가 iTunes 를 찾지 못하면 apple.com 의 iTunes(64-bit, Store 아닌 버전)를 설치 |
| kgeoScan.ipa | GitHub 저장소 **Releases → latest** 의 `kgeoScan.ipa`, 또는 **Actions → 해당 빌드 → Artifacts → kgeoScan-ipa** (zip 을 풀면 ipa) |

## 1. 아이폰 준비

1. 아이폰을 PC 에 USB 로 연결하고, 아이폰 화면의 "이 컴퓨터를 신뢰하시겠습니까?" 에서 **신뢰**를 누릅니다.
2. (iOS 16 이상) **개발자 모드**를 켭니다: 설정 → 개인정보 보호 및 보안 → 맨 아래 **개발자 모드** → 켬 → 재시동.
   이 항목이 보이지 않으면, 아래 2단계로 앱을 한 번 설치한 뒤 다시 보면 나타납니다.

## 2. Sideloadly 로 설치

1. Sideloadly 를 실행합니다. 왼쪽 위 기기 목록에 아이폰 이름이 보여야 합니다 (안 보이면 케이블·신뢰·Apple Devices 앱 확인).
2. `kgeoScan.ipa` 를 Sideloadly 창으로 드래그합니다 (또는 IPA 아이콘 클릭 → 파일 선택).
3. **Apple account** 란에 Apple ID 이메일을 넣고 **Start**.
4. 비밀번호 입력 → 아이폰/다른 Apple 기기에 뜬 **2단계 인증 코드** 6자리 입력.
5. 1~2분 뒤 "Done" 이 뜨면 아이폰 홈 화면에 kgeoScan 이 생깁니다.
6. 아이폰: 설정 → 일반 → **VPN 및 기기 관리** → "개발자 앱" 아래 내 Apple ID → **신뢰**.
7. 앱을 열 때 "개발자 모드가 필요합니다" 가 나오면 1-2 를 하고 다시 엽니다.
8. 처음 실행 시 **카메라**와 **위치** 권한을 허용합니다 (위치는 "앱을 사용하는 동안").

Sideloadly 의 Advanced Options 는 기본값 그대로 둡니다. 특히 **Bundle ID 를 바꾸지 마세요** — 바꾸면 다음 재설치 때
다른 앱으로 인식되어 녹화 데이터가 이어지지 않습니다.

## 3. 무료 계정의 제한

- **7일 서명**: 7일이 지나면 앱이 열리자마자 꺼집니다. Sideloadly 로 같은 IPA 를 다시 넣으면 됩니다 (아래 5번). 데이터는 남습니다.
- **앱 3개**: 한 Apple ID 로 동시에 서명해 둘 수 있는 앱이 3개까지입니다.
- **App ID 10개 / 7일**: 일주일에 만들 수 있는 App ID 가 10개입니다. Bundle ID 를 바꿔 가며 여러 번 설치하면 "maximum App IDs" 오류가 나고 일주일 기다려야 합니다. 같은 Bundle ID 로 재설치하는 것은 괜찮습니다.
- Push 알림·iCloud 같은 유료 기능은 못 씁니다 (이 앱은 쓰지 않습니다).

## 4. 자주 겪는 문제

| 증상 | 해결 |
|---|---|
| Sideloadly 가 "iTunes not found" / 기기 목록이 비어 있음 | Apple Devices 앱(Store) 설치 → PC 재시동. 그래도 안 되면 apple.com 의 iTunes 64-bit 설치 (Store 버전 iTunes 는 제거) |
| 로그인에서 멈추거나 "anisette" 오류 | Sideloadly 를 최신으로 업데이트. 2단계 인증 코드를 요구할 때 아이폰에서 코드를 확인 |
| "Untrusted Developer" | 설정 → 일반 → VPN 및 기기 관리 → 신뢰 |
| 앱이 바로 꺼짐 | 7일 만료 → 재설치. 또는 개발자 모드 꺼짐 |
| 카메라 화면이 검게 나옴 | 설정 → kgeoScan → 카메라 허용. LiDAR 없는 모델이면 "지원하지 않는 기기" 가 뜸 |
| 설정 화면에 "GPS 수신 대기 중" 이 계속 뜸 | 설정 → kgeoScan → 위치 → "앱을 사용하는 동안". 실내에서는 오래 걸리니 창가·실외에서 한 번 잡은 뒤 시작 |
| 업로드가 HTTP 413/500 으로 실패 | 서버 업로드 한도(1 GB)·IIS 설정 문제. 1분 녹화 ≈ 170 MB. 녹화를 짧게 나눠 시도 |
| "maximum App IDs" | 일주일 뒤 다시, 그 전엔 Bundle ID 를 바꾸지 않고 재설치만 |

## 5. 7일마다 다시 서명하기 / 새 버전 올리기

Sideloadly 실행 → 아이폰 연결 → 같은(또는 새) `kgeoScan.ipa` 드래그 → Apple ID → Start. 설치 과정은 처음과 같고,
기존 앱 위에 덮어써서 녹화 폴더와 설정은 그대로 남습니다.

같은 PC 에서 Sideloadly 를 열어 두면 트레이에서 만료일을 보여 주므로 미리 갱신할 수 있습니다.

## 6. 설치 뒤 첫 테스트 (확인 목록)

1. 앱 실행 → 카메라·위치 권한 허용 → 목록에 "새 스캔" 버튼이 보이는지.
2. 새 스캔 → 설정 화면에서 **위도·경도·정확도·방위**가 채워지는지 (창가나 실외에서 30초 정도).
3. 녹화 화면 → 위쪽에 `GPS ±Nm · 방위 N°` 라벨이 보이는지 → 빨간 버튼 → 10~20초 천천히 움직이며 녹화 → 버튼으로 종료.
4. 업로드 화면으로 자동 전환 → 1 압축 → 2 업로드(MB 진행률) → 3 서버 처리(단계 n/7 이름)가 넘어가는지.
5. "완료" 뒤 **결과 보기** → Safari 에서 https://kgeodata.com/app/3dscan/?select=… 이 열리고 지도에 새 점·3D 가 보이는지.
6. 목록으로 돌아오면 그 스캔 행에 **완료** 배지, 상세 화면에 위치·방위·작업 ID 가 보이는지.

안 되는 단계와 화면의 문구(오류 메시지)를 그대로 적어 주면 원인을 찾기 쉽습니다. 녹화 폴더는 파일 앱 → 나의 iPhone → kgeoScan
에 있고, `meta.json` 을 열어 보면 기록된 위치·업로드 상태가 들어 있습니다.

## 7. 대안

- **AltStore (AltServer for Windows)**: 같은 무료 Apple ID 방식이지만 같은 Wi-Fi 의 PC 가 7일 갱신을 자동으로 해 줍니다. 다음 단계에서 검토.
- 유료 Apple Developer Program (연 US$99) 에 가입하면 1년 서명, TestFlight 배포가 가능해지고 Mac 없이도 CI 에서 서명까지 할 수 있습니다.
