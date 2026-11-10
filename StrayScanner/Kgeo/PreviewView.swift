//
//  PreviewView.swift
//  kgeoScan
//
//  촬영 뒤 미리보기: 3D 를 손가락으로 돌려 보고 [업로드] [다시 찍기] [나중에 올리기] 를 고른다.
//  굴착 기록은 색 점을 한 번 탭해 관 종류(가스·상수·하수·전력·통신·난방·모름)를 표시한다 → marks.json kind=utility.
//  목록의 녹화 상세에서도 같은 화면(버튼 없이)을 연다. (Stray Scanner 포크에 추가된 파일)
//

import SwiftUI
import SceneKit
import Network
import CoreData

/// 녹화 폴더와 그 Core Data 항목 지우기 (메인 스레드)
enum RecordingStore {
    static func delete(directory: URL) {
        let target = directory.standardizedFileURL.lastPathComponent
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            let context = appDelegate.persistentContainer.viewContext
            let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
            if let fetched = try? context.fetch(request) {
                for object in fetched {
                    guard let recording = object as? Recording,
                          recording.directoryPath()?.standardizedFileURL.lastPathComponent == target else { continue }
                    context.delete(recording)
                }
            }
            try? context.save()
        }
        try? FileManager.default.removeItem(at: directory)
        NotificationCenter.default.post(name: NSNotification.Name("sessionsChanged"), object: nil)
    }
}

/// SceneKit 3D 뷰 (메시·Object Capture 모델, Metal 을 못 쓸 때의 색 점): 한 손가락으로 돌리고 두 손가락으로 확대·이동
struct PreviewSceneView: UIViewRepresentable {
    let result: PreviewSceneResult

    func makeUIView(context: Context) -> SCNView {
        PreviewSceneView.makeView(result)
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    static func makeView(_ result: PreviewSceneResult) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = result.scene
        view.backgroundColor = UIColor(white: 0.13, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X

        let radius = max(result.radius, 0.05)
        let center = result.center
        let camera = SCNCamera()
        camera.zNear = Double(radius) * 0.01
        camera.zFar = Double(radius) * 60
        camera.fieldOfView = 50
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        if let eye = result.eye {
            // 색 점: 녹화를 시작한 자리에서 바라본다
            cameraNode.position = eye
        } else {
            cameraNode.position = SCNVector3(center.x, center.y + radius * 0.8, center.z + radius * 2.6)
        }
        cameraNode.look(at: center)
        result.scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode

        let ambient = SCNNode()
        let light = SCNLight()
        light.type = .ambient
        light.intensity = 500
        ambient.light = light
        result.scene.rootNode.addChildNode(ambient)

        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = center
        view.defaultCameraController.inertiaEnabled = true
        return view
    }
}

final class PreviewViewModel: ObservableObject {
    @Published var meta: ScanMeta?
    /// 색 점 미리보기 (영상 녹화의 기본)
    @Published var points: PreviewPointCloud?
    @Published var loadingPoints = false
    @Published var pointsReason: String?
    /// 메시 미리보기 또는 Object Capture 모델
    @Published var model: PreviewSceneResult?
    @Published var loadingModel = false
    @Published var modelReason: String?
    @Published var uploadBytes: Int64 = 0
    /// nil = 아직 모름
    @Published var onWifi: Bool?
    /// 굴착 기록: 미리보기에서 탭한 관 종류 표시 (marks.json kind=utility)
    @Published var utilityMarks: [PreviewMark] = []

    let directory: URL
    private let monitor = NWPathMonitor()
    private var waitingForPoints = false
    private var waitingForMesh = false

    var isObjcap: Bool { meta?.isObjcap == true }
    var isTrench: Bool { meta?.capture == "trench" }

    init(directory: URL) {
        self.directory = directory
        self.meta = ScanMeta.load(from: directory)
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            DispatchQueue.main.async {
                self?.onWifi = wifi
            }
        }
        monitor.start(queue: DispatchQueue(label: "kgeo.preview.network"))
    }

    deinit {
        monitor.cancel()
    }

    /// 메인 스레드에서 부른다: 메타·업로드 크기, 그리고 기본 미리보기(영상은 색 점, Object Capture 는 모델)
    func load() {
        meta = ScanMeta.load(from: directory)
        loadUtilityMarks()
        let dir = directory
        DispatchQueue.global(qos: .utility).async {
            let bytes = ZipPackager.uploadSize(of: dir)
            DispatchQueue.main.async {
                self.uploadBytes = bytes
            }
        }
        if isObjcap {
            loadModel()
        } else {
            loadPoints()
        }
    }

