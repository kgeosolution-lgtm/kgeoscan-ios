//
//  ScanSetupView.swift
//  kgeoScan
//
//  녹화 전 입력 화면: 제목, 비고, 모드, 위치(현재 위치 또는 지도에서 선택). (Stray Scanner 포크에 추가된 파일)
//  서버 주소·업로드·노출 설정은 설정 화면(SettingsView)에 있다.
//

import SwiftUI
import CoreLocation

struct ScanSetupView: View {
    @AppStorage(KgeoDefaults.serverBaseKey) private var serverBase: String = KgeoDefaults.serverBase
    @AppStorage(KgeoDefaults.modeKey) private var modeRaw: String = ScanMode.home.rawValue
    @AppStorage(KgeoDefaults.locationSourceKey) private var locationSourceRaw: String = "gps"
    @AppStorage(ExposureController.modeKey) private var exposureRaw: String = ExposureController.Mode.auto.rawValue
    @AppStorage(KgeoDefaults.objectModeKey) private var objectMode: Bool = true
    @AppStorage(KgeoDefaults.captureMethodKey) private var captureMethod: String = "objcap"
    @State private var title: String = ScanSetupView.defaultTitle()
    @State private var note: String = ""
    @State private var validationMessage: String?
    @State private var pickedCoordinate: CLLocationCoordinate2D?
    @State private var manualHeadingText: String = ""
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
                Text(modeRaw == ScanMode.survey.rawValue
                     ? "현장조사: 물체에서 40~80 cm 떨어져 천천히 한 바퀴(20~30초). 반투명·광택 표면은 LiDAR 에 안 잡힙니다."
                     : "홈스캔: 벽과 바닥을 0.3~3 m 거리에서 천천히 훑습니다. 방 단위로 나눠 찍는 것이 좋습니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if modeRaw == ScanMode.survey.rawValue {
                    Toggle("물체 모드 (소형 물체 360° 촬영)", isOn: $objectMode)
                    if objectMode {
                        if ObjcapSupport.isAvailable {
                            Picker("촬영 방식", selection: $captureMethod) {
                                Text("고화질 사진").tag("objcap")
                                Text("영상 (LiDAR)").tag("video")
                            }
                            .pickerStyle(.segmented)
                            Text(captureMethod == "objcap"
                                 ? "Apple Object Capture: 물체 둘레를 2~3바퀴 돌면 사진을 자동으로 찍고, 폰에서 3D 모델(reduced 품질)을 만든 뒤 사진·카메라 위치와 함께 올립니다. 서버는 사진으로 더 높은 품질을 만들 수 있습니다. 촬영 뒤 생성에 몇 분 걸립니다."
                                 : "영상 방식: 녹화 화면에서 물체를 탭하면 자를 영역(반투명 구)이 표시되고, 둘레를 얼마나 돌았는지 링 게이지로 보여 줍니다. 서버는 그 영역만 잘라 복원합니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("이 기기(또는 iOS 버전)는 Object Capture 를 지원하지 않아 영상 방식으로 찍습니다. 녹화 화면에서 물체를 탭하면 자를 영역이 표시됩니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section("위치 · 방위") {
                Picker("위치 입력", selection: $locationSourceRaw) {
                    Text("현재 위치 (GPS)").tag("gps")
                    Text("지도에서 선택").tag("map")
                }
                .pickerStyle(.segmented)
                if locationSourceRaw == "map" {
                    mapRows
                } else {
                    gpsRows
                }
                headingRow
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
                Text("서버: \(serverBase) · 노출: \(ExposureController.currentMode.label) — 설정에서 변경")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("새 스캔")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            location.start()
        }
    }

    // MARK: - 위치 입력

    @ViewBuilder
    private var gpsRows: some View {
        if location.isDenied {
            Text("위치 권한이 꺼져 있습니다. 설정 > kgeoScan > 위치 에서 허용하거나 '지도에서 선택'을 쓰세요.")
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
                HStack {
                    Text("수평 정확도")
                    Spacer()
                    Text(loc.horizontalAccuracy >= 0 ? String(format: "±%.0f m", loc.horizontalAccuracy) : "-")
                        .foregroundColor(loc.horizontalAccuracy > 30 ? .orange : .secondary)
                }
                if loc.horizontalAccuracy > 30 {
                    Text("정확도가 낮습니다. 창가·실외에서 잠시 기다리거나 '지도에서 선택'을 쓰세요.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else {
                HStack {
                    ProgressView()
                    Text("GPS 수신 대기 중…").foregroundColor(.secondary)
                }
            }
            Button {
                location.restart()
            } label: {
                Label("다시 잡기", systemImage: "location.circle")
            }
            if let error = location.lastError {
                Text(error).font(.caption).foregroundColor(.orange)
            }
            Text("녹화 버튼을 누르는 순간의 GPS 가 스캔 원점이 됩니다.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var mapRows: some View {
        MapPickerView(coordinate: $pickedCoordinate, initialCenter: location.location?.coordinate)
            .frame(height: 280)
            .cornerRadius(8)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        if let c = pickedCoordinate {
            LabeledContent("선택한 위치", value: String(format: "%.6f, %.6f", c.latitude, c.longitude))
        } else {
            Text("지도를 탭해 스캔 위치를 찍으세요. 핀은 끌어서 옮길 수 있습니다.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        Button {
            pickedCoordinate = location.location?.coordinate
        } label: {
            Label("현재 위치로 핀 옮기기", systemImage: "location.fill")
        }
        .disabled(location.location == nil)
    }

    @ViewBuilder
    private var headingRow: some View {
        if let h = location.heading {
            LabeledContent("나침반 방위", value: h.trueHeading >= 0
                           ? String(format: "%.0f° (진북)", h.trueHeading)
                           : String(format: "%.0f° (자북)", h.magneticHeading))
        } else {
            Text("나침반 대기 중…").foregroundColor(.secondary)
        }
        if locationSourceRaw == "map" {
            TextField("방위 직접 입력 (도, 비우면 녹화 시작 때 나침반)", text: $manualHeadingText)
                .keyboardType(.decimalPad)
        }
        Text("녹화 버튼을 누르는 순간 카메라가 향한 방향이 스캔의 기준 방위(heading)가 됩니다.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private func startTapped() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            validationMessage = "제목을 입력해 주세요."
            return
        }
        guard let endpoints = ServerEndpoints(string: serverBase) else {
            validationMessage = "서버 주소가 올바르지 않습니다. 설정에서 https://… 형식으로 적어 주세요."
            return
        }
        var meta = ScanMeta(title: String(trimmedTitle.prefix(100)),
                            note: String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)),
                            mode: ScanMode(rawValue: modeRaw) ?? .home,
                            serverBase: endpoints.normalized)
        meta.locationSource = locationSourceRaw
        meta.objectMode = (meta.mode == .survey) && objectMode
        let useObjectCapture = meta.objectMode == true && captureMethod == "objcap" && ObjcapSupport.isAvailable
        meta.capture = useObjectCapture ? "objcap" : "video"
        if locationSourceRaw == "map" {
            guard let c = pickedCoordinate else {
                validationMessage = "지도에서 스캔 위치를 찍어 주세요."
                return
            }
            var manual = GeoFix(lat: c.latitude, lon: c.longitude, fixTime: Date())
            let headingText = manualHeadingText.trimmingCharacters(in: .whitespaces)
            if !headingText.isEmpty {
                guard let heading = Double(headingText), heading >= 0, heading < 360 else {
                    validationMessage = "방위는 0~359 사이의 숫자로 적어 주세요."
                    return
                }
                manual.trueHeading = heading
            }
            meta.manualFix = manual
        }
        validationMessage = nil
        onStart(meta)
    }

    static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return "스캔 " + formatter.string(from: Date())
    }
}
