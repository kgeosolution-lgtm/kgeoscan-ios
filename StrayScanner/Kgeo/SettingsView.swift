//
//  SettingsView.swift
//  kgeoScan
//
//  앱 설정: 서버 주소, 기본 스캔 유형, 업로드 방식, 촬영 노출. (Stray Scanner 포크에 추가된 파일)
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(KgeoDefaults.serverBaseKey) private var serverBase: String = KgeoDefaults.serverBase
    @AppStorage(KgeoDefaults.modeKey) private var modeRaw: String = ScanMode.home.rawValue
    @AppStorage(KgeoDefaults.autoUploadKey) private var autoUpload: Bool = true
    @AppStorage(KgeoDefaults.wifiOnlyKey) private var wifiOnly: Bool = false
    @AppStorage(KgeoDefaults.backgroundUploadKey) private var backgroundUpload: Bool = false
    @AppStorage(ExposureController.modeKey) private var exposureRaw: String = ExposureController.Mode.auto.rawValue
    @AppStorage(KgeoDefaults.locationSourceKey) private var locationSourceRaw: String = "gps"

    private var serverValid: Bool { ServerEndpoints(string: serverBase) != nil }

    var body: some View {
        Form {
            Section("서버") {
                TextField("업로드 주소", text: $serverBase)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if serverValid {
                    Text("upload.py / status.py 가 있는 폴더. 결과 페이지는 같은 서버의 /3dscan/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("주소가 올바르지 않습니다 (https://… 형식)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Button("기본값으로") {
                    serverBase = KgeoDefaults.serverBase
                }
            }

            Section("기본값") {
                Picker("스캔 유형", selection: $modeRaw) {
                    ForEach(ScanMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                Picker("위치 입력", selection: $locationSourceRaw) {
                    Text("현재 위치 (GPS)").tag("gps")
                    Text("지도에서 선택").tag("map")
                }
                Toggle("녹화가 끝나면 바로 업로드", isOn: $autoUpload)
                Text("끄면 녹화 뒤 목록으로 돌아오고, 스캔을 열어 '서버에 업로드'를 눌러 올립니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("업로드") {
                Toggle("Wi-Fi 에서만 업로드", isOn: $wifiOnly)
                Text("켜면 셀룰러에서는 Wi-Fi 가 잡힐 때까지 기다립니다 (업로드 화면 로그에 표시).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("백그라운드로 전송 (실험)", isOn: $backgroundUpload)
                Text("꺼짐(기본): 앱을 열어 둔 채 보내고, 끊기면 바로 오류를 보여 줍니다. 켜짐: iOS 가 대신 보내지만 응답을 못 받으면 처음부터 다시 보내려 하므로 앱이 전송을 끊고 알립니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("촬영") {
                Picker("노출", selection: $exposureRaw) {
                    ForEach(ExposureController.Mode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("빠른 셔터는 움직일 때 생기는 번짐(모션블러)을 줄여 사진 기반 복원에 쓸 프레임을 선명하게 합니다. 어두운 곳에서는 노이즈가 늘어나니 밝은 곳에서 쓰세요.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("녹화 화면의 '메시' 는 스캔된 면을 파란 반투명으로 보여 줍니다(표시용, 녹화 파일에는 영향 없음). 반투명·광택 표면은 LiDAR 깊이가 비어 메시에 안 나옵니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("정보") {
                LabeledContent("버전", value: KgeoDefaults.appVersion)
                Link("소스 (GitHub)", destination: URL(string: "https://github.com/kgeosolution-lgtm/kgeoscan-ios")!)
                Link("3D 스캔 지도", destination: URL(string: "https://kgeodata.com/app/3dscan/")!)
            }
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
    }
}