    /// 메인 스레드에서 부른다
    func loadPoints(force: Bool = false) {
        let dir = directory
        if PreviewBuilder.shared.isBuildingPoints(dir) {
            waitingForPoints = true
            return
        }
        guard force || (points == nil && !loadingPoints && pointsReason == nil) else { return }
        loadingPoints = true
        DispatchQueue.global(qos: .userInitiated).async {
            var result: PreviewPointCloud?
            var reason: String?
            do {
                result = try PreviewSceneLoader.loadPoints(directory: dir)
                if result == nil {
                    reason = "이 녹화에는 색 점 미리보기가 없습니다 (이 기능 이전 녹화). 위에서 '메시' 로 바꿔 보세요."
                }
            } catch {
                reason = "미리보기를 열 수 없습니다: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.loadingPoints = false
                self.points = result
                self.pointsReason = reason
            }
        }
    }

    /// 메인 스레드에서 부른다: Object Capture 모델 또는 ARKit 메시 미리보기
    func loadModel(force: Bool = false) {
        let dir = directory
        if !isObjcap && PreviewBuilder.shared.isBuilding(dir) {
            waitingForMesh = true
            return
        }
        guard force || (model == nil && !loadingModel && modelReason == nil) else { return }
        loadingModel = true
        DispatchQueue.global(qos: .userInitiated).async {
            var result: PreviewSceneResult?
            var reason: String?
            do {
                result = try PreviewSceneLoader.load(directory: dir)
                if result == nil {
                    reason = "이 녹화에는 메시 미리보기가 없습니다 (스캔된 면이 없거나 이 기능 이전 녹화)"
                }
            } catch {
                reason = "미리보기를 열 수 없습니다: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.loadingModel = false
                self.model = result
                self.modelReason = reason
            }
        }
    }

    /// 메인 스레드: marks.json 의 관 종류 표시
    func loadUtilityMarks() {
        utilityMarks = CrackMarks.read(from: directory).compactMap { mark in
            guard mark.kind == "utility", let x = mark.x, let y = mark.y, let z = mark.z else { return nil }
            return PreviewMark(id: mark.id, position: SIMD3<Float>(Float(x), Float(y), Float(z)),
                               utilityClass: UtilityClass(rawValue: mark.utilityClass ?? "") ?? .unknown)
        }
    }

    /// 미리보기에서 고른 색 점에 관 종류 표시를 더한다 (marks.json 과 meta.json trench.utility_marks)
    func addUtilityMark(at position: SIMD3<Float>, utilityClass: UtilityClass) {
        var marks = CrackMarks.read(from: directory)
        let id = (marks.map { $0.id }.max() ?? 0) + 1
        marks.append(CrackMarks.utility(id: id, at: position, utilityClass: utilityClass, t: nil, frame: nil,
                                        source: "preview"))
        saveMarks(marks)
    }

    /// 마지막 관 종류 표시를 지운다
    func removeLastUtilityMark() {
        var marks = CrackMarks.read(from: directory)
        guard let index = marks.lastIndex(where: { $0.kind == "utility" }) else { return }
        marks.remove(at: index)
        saveMarks(marks)
    }

    private func saveMarks(_ marks: [CrackMark]) {
        do {
            try CrackMarks.write(marks, to: directory)
        } catch {
            print("marks.json 저장 실패: \(error.localizedDescription)")
        }
        meta?.trench?.utilityMarks = marks.filter { $0.kind == "utility" }.count
        try? meta?.save(to: directory)
        loadUtilityMarks()
    }

    /// 미리보기 저장이 끝났을 때 (메인 스레드)
    func buildFinished() {
        if waitingForPoints && !PreviewBuilder.shared.isBuildingPoints(directory) {
            waitingForPoints = false
            loadPoints(force: true)
        }
        if waitingForMesh && !PreviewBuilder.shared.isBuilding(directory) {
            waitingForMesh = false
            loadModel(force: true)
        }
    }
}

struct PreviewView: View {
    enum Context {
        case afterCapture
        case review
    }

    @StateObject private var vm: PreviewViewModel
    @ObservedObject private var builder = PreviewBuilder.shared
    @AppStorage(KgeoDefaults.skipPreviewKey) private var skipPreview: Bool = false
    @State private var confirmRetake = false
    /// 영상 녹화: false = 색 점(기본), true = 메시
    @State private var showMesh = false
    /// 색 점 EDL 음영 (기본 켬)
    @AppStorage(KgeoDefaults.previewEDLKey) private var edlEnabled: Bool = true
    /// 굴착 기록: 탭한 색 점과 관 종류 고르기
    @State private var pickedPoint: SIMD3<Float>?
    @State private var choosingUtility = false
    let context: Context
    let onUpload: (() -> Void)?
    let onRetake: ((ScanMeta) -> Void)?
    let onLater: (() -> Void)?

