//
//  RecordSessionViewController.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//
//  kgeoScan 변경:
//  - 화면: Stray 의 Metal 깊이/RGB 뷰 대신 ARSCNView 가 실제 카메라 화면을 그리고, 그 위에 ARKit
//    sceneReconstruction 메시(ARMeshAnchor)를 반투명 면으로 덮어 "어디를 찍었는지" 보여 준다 (탭하면 끄고 켬).
//  - 녹화 시작 시 ARKit 트래킹을 리셋해 월드 원점을 녹화 시작 지점으로 맞춘다
//    (서버는 원점을 lon/lat/elev 에 놓고, -z(정면)를 heading 방위로 돌린다). 메시도 이때 비워진다.
//  - 트래킹이 normal 이 된 첫 프레임에서 GPS·나침반 스냅샷을 찍는다.
//  - 촬영 안내: 트래킹 상태, LiDAR 거리(0.3~3 m), 움직임 속도 경고, 모드별 힌트.
//  - 노출 옵션(빠른 셔터)으로 모션블러를 줄인다.
//  - 녹화가 끝나면 meta.json 을 쓰고 onFinished(녹화 폴더) 를 부른다.
//  녹화 데이터(DatasetEncoder 이하)는 원본 그대로다.
//

import Foundation
import UIKit
import Metal
import ARKit
import SceneKit
import CoreData
import CoreMotion

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
    /// 설정 화면에서 넘어온 제목·모드·서버 주소. 녹화가 끝나면 meta.json 으로 저장된다.
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
    private let overlayButton = UIButton(type: .system)
    private var geoLabelTimer: Timer?
    private let sceneView = ARSCNView(frame: .zero)
    private let meshOverlay = MeshOverlayDelegate()
    private var meshSupported = false
    private let guide = CaptureGuide()
    private let exposure = ExposureController()
    private var frameCounter = 0

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

        setupSceneView()
        setupOverlayViews()
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
        sceneView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(viewTapped)))
    }

    private func setupOverlayViews() {
        for label in [geoLabel, trackingLabel, guideLabel] {
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
        guideLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        guideLabel.numberOfLines = 2
        guideLabel.isHidden = true

        overlayButton.translatesAutoresizingMaskIntoConstraints = false
        overlayButton.setTitle("메시 켜짐", for: .normal)
        overlayButton.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        overlayButton.setTitleColor(.white, for: .normal)
        overlayButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        overlayButton.layer.cornerRadius = 8
        overlayButton.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
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
        ])
        geoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        // 월드 원점을 녹화 시작 지점으로 맞춘다. 첫 프레임은 트래킹이 normal 로 돌아온 뒤 저장한다. 메시도 비워진다.
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        scheduleExposureApply()
        guide.reset()
        awaitingTracking = true
        trackingWaitStarted = Date()
        geoFix = nil
        captureStartedAt = nil
        self.startedRecording = Date()
        updateTime()
        updateLabelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.updateTime()
        }
        datasetEncoder = DatasetEncoder(arConfiguration: config, fpsDivider: FpsDividers[chosenFpsSetting])
    }

    /// 트래킹이 잡힌 첫 프레임: 이 순간의 GPS·방위가 스캔의 원점·기준 방위가 된다.
    private func beginCapture() {
        awaitingTracking = false
        geoFix = LocationService.shared.snapshot()
        startedRecording = Date()
        captureStartedAt = Date()
        startRawIMU()
    }

    private func stopRecording() {
        guard let started = self.startedRecording else {
            print("Hasn't started recording. Something is wrong.")
            return
        }
        startedRecording = nil
        awaitingTracking = false
        updateLabelTimer?.invalidate()
        updateLabelTimer = nil
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
                saveRecording(started, encoder)
                writeMeta(started: started, encoder: encoder, directory: directory)
                if let onFinished = onFinished {
                    onFinished(directory)
                } else {
                    self.dismissFunction?()
                }
            case .videoEncodingError, .directoryCreationError:
                showError(message: "영상 인코딩 중 오류가 났습니다. 다시 녹화해 주세요.")
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

    private func writeMeta(started: Date, encoder: DatasetEncoder, directory: URL) {
        var meta = scanMeta ?? ScanMeta(title: "Recording", note: "", mode: .home, serverBase: KgeoDefaults.storedServerBase)
        meta.createdAt = started
        meta.durationSeconds = Date().timeIntervalSince(started)
        meta.fpsDivider = FpsDividers[chosenFpsSetting]
        meta.savedFrames = encoder.savedFrameCount
        meta.device = ScanMeta.deviceModel()
        meta.systemVersion = UIDevice.current.systemVersion
        meta.fix = geoFix
        meta.exposureMode = ExposureController.currentMode.rawValue
        meta.meshOverlay = meshSupported
        do {
            try meta.save(to: directory)
        } catch {
            print("meta.json 저장 실패: \(error.localizedDescription)")
        }
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
    }

    // MARK: - 메시 오버레이 켜고 끄기

    @objc func viewTapped() {
        toggleOverlay()
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

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCounter += 1
        if frameCounter % 6 == 0 {
            updateGuidance(frame: frame)
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
    }

    // MARK: - 촬영 안내

    private func updateGuidance(frame: ARFrame) {
        let guidance = guide.evaluate(frame: frame)
        var trackingText = guidance.trackingText
        if let depth = guidance.centerDepth {
            trackingText += String(format: " · %.1f m", depth)
        }
        trackingLabel.text = trackingText
        trackingLabel.backgroundColor = guidance.trackingOK
            ? UIColor.black.withAlphaComponent(0.55)
            : UIColor.systemOrange.withAlphaComponent(0.85)

        var text = guidance.warning
        let isWarning = text != nil
        if text == nil {
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
        guideLabel.text = text
        guideLabel.isHidden = (text == nil)
        guideLabel.backgroundColor = isWarning
            ? UIColor.systemOrange.withAlphaComponent(0.9)
            : UIColor.black.withAlphaComponent(0.55)
    }

    private func modeHint() -> String {
        switch scanMeta?.mode ?? .home {
        case .survey:
            return "물체를 화면 중앙에 두고 0.3~3 m 거리에서 천천히 한 바퀴 돌며 찍으세요"
        case .home:
            return "벽과 바닥을 0.3~3 m 거리에서 천천히 훑으세요. 같은 곳을 두 번 지나면 더 좋습니다"
        }
    }

    private func updateGeoLabel() {
        geoLabel.text = LocationService.shared.shortStatus
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
