//
//  ObjectCaptureFlow.swift
//  kgeoScan
//
//  물체 모드 고화질 촬영: Apple Object Capture (iOS 17+, LiDAR 기기)
//  1) ObjectCaptureSession + ObjectCaptureView 로 사진을 자동 촬영 (heic/), 한국어 안내와 '다음 바퀴' 진행
//  2) PhotogrammetrySession 으로 폰에서 3D 모델 생성 → model/ (OBJ + MTL + 텍스처). iOS 는 detail .reduced 만 지원한다
//  3) 사진을 업로드용 JPEG(images/, 긴 변 최대 4032, 품질 0.85, 센서 방향 그대로)로 바꾸고 poses.json, thumb.jpg, meta.json 작성
//  업로드 zip: model/, images/, poses.json, thumb.jpg, meta.json (heic/, checkpoint/, preview/ 는 빠진다). 필드 mode=objcap.
//  (Stray Scanner 포크에 추가된 파일)
//

import SwiftUI
import RealityKit
import CryptoKit
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import CoreData
import simd

/// Object Capture 를 쓸 수 있는 기기·OS 인지
enum ObjcapSupport {
    @MainActor static var isAvailable: Bool {
        if #available(iOS 17.0, *) {
            return ObjectCaptureSession.isSupported
        }
        return false
    }
}

/// iOS 버전에 따라 Object Capture 화면 또는 안내문
struct ObjcapRouteView: View {
    let meta: ScanMeta
    let onFinished: (URL) -> Void
    let onCancel: () -> Void

    var body: some View {
        if #available(iOS 17.0, *) {
            ObjectCaptureFlowView(meta: meta, onFinished: onFinished, onCancel: onCancel)
        } else {
            Text("Object Capture 는 iOS 17 이상에서 쓸 수 있습니다. 새 스캔에서 '영상' 방식을 고르세요.")
                .padding()
        }
    }
}

// MARK: - 모델

@available(iOS 17.0, *)
@MainActor
final class ObjcapModel: ObservableObject {
    enum Phase: Equatable {
        case capture
        case reconstructing(Double)
        case exporting(Double)
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .capture
    @Published private(set) var session: ObjectCaptureSession?
    @Published private(set) var passCount = 1
    @Published private(set) var detail = ""

    private(set) var meta: ScanMeta
    let directory: URL
    var onFinished: ((URL) -> Void)?
    private var started = false
    private var cancelled = false
    private var stateTask: Task<Void, Never>?
    private var captureStartedAt: Date?
    private var captureEndedAt: Date?
    private var geoFix: GeoFix?
    /// ARKit 광각 카메라 내부 파라미터 (사진 해상도로 환산해 poses.json 에 쓴다)
    private var arkitIntrinsics: CameraIntrinsics?

    var heicDirectory: URL { directory.appendingPathComponent("heic", isDirectory: true) }
    var checkpointDirectory: URL { directory.appendingPathComponent("checkpoint", isDirectory: true) }
    var modelDirectory: URL { directory.appendingPathComponent("model", isDirectory: true) }
    var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    init(meta: ScanMeta) {
        self.meta = meta
        self.directory = ObjcapModel.makeDirectory()
    }

