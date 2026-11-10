//
//  ScanSetupView.swift
//  kgeoScan
//
//  녹화 전 입력 화면: 제목, 비고, 모드, 위치(현재 위치 또는 지도에서 선택), 관리 대상(장소, 서버 sites.py).
//  (Stray Scanner 포크에 추가된 파일)
//  서버 주소·업로드·노출 설정은 설정 화면(SettingsView)에 있다.
//

import SwiftUI
import CoreLocation

struct ScanSetupView: View {
    @AppStorage(KgeoDefaults.serverBaseKey) private var serverBase: String = KgeoDefaults.serverBase
    @AppStorage(KgeoDefaults.modeKey) private var modeRaw: String = ScanMode.home.rawValue
    @AppStorage(KgeoDefaults.locationSourceKey) private var locationSourceRaw: String = "gps"
    @AppStorage(ExposureController.modeKey) private var exposureRaw: String = ExposureController.Mode.auto.rawValue
    @AppStorage(KgeoDefaults.captureMethodKey) private var captureMethod: String = "objcap"
    @AppStorage(KgeoDefaults.surveyStyleKey) private var surveyStyle: String = "object"
    @AppStorage(KgeoDefaults.areaSurfaceKey) private var areaSurface: String = "auto"
    @AppStorage(KgeoDefaults.areaCrackModeKey) private var areaCrackMode: Bool = false
    @State private var title: String = ScanSetupView.defaultTitle()
    @State private var note: String = ""
    @State private var validationMessage: String?
    @State private var pickedCoordinate: CLLocationCoordinate2D?
    @State private var manualHeadingText: String = ""
    @ObservedObject private var location = LocationService.shared
    // 관리 대상(장소): none | nearby (근처 장소 고르기) | new (새 장소 만들기). 기본 없음
    @State private var siteChoice = "none"
    @State private var nearbySites: [SiteSummary] = []
    @State private var loadingSites = false
    @State private var siteError: String?
    @State private var selectedSiteId: String?
    /// 근처 장소를 못 불러왔을 때 직접 적는 이름 (업로드할 때 서버에 만든다)
    @State private var manualSiteName = ""
    @State private var newSiteName = ""
    @State private var newSiteNote = ""
    @State private var creatingSite = false
    @State private var createdSite: SiteRef?
    @State private var createMessage: String?

    /// 입력이 끝나면 호출된다. 호출한 쪽이 녹화 화면으로 넘긴다.
    let onStart: (ScanMeta) -> Void