    init(directory: URL, context: Context, onUpload: (() -> Void)? = nil,
         onRetake: ((ScanMeta) -> Void)? = nil, onLater: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: PreviewViewModel(directory: directory))
        self.context = context
        self.onUpload = onUpload
        self.onRetake = onRetake
        self.onLater = onLater
    }

    private var key: String { vm.directory.lastPathComponent }

    var body: some View {
        Form {
            Section {
                if !vm.isObjcap {
                    HStack(spacing: 10) {
                        Picker("표시", selection: $showMesh) {
                            Text("색 점").tag(false)
                            Text("메시").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if !showMesh {
                            Toggle(isOn: $edlEnabled) {
                                Text("음영")
                            }
                            .toggleStyle(.button)
                            .fixedSize()
                        }
                    }
                }
                viewer
                    .frame(height: 360)
                    .listRowInsets(EdgeInsets())
                if vm.isTrench && !showMesh && vm.points != nil {
                    HStack {
                        Text(vm.utilityMarks.isEmpty ? "관을 한 번 탭하면 종류를 표시합니다 (선택)"
                             : "관 종류 표시 \(vm.utilityMarks.count)개 — 더 탭해서 표시")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if !vm.utilityMarks.isEmpty {
                            Button("마지막 지우기") {
                                vm.removeLastUtilityMark()
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if let text = caption {
                    Text(text)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("촬영 요약") {
                summaryRows
            }

            Section("업로드") {
                LabeledContent("업로드 크기", value: SessionRow.formatBytes(vm.uploadBytes))
                if let wifi = vm.onWifi, !wifi, vm.uploadBytes > 50 * 1_048_576 {
                    Text("지금 Wi‑Fi 가 아닙니다. 큰 파일이니 Wi‑Fi 에서 올리는 것을 권장합니다 (설정의 'Wi‑Fi 에서만 업로드' 를 켜면 Wi‑Fi 가 잡힐 때까지 기다립니다).")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if context == .afterCapture {
                    Toggle("다음부터 미리보기 없이 바로 업로드", isOn: $skipPreview)
                }
            }

            if context == .afterCapture {
                Section {
                    Button {
                        onUpload?()
                    } label: {
                        Label("업로드", systemImage: "icloud.and.arrow.up")
                            .font(.headline)
                    }
                    Button(role: .destructive) {
                        confirmRetake = true
                    } label: {
                        Label("다시 찍기 (이 녹화 삭제)", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        onLater?()
                    } label: {
                        Label("나중에 올리기 (목록에 보관)", systemImage: "tray.and.arrow.down")
                    }
                }
            }
        }
        .navigationTitle(vm.meta?.title ?? "미리보기")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            vm.load()
        }
        .onReceive(builder.$progress) { progress in
            if progress[key] == nil {
                vm.buildFinished()
            }
        }
        .onReceive(builder.$pointsProgress) { progress in
            if progress[key] == nil {
                vm.buildFinished()
            }
        }
        .onChange(of: showMesh) { mesh in
            if mesh {
                vm.loadModel()
            } else {
                vm.loadPoints()
            }
        }
        .confirmationDialog("이 자리의 관 종류", isPresented: $choosingUtility, titleVisibility: .visible) {
            ForEach(UtilityClass.allCases, id: \.self) { item in
                Button(item.label) {
                    if let point = pickedPoint {
                        vm.addUtilityMark(at: point, utilityClass: item)
                    }
                }
            }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog("이 녹화를 지우고 같은 설정으로 다시 찍을까요?", isPresented: $confirmRetake,
                            titleVisibility: .visible) {
            Button("지우고 다시 찍기", role: .destructive) {
                let fresh = (vm.meta ?? ScanMeta(title: ScanSetupView.defaultTitle(), note: "", mode: .home,
                                                 serverBase: KgeoDefaults.storedServerBase)).freshCopy()
                RecordingStore.delete(directory: vm.directory)
                onRetake?(fresh)
            }
            Button("취소", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var viewer: some View {
        if vm.isObjcap || showMesh {
            modelViewer
        } else {
            pointsViewer
        }
    }

    @ViewBuilder
    private var pointsViewer: some View {
        if builder.pointsProgress[key] != nil {
            VStack(spacing: 10) {
                ProgressView()
                Text("색 점 미리보기 만드는 중…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(24)
        } else if let cloud = vm.points {
            PointCloudView(cloud: cloud, edl: edlEnabled, marks: vm.utilityMarks, onPick: pickHandler)
        } else if vm.loadingPoints {
            ProgressView("미리보기 여는 중…")
        } else if let failure = builder.pointsFailures[key] {
            Text("색 점 미리보기를 만들지 못했습니다: \(failure)")
                .foregroundColor(.secondary)
                .padding()
        } else {
            Text(vm.pointsReason ?? "미리보기 없음")
                .foregroundColor(.secondary)
                .padding()
        }
    }

    /// 굴착 기록이면 색 점 한 번 탭 → 관 종류 고르기
    private var pickHandler: ((SIMD3<Float>) -> Void)? {
        guard vm.isTrench else { return nil }
        return { point in
            pickedPoint = point
            choosingUtility = true
        }
    }

    @ViewBuilder
    private var modelViewer: some View {
        if !vm.isObjcap, let fraction = builder.progress[key] {
            VStack(spacing: 10) {
                ProgressView(value: fraction)
                Text(String(format: "메시 미리보기 만드는 중 %.0f%%", fraction * 100))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(24)
        } else if let result = vm.model {
            PreviewSceneView(result: result)
        } else if vm.loadingModel {
            ProgressView("미리보기 여는 중…")
        } else if let failure = builder.failures[key] {
            Text("메시 미리보기를 만들지 못했습니다: \(failure)")
                .foregroundColor(.secondary)
                .padding()
        } else {
            Text(vm.modelReason ?? "미리보기 없음")
                .foregroundColor(.secondary)
                .padding()
        }
    }

    private var caption: String? {
        if !(vm.isObjcap || showMesh) {
            guard let cloud = vm.points else { return nil }
            let shading = edlEnabled ? " · 음영(EDL)" : ""
            return "\(cloud.kind) · 점 \(cloud.pointCount)\(shading) — 한 손가락으로 돌리고 두 손가락으로 확대·이동, 두 번 탭하면 처음 시점"
        }
        guard let result = vm.model else { return nil }
        var parts = [result.kind]
        if result.triangles > 0 {
            parts.append("삼각형 \(result.triangles)")
        }
        return parts.joined(separator: " · ") + " — 한 손가락으로 돌리고 두 손가락으로 확대"
    }

    @ViewBuilder
    private var summaryRows: some View {
        if let meta = vm.meta {
            if let site = meta.site {
                LabeledContent("관리 대상", value: site.name + (site.id == nil ? " (업로드할 때 서버에 만듦)" : ""))
            }
            if meta.isObjcap {
                LabeledContent("방식", value: "고화질 사진 (Object Capture)")
                if let info = meta.objcap {
                    LabeledContent("사진", value: "\(info.images)장" + (info.posedImages.map { " · 자세 추정 \($0)장" } ?? ""))
                    LabeledContent("폰 3D 생성", value: info.reconstruction == "device"
                                   ? "완료 (\(info.detail))" : "안 함 — 서버가 사진으로 처리")
                    if let seconds = info.reconstructionSeconds {
                        LabeledContent("생성 시간", value: String(format: "%.0f초", seconds))
                    }
                    if let error = info.error {
                        Text(error).font(.caption).foregroundColor(.orange)
                    }
                }
            } else {
                if let count = vm.points?.pointCount {
                    LabeledContent("색 점", value: "\(count)")
                }
                if let trench = meta.trench {
                    LabeledContent("방식", value: "⛏ 굴착 기록")
                    LabeledContent("고해상도 사진", value: "\(trench.hires ?? 0)장"
                                   + ((trench.hiresSkipped ?? 0) > 0 ? " · 흔들려서 건너뜀 \(trench.hiresSkipped ?? 0)회" : ""))
                    LabeledContent("가장자리 왕복", value: "\(trench.passes ?? 0)구간 (양쪽 = 2)")
                    LabeledContent("주변 지면", value: (trench.startContext == true ? "시작 ✓" : "시작 ✗")
                                   + " · " + (trench.endContext == true ? "끝 ✓" : "끝 ✗"))
                    if let marks = trench.utilityMarks, marks > 0 {
                        LabeledContent("관 종류 표시", value: "\(marks)개")
                    }
                    if let rows = trench.gnssRows, rows > 0 {
                        LabeledContent("위치 기록", value: "gnss.csv \(rows)행 (폰 GPS)")
                    }
                }
                if let area = meta.area {
                    LabeledContent("방식", value: "면 촬영 (정사영상) · \(PreviewView.surfaceLabel(area.surface))")
                    if area.crackMode == true {
                        LabeledContent("균열 근접 모드", value: "켬 (30~50 cm, 사진 간격 절반)")
                    }
                    if let marks = area.crackMarks, marks > 0 {
                        LabeledContent("균열 표시", value: "\(marks)개")
                    }
                    if let source = area.hiresSource {
                        LabeledContent("정지 사진", value: (source == "video_frame" ? "무음 (영상 프레임)" : "고해상도 사진 (셔터음)")
                                       + (area.hiresFormat.map { " · \($0)" } ?? ""))
                    }
                    if let videoSize = area.videoSize {
                        LabeledContent("영상 (rgb.mp4)", value: videoSize)
                    }
                    LabeledContent("고해상도 사진", value: "\(area.hires)장" + ((area.hiresSkipped ?? 0) > 0 ? " · 흔들려서 건너뜀 \(area.hiresSkipped ?? 0)회" : ""))
                    if area.hires < 10 {
                        Text("고해상도 사진이 적습니다 — 대상 면을 더 넓게, 천천히 지그재그로 훑으면 정사영상이 좋아집니다.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                if let duration = meta.durationSeconds {
                    LabeledContent("녹화 시간", value: String(format: "%.0f초", duration))
                }
                if let frames = meta.savedFrames {
                    LabeledContent("프레임", value: "\(frames)")
                }
                if let stats = meta.captureStats {
                    if let distance = stats.avgDistance {
                        LabeledContent("평균 거리", value: String(format: "%.2f m", distance))
                    }
                    LabeledContent("최대 속도", value: String(format: "%.1f m/s", stats.maxSpeed))
                    if let confidence = stats.highConfidenceRatio {
                        LabeledContent("깊이 신뢰", value: String(format: "%.0f%%", confidence * 100))
                    }
                    if let coverage = stats.coveragePct {
                        let bands = stats.elevationBands ?? [:]
                        LabeledContent("둘레 커버리지", value: String(format: "%.0f%% (위 %.0f%%)", coverage, bands["high"] ?? 0))
                    }
                    if let ratio = stats.blurFrameRatio {
                        LabeledContent("흔들림 프레임", value: String(format: "%.0f%% (%.0f px 이상) · 중앙값 %.1f px",
                                                                  ratio * 100, stats.blurLimitPx ?? 6, stats.blurMedianPx ?? 0))
                    }
                    if let unstable = stats.trackingUnstableSeconds {
                        LabeledContent("추적 불안정", value: String(format: "%.0f초", unstable))
                    }
                    if let turns = stats.inPlaceRotations {
                        LabeledContent("제자리 회전 경고", value: "\(turns)회")
                    }
                    if let counts = stats.warningCounts, !counts.isEmpty {
                        LabeledContent("경고 시간", value: PreviewView.countsText(counts))
                    }
                    ForEach(stats.warnings, id: \.self) { warning in
                        Text("⚠︎ " + warning)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if stats.warnings.isEmpty {
                        Text("촬영 품질 기준을 통과했습니다")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            }
        } else {
            Text("meta.json 이 없습니다")
                .foregroundColor(.secondary)
        }
    }

    static func surfaceLabel(_ surface: String) -> String {
        switch surface {
        case "floor": return "바닥·트렌치"
        case "wall": return "벽"
        default: return "자동"
        }
    }

    /// meta.json 을 다시 읽으면 snake_case 사전 키가 camelCase 로 바뀌어 온다 (JSONDecoder.convertFromSnakeCase)
    private static func camelCase(_ key: String) -> String {
        let parts = key.split(separator: "_")
        guard let first = parts.first else { return key }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// 경고 샘플(10 Hz) 수를 '가까움 ≈3초' 형태로
    static func countsText(_ counts: [String: Int]) -> String {
        let labels: [(String, String)] = [
            ("tracking", "트래킹"), ("close", "가까움"), ("far", "멂"), ("no_depth", "깊이 없음"),
            ("fast", "빠름"), ("shake", "흔들림"), ("blur", "흐림"), ("low_confidence", "신뢰 낮음"),
            ("object", "물체 거리·회전"), ("tilt", "기울기"), ("in_place", "제자리 회전"),
        ]
        var parts: [String] = []
        for (key, label) in labels {
            if let count = counts[key] ?? counts[PreviewView.camelCase(key)], count > 0 {
                parts.append(String(format: "%@ ≈%.0f초", label, Double(count) / 10))
            }
        }
        return parts.isEmpty ? "없음" : parts.joined(separator: ", ")
    }
}
