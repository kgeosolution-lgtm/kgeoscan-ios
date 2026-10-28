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
    @AppStorage(KgeoDefaults.skipPreviewKey) private var skipPreview: Bool = false
    @AppStorage(KgeoDefaults.wifiOnlyKey) private var wifiOnly: Bool = false
    @AppStorage(KgeoDefaults.uploadTransportKey) private var transportRaw: String = UploadTransport.system.rawValue
    @AppStorage(KgeoDefaults.meshColorKey) private var meshColor: String = "red"
    @AppStorage(KgeoDefaults.meshOpacityKey) private var meshOpacity: Double = 0.5
    @AppStorage(KgeoDefaults.areaStillModeKey) private var areaStillMode: String = "silent"
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
                Toggle("녹화 뒤 미리보기 없이 바로 업로드", isOn: $skipPreview)
                Text("꺼짐(기본): 촬영이 끝나면 3D 미리보기에서 [업로드] [다시 찍기] [나중에 올리기] 를 고릅니다. 켜면 미리보기를 건너뛰고 바로 업로드합니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("업로드") {
                Toggle("Wi-Fi 에서만 업로드", isOn: $wifiOnly)
                Text("켜면 셀룰러에서는 Wi-Fi 가 잡힐 때까지 기다립니다 (업로드 화면 로그에 표시).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("전송 방식", selection: $transportRaw) {
                    Text(UploadTransport.system.label).tag(UploadTransport.system.rawValue)
                    Text(UploadTransport.http1.label).tag(UploadTransport.http1.rawValue)
                    Text(UploadTransport.background.label).tag(UploadTransport.background.rawValue)
                }
                Text("기본은 iOS 의 URLSession 입니다(프록시·IPv6·인증서 처리를 시스템이 맡음). 서버의 HTTP/2 응답 문제는 2026-10-27 에 서버 쪽에서 고쳐졌고, 재발하면 'HTTP/1.1 직접 연결'로 바꿀 수 있습니다. 어느 방식이든 끊기면 서버에 작업이 생겼는지(client_id) 최대 60초 확인한 뒤에만 다시 보냅니다. 백그라운드는 화면을 꺼도 이어지지만 응답을 못 받으면 처음부터 다시 보내려 하므로 앱이 전송을 끊고 알립니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("메시 표시") {
                Picker("색", selection: $meshColor) {
                    ForEach(MeshOverlayDelegate.colorNames, id: \.key) { item in
                        Text(item.label).tag(item.key)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("불투명도")
                    Slider(value: $meshOpacity, in: 0.2...0.9, step: 0.05)
                    Text(String(format: "%.0f%%", meshOpacity * 100))
                        .font(.caption)
                        .frame(width: 40, alignment: .trailing)
                }
                Text("녹화 화면에서 스캔된 면을 덮는 색입니다. 흰 윤곽선이 함께 그려집니다. 다음 녹화 화면부터 적용됩니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("면 촬영 사진") {
                Picker("방식", selection: $areaStillMode) {
                    Text("무음 (영상 프레임)").tag("silent")
                    Text("고해상도 사진 (셔터음)").tag("shutter")
                }
                .pickerStyle(.segmented)
                Text(areaStillMode == "silent"
                     ? "무음: 높은 해상도 영상 형식으로 녹화하면서 그 프레임을 정지 사진으로 저장합니다(셔터음 없음). 쓸 형식이 없으면 자동으로 고해상도 사진(셔터음) 방식으로 찍습니다."
                     : "고해상도 사진: ARKit 정지 사진(captureHighResolutionFrame)을 씁니다. 한국판 아이폰은 찍을 때마다 셔터음이 납니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(FormatCatalog.silentStatus())
                    .font(.caption)
                    .foregroundColor(.secondary)
                NavigationLink("카메라 형식 진단") {
                    FormatDiagnosticsView()
                }
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