    /// Stray 와 같은 방식의 10자리 폴더 이름 (문서 폴더 아래)
    static func makeDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var hasher = SHA256()
        hasher.update(data: Data(UUID().uuidString.utf8))
        let name = hasher.finalize().prefix(5).map { String(format: "%02x", $0) }.joined()
        return documents.appendingPathComponent(name, isDirectory: true)
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            for folder in [heicDirectory, checkpointDirectory, modelDirectory, imagesDirectory] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        } catch {
            phase = .failed("폴더를 만들 수 없습니다: \(error.localizedDescription)")
            return
        }
        LocationService.shared.start()
        // 이 기기의 ARKit 내부 파라미터가 없으면 Object Capture 전에 잠깐 읽어 둔다 (한 번만)
        if let cached = CameraIntrinsics.cached() {
            arkitIntrinsics = cached
            startCaptureSession()
            return
        }
        detail = "카메라 보정값 확인 중…"
        Task { [weak self] in
            let measured = await IntrinsicsProbe.measure()
            guard let self = self, !self.cancelled else { return }
            if let measured = measured {
                CameraIntrinsics.store(measured)
                self.arkitIntrinsics = measured
            }
            self.detail = ""
            try? await Task.sleep(nanoseconds: 500_000_000)   // ARSession 이 카메라를 놓을 시간
            guard !self.cancelled else { return }
            self.startCaptureSession()
        }
    }

    private func startCaptureSession() {
        guard !cancelled, session == nil else { return }
        let newSession = ObjectCaptureSession()
        var configuration = ObjectCaptureSession.Configuration()
        configuration.checkpointDirectory = checkpointDirectory
        configuration.isOverCaptureEnabled = false
        newSession.start(imagesDirectory: heicDirectory, configuration: configuration)
        session = newSession
        stateTask = Task { [weak self] in
            for await state in newSession.stateUpdates {
                self?.handle(state)
            }
        }
    }

    private func handle(_ state: ObjectCaptureSession.CaptureState) {
        guard !cancelled else { return }
        switch state {
        case .capturing:
            if captureStartedAt == nil {
                captureStartedAt = Date()
                geoFix = LocationService.shared.fix(for: meta)
            }
        case .completed:
            captureEndedAt = Date()
            session = nil                    // 카메라·메모리를 놓아준 뒤 3D 생성
            stateTask?.cancel()
            Task { await self.process() }
        case .failed(let error):
            session = nil
            stateTask?.cancel()
            phase = .failed("촬영 세션이 멈췄습니다: \(error.localizedDescription)")
        default:
            break
        }
    }

    /// 한 바퀴를 마친 뒤 다음 바퀴 (높이를 바꿔서 / 물체를 뒤집어서)
    func nextPass(flip: Bool) {
        guard let session = session else { return }
        if flip {
            session.beginNewScanPassAfterFlip()
        } else {
            session.beginNewScanPass()
        }
        passCount += 1
    }

    func finishCapture() {
        session?.finish()
    }

    /// 촬영을 버리고 폴더를 지운다
    func cancel() {
        cancelled = true
        session?.cancel()
        session = nil
        stateTask?.cancel()
        let folder = directory
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: 촬영 뒤 처리

    private func process() async {
        guard !cancelled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        let reconstructionStart = Date()
        var info = ObjcapInfo(detail: "reduced", images: 0, reconstruction: "none")
        info.passes = passCount
        var poses: PhotogrammetrySession.Poses?
        if PhotogrammetrySession.isSupported {
            phase = .reconstructing(0)
            detail = "사진에서 3D 모델을 만드는 중 (폰 안에서, reduced 품질)"
            let outcome = await reconstruct()
            poses = outcome.poses
            info.error = outcome.error
            if ObjcapExporter.hasModel(in: modelDirectory) {
                info.reconstruction = "device"
            }
        } else {
            info.error = "이 기기는 폰 안의 3D 생성을 지원하지 않습니다 — 사진과 위치만 올립니다"
        }
        info.reconstructionSeconds = Date().timeIntervalSince(reconstructionStart)
        guard !cancelled else { return }

        phase = .exporting(0)
        detail = "사진을 업로드용 JPEG 로 바꾸는 중"
        let heic = heicDirectory
        let images = imagesDirectory
        let root = directory
        let estimatedPoses = poses
        let cameraIntrinsics = arkitIntrinsics
        let export = await Task.detached(priority: .userInitiated) { () -> ObjcapExportResult in
            ObjcapExporter.export(heicDirectory: heic, imagesDirectory: images, root: root, poses: estimatedPoses,
                                  arkit: cameraIntrinsics) { fraction in
                Task { @MainActor [weak self] in
                    self?.phase = .exporting(fraction)
                }
            }
        }.value
        info.images = export.images
        info.posedImages = export.posedImages
        info.intrinsics = export.intrinsicsSource
        guard !cancelled else { return }

        writeMeta(info: info, thumbWritten: export.thumbWritten)
        saveRecording()
        phase = .done
        detail = ""
        onFinished?(directory)
    }

    /// PhotogrammetrySession: model/ 에 OBJ, 그리고 사진별 카메라 자세
    private func reconstruct() async -> (poses: PhotogrammetrySession.Poses?, error: String?) {
        var configuration = PhotogrammetrySession.Configuration()
        configuration.checkpointDirectory = checkpointDirectory
        let photogrammetry: PhotogrammetrySession
        do {
            photogrammetry = try PhotogrammetrySession(input: heicDirectory, configuration: configuration)
            try photogrammetry.process(requests: [.modelFile(url: modelDirectory), .poses])
        } catch {
            return (nil, "3D 생성을 시작하지 못했습니다: \(error.localizedDescription)")
        }
        var poses: PhotogrammetrySession.Poses?
        var errors: [String] = []
        do {
            outputLoop: for try await output in photogrammetry.outputs {
                switch output {
                case .requestProgress(let request, fractionComplete: let fraction):
                    if case .modelFile = request {
                        phase = .reconstructing(fraction)
                    }
                case .requestComplete(_, let result):
                    if case .poses(let estimated) = result {
                        poses = estimated
                    }
                case .requestError(let request, let error):
                    if case .modelFile = request {
                        errors.append("3D 모델 생성 실패: \(error.localizedDescription)")
                    } else {
                        errors.append("카메라 자세 추정 실패: \(error.localizedDescription)")
                    }
                case .processingComplete:
                    break outputLoop
                case .processingCancelled:
                    errors.append("3D 생성이 취소됐습니다")
                    break outputLoop
                case .automaticDownsampling:
                    detail = "메모리가 모자라 사진 해상도를 줄여서 처리 중"
                default:
                    break
                }
            }
        } catch {
            errors.append("3D 생성 중 오류: \(error.localizedDescription)")
        }
        return (poses, errors.isEmpty ? nil : errors.joined(separator: " / "))
    }

    private func writeMeta(info: ObjcapInfo, thumbWritten: Bool) {
        var updated = meta
        updated.capture = "objcap"
        updated.objcap = info
        updated.mode = .survey
        updated.objectMode = true
        updated.createdAt = captureStartedAt ?? Date()
        if let start = captureStartedAt, let end = captureEndedAt {
            updated.durationSeconds = end.timeIntervalSince(start)
        }
        updated.device = ScanMeta.deviceModel()
        updated.systemVersion = UIDevice.current.systemVersion
        updated.fix = geoFix ?? LocationService.shared.fix(for: meta)
        if thumbWritten {
            updated.thumbFile = "thumb.jpg"
        }
        updated.folderBytes = ZipPackager.uploadSize(of: directory)
        do {
            try updated.save(to: directory)
        } catch {
            print("meta.json 저장 실패: \(error.localizedDescription)")
        }
        meta = updated
    }

    /// 목록에 보이도록 Core Data 항목을 만든다 (rgbFilePath 는 영상이 없으므로 meta.json 을 가리킨다)
    private func saveRecording() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let context = appDelegate.persistentContainer.viewContext
        guard let entity = NSEntityDescription.entity(forEntityName: "Recording", in: context) else { return }
        let recording = Recording(entity: entity, insertInto: context)
        recording.id = UUID()
        recording.createdAt = captureStartedAt ?? Date()
        recording.duration = meta.durationSeconds ?? 0
        recording.name = meta.title
        recording.rgbFilePath = directory.lastPathComponent + "/" + ScanMeta.fileName
        recording.depthFilePath = nil
        do {
            try context.save()
        } catch {
            print("Could not save recording. \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: NSNotification.Name("sessionsChanged"), object: nil)
    }
}

// MARK: - 화면

@available(iOS 17.0, *)
struct ObjectCaptureFlowView: View {
    @StateObject private var model: ObjcapModel
    let onFinished: (URL) -> Void
    let onCancel: () -> Void

    init(meta: ScanMeta, onFinished: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ObjcapModel(meta: meta))
        self.onFinished = onFinished
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session = model.session {
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
                ObjcapCaptureOverlay(session: session, model: model) {
                    model.cancel()
                    onCancel()
                }
            } else {
                processingView
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            model.onFinished = onFinished
            model.start()
        }
    }

    @ViewBuilder
    private var processingView: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .capture:
                ProgressView("카메라 준비 중…")
            case .reconstructing(let fraction):
                ProgressView(value: fraction)
                Text(String(format: "폰에서 3D 모델 만드는 중 %.0f%%", fraction * 100))
                    .font(.headline)
                Text("몇 분 걸립니다. 화면을 켠 채 앱을 열어 두세요.")
                    .font(.caption)
            case .exporting(let fraction):
                ProgressView(value: fraction)
                Text(String(format: "사진 정리 중 %.0f%%", fraction * 100))
                    .font(.headline)
            case .done:
                ProgressView("완료")
            case .failed(let message):
                Text(message)
                    .multilineTextAlignment(.center)
                Button("목록으로") {
                    model.cancel()
                    onCancel()
                }
                .buttonStyle(.borderedProminent)
            }
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundColor(.white)
        .tint(.white)
        .padding(32)
    }
}

