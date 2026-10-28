//
//  RecordSessionViewController.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//
//  kgeoScan 변경:
//  - 화면: Stray 의 Metal 깊이/RGB 뷰 대신 ARSCNView 가 실제 카메라 화면을 그리고, 그 위에 ARKit
//    sceneReconstruction 메시(ARMeshAnchor)를 반투명 면으로 덮어 "어디를 찍었는지" 보여 준다 (버튼/탭으로 끄고 켬).
//  - 녹화 시작 시 ARKit 트래킹을 리셋해 월드 원점을 녹화 시작 지점으로 맞춘다
//    (서버는 원점을 lon/lat/elev 에 놓고, -z(정면)를 heading 방위로 돌린다). 메시도 이때 비워진다.
//  - 물체 모드: 탭(레이캐스트, 실패 시 깊이맵)으로 물체 중심을 잡아 반투명 구로 자를 영역을 보여 주고, 카메라 방위각
//    36칸 커버리지 링과 고도 3단, 거리·회전 속도 안내를 낸다. 녹화 전에 물체를 지정하면 그 순간 트래킹을 리셋해
//    월드 원점을 고정하고(물체 좌표 = odometry.csv 좌표계), 녹화 시작 때는 다시 리셋하지 않는다.
//  - 트래킹이 normal 이 된 첫 프레임에서 GPS·나침반 스냅샷(또는 지도에서 찍은 위치 + 나침반)을 기록한다.
//  - 촬영 안내: 트래킹 상태, LiDAR 거리, 깊이 신뢰도, 움직임 속도, 흐림 경고, 모드별 힌트, 프레임 수·예상 용량.
//  - 녹화 중 가장 선명한 프레임을 thumb.jpg 로 저장, 종료 뒤 촬영 통계 요약과 '다시 찍기' 제안.
//  - 노출 옵션(빠른 셔터)으로 모션블러를 줄인다.
//  녹화 데이터(DatasetEncoder 이하)는 원본 그대로다.
//

import Foundation
import UIKit
import Metal
import ARKit
import SceneKit
import CoreData
import CoreMotion
import CoreImage
import ImageIO
import AVFoundation
import simd

let FpsDividers: [Int] = [1, 2, 4, 12, 60]
let AvailableFpsSettings: [Int] = FpsDividers.map { Int(60 / $0) }
let FpsUserDefaultsKey: String = "FPS"

class MetalView : UIView {
    override class var layerClass: AnyClass {
        get {
            return CAMetalLayer.self
        }
    }
    override var layer: CAMetalLayer {
        return super.layer as! CAMetalLayer
    }
}

class RecordSessionViewController : UIViewController, ARSessionDelegate {
    private var unsupported: Bool = false
    private var arConfiguration: ARWorldTrackingConfiguration?
    private let session = ARSession()
    private let motionManager = CMMotionManager()
    private var updateLabelTimer: Timer?
    private var startedRecording: Date?
    private var dataContext: NSManagedObjectContext!
    private var datasetEncoder: DatasetEncoder?
    private let imuOperationQueue = OperationQueue()
    private var chosenFpsSetting: Int = 0
    @IBOutlet private var rgbView: UIView!
    @IBOutlet private var depthView: UIView!
    @IBOutlet private var recordButton: RecordButton!
    @IBOutlet private var timeLabel: UILabel!
    @IBOutlet weak var fpsButton: UIButton!
    var dismissFunction: Optional<() -> Void> = Optional.none

    // MARK: kgeoScan
    /// 설정 화면에서 넘어온 제목·모드·서버 주소·위치 입력 방식·물체 모드. 녹화가 끝나면 meta.json 으로 저장된다.
    var scanMeta: ScanMeta?
    /// 녹화가 정상적으로 끝났을 때 (녹화 폴더 절대 경로) 로 불린다. 없으면 dismissFunction 을 쓴다.
    var onFinished: ((URL) -> Void)?
    private var awaitingTracking = false
    private var trackingWaitStarted: Date?
    private let trackingWaitTimeout: TimeInterval = 3.0
    private var geoFix: GeoFix?
    private var captureStartedAt: Date?
    private let geoLabel = PaddedLabel()
    private let trackingLabel = PaddedLabel()
    private let guideLabel = PaddedLabel()
    private let statsLabel = PaddedLabel()
    private let overlayButton = UIButton(type: .system)
    private var geoLabelTimer: Timer?
    private let sceneView = ARSCNView(frame: .zero)
    private let meshOverlay = MeshOverlayDelegate()
    private var meshSupported = false
    private let guide = CaptureGuide()
    private let exposure = ExposureController()
    private var frameCounter = 0
    private let thumbQueue = DispatchQueue(label: "kgeo.thumb", qos: .utility)
    private let ciContext = CIContext()
    private var bestThumbSharpness: Float = -1
    private var lastThumbCheck: TimeInterval = 0
    private var thumbWritten = false

