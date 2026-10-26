//
//  ScanSetupView.swift
//  kgeoScan
//
//  녹화 전 입력 화면: 제목, 비고, 모드, 서버 주소, 현재 위치·방위 확인. (Stray Scanner 포크에 추가된 파일)
//

import SwiftUI
import CoreLocation

struct ScanSetupView: View {
    @AppStorage(KgeoDefaults.serverBaseKey) private var serverBase: String = KgeoDefaults.serverBase
    @AppStorage(KgeoDefaults.modeKey) private var modeRaw: String = ScanMode.home.rawValue
    @State private var title: String = ScanSetupView.defaultTitle()
    @State private var note: String = ""
    @State private var validationMessage: String?
    @ObservedObject private var location = LocationService.shared

    /// 입력이 끝나면 호출된다. 호출한 쪽이 녹화 화면으로 넘긴다.
    let onStart: (ScanMeta) -> Void

    var body: some View {
        Form {
            Section("스캔 정보") {
                TextField("제목", text: $title)
                TextField("비고 (선택)", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                Picker("모드", selection: $modeRaw) {
                    ForEach(ScanMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("모드는 지금은 라벨로만 저장됩니다 (meta.json, 업로드 필드 scan_mode).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("서버") {
                TextField("업로드 주소", text: $serverBase)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("upload.py / status.py 가 있는 폴더 주소")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("위치 · 방위 (녹화 버튼을 누르는 순간 기록)") {
                locationRows
            }

            if let message = validationMessage {
                Section {
                    Text(message).foregroundColor(.red)
                }
            }

            Section {
                Button(action: startTapped) {
                    HStack {
                        Spacer()
                        Label("녹화 화면으로", systemImage: "record.circle")
                            .font(.headline)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("새 스캔")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            location.start()
        }
    }

    @ViewBuilder
    private var locationRows: some View {
        if location.isDenied {
            Text("위치 권한이 꺼져 있습니다. 설정 > kgeoScan > 위치 에서 허용해 주세요. 위치가 없으면 서버가 스캔을 지도에 놓지 못합니다.")
                .foregroundColor(.red)
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } else {
            if let loc = location.location {
                LabeledContent("위도", value: String(format: "%.6f", loc.coordinate.latitude))
                LabeledContent("경도", value: String(format: "%.6f", loc.coordinate.longitude))
                LabeledContent("고도", value: loc.verticalAccuracy >= 0
                               ? String(format: "%.1f m (±%.0f)", loc.altitude, loc.verticalAccuracy) : "-")
                LabeledContent("수평 정확도", value: loc.horizontalAccuracy >= 0
                               ? String(format: "±%.0f m", loc.horizontalAccuracy) : "-")
            } else {
                HStack {
                    ProgressView()
                    Text("GPS 수신 대기 중…").foregroundColor(.secondary)
                }
            }
            if let h = location.heading {
                LabeledContent("방위", value: h.trueHeading >= 0
                               ? String(format: "%.0f° (진북)", h.trueHeading)
                               : String(format: "%.0f° (자북)", h.magneticHeading))
            } else {
                Text("나침반 대기 중…").foregroundColor(.secondary)
            }
            if let error = location.lastError {
                Text(error).font(.caption).foregroundColor(.orange)
            }
            Text("녹화 버튼을 누르는 순간 카메라가 향한 방향이 스캔의 기준 방위(heading)가 되고, 그 자리가 원점이 됩니다. 정확도가 나쁘면 잠시 기다렸다가 시작하세요.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func startTapped() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            validationMessage = "제목을 입력해 주세요."
            return
        }
        guard let endpoints = ServerEndpoints(string: serverBase) else {
            validationMessage = "서버 주소가 올바르지 않습니다. https://… 형식으로 적어 주세요."
            return
        }
        validationMessage = nil
        serverBase = endpoints.normalized
        let meta = ScanMeta(title: String(trimmedTitle.prefix(100)),
                            note: String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)),
                            mode: ScanMode(rawValue: modeRaw) ?? .home,
                            serverBase: endpoints.normalized)
        onStart(meta)
    }

    static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return "스캔 " + formatter.string(from: Date())
    }
}