    var body: some View {
        Form {
            Section("스캔 정보") {
                TextField("제목", text: $title)
                TextField("비고 (선택)", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                Picker("모드", selection: topModeBinding) {
                    Text(ScanMode.home.label).tag(ScanMode.home.rawValue)
                    Text(ScanMode.survey.label).tag(ScanMode.survey.rawValue)
                    Text("⛏ 굴착 기록").tag("trench")
                }
                .pickerStyle(.segmented)
                Text(modeDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if isTrench {
                    trenchRows
                }
                if modeRaw == ScanMode.survey.rawValue && !isTrench {
                    Picker("촬영 대상", selection: $surveyStyle) {
                        Text("물체 360°").tag("object")
                        Text("면 (정사영상)").tag("area")
                        Text("일반").tag("plain")
                    }
                    .pickerStyle(.segmented)
                    if surveyStyle == "area" {
                        Picker("대상 면", selection: $areaSurface) {
                            Text("바닥·트렌치").tag("floor")
                            Text("벽").tag("wall")
                            Text("자동").tag("auto")
                        }
                        .pickerStyle(.segmented)
                        Text(areaDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Toggle("균열 근접 모드", isOn: $areaCrackMode)
                        if areaCrackMode {
                            Text("벽에서 30~50 cm 로 가까이 찍어 서버가 균열 폭을 잽니다. 화면 위 오른쪽에 예상 해상도(mm/px)가 0.25 이하면 녹색, 0.4 이하 황색, 넘으면 적색으로 나옵니다. 사진은 6 cm 마다(일반의 절반) 흔들림이 아주 작을 때만 찍히니, 조금 옮기고 잠깐 멈추기를 반복하세요 (찍힐 때 가볍게 진동). 설정의 '빠른 셔터' 를 함께 쓰면 더 선명합니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if surveyStyle == "plain" {
                        Text("일반 영상: 물체 자르기나 정사영상 없이 LiDAR 영상·깊이만 기록합니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if surveyStyle == "object" {
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

            siteSection

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
        switch siteChoice {
        case "nearby":
            if let id = selectedSiteId, let site = nearbySites.first(where: { $0.siteId == id }) {
                meta.site = site.ref
            } else {
                let name = manualSiteName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    validationMessage = "관리 대상을 목록에서 고르거나 이름을 적어 주세요 (없으면 '없음')."
                    return
                }
                meta.site = SiteRef(id: nil, name: String(name.prefix(100)))
            }
        case "new":
            let name = newSiteName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                validationMessage = "새 장소 이름을 적어 주세요 (없으면 '없음')."
                return
            }
            if let created = createdSite {
                meta.site = created
            } else {
                let note = newSiteNote.trimmingCharacters(in: .whitespacesAndNewlines)
                meta.site = SiteRef(id: nil, name: String(name.prefix(100)), note: note.isEmpty ? nil : String(note.prefix(300)))
            }
        default:
            meta.site = nil
        }
        let style = meta.mode == .survey ? surveyStyle : "plain"
        meta.objectMode = style == "object"
        if style == "area" {
            meta.capture = "area"
            meta.area = AreaInfo(surface: areaSurface, hires: 0, crackMode: areaCrackMode ? true : nil)
        } else if style == "trench" {
            // 굴착 기록: scan_type=survey + trench_mode=1, 고해상도 사진은 면 촬영과 같은 방식
            meta.capture = "trench"
            meta.trench = TrenchInfo()
        } else {
            let useObjectCapture = meta.objectMode == true && captureMethod == "objcap" && ObjcapSupport.isAvailable
            meta.capture = useObjectCapture ? "objcap" : "video"
        }
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

    // MARK: - 굴착 기록

    /// 맨 위 모드: 홈스캔 | 현장조사 | 굴착 기록. 굴착은 현장조사(scan_type=survey)의 촬영 대상 trench 로 저장한다
    private var topModeBinding: Binding<String> {
        Binding(
            get: { isTrench ? "trench" : modeRaw },
            set: { value in
                if value == "trench" {
                    modeRaw = ScanMode.survey.rawValue
                    surveyStyle = "trench"
                } else {
                    if surveyStyle == "trench" {
                        surveyStyle = "object"
                    }
                    modeRaw = value
                }
            }
        )
    }

    private var isTrench: Bool {
        modeRaw == ScanMode.survey.rawValue && surveyStyle == "trench"
    }

    private var modeDescription: String {
        if isTrench {
            return "굴착 기록: 되메우기 전에 드러난 배관·케이블을 찍으면 서버가 관의 위치·직경·깊이(지표~관 윗면)·종류를 뽑아 3D·서류·지도로 남깁니다. 트렌치 가장자리를 따라 양쪽을 왕복하며(2~5분) 0.5~3 m 거리로 찍고, 시작과 끝에는 주변 지면·연석·맨홀이 3~5 m 들어가게 찍습니다(원지반·지도 맞춤용)."
        }
        return modeRaw == ScanMode.survey.rawValue
            ? "현장조사: 물체(360°), 면(정사영상 — 트렌치·벽 균열·바닥), 일반 영상 중에서 고릅니다. 반투명·광택 표면은 LiDAR 에 안 잡힙니다."
            : "홈스캔: 벽과 바닥을 0.3~3 m 거리에서 천천히 훑습니다. 방 단위로 나눠 찍는 것이 좋습니다."
    }

    @ViewBuilder
    private var trenchRows: some View {
        Label("트렌치 안에 들어가지 마세요. 가장자리에서 찍고, 깊으면 셀카봉을 쓰세요.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(.orange)
        Text("• 가장자리 모서리에 기준 표식(AprilTag 스티커) 3~4개를 붙이세요 — 서버가 가설기준점·축척으로 씁니다\n• 물이 고였으면 빼고 찍으세요\n• 폰은 트렌치 안쪽으로 30~45° 기울여 반대쪽 벽과 바닥이 보이게\n• 녹화 중 관을 탭하면 종류(가스·상수·하수·전력·통신·난방)를 표시합니다\n• 약 1 m 마다 4K 무음 사진이 자동으로 찍힙니다\n• RTK 수신기(Emlid Reach RX2·Bad Elf Flex 등 MFi)를 연결하면 위치가 cm 급으로 기록되고 화면에 RTK 가 뜹니다")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    // MARK: - 관리 대상 (장소)

    private var siteSection: some View {
        Section("관리 대상 (선택)") {
            Picker("관리 대상", selection: $siteChoice) {
                Text("없음").tag("none")
                Text("근처 장소").tag("nearby")
                Text("새 장소").tag("new")
            }
            .pickerStyle(.segmented)
            if siteChoice == "nearby" {
                nearbySiteRows
            } else if siteChoice == "new" {
                newSiteRows
            }
            if siteChoice != "none" {
                Text("같은 벽·구역을 날짜별로 다시 찍어 위험요소 변화를 비교합니다. 녹화 화면 위 왼쪽에 지난 점검 사진이 작게 뜨니 같은 곳·같은 방향에서 찍고, 지난번에 붙인 표식이 함께 찍히게 해 주세요.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onChange(of: siteChoice) { choice in
            if choice == "nearby" && nearbySites.isEmpty && !loadingSites {
                loadNearbySites()
            }
        }
        .onChange(of: newSiteName) { _ in
            // 이름을 고치면 앞서 서버에 만든 장소와 다르다
            createdSite = nil
            createMessage = nil
        }
    }

    @ViewBuilder
    private var nearbySiteRows: some View {
        if loadingSites {
            HStack {
                ProgressView()
                Text("근처 장소를 찾는 중…").foregroundColor(.secondary)
            }
        } else if let error = siteError {
            Text("근처 장소를 불러오지 못했습니다: \(error)")
                .font(.caption)
                .foregroundColor(.orange)
            TextField("장소 이름 직접 입력", text: $manualSiteName)
            Text("이름만 저장해 두고 업로드할 때 서버에 장소를 만듭니다.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if nearbySites.isEmpty {
            Text("반경 \(Int(CaptureTuning.siteSearchRadius)) m 안에 등록된 장소가 없습니다. '새 장소' 에서 만드세요.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            ForEach(nearbySites) { site in
                Button {
                    selectedSiteId = site.siteId
                } label: {
                    siteRow(site)
                }
                .buttonStyle(.plain)
            }
        }
        Button {
            loadNearbySites()
        } label: {
            Label("다시 찾기", systemImage: "arrow.clockwise")
        }
        .disabled(loadingSites)
    }

    private func siteRow(_ site: SiteSummary) -> some View {
        HStack(spacing: 10) {
            siteThumbnail(site)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(siteDetail(site))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if selectedSiteId == site.siteId {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func siteThumbnail(_ site: SiteSummary) -> some View {
        if let url = SiteClient.thumbURL(site.lastThumbUrl, endpoints: ServerEndpoints(string: serverBase)) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.2)
            }
            .frame(width: 44, height: 44)
            .clipped()
            .cornerRadius(6)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.2))
                Image(systemName: "mappin.and.ellipse").foregroundColor(.secondary)
            }
            .frame(width: 44, height: 44)
        }
    }

    /// "12 m · 점검 3회 · 마지막 2026-11-09"
    private func siteDetail(_ site: SiteSummary) -> String {
        var parts: [String] = []
        if let distance = site.distanceM {
            parts.append(distance < 1000 ? String(format: "%.0f m", distance) : String(format: "%.1f km", distance / 1000))
        }
        parts.append("점검 \(site.scans ?? 0)회")
        if let day = site.lastScanDay {
            parts.append("마지막 " + day)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var newSiteRows: some View {
        TextField("장소 이름 (예: 본관 B1 북벽)", text: $newSiteName)
        TextField("메모 (선택)", text: $newSiteNote)
        Button {
            createSiteTapped()
        } label: {
            if creatingSite {
                HStack {
                    ProgressView()
                    Text("만드는 중…")
                }
            } else {
                Label(createdSite == nil ? "지금 서버에 만들기" : "서버에 만들었습니다", systemImage: createdSite == nil ? "plus.circle" : "checkmark.circle")
            }
        }
        .disabled(creatingSite || createdSite != nil
                  || newSiteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let message = createMessage {
            Text(message)
                .font(.caption)
                .foregroundColor(createdSite == nil ? .orange : .secondary)
        }
        Text("만들지 않고 녹화해도 이름은 저장되고, 업로드할 때 서버에 만듭니다. 위치는 지금 GPS(또는 지도에서 고른 점)를 씁니다.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    /// 장소 찾기·만들기에 쓸 좌표: 지도에서 고른 점, 아니면 지금 GPS
    private var siteCoordinate: CLLocationCoordinate2D? {
        if locationSourceRaw == "map", let picked = pickedCoordinate {
            return picked
        }
        return location.location?.coordinate
    }

    private func loadNearbySites() {
        guard let endpoints = ServerEndpoints(string: serverBase) else {
            siteError = "서버 주소가 올바르지 않습니다"
            return
        }
        guard let coordinate = siteCoordinate else {
            siteError = "위치를 아직 모릅니다 — GPS 가 잡힌 뒤 '다시 찾기' 를 누르세요"
            return
        }
        loadingSites = true
        siteError = nil
        Task {
            do {
                let sites = try await SiteClient.nearby(endpoints: endpoints, lat: coordinate.latitude,
                                                        lon: coordinate.longitude)
                nearbySites = sites
                if let selected = selectedSiteId, !sites.contains(where: { $0.siteId == selected }) {
                    selectedSiteId = nil
                }
            } catch {
                siteError = SiteClient.describe(error)
            }
            loadingSites = false
        }
    }

    private func createSiteTapped() {
        let name = newSiteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let endpoints = ServerEndpoints(string: serverBase) else { return }
        let note = newSiteNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinate = siteCoordinate
        creatingSite = true
        createMessage = nil
        Task {
            do {
                var site = try await SiteClient.create(endpoints: endpoints, name: String(name.prefix(100)),
                                                       lat: coordinate?.latitude, lon: coordinate?.longitude,
                                                       note: String(note.prefix(300)))
                site.note = note.isEmpty ? nil : String(note.prefix(300))
                createdSite = site
                createMessage = "서버에 '\(site.name)' 장소를 만들었습니다 (\(site.id ?? "-"))"
            } catch {
                createdSite = nil
                createMessage = "지금은 만들 수 없습니다 (\(SiteClient.describe(error))). 이름만 저장해 두고 업로드할 때 만듭니다."
            }
            creatingSite = false
        }
    }

    private var areaDescription: String {
        let common = " 녹화하는 동안 12 cm 움직이거나 10° 돌 때마다 고해상도 사진(최대 200장)이 자동으로 찍혀, 서버가 정사영상(위·정면에서 본 실측 사진)을 만듭니다. 대상에서 40 cm~1.2 m 거리로 천천히 지그재그로 겹치게 훑으세요. 녹화 중 균열을 탭하면 위치가 표시됩니다(길게 누르면 선). 사진 방식(무음/셔터음)은 설정에서 고릅니다."
        switch areaSurface {
        case "floor":
            return "바닥·트렌치: 폰을 아래로 향하게 기울여 위에서 내려다봅니다." + common
        case "wall":
            return "벽: 폰을 세워 벽을 정면으로 봅니다." + common
        default:
            return "자동: 방향 안내 없이 찍고 서버가 면을 찾습니다." + common
        }
    }

    static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return "스캔 " + formatter.string(from: Date())
    }
}