    // 물체 모드
    private var objectMode = false
    private let objectTracker = ObjectTracker()
    private var objectNode: SCNNode?
    private let reticle = ReticleView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    private let objectButton = UIButton(type: .system)
    private let radiusSlider = UISlider()
    private let ringView = CoverageRingView(frame: .zero)
    private let haptic = UINotificationFeedbackGenerator()
    /// 물체 지정 때 트래킹을 리셋해 월드 원점을 이미 고정했는지 (녹화 시작 때 다시 리셋하지 않는다)
    private var worldFrameFixed = false
    private var awaitingFrameFix = false
    private var frameFixStarted: Date?
    private var pendingDesignationPoint: CGPoint?
    private var fixedGeoFix: GeoFix?

    // 미리보기 정점 색용 키프레임 (녹화 중 0.7초마다, 60장을 넘으면 절반으로 솎고 간격을 두 배로)
    private var colorKeyframes: [ColorKeyframe] = []
    private var lastKeyframeTime: TimeInterval = 0
    private var keyframeInterval: TimeInterval = 0.7

    // 면 촬영 (정사영상): 녹화하면서 12 cm 이동·10° 회전마다 고해상도 정지 사진 (hires/)
    private var areaMode = false
    private var areaSurface = "auto"
    private var hiresRecorder: HiresRecorder?
    private var hiresAccepting = false
    private var hiresInFlight = false
    private var hiresCount = 0
    private var hiresWritten = 0
    private var hiresSkipped = 0
    private var hiresFormatRecommended = false
    private var lastHiresTransform: simd_float4x4?
    private var lastHiresRequestTime: TimeInterval = 0
    private var lastShakeSkipTime: TimeInterval = 0
    private var lastGuidanceSpeed: Float = 0
    private var lastGuidanceRotation: Float = 0