/// 촬영 중 위에 겹치는 안내·버튼 (ObjectCaptureSession 은 Observable 이라 body 에서 읽으면 자동 갱신)
@available(iOS 17.0, *)
private struct ObjcapCaptureOverlay: View {
    let session: ObjectCaptureSession
    @ObservedObject var model: ObjcapModel
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("취소") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Spacer()
                Text("\(session.numberOfShotsTaken)/\(session.maximumNumberOfInputImages)장 · \(model.passCount)바퀴째")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(8)
            }
            Text(instruction)
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(10)
                .background(Color.black.opacity(0.55))
                .cornerRadius(10)
            ForEach(feedbackTexts, id: \.self) { message in
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.black)
                    .padding(8)
                    .background(Color.orange)
                    .cornerRadius(8)
            }
            Spacer()
            if session.userCompletedScanPass {
                passCard
            } else {
                controls
            }
        }
        .padding()
    }

    private var instruction: String {
        switch session.state {
        case .initializing:
            return "카메라 준비 중…"
        case .ready:
            return "물체를 화면 가운데 두고 '물체 찾기' 를 누르세요"
        case .detecting:
            return "상자가 물체를 감싸는지 확인하고 '촬영 시작' 을 누르세요 (모서리를 끌어 크기 조절)"
        case .capturing:
            return passHint
        case .finishing:
            return "사진을 저장하는 중…"
        case .completed:
            return "촬영 완료"
        case .failed(let error):
            return "오류: \(error.localizedDescription)"
        @unknown default:
            return ""
        }
    }

    private var passHint: String {
        switch model.passCount {
        case 1:
            return "1바퀴: 물체와 같은 높이에서 천천히 한 바퀴 (점이 다 찰 때까지)"
        case 2:
            return "2바퀴: 위에서 내려다보며 한 바퀴"
        default:
            return "\(model.passCount)바퀴: 낮은 각도(또는 뒤집은 면)에서 한 바퀴"
        }
    }

    private var feedbackTexts: [String] {
        session.feedback.compactMap { ObjcapCaptureOverlay.text(for: $0) }.sorted()
    }

    static func text(for feedback: ObjectCaptureSession.Feedback) -> String? {
        switch feedback {
        case .objectTooClose:
            return "물체에 너무 가깝습니다"
        case .objectTooFar:
            return "물체에서 너무 멉니다"
        case .movingTooFast:
            return "너무 빠릅니다 — 천천히 움직이세요"
        case .environmentLowLight:
            return "조명이 어둡습니다 — 밝게 하면 결과가 좋아집니다"
        case .environmentTooDark:
            return "너무 어두워 촬영이 멈췄습니다"
        case .outOfFieldOfView:
            return "물체가 화면을 벗어났습니다"
        case .objectNotFlippable:
            return "이 물체는 뒤집지 말고 높이를 바꿔 도세요"
        case .overCapturing:
            return "사진이 최대 장수를 넘었습니다"
        case .objectNotDetected:
            return "물체를 찾지 못했습니다 — 상자를 직접 조절하세요"
        @unknown default:
            return nil
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch session.state {
        case .ready:
            Button {
                _ = session.startDetecting()
            } label: {
                Label("물체 찾기", systemImage: "viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .detecting:
            HStack {
                Button {
                    _ = session.resetDetection()
                } label: {
                    Text("다시 찾기")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.white)
                Button {
                    session.startCapturing()
                } label: {
                    Text("촬영 시작")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .capturing:
            Button {
                model.finishCapture()
            } label: {
                Text(session.numberOfShotsTaken >= 20 ? "촬영 끝내기" : "촬영 끝내기 (사진이 아직 적음)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.white)
        default:
            EmptyView()
        }
    }

    private var passCard: some View {
        VStack(spacing: 10) {
            Text("한 바퀴 완료! (\(model.passCount)바퀴)")
                .font(.headline)
            Text("고화질을 위해 높이를 바꿔 2~3바퀴 도는 것을 권장합니다.")
                .font(.caption)
            Button {
                model.nextPass(flip: false)
            } label: {
                Text(model.passCount == 1 ? "위에서 한 바퀴 더" : "낮은 각도에서 한 바퀴 더")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if !session.feedback.contains(.objectNotFlippable) {
                Button {
                    model.nextPass(flip: true)
                } label: {
                    Text("물체를 뒤집고 한 바퀴")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                model.finishCapture()
            } label: {
                Text("촬영 끝내기")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(14)
    }
}

// MARK: - 업로드용 파일 만들기 (백그라운드)

struct ObjcapExportResult: Sendable {
    var images: Int
    var posedImages: Int
    var thumbWritten: Bool
    /// 가장 많이 쓴 내부 파라미터 출처
    var intrinsicsSource: String?
}

@available(iOS 17.0, *)
enum ObjcapExporter {
    static let maxSide = 4032
    static let jpegQuality = 0.85

    struct ConvertedImage {
        let width: Int
        let height: Int
        let fx: Double
        let fy: Double
        let cx: Double
        let cy: Double
        let orientation: Int
        let intrinsicsSource: String
    }

    static func hasModel(in directory: URL) -> Bool {
        PreviewSceneLoader.firstFile(in: directory, extension: "obj") != nil
    }

    /// heic/ → images/*.jpg, poses.json, thumb.jpg
    static func export(heicDirectory: URL, imagesDirectory: URL, root: URL, poses: PhotogrammetrySession.Poses?,
                       arkit: CameraIntrinsics?, progress: (Double) -> Void) -> ObjcapExportResult {
        let allowed: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]
        let inputs = ((try? FileManager.default.contentsOfDirectory(at: heicDirectory, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? [])
            .filter { allowed.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var poseByName: [String: PhotogrammetrySession.Pose] = [:]
        if let poses = poses {
            for (sample, pose) in poses.posesBySample {
                if let url = poses.urlsBySample[sample] {
                    poseByName[url.lastPathComponent] = pose
                }
            }
        }

        var entries: [[String: Any]] = []
        var unposed: [String] = []
        var written = 0
        var bestSharpness = -1.0
        var bestInput: URL?
        var sourceCounts: [String: Int] = [:]
        for (index, input) in inputs.enumerated() {
            progress(Double(index) / Double(max(inputs.count, 1)))
            let base = input.deletingPathExtension().lastPathComponent
            let output = imagesDirectory.appendingPathComponent(base + ".jpg", isDirectory: false)
            guard let converted = convert(input, to: output, arkit: arkit) else { continue }
            written += 1
            sourceCounts[converted.intrinsicsSource, default: 0] += 1
            let file = "images/" + output.lastPathComponent
            if index % 4 == 0, let value = sharpness(of: input), value > bestSharpness {
                bestSharpness = value
                bestInput = input
            }
            if let pose = poseByName[input.lastPathComponent] {
                let entry: [String: Any] = [
                    "file": file,
                    "source": input.lastPathComponent,
                    "transform": matrixArray(pose),
                    "fx": converted.fx,
                    "fy": converted.fy,
                    "cx": converted.cx,
                    "cy": converted.cy,
                    "width": converted.width,
                    "height": converted.height,
                    "exif_orientation": converted.orientation,
                    "intrinsics_source": converted.intrinsicsSource,
                ]
                entries.append(entry)
            } else {
                unposed.append(file)
            }
        }

        var thumbWritten = false
        if let best = bestInput ?? inputs.first {
            thumbWritten = writeThumbnail(from: best, to: root.appendingPathComponent("thumb.jpg", isDirectory: false))
        }

        var document: [String: Any] = [
            "frame": "model",
            "units": "m",
            "up": "y",
            "pose_source": "PhotogrammetrySession .poses (iOS, on device)",
            "transform_convention": "column-major 4x4, camera-to-model; camera axes ARKit/RealityKit (x right, y up, -z forward). Matched SfM on 2026-10-28: 0.31 cm RMS, 0.19 deg",
            "image_orientation": "JPEG pixels are stored in sensor orientation (EXIF orientation not applied, written as 1); the original tag is exif_orientation. Other EXIF/TIFF tags are copied from the HEIC",
            "intrinsics_note": "intrinsics_source per image: depth_calibration (HEIC depth calibration) > arkit_scaled (ARKit wide camera intrinsics scaled to the JPEG size, same 4:3 full field of view) > exif_35mm > guess",
            "intrinsics_sources": sourceCounts,
            "poses_available": poses != nil,
            "images": entries,
            "unposed_images": unposed,
        ]
        if let arkit = arkit {
            document["arkit_intrinsics"] = arkit.dictionary
        }
        if let data = try? JSONSerialization.data(withJSONObject: document,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: root.appendingPathComponent("poses.json", isDirectory: false), options: .atomic)
        }
        progress(1)
        let mainSource = sourceCounts.max { $0.value < $1.value }?.key
        return ObjcapExportResult(images: written, posedImages: entries.count, thumbWritten: thumbWritten,
                                  intrinsicsSource: mainSource)
    }

    /// 열 우선 4×4 (회전 + 이동)
    static func matrixArray(_ pose: PhotogrammetrySession.Pose) -> [Float] {
        var m = simd_float4x4(pose.rotation)
        m.columns.3 = SIMD4<Float>(pose.translation.x, pose.translation.y, pose.translation.z, 1)
        let c0 = m.columns.0
        let c1 = m.columns.1
        let c2 = m.columns.2
        let c3 = m.columns.3
        return [c0.x, c0.y, c0.z, c0.w, c1.x, c1.y, c1.z, c1.w, c2.x, c2.y, c2.z, c2.w, c3.x, c3.y, c3.z, c3.w]
    }

    /// HEIC → JPEG (센서 방향 그대로, 긴 변 최대 4032, 원본 EXIF·TIFF·GPS 유지, Orientation 1) 와 그 해상도 기준 내부 파라미터.
    /// 내부 파라미터 순서: HEIC 깊이 보정값 → ARKit 광각 카메라 값 환산 → EXIF 35mm 환산 → 추정
    static func convert(_ input: URL, to output: URL, arkit: CameraIntrinsics?) -> ConvertedImage? {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { return nil }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard rawWidth > 0, rawHeight > 0 else { return nil }

        let image: CGImage?
        if max(rawWidth, rawHeight) > maxSide {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceCreateThumbnailWithTransform: false,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let cgImage = image,
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        // 사진측량 프로그램이 EXIF 초점거리·기기 정보로 시작값을 잡으므로 원본 메타데이터를 옮긴다
        var destinationOptions: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary] {
            if let value = properties[key] {
                destinationOptions[key] = value
            }
        }
        if var tiff = destinationOptions[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            destinationOptions[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = destinationOptions[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            destinationOptions[kCGImagePropertyExifDictionary] = exif
        }
        destinationOptions[kCGImagePropertyOrientation] = 1
        destinationOptions[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        if let found = ObjcapExporter.calibration(from: source) {
            let matrix = found.matrix
            let referenceWidth = Double(found.reference.width)
            let referenceHeight = Double(found.reference.height)
            if referenceWidth > 0, referenceHeight > 0 {
                let fx = Double(matrix.columns.0.x)
                let fy = Double(matrix.columns.1.y)
                let cx = Double(matrix.columns.2.x)
                let cy = Double(matrix.columns.2.y)
                if (referenceWidth >= referenceHeight) == (width >= height) {
                    let sx = Double(width) / referenceWidth
                    let sy = Double(height) / referenceHeight
                    return ConvertedImage(width: width, height: height, fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy,
                                          orientation: orientation, intrinsicsSource: "depth_calibration")
                }
                // 픽셀이 센서와 90° 돌아가 저장된 경우 (시계 방향 가정)
                let sx = Double(width) / referenceHeight
                let sy = Double(height) / referenceWidth
                return ConvertedImage(width: width, height: height, fx: fy * sx, fy: fx * sy,
                                      cx: (referenceHeight - cy) * sx, cy: cx * sy,
                                      orientation: orientation, intrinsicsSource: "depth_calibration_rotated90")
            }
        }
        // ARKit 광각 카메라의 실제 내부 파라미터를 사진 해상도로 환산 (같은 4:3 전체 화각)
        if let k = arkit, k.width > 0, k.height > 0 {
            if (k.width >= k.height) == (width >= height) {
                let sx = Double(width) / k.width
                let sy = Double(height) / k.height
                if abs(sx - sy) / sx < 0.01 {
                    return ConvertedImage(width: width, height: height, fx: k.fx * sx, fy: k.fy * sy,
                                          cx: k.cx * sx, cy: k.cy * sy,
                                          orientation: orientation, intrinsicsSource: "arkit_scaled")
                }
            } else {
                let sx = Double(width) / k.height
                let sy = Double(height) / k.width
                if abs(sx - sy) / sx < 0.01 {
                    return ConvertedImage(width: width, height: height, fx: k.fy * sx, fy: k.fx * sy,
                                          cx: (k.height - k.cy) * sx, cy: k.cx * sy,
                                          orientation: orientation, intrinsicsSource: "arkit_scaled_rotated90")
                }
            }
        }
        // EXIF 35mm 환산 초점거리로 추정 (35mm 값이 정수로 반올림돼 몇 % 어긋날 수 있다)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let diagonal = sqrt(Double(width * width + height * height))
        if let f35 = (exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue, f35 > 0 {
            let focal = f35 * diagonal / 43.2666
            return ConvertedImage(width: width, height: height, fx: focal, fy: focal,
                                  cx: Double(width) / 2, cy: Double(height) / 2,
                                  orientation: orientation, intrinsicsSource: "exif_35mm")
        }
        let guess = Double(max(width, height)) * 0.82   // 대각 약 75° 화각 가정
        return ConvertedImage(width: width, height: height, fx: guess, fy: guess,
                              cx: Double(width) / 2, cy: Double(height) / 2,
                              orientation: orientation, intrinsicsSource: "guess")
    }

    /// HEIC 에 들어 있는 깊이 보조 데이터의 카메라 보정값
    static func calibration(from source: CGImageSource) -> (matrix: matrix_float3x3, reference: CGSize)? {
        for type in [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity] {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any],
                  let depthData = try? AVDepthData(fromDictionaryRepresentation: info),
                  let calibration = depthData.cameraCalibrationData else { continue }
            return (calibration.intrinsicMatrix, calibration.intrinsicMatrixReferenceDimensions)
        }
        return nil
    }

    /// 작은 회색조 사본의 라플라시안 분산 (클수록 선명)
    static func sharpness(of url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 4, height > 4 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = Double(pixels[y * width + x])
                let left = Double(pixels[y * width + x - 1])
                let right = Double(pixels[y * width + x + 1])
                let up = Double(pixels[(y - 1) * width + x])
                let down = Double(pixels[(y + 1) * width + x])
                let laplacian = left + right + up + down - 4 * center
                sum += laplacian
                sumSquares += laplacian * laplacian
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }

    /// 화면용 썸네일 (방향 적용, 긴 변 640)
    static func writeThumbnail(from input: URL, to output: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