    func setDismissFunction(_ fn: Optional<() -> Void>) {
        self.dismissFunction = fn
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.chosenFpsSetting = UserDefaults.standard.integer(forKey: FpsUserDefaultsKey)
        updateFpsSetting()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        self.dataContext = appDelegate.persistentContainer.newBackgroundContext()

        objectMode = scanMeta?.objectMode ?? false
        areaMode = scanMeta?.capture == "area"
        areaSurface = scanMeta?.area?.surface ?? "auto"
        if areaMode {
            guide.thresholds = CaptureGuide.area
        } else if objectMode {
            guide.thresholds = CaptureGuide.object
        } else {
            guide.thresholds = (scanMeta?.mode ?? .home) == .survey ? CaptureGuide.survey : CaptureGuide.home
        }
        setupSceneView()
        setupOverlayViews()
        if objectMode {
            setupObjectViews()
        }
        setViewProperties()
        session.delegate = self

        recordButton.setCallback { (recording: Bool) in
            self.toggleRecording(recording)
        }
        fpsButton.layer.masksToBounds = true
        fpsButton.layer.cornerRadius = 12.0

        imuOperationQueue.qualityOfService = .userInitiated

        rgbView.isHidden = true
        LocationService.shared.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.pause()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        updateLabelTimer?.invalidate()
        geoLabelTimer?.invalidate()
        geoLabelTimer = nil
        exposure.stop()
        datasetEncoder = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
        geoLabelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateGeoLabel()
        }
        updateGeoLabel()
    }

    // MARK: - 화면 구성

    private func setupSceneView() {
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        depthView.addSubview(sceneView)
        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: depthView.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: depthView.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: depthView.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: depthView.bottomAnchor),
        ])
        sceneView.session = session
        sceneView.delegate = meshOverlay
        sceneView.scene = SCNScene()
        sceneView.automaticallyUpdatesLighting = false
        sceneView.rendersCameraGrain = false
        sceneView.rendersMotionBlur = false
        sceneView.antialiasingMode = .none
        sceneView.preferredFramesPerSecond = 30
        sceneView.backgroundColor = .black
        sceneView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(viewTapped(_:))))
    }

    private func setupOverlayViews() {
        for label in [geoLabel, trackingLabel, guideLabel, statsLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 8
            label.layer.masksToBounds = true
            label.textAlignment = .center
            label.numberOfLines = 1
            view.addSubview(label)
        }
        geoLabel.text = "위치 확인 중…"
        trackingLabel.text = "트래킹 준비"
        statsLabel.text = "0 프레임 · ≈0 MB"
        statsLabel.isHidden = true
        guideLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        guideLabel.numberOfLines = 3
        guideLabel.isHidden = true

        styleButton(overlayButton, title: "메시 켜짐")
        overlayButton.addTarget(self, action: #selector(overlayButtonTapped), for: .touchUpInside)
        view.addSubview(overlayButton)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            geoLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            geoLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            trackingLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            trackingLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            trackingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: geoLabel.trailingAnchor, constant: 8),
            guideLabel.bottomAnchor.constraint(equalTo: depthView.bottomAnchor, constant: -12),
            guideLabel.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            guideLabel.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -24),
            overlayButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            overlayButton.bottomAnchor.constraint(equalTo: guideLabel.topAnchor, constant: -8),
            statsLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            statsLabel.bottomAnchor.constraint(equalTo: guideLabel.topAnchor, constant: -8),
        ])
        geoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func styleButton(_ button: UIButton, title: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    }

    /// 물체 모드 UI: 조준점, 물체 지정 버튼, 반경 슬라이더, 커버리지 링
    private func setupObjectViews() {
        reticle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reticle)

        styleButton(objectButton, title: "물체 지정")
        objectButton.addTarget(self, action: #selector(objectButtonTapped), for: .touchUpInside)

        radiusSlider.translatesAutoresizingMaskIntoConstraints = false
        radiusSlider.minimumValue = ObjectTracker.minRadius
        radiusSlider.maximumValue = ObjectTracker.maxRadius
        radiusSlider.value = objectTracker.radius
        radiusSlider.isHidden = true
        radiusSlider.addTarget(self, action: #selector(radiusChanged), for: .valueChanged)

        let row = UIStackView(arrangedSubviews: [objectButton, radiusSlider])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        view.addSubview(row)

        ringView.translatesAutoresizingMaskIntoConstraints = false
        ringView.isHidden = true
        view.addSubview(ringView)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            reticle.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            reticle.centerYAnchor.constraint(equalTo: depthView.centerYAnchor),
            reticle.widthAnchor.constraint(equalToConstant: 44),
            reticle.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: statsLabel.topAnchor, constant: -8),
            radiusSlider.widthAnchor.constraint(equalToConstant: 140),
            ringView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            ringView.bottomAnchor.constraint(equalTo: overlayButton.topAnchor, constant: -8),
            ringView.widthAnchor.constraint(equalToConstant: 84),
            ringView.heightAnchor.constraint(equalToConstant: 106),
        ])

        haptic.prepare()
        objectTracker.didReachFullCircle = { [weak self] in
            guard let self = self else { return }
            self.haptic.notificationOccurred(.success)
            self.ringView.complete = true
        }
    }

    private func setViewProperties() {
        self.view.backgroundColor = UIColor(named: "BackgroundColor")
    }

    // MARK: - AR 세션

    private func startSession() {
        let config = ARWorldTrackingConfiguration()
        arConfiguration = config
        if !ARWorldTrackingConfiguration.isSupported || !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            print("AR is not supported.")
            unsupported = true
        } else {
            config.frameSemantics.insert(.sceneDepth)
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
                meshSupported = true
            } else {
                overlayButton.isHidden = true
            }
            config.planeDetection = objectMode ? [.horizontal, .vertical] : []
            if areaMode {
                preferHighResolutionStillFormat(config)
            }
            guide.reset()
            session.run(config)
            scheduleExposureApply()
        }
    }

    /// 세션이 돈 뒤 카메라 장치가 준비되면 노출 설정을 적용한다 (리셋 뒤에도 다시 부른다)
    private func scheduleExposureApply() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.exposure.apply()
        }
    }

    private func startRawIMU() {
        if self.motionManager.isAccelerometerAvailable {
            self.motionManager.accelerometerUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startAccelerometerUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving accelerometer data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawAccelerometer(data: data)
            }
        } else {
            print("Accelerometer not available on this device.")
        }

        if self.motionManager.isGyroAvailable {
            self.motionManager.gyroUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startGyroUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving gyroscope data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawGyroscope(data: data)
            }
        } else {
            print("Gyroscope not available on this device.")
        }
    }

    private func stopRawIMU() {
        if self.motionManager.isAccelerometerActive {
            self.motionManager.stopAccelerometerUpdates()
            print("Stopped accelerometer updates.")
        }
        if self.motionManager.isGyroActive {
            self.motionManager.stopGyroUpdates()
            print("Stopped gyroscope updates.")
        }
    }

    // MARK: - 녹화

    private func toggleRecording(_ recording: Bool) {
        if unsupported {
            showUnsupportedAlert()
            return
        }
        if recording && self.startedRecording == nil {
            startRecording()
        } else if self.startedRecording != nil && !recording {
            stopRecording()
        } else {
            print("This should not happen. We are either not recording and want to stop, or we are recording and want to start.")
        }
    }

    private func startRecording() {
        guard let config = arConfiguration else { return }
        geoFix = nil
        captureStartedAt = nil
        bestThumbSharpness = -1
        lastThumbCheck = 0
        thumbWritten = false
        colorKeyframes = []
        lastKeyframeTime = 0
        keyframeInterval = 0.7
        self.startedRecording = Date()
        updateTime()
        updateLabelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.updateTime()
        }
        datasetEncoder = DatasetEncoder(arConfiguration: config, fpsDivider: FpsDividers[chosenFpsSetting])
        statsLabel.isHidden = false
        hiresRecorder = nil
        hiresAccepting = false
        hiresInFlight = false
        hiresCount = 0
        hiresWritten = 0
        hiresSkipped = 0
        lastHiresTransform = nil
        lastHiresRequestTime = 0
        if areaMode, let encoder = datasetEncoder {
            hiresRecorder = try? HiresRecorder(datasetDirectory: encoder.directory.absoluteURL.standardizedFileURL)
            hiresAccepting = hiresRecorder != nil
        }
        if objectMode && worldFrameFixed {
            // 물체 지정 때 이미 원점을 잡았다 — 리셋하면 물체 좌표가 어긋나므로 그대로 녹화한다
            awaitingTracking = false
            objectTracker.resetCoverage()
            ringView.complete = false
            beginCapture()
        } else {
            // 월드 원점을 녹화 시작 지점으로 맞춘다. 첫 프레임은 트래킹이 normal 로 돌아온 뒤 저장한다. 메시도 비워진다.
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
            scheduleExposureApply()
            guide.reset()
            awaitingTracking = true
            trackingWaitStarted = Date()
        }
    }

    /// 트래킹이 잡힌 첫 프레임: 이 순간의 GPS·방위(또는 지도에서 찍은 위치 + 나침반)가 스캔의 원점·기준 방위가 된다.
    private func beginCapture() {
        awaitingTracking = false
        geoFix = fixedGeoFix ?? currentGeoFix()
        startedRecording = Date()
        captureStartedAt = Date()
        guide.resetStats()
        startRawIMU()
    }

    /// 지금 순간의 위치·방위 (지도 선택이면 그 좌표 + 나침반)
    private func currentGeoFix() -> GeoFix? {
        let compass = LocationService.shared.snapshot()
        if scanMeta?.locationSource == "map", var manual = scanMeta?.manualFix {
            if manual.trueHeading == nil {
                manual.trueHeading = compass?.trueHeading
                manual.magneticHeading = compass?.magneticHeading
                manual.headingAccuracy = compass?.headingAccuracy
                manual.headingTime = compass?.headingTime
            }
            if manual.alt == nil {
                manual.alt = compass?.alt
                manual.vAcc = compass?.vAcc
            }
            return manual
        }
        return compass
    }

    private func stopRecording() {
        guard let started = self.startedRecording else {
            print("Hasn't started recording. Something is wrong.")
            return
        }
        startedRecording = nil
        awaitingTracking = false
        hiresAccepting = false
        updateLabelTimer?.invalidate()
        updateLabelTimer = nil
        statsLabel.isHidden = true
        // Stop IMU updates
        stopRawIMU()
        guard let encoder = datasetEncoder else {
            print("No dataset encoder. Something is wrong.")
            self.dismissFunction?()
            return
        }
        encoder.wrapUp()
        let directory = encoder.directory.absoluteURL.standardizedFileURL
        if encoder.savedFrameCount == 0 {
            try? FileManager.default.removeItem(at: directory)
            datasetEncoder = nil
            showError(message: "녹화된 프레임이 없습니다. 트래킹이 잡힌 뒤 조금 더 길게 녹화해 주세요.", popOnDismiss: false)
            return
        }
        switch encoder.status {
            case .allGood:
                var stats = guide.summary()
                if objectMode && objectTracker.isSet {
                    let coverage = objectTracker.coveragePercent
                    stats.coveragePct = coverage
                    stats.elevationBands = objectTracker.elevationBands
                    if coverage < 70 {
                        stats.warnings.append(String(format: "물체 둘레 커버리지 %.0f%% — 70%% 이상 권장 (한 바퀴를 더 도세요)", coverage))
                    }
                }
                // 품질 판단(다시 찍기)은 미리보기 화면에서 한다. 미리보기용 ARKit 메시는 지금 복사해 둔다
                let mesh = meshSupported ? MeshSnapshot.capture(from: session.currentFrame) : nil
                // 면 촬영: 남은 고해상도 사진 저장을 기다리고 hires/poses.json 을 쓴다
                hiresWritten = hiresRecorder?.finish(surface: areaSurface, formatRecommended: hiresFormatRecommended) ?? 0
                hiresRecorder = nil
                finishRecording(started: started, encoder: encoder, directory: directory, stats: stats, mesh: mesh)
            case .videoEncodingError, .directoryCreationError:
                showError(message: "영상 인코딩 중 오류가 났습니다. 다시 녹화해 주세요.")
        }
    }

    private func finishRecording(started: Date, encoder: DatasetEncoder, directory: URL, stats: CaptureStats,
                                 mesh: MeshSnapshot?) {
        saveRecording(started, encoder)
        writeMeta(started: started, encoder: encoder, directory: directory, stats: stats)
        if let mesh = mesh {
            var crop: PreviewCrop?
            if objectMode, let center = objectTracker.center {
                crop = PreviewCrop(center: center, radius: objectTracker.radius)
            }
            PreviewBuilder.shared.start(directory: directory, mesh: mesh, keyframes: colorKeyframes, crop: crop)
        }
        colorKeyframes = []
        if let onFinished = onFinished {
            onFinished(directory)
        } else {
            self.dismissFunction?()
        }
    }

    private func saveRecording(_ started: Date, _ encoder: DatasetEncoder) {
        let sessionCount = countSessions()

        let duration = Date().timeIntervalSince(started)
        let entity = NSEntityDescription.entity(forEntityName: "Recording", in: self.dataContext)!
        let recording: Recording = Recording(entity: entity, insertInto: self.dataContext)
        recording.setValue(encoder.id, forKey: "id")
        recording.setValue(duration, forKey: "duration")
        recording.setValue(started, forKey: "createdAt")
        recording.setValue(scanMeta?.title ?? "Recording \(sessionCount)", forKey: "name")
        recording.setValue(encoder.rgbFilePath.relativeString, forKey: "rgbFilePath")
        recording.setValue(encoder.depthFilePath.relativeString, forKey: "depthFilePath")
        do {
            try self.dataContext.save()
        } catch let error as NSError {
            print("Could not save recording. \(error), \(error.userInfo)")
        }
    }

    private func writeMeta(started: Date, encoder: DatasetEncoder, directory: URL, stats: CaptureStats) {
        var meta = scanMeta ?? ScanMeta(title: "Recording", note: "", mode: .home, serverBase: KgeoDefaults.storedServerBase)
        meta.createdAt = started
        meta.durationSeconds = Date().timeIntervalSince(started)
        meta.fpsDivider = FpsDividers[chosenFpsSetting]
        meta.savedFrames = encoder.savedFrameCount
        meta.device = ScanMeta.deviceModel()
        meta.systemVersion = UIDevice.current.systemVersion
        meta.fix = geoFix
        meta.exposureMode = ExposureController.currentMode.rawValue
        if areaMode {
            meta.capture = "area"
            meta.area = AreaInfo(surface: areaSurface, hires: hiresWritten, hiresSkipped: hiresSkipped,
                                 hiresFormatRecommended: hiresFormatRecommended)
        } else {
            meta.capture = "video"
        }
        meta.meshOverlay = meshSupported
        meta.captureStats = stats
        meta.folderBytes = RecordSessionViewController.folderSize(directory)
        if thumbWritten {
            meta.thumbFile = "thumb.jpg"
        }
        meta.objectMode = objectMode
        if objectMode {
            let center = objectTracker.center.map { [$0.x, $0.y, $0.z] }
            meta.object = ObjectInfo(center: center,
                                     radius: objectTracker.radius,
                                     setBy: objectTracker.isSet ? objectTracker.setBy : "auto",
                                     coveragePct: objectTracker.isSet ? objectTracker.coveragePercent : nil,
                                     elevationBands: objectTracker.isSet ? objectTracker.elevationBands : nil)
        }
        do {
            try meta.save(to: directory)
        } catch {
            print("meta.json 저장 실패: \(error.localizedDescription)")
        }
    }

    /// 폴더 전체 바이트 (meta.json 기록용)
    static func folderSize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey],
                                                              options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func showError(message: String, popOnDismiss: Bool = true) {
        let controller = UIAlertController(title: "오류", message: message, preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: "확인", style: .default, handler: { _ in
            if popOnDismiss {
                self.dismissFunction?()
            }
        }))
        self.present(controller, animated: true, completion: nil)
    }

    private func updateTime() {
        guard let started = self.startedRecording else { return }
        let seconds = Date().timeIntervalSince(started)
        let minutes: Int = Int(floor(seconds / 60).truncatingRemainder(dividingBy: 60))
        let hours: Int = Int(floor(seconds / 3600))
        let roundSeconds: Int = Int(floor(seconds.truncatingRemainder(dividingBy: 60)))
        self.timeLabel.text = String(format: "%02d:%02d:%02d", hours, minutes, roundSeconds)
        if let encoder = datasetEncoder {
            let frames = encoder.savedFrameCount
            var megabytes = Double(Int64(frames) * KgeoDefaults.bytesPerFrameEstimate) / 1_048_576
            if areaMode {
                megabytes += Double(hiresCount) * 3.5
                statsLabel.text = String(format: "%d 프레임 · 고해상도 %d장 · ≈%.0f MB", frames, hiresCount, megabytes)
            } else {
                statsLabel.text = String(format: "%d 프레임 · ≈%.0f MB", frames, megabytes)
            }
        }
    }

    // MARK: - 메시 오버레이 / 탭

    @objc func viewTapped(_ gesture: UITapGestureRecognizer) {
        if objectMode {
            designateObject(at: gesture.location(in: sceneView))
        } else {
            toggleOverlay()
        }
    }

    @objc private func overlayButtonTapped() {
        toggleOverlay()
    }

    private func toggleOverlay() {
        guard meshSupported else { return }
        meshOverlay.isEnabled.toggle()
        MeshOverlayDelegate.setHidden(!meshOverlay.isEnabled, in: sceneView)
        overlayButton.setTitle(meshOverlay.isEnabled ? "메시 켜짐" : "메시 꺼짐", for: .normal)
    }

    @IBAction func fpsButtonTapped() {
        chosenFpsSetting = (chosenFpsSetting + 1) % AvailableFpsSettings.count
        updateFpsSetting()
        UserDefaults.standard.set(chosenFpsSetting, forKey: FpsUserDefaultsKey)
    }

    // MARK: - 물체 모드

    @objc private func objectButtonTapped() {
        if objectTracker.isSet {
            clearObject()
        } else {
            designateObject(at: CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY))
        }
    }

    @objc private func radiusChanged() {
        objectTracker.radius = radiusSlider.value
        if let node = objectNode {
            ObjectTracker.setRadius(radiusSlider.value, on: node)
        }
    }

    private func clearObject() {
        objectTracker.clear()
        removeObjectNode()
        radiusSlider.isHidden = true
        ringView.isHidden = true
        ringView.complete = false
        reticle.isHidden = false
        objectButton.setTitle("물체 지정", for: .normal)
    }

    /// 탭한 지점의 물체를 지정한다. 녹화 전이면 먼저 트래킹을 리셋해 월드 원점을 고정한 뒤 같은 지점을 다시 레이캐스트한다.
    private func designateObject(at point: CGPoint) {
        guard !awaitingFrameFix else { return }
        if startedRecording == nil && !worldFrameFixed {
            guard let config = arConfiguration else { return }
            pendingDesignationPoint = point
            objectTracker.clear()
            removeObjectNode()
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
            scheduleExposureApply()
            guide.reset()
            awaitingFrameFix = true
            frameFixStarted = Date()
            guideLabel.text = "잠시 그대로 — 기준 위치를 잡는 중"
            guideLabel.isHidden = false
            return
        }
        performDesignation(at: point)
    }

    private func performDesignation(at point: CGPoint) {
        guard let frame = session.currentFrame else { return }
        var center: simd_float3?
        if let query = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
           let hit = session.raycast(query).first {
            center = simd_make_float3(hit.worldTransform.columns.3)
        } else if let query = sceneView.raycastQuery(from: point, allowing: .existingPlaneGeometry, alignment: .any),
                  let hit = session.raycast(query).first {
            center = simd_make_float3(hit.worldTransform.columns.3)
        } else if let depthPoint = unproject(viewPoint: point, frame: frame) {
            center = depthPoint
        }
        guard let c = center else {
            guideLabel.text = "물체를 찾지 못했습니다 — 조금 더 가까이에서 다시 탭하세요"
            guideLabel.isHidden = false
            return
        }
        objectTracker.setCenter(c, setBy: "tap")
        placeObjectNode(at: c)
        radiusSlider.isHidden = false
        ringView.isHidden = false
        ringView.complete = false
        reticle.isHidden = true
        objectButton.setTitle("물체 해제", for: .normal)
        haptic.prepare()
        updateRing()
    }

    /// 깊이맵으로 화면 점을 3D 로 되돌린다 (레이캐스트 실패 시)
    private func unproject(viewPoint: CGPoint, frame: ARFrame) -> simd_float3? {
        guard let depthMap = frame.sceneDepth?.depthMap else { return nil }
        let viewport = sceneView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let normalized = CGPoint(x: viewPoint.x / viewport.width, y: viewPoint.y / viewport.height)
        let toImage = frame.displayTransform(for: .portrait, viewportSize: viewport).inverted()
        let imagePoint = normalized.applying(toImage)
        guard imagePoint.x >= 0, imagePoint.x <= 1, imagePoint.y >= 0, imagePoint.y <= 1 else { return nil }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let px = Int(imagePoint.x * CGFloat(depthWidth - 1))
        let py = Int(imagePoint.y * CGFloat(depthHeight - 1))
        guard let depth = CaptureGuide.depth(atX: px, y: py, in: depthMap) else { return nil }
        let imageSize = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        let u = Float(imagePoint.x) * Float(imageSize.width)
        let v = Float(imagePoint.y) * Float(imageSize.height)
        let cameraPoint = simd_float4((u - cx) / fx * depth, -(v - cy) / fy * depth, -depth, 1)
        let world = frame.camera.transform * cameraPoint
        return simd_make_float3(world)
    }

    private func placeObjectNode(at center: simd_float3) {
        removeObjectNode()
        let node = ObjectTracker.makeNode(center: center, radius: objectTracker.radius)
        sceneView.scene.rootNode.addChildNode(node)
        objectNode = node
    }

    private func removeObjectNode() {
        objectNode?.removeFromParentNode()
        objectNode = nil
    }

    private func updateRing() {
        guard objectMode, objectTracker.isSet else { return }
        ringView.covered = objectTracker.coveredBins
        ringView.percentText = String(format: "%.0f%%", objectTracker.coveragePercent)
        ringView.bandPercents = ObjectTracker.Band.allCases.map { objectTracker.bandPercent($0) }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCounter += 1
        if awaitingFrameFix {
            var ready = false
            if case .normal = frame.camera.trackingState {
                ready = true
            } else if let t0 = frameFixStarted, Date().timeIntervalSince(t0) > trackingWaitTimeout {
                ready = true
            }
            if ready {
                awaitingFrameFix = false
                worldFrameFixed = true
                fixedGeoFix = currentGeoFix()
                if let point = pendingDesignationPoint {
                    performDesignation(at: point)
                }
                pendingDesignationPoint = nil
            }
        }
        let capturing = startedRecording != nil && !awaitingTracking
        if frameCounter % 6 == 0 {
            updateGuidance(frame: frame, capturing: capturing)
            if objectMode {
                objectTracker.update(cameraTransform: frame.camera.transform, timestamp: frame.timestamp, recording: capturing)
                updateRing()
            }
        }
        guard startedRecording != nil, let encoder = datasetEncoder else { return }
        if awaitingTracking {
            var ready = false
            if case .normal = frame.camera.trackingState {
                ready = true
            } else if let t0 = trackingWaitStarted, Date().timeIntervalSince(t0) > trackingWaitTimeout {
                ready = true
            }
            guard ready else { return }
            beginCapture()
        }
        encoder.add(frame: frame)
        considerThumbnail(frame: frame, directory: encoder.directory.absoluteURL.standardizedFileURL)
        considerColorKeyframe(frame: frame)
        considerHighResolution(frame: frame)
    }

    // MARK: - 면 촬영 (정사영상)

    /// 고해상도 정지 사진에 맞는 영상 형식으로 바꾼다 — 녹화 해상도·프레임 수·카메라가 같은 형식만 (Stray rgb.mp4 형식 유지)
    private func preferHighResolutionStillFormat(_ config: ARWorldTrackingConfiguration) {
        let current = config.videoFormat
        if current.isRecommendedForHighResolutionFrameCapturing {
            hiresFormatRecommended = true
            return
        }
        let match = ARWorldTrackingConfiguration.supportedVideoFormats.first { format in
            format.isRecommendedForHighResolutionFrameCapturing
                && format.imageResolution == current.imageResolution
                && format.framesPerSecond == current.framesPerSecond
                && format.captureDeviceType == current.captureDeviceType
        }
        if let format = match {
            config.videoFormat = format
            hiresFormatRecommended = true
        } else {
            hiresFormatRecommended = false
        }
    }

    /// 마지막 사진 대비 12 cm 이동 또는 10° 회전이면 고해상도 정지 사진 요청 (흔들리면 건너뜀, 최대 200장)
    private func considerHighResolution(frame: ARFrame) {
        guard areaMode, hiresAccepting, !hiresInFlight, hiresCount < HiresRecorder.maxShots else { return }
        guard case .normal = frame.camera.trackingState else { return }
        guard frame.timestamp - lastHiresRequestTime >= 0.4 else { return }
        let transform = frame.camera.transform
        if let last = lastHiresTransform {
            let moved = simd_distance(transform.columns.3, last.columns.3)
            let delta = simd_quatf(transform) * simd_quatf(last).inverse
            var turned = delta.angle * 180 / Float.pi
            if turned > 180 {
                turned = 360 - turned
            }
            guard moved >= 0.12 || turned >= 10 else { return }
        }
        if lastGuidanceSpeed > 0.5 || lastGuidanceRotation > 45 {
            if frame.timestamp - lastShakeSkipTime >= 1 {
                lastShakeSkipTime = frame.timestamp
                hiresSkipped += 1
            }
            return
        }
        hiresInFlight = true
        lastHiresRequestTime = frame.timestamp
        session.captureHighResolutionFrame { [weak self] hiresFrame, error in
            DispatchQueue.main.async {
                self?.handleHighResolution(hiresFrame, error: error)
            }
        }
    }

    private func handleHighResolution(_ frame: ARFrame?, error: Error?) {
        hiresInFlight = false
        guard hiresAccepting, let recorder = hiresRecorder else { return }
        guard let frame = frame else {
            if let error = error {
                print("고해상도 사진 실패: \(error.localizedDescription)")
            }
            return
        }
        hiresCount += 1
        lastHiresTransform = frame.camera.transform
        recorder.add(frame: frame, index: hiresCount)
    }

    /// 바닥 모드: 폰이 아래를 보는지, 벽 모드: 수평을 보는지
    private func tiltWarning(frame: ARFrame) -> String? {
        // 카메라 정면(-z)의 월드 y 성분 (-1 = 바로 아래)
        let forwardY = -frame.camera.transform.columns.2.y
        switch areaSurface {
        case "floor":
            return forwardY > -0.8 ? "폰을 더 아래로 기울여 바닥(트렌치)을 위에서 내려다보세요" : nil
        case "wall":
            return abs(forwardY) > 0.5 ? "벽을 정면으로 보도록 폰을 세우세요" : nil
        default:
            return nil
        }
    }

    private func areaHint() -> String {
        let count = hiresCount > 0 ? " · 고해상도 \(hiresCount)장" : ""
        switch areaSurface {
        case "floor":
            return "폰을 아래로 향해 바닥(트렌치)을 내려다보며 40 cm~1.2 m 거리로 천천히 지그재그로 겹치게 훑으세요" + count
        case "wall":
            return "벽을 정면으로 보며 40 cm~1.2 m 거리로 천천히 지그재그로 겹치게 훑으세요" + count
        default:
            return "대상 면에서 40 cm~1.2 m 거리로 천천히 지그재그로 겹치게 훑으세요" + count
        }
    }

    /// 미리보기 정점 색용 키프레임 (트래킹 정상일 때만)
    private func considerColorKeyframe(frame: ARFrame) {
        guard meshSupported, frame.timestamp - lastKeyframeTime >= keyframeInterval else { return }
        guard case .normal = frame.camera.trackingState else { return }
        lastKeyframeTime = frame.timestamp
        guard let keyframe = ColorKeyframe(frame: frame) else { return }
        colorKeyframes.append(keyframe)
        if colorKeyframes.count > 60 {
            colorKeyframes = colorKeyframes.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
            keyframeInterval *= 2
        }
    }

    /// 녹화 시작 20초 동안 1초마다 선명도를 보고, 가장 선명한 프레임을 thumb.jpg 로 남긴다
    private func considerThumbnail(frame: ARFrame, directory: URL) {
        guard let began = captureStartedAt, Date().timeIntervalSince(began) < 20,
              frame.timestamp - lastThumbCheck >= 1.0 else { return }
        lastThumbCheck = frame.timestamp
        let sharpness = guide.lastSharpness
        guard sharpness > bestThumbSharpness else { return }
        bestThumbSharpness = sharpness
        let pixelBuffer = frame.capturedImage
        let context = ciContext
        thumbQueue.async { [weak self] in
            let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
            let scale = 480 / max(image.extent.width, 1)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            let options: [CIImageRepresentationOption: Any] = [qualityKey: 0.8]
            guard let data = context.jpegRepresentation(of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(), options: options) else { return }
            let url = directory.appendingPathComponent("thumb.jpg", isDirectory: false)
            do {
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { self?.thumbWritten = true }
            } catch {
                print("thumb.jpg 저장 실패: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 촬영 안내

    private func updateGuidance(frame: ARFrame, capturing: Bool) {
        let guidance = guide.evaluate(frame: frame, recording: capturing)
        lastGuidanceSpeed = guidance.speed
        lastGuidanceRotation = guidance.rotationSpeed
        var trackingText = guidance.trackingText
        if objectMode, objectTracker.isSet {
            trackingText += String(format: " · 물체 %.2f m", objectTracker.distance)
        } else if let depth = guidance.centerDepth {
            trackingText += String(format: " · %.2f m", depth)
        }
        trackingLabel.text = trackingText
        trackingLabel.backgroundColor = guidance.trackingOK
            ? UIColor.black.withAlphaComponent(0.55)
            : UIColor.systemOrange.withAlphaComponent(0.85)

        if awaitingFrameFix { return }

        var text: String?
        if !guidance.trackingOK {
            text = guidance.warning
        } else if objectMode, let objectWarning = objectTracker.warning() {
            text = objectWarning
            if capturing {
                guide.countWarning("object")
            }
        } else if areaMode, let tilt = tiltWarning(frame: frame) {
            text = tilt
            if capturing {
                guide.countWarning("tilt")
            }
        } else {
            text = guidance.warning
        }
        let isWarning = text != nil
        if text == nil {
            if objectMode {
                text = objectTracker.hint(recording: startedRecording != nil)
            } else if areaMode {
                text = areaHint()
            } else {
                // 모드 힌트: 녹화 전, 그리고 녹화 시작 8초 동안
                let showHint: Bool
                if startedRecording == nil {
                    showHint = true
                } else if let began = captureStartedAt {
                    showHint = Date().timeIntervalSince(began) < 8
                } else {
                    showHint = true
                }
                if showHint {
                    text = modeHint()
                }
            }
        }
        guideLabel.text = text
        guideLabel.isHidden = (text == nil)
        guideLabel.backgroundColor = isWarning
            ? UIColor.systemOrange.withAlphaComponent(0.9)
            : UIColor.black.withAlphaComponent(0.55)
    }

    private func modeHint() -> String {
        switch scanMeta?.mode ?? .home {
        case .survey:
            return "물체에서 40~80 cm 떨어져 천천히 한 바퀴 (20~30초). 중앙에 두고 찍으세요"
        case .home:
            return "벽과 바닥을 0.3~3 m 거리에서 천천히 훑으세요. 같은 곳을 두 번 지나면 더 좋습니다"
        }
    }

    private func updateGeoLabel() {
        if scanMeta?.locationSource == "map", let manual = scanMeta?.manualFix {
            geoLabel.text = String(format: "지도 위치 %.5f, %.5f", manual.lat, manual.lon)
        } else {
            geoLabel.text = LocationService.shared.shortStatus
        }
    }

    private func updateFpsSetting() {
        let fps = AvailableFpsSettings[chosenFpsSetting]
        let buttonLabel: String = "\(fps) fps"
        fpsButton.setTitle(buttonLabel, for: UIControl.State.normal)
    }

    private func showUnsupportedAlert() {
        let alert = UIAlertController(title: "지원하지 않는 기기", message: "이 기기는 LiDAR(sceneDepth) 가 있는 ARKit 을 지원하지 않습니다. iPhone 12 Pro 이후의 Pro 모델이 필요합니다.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default, handler: { _ in
            self.dismissFunction?()
        }))
        self.present(alert, animated: true)
    }

    private func countSessions() -> Int {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return 0 }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        do {
            let fetched: [NSManagedObject] = try appDelegate.persistentContainer.viewContext.fetch(request)
            return fetched.count
        } catch let error {
            print("Could not fetch sessions for counting. \(error.localizedDescription)")
        }
        return 0
    }
}
