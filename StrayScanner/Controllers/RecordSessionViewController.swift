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
//  - 촬영 품질 (FrameQuality.swift): 프레임마다 흔들림을 예측해 '천천히' + 가벼운 햅틱(1초에 1번까지), 흔들린 프레임은
//    색 점 미리보기 누적에서 빼고 frame_quality.csv 로 남긴다. 방 모드 제자리 회전 경고, 모드별 거리 배지,
//    3분 경과 안내(녹화는 계속), 발열(serious 이상) 때 미리보기 수집 간격·화면 갱신 줄이기, 촬영 요약 통계.
//  - 면 촬영 균열 근접 모드: 예상 해상도(mm/px) 배지 녹색·황색·적색, 벽에서 30~50 cm, 정지 사진 간격 절반,
//    흔들림이 작을 때만 정지 사진 (+ 찍힐 때 가벼운 진동). 녹화 중 화면 탭 = 균열 표시(핀), 길게 누르기 또는 '선' = 두 점 선분,
//    '되돌리기' = 마지막 표시 지우기 → marks.json (CrackMarks.swift).
//  - 관리 대상(장소)을 골랐으면 위 왼쪽에 그 장소의 지난 점검 사진(반투명, 탭하면 크게)과 '지난번에 붙인 표식이 함께 찍히게' 안내.
//    정밀 정렬은 서버가 표식·특징점으로 하므로 앱은 참고 그림만 보여 준다.
//  - 굴착 기록(⛏ 트렌치): 진행 체크리스트(표식·시작 주변·양쪽 왕복·관 표시·끝 주변), 기울기 30~45° 안내, 약 1 m 마다 4K 사진,
//    관을 탭해 종류 표시(marks.json kind=utility), 프레임마다 위치 gnss.csv, 수평 정확도 5 cm 이하면 RTK 배지.
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
import CoreLocation
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

    // 촘촘한 색 점 미리보기: 0.25초마다(또는 8 cm·8° 움직이면) 깊이를 역투영해 복셀 평균
    private var pointAccumulator: PointCloudAccumulator?
    private var lastPointSampleTime: TimeInterval = 0
    private var lastPointSampleTransform: simd_float4x4?
    private var firstPointTransform: simd_float4x4?

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
    /// 정지 사진 출처: 영상 프레임(무음) | captureHighResolutionFrame(셔터음)
    private enum HiresSource {
        case videoFrame
        case highResCapture
    }
    private var hiresSource: HiresSource = .highResCapture
    private var hiresFormatLabel = ""
    private var defaultVideoFormat: ARConfiguration.VideoFormat?
    /// 면 촬영 무음: 시험할 후보 형식과 지금 시험 중인 형식
    private var formatCandidates: [ARConfiguration.VideoFormat] = []
    private var testingFormat: ARConfiguration.VideoFormat?
    private var formatTestStarted = Date()
    /// 형식 시험이 끝나 녹화를 시작해도 되는지
    private var formatReady = true
    /// rgb.mp4 크기
    private var recordVideoSize: CGSize = .zero
    private var lastHiresTransform: simd_float4x4?
    private var lastHiresRequestTime: TimeInterval = 0
    private var lastShakeSkipTime: TimeInterval = 0
    private var lastGuidanceSpeed: Float = 0
    private var lastGuidanceRotation: Float = 0
    /// 이 기기의 ARKit 광각 카메라 내부 파라미터를 한 번 저장했는지 (Object Capture 사진의 내부 파라미터 환산용)
    private var intrinsicsChecked = false

    // 촬영 품질 (FrameQuality.swift): 흔들림 예측·제자리 회전·거리 배지·발열
    private let qualityMonitor = FrameQualityMonitor()
    private let rotationDetector = InPlaceRotationDetector()
    /// 제자리 회전 경고를 쓰는지 (방 모드만 — 물체·현장조사·면은 돌거나 훑는 게 정상)
    private var inPlaceCheck = false
    private var lastQuality: FrameQualitySample?
    private var lastCenterDepth: Float?
    private let distanceLabel = PaddedLabel()
    private let shakeHaptic = UIImpactFeedbackGenerator(style: .light)
    private var lastShakeHaptic: TimeInterval = 0
    private var thermalThrottled = false
    /// 면 촬영 셔터음 방식의 정지 사진 가로 px (첫 사진에서 알게 된다)
    private var hiresStillWidth: Int?

    // 면 촬영 균열 근접 모드와 균열 표시 (CrackMarks.swift)
    private var crackMode = false
    private var crackMarks: [CrackMark] = []
    /// crackMarks 와 같은 순서의 화면 노드 (되돌리기용)
    private var markNodes: [SCNNode] = []
    private var nextMarkID = 1
    private enum LineStage {
        case off
        case needStart
        case needEnd(start: SIMD3<Float>, source: String, node: SCNNode)
    }
    private var lineStage: LineStage = .off
    private let markLineButton = UIButton(type: .system)
    private let markUndoButton = UIButton(type: .system)
    private var markRow: UIStackView?
    private let markHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let stillHaptic = UISelectionFeedbackGenerator()
    /// 탭 결과처럼 잠깐 보여 줄 안내 (10 Hz 안내 갱신이 바로 덮어쓰지 않게)
    private var noticeText: String?
    private var noticeUntil = Date.distantPast

    // 관리 대상(장소): 지난 점검 사진 (같은 곳·같은 방향에서 찍게 돕는 참고 그림)
    private let siteThumbView = UIImageView()
    private let siteCaptionLabel = PaddedLabel()
    private var siteThumbLarge = false
    private var siteThumbWidth: NSLayoutConstraint?
    private var siteThumbHeight: NSLayoutConstraint?

    // 굴착 기록 (⛏ 트렌치): 왕복 세기·진행 체크리스트·관 종류 표시·gnss.csv
    private var trenchMode = false
    /// 고해상도 정지 사진(hires/)을 찍는 모드: 면 촬영 또는 굴착 기록
    private var hiresMode = false
    private let passCounter = TrenchPassCounter()
    private var trenchMarkersPlaced = false
    private var trenchStartContext = false
    private var trenchEndContext = false
    private var contextFarSeconds: TimeInterval = 0
    private var lastTrenchUpdate: TimeInterval = 0
    private var utilityClass: UtilityClass = .unknown
    private let utilityButton = UIButton(type: .system)
    private let checklistStack = UIStackView()
    private var checklistButtons: [String: UIButton] = [:]
    private var gnssRows = 0
    private var gnssRTKRows = 0
    private var gnssAccessorySeen = false

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
        trenchMode = scanMeta?.capture == "trench"
        hiresMode = areaMode || trenchMode
        areaSurface = scanMeta?.area?.surface ?? "auto"
        crackMode = areaMode && scanMeta?.area?.crackMode == true
        if areaMode {
            guide.thresholds = crackMode ? CaptureGuide.crack : CaptureGuide.area
        } else if trenchMode {
            guide.thresholds = CaptureGuide.trench
        } else if objectMode {
            guide.thresholds = CaptureGuide.object
        } else {
            guide.thresholds = (scanMeta?.mode ?? .home) == .survey ? CaptureGuide.survey : CaptureGuide.home
        }
        qualityMonitor.limits = areaMode ? FrameQualityMonitor.area : FrameQualityMonitor.standard
        inPlaceCheck = !objectMode && !areaMode && (scanMeta?.mode ?? .home) == .home
        setupSceneView()
        setupOverlayViews()
        if objectMode {
            setupObjectViews()
        }
        if areaMode || trenchMode {
            setupMarkViews()
        }
        if trenchMode {
            setupTrenchViews()
        }
        if scanMeta?.site != nil {
            setupSiteViews()
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
        if trenchMode {
            LocationService.shared.setNavigationAccuracy(false)
        }
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
        sceneView.preferredFramesPerSecond = CaptureTuning.viewFPS
        sceneView.backgroundColor = .black
        let tap = UITapGestureRecognizer(target: self, action: #selector(viewTapped(_:)))
        if areaMode {
            // 면 촬영: 길게 누르면 균열 선의 시작점
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(viewLongPressed(_:)))
            longPress.minimumPressDuration = CaptureTuning.markLongPress
            tap.require(toFail: longPress)
            sceneView.addGestureRecognizer(longPress)
        }
        sceneView.addGestureRecognizer(tap)
    }

    private func setupOverlayViews() {
        for label in [geoLabel, trackingLabel, guideLabel, statsLabel, distanceLabel] {
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
        distanceLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        distanceLabel.text = "거리 —"
        shakeHaptic.prepare()

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
            distanceLabel.topAnchor.constraint(equalTo: trackingLabel.bottomAnchor, constant: 6),
            distanceLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            distanceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 12),
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

    // MARK: - 굴착 기록 (⛏ 트렌치)

    /// 위 오른쪽(거리 배지 아래) 진행 체크리스트. 표식·시작·끝은 눌러서 직접 체크할 수도 있다 (왕복·관 표시는 앱이 센다)
    private func setupTrenchViews() {
        checklistStack.translatesAutoresizingMaskIntoConstraints = false
        checklistStack.axis = .vertical
        checklistStack.alignment = .trailing
        checklistStack.spacing = 4
        for key in ["markers", "start", "passes", "utility", "end"] {
            let button = UIButton(type: .system)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
            button.setTitleColor(.white, for: .normal)
            button.layer.cornerRadius = 7
            button.contentEdgeInsets = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
            button.accessibilityIdentifier = key
            button.addTarget(self, action: #selector(checklistTapped(_:)), for: .touchUpInside)
            checklistStack.addArrangedSubview(button)
            checklistButtons[key] = button
        }
        view.addSubview(checklistStack)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            checklistStack.topAnchor.constraint(equalTo: distanceLabel.bottomAnchor, constant: 8),
            checklistStack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
        ])
        updateChecklist()
        // 외부 RTK 수신기가 있으면 그 값을 가장 높은 정확도로 받는다
        LocationService.shared.setNavigationAccuracy(true)
    }

    @objc private func checklistTapped(_ sender: UIButton) {
        switch sender.accessibilityIdentifier ?? "" {
        case "markers":
            trenchMarkersPlaced.toggle()
        case "start":
            trenchStartContext.toggle()
        case "end":
            trenchEndContext.toggle()
        default:
            showNotice("왕복과 관 표시는 앱이 셉니다")
            return
        }
        updateChecklist()
    }

    private func updateChecklist() {
        guard trenchMode else { return }
        let legs = passCounter.legsIncludingCurrent
        let items: [(key: String, done: Bool, title: String)] = [
            ("markers", trenchMarkersPlaced, "기준 표식 3~4개 붙임"),
            ("start", trenchStartContext, "시작: 주변 지면·연석 3~5 m"),
            ("passes", legs >= 2, "가장자리 양쪽 왕복 \(min(legs, 9))/2"),
            ("utility", !crackMarks.isEmpty, "관 종류 표시 \(crackMarks.count)"),
            ("end", trenchEndContext, "끝: 주변 지면 다시"),
        ]
        for item in items {
            guard let button = checklistButtons[item.key] else { continue }
            button.setTitle((item.done ? "✓ " : "○ ") + item.title, for: .normal)
            button.backgroundColor = item.done ? UIColor.systemGreen.withAlphaComponent(0.75)
                : UIColor.black.withAlphaComponent(0.55)
        }
    }

    /// [관: 종류 ▾] 메뉴: 가스·상수·하수·전력·통신·난방·모름
    private func makeUtilityMenu() -> UIMenu {
        let actions = UtilityClass.allCases.map { item in
            UIAction(title: item.label, state: item == utilityClass ? .on : .off) { [weak self] _ in
                self?.utilityClass = item
                self?.updateMarkButtons()
            }
        }
        return UIMenu(title: "관 종류 — 고른 뒤 화면의 관을 탭", children: actions)
    }

    private func resetTrenchProgress() {
        passCounter.reset()
        trenchStartContext = false
        trenchEndContext = false
        contextFarSeconds = 0
        lastTrenchUpdate = 0
        gnssRows = 0
        gnssRTKRows = 0
        gnssAccessorySeen = false
        updateChecklist()
    }

    /// 10 Hz: 왕복 세기, 시작·끝 주변 지면 (화면 중앙이 2.5 m 넘게 멀거나 LiDAR 밖이 1.5초)
    private func updateTrenchProgress(frame: ARFrame, depth: Float?, capturing: Bool) {
        guard trenchMode, capturing else { return }
        let dt = lastTrenchUpdate > 0 ? min(frame.timestamp - lastTrenchUpdate, 0.5) : 0
        lastTrenchUpdate = frame.timestamp
        let position = frame.camera.transform.columns.3
        if passCounter.update(position: SIMD3<Float>(position.x, position.y, position.z)) {
            markHaptic.impactOccurred()
            showNotice(passCounter.legs >= 2 ? "왕복 \(passCounter.legs)구간 — 양쪽을 다 찍었습니다"
                       : "1구간 끝 — 반대쪽 가장자리를 따라 돌아오며 찍으세요")
        }
        var far = true
        if let d = depth {
            far = d >= CaptureTuning.trenchContextDepth
        }
        contextFarSeconds = far ? contextFarSeconds + dt : 0
        let elapsed = captureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if !trenchStartContext && elapsed <= CaptureTuning.trenchStartWindow
            && contextFarSeconds >= CaptureTuning.trenchContextHold {
            trenchStartContext = true
            markHaptic.impactOccurred()
            showNotice("✓ 시작 주변 지면 — 이제 트렌치 가장자리를 따라 찍으세요")
        } else if trenchStartContext && !trenchEndContext && passCounter.legsIncludingCurrent >= 1
                    && elapsed >= CaptureTuning.trenchEndAfter && contextFarSeconds >= CaptureTuning.trenchContextHold {
            trenchEndContext = true
            markHaptic.impactOccurred()
            showNotice("✓ 끝 주변 지면 — 다 찍었으면 멈추세요")
        }
        updateChecklist()
    }

    /// 카메라가 수평 아래로 내려다보는 각 (°): 0 = 수평, 90 = 바로 아래
    private func trenchTilt(frame: ARFrame) -> Float {
        let up = max(-1, min(1, frame.camera.transform.columns.2.y))
        return asin(up) * 180 / Float.pi
    }

    /// 트렌치를 볼 때(가까운 깊이)만: 30~45° 권장, 15° 미만이면 더 기울이고 70° 넘으면 덜 내려다보게
    private func trenchTiltWarning(frame: ARFrame, depth: Float?) -> String? {
        guard let d = depth, d < CaptureTuning.trenchContextDepth else { return nil }
        let tilt = trenchTilt(frame: frame)
        let range = "\(Int(CaptureTuning.trenchTiltNear))~\(Int(CaptureTuning.trenchTiltFar))°"
        if tilt < CaptureTuning.trenchTiltLow {
            return "폰을 트렌치 안쪽으로 더 기울이세요 (\(range), 지금 \(Int(tilt.rounded()))°)"
        }
        if tilt > CaptureTuning.trenchTiltHigh {
            return "너무 내려다봅니다 — \(range) 로 비스듬히, 반대쪽 벽까지 보이게 (지금 \(Int(tilt.rounded()))°)"
        }
        return nil
    }

    private func trenchHint() -> String {
        let photos = hiresCount > 0 ? " · 사진 \(hiresCount)장" : ""
        if startedRecording == nil {
            return "⚠︎ 트렌치 안에 들어가지 마세요 · 기준 표식 3~4개를 붙이고, 시작은 주변 지면·연석·맨홀이 3~5 m 보이게"
        }
        if !trenchStartContext {
            return "먼저 주변 지면·연석·맨홀이 3~5 m 들어가게 천천히 둘러보세요" + photos
        }
        let legs = passCounter.legsIncludingCurrent
        if legs < 2 {
            return "가장자리를 따라 걸으며 안쪽으로 30~45° 기울여 찍으세요 (왕복 \(legs)/2) · 관은 탭해서 종류 표시" + photos
        }
        if !trenchEndContext {
            return "양쪽을 다 찍었습니다 — 끝으로 주변 지면·연석을 3~5 m 넣고 멈추세요" + photos
        }
        return "다 찍었습니다 — 빠진 관이 있으면 탭해서 종류를 표시하고 멈추세요" + photos
    }

    /// 촬영 요약 경고: 왕복·주변 지면·표식
    private func applyTrenchStats(_ stats: inout CaptureStats) {
        guard trenchMode else { return }
        let legs = passCounter.legsIncludingCurrent
        if legs < 2 {
            stats.warnings.append("트렌치 양쪽 왕복이 부족합니다 (\(legs)/2) — 반대쪽 가장자리에서도 찍어야 관의 아래쪽과 벽이 나옵니다")
        }
        if !trenchStartContext || !trenchEndContext {
            stats.warnings.append("시작·끝에 주변 지면(연석·맨홀)을 3~5 m 넣지 않았습니다 — 원지반(깊이 기준)과 지도 맞춤이 약해집니다")
        }
        if !trenchMarkersPlaced {
            stats.warnings.append("기준 표식 체크가 없습니다 — 표식 3~4개가 찍혀야 가설기준점·축척으로 씁니다")
        }
    }

    /// 관리 대상: 위 왼쪽에 장소 이름과 지난 점검 사진 (반투명, 탭하면 크게). 사진은 서버에서 받는다 (없거나 오프라인이면 이름만)
    private func setupSiteViews() {
        guard let site = scanMeta?.site else { return }
        siteCaptionLabel.translatesAutoresizingMaskIntoConstraints = false
        siteCaptionLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        siteCaptionLabel.textColor = .white
        siteCaptionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        siteCaptionLabel.layer.cornerRadius = 8
        siteCaptionLabel.layer.masksToBounds = true
        siteCaptionLabel.numberOfLines = 2
        siteCaptionLabel.text = "장소: " + site.name
        view.addSubview(siteCaptionLabel)

        siteThumbView.translatesAutoresizingMaskIntoConstraints = false
        siteThumbView.contentMode = .scaleAspectFill
        siteThumbView.clipsToBounds = true
        siteThumbView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        siteThumbView.layer.cornerRadius = 8
        siteThumbView.layer.borderWidth = 1
        siteThumbView.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        siteThumbView.alpha = CaptureTuning.siteThumbAlpha
        siteThumbView.isHidden = true
        siteThumbView.isUserInteractionEnabled = true
        siteThumbView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(siteThumbTapped)))
        view.addSubview(siteThumbView)

        let safe = view.safeAreaLayoutGuide
        let width = siteThumbView.widthAnchor.constraint(equalToConstant: CaptureTuning.siteThumbWidth)
        let height = siteThumbView.heightAnchor.constraint(equalToConstant: CaptureTuning.siteThumbWidth)
        siteThumbWidth = width
        siteThumbHeight = height
        NSLayoutConstraint.activate([
            siteCaptionLabel.topAnchor.constraint(equalTo: geoLabel.bottomAnchor, constant: 6),
            siteCaptionLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            siteCaptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            siteThumbView.topAnchor.constraint(equalTo: siteCaptionLabel.bottomAnchor, constant: 4),
            siteThumbView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            width,
            height,
        ])
        loadSiteThumb(site)
    }

    private func loadSiteThumb(_ site: SiteRef) {
        let endpoints = ServerEndpoints(string: scanMeta?.serverBase ?? KgeoDefaults.storedServerBase)
        guard let url = SiteClient.thumbURL(site.lastThumbUrl, endpoints: endpoints) else {
            siteCaptionLabel.text = "장소: \(site.name)\n지난 점검 사진 없음"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = CaptureTuning.siteRequestTimeout
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let image = image {
                    self.siteThumbView.image = image
                    self.siteThumbView.isHidden = false
                    self.applySiteThumbSize()
                    self.siteCaptionLabel.text = "장소: \(site.name)\n지난 점검 사진 (탭하면 크게)"
                } else {
                    self.siteCaptionLabel.text = "장소: \(site.name)\n지난 점검 사진을 받지 못했습니다"
                }
            }
        }.resume()
    }

    @objc private func siteThumbTapped() {
        siteThumbLarge.toggle()
        applySiteThumbSize()
        UIView.animate(withDuration: 0.2) {
            self.siteThumbView.alpha = self.siteThumbLarge ? CaptureTuning.siteThumbLargeAlpha : CaptureTuning.siteThumbAlpha
            self.view.layoutIfNeeded()
        }
    }

    /// 사진 비율대로 (세로 길이는 가로의 0.5~1.6배)
    private func applySiteThumbSize() {
        let width = siteThumbLarge ? CaptureTuning.siteThumbLargeWidth : CaptureTuning.siteThumbWidth
        var aspect: CGFloat = 1
        if let size = siteThumbView.image?.size, size.width > 0 {
            aspect = min(max(size.height / size.width, 0.5), 1.6)
        }
        siteThumbWidth?.constant = width
        siteThumbHeight?.constant = width * aspect
    }

    /// 관리 대상을 골랐을 때: 녹화 전과 시작 직후 '지난번에 붙인 표식이 함께 찍히게'
    private func siteHint() -> String? {
        guard scanMeta?.site != nil else { return nil }
        if startedRecording == nil {
            return "지난번에 붙인 표식이 함께 찍히게 해 주세요 — 위 왼쪽 지난 사진과 같은 곳·같은 방향에서"
        }
        guard let began = captureStartedAt, Date().timeIntervalSince(began) < CaptureTuning.siteHintSeconds else {
            return nil
        }
        return "지난번에 붙인 표식이 함께 찍히게 해 주세요"
    }

    /// 표시 버튼 (녹화 중에만 보인다): 면 촬영 [선] [되돌리기], 굴착 기록 [관: 종류 ▾] [되돌리기]
    private func setupMarkViews() {
        let first: UIButton
        if trenchMode {
            // 굴착 기록: 관 종류를 고른 뒤 화면의 관을 탭
            styleButton(utilityButton, title: "관: \(utilityClass.label) ▾")
            utilityButton.showsMenuAsPrimaryAction = true
            utilityButton.menu = makeUtilityMenu()
            first = utilityButton
        } else {
            styleButton(markLineButton, title: "선")
            markLineButton.addTarget(self, action: #selector(markLineTapped), for: .touchUpInside)
            first = markLineButton
        }
        styleButton(markUndoButton, title: "되돌리기")
        markUndoButton.addTarget(self, action: #selector(markUndoTapped), for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [first, markUndoButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.isHidden = true
        view.addSubview(row)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: statsLabel.topAnchor, constant: -8),
        ])
        markRow = row
        markHaptic.prepare()
        stillHaptic.prepare()
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
            defaultVideoFormat = config.videoFormat
            guide.reset()
            if hiresMode && areaSilentRequested {
                // 무음 정지 사진: 높은 해상도 형식을 하나씩 켜서 깊이·비율을 확인한 뒤 고른다
                beginSilentFormatSearch(config)
            } else {
                if hiresMode {
                    useShutterStills(config)
                }
                session.run(config)
            }
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
        pointAccumulator = PointCloudAccumulator(voxelSize: objectMode ? 0.003 : 0.01)
        lastPointSampleTime = 0
        lastPointSampleTransform = nil
        firstPointTransform = nil
        qualityMonitor.reset()
        rotationDetector.reset()
        lastQuality = nil
        lastShakeHaptic = 0
        clearMarks()
        self.startedRecording = Date()
        updateTime()
        updateLabelTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.updateTime()
        }
        // 무음 면 촬영으로 높은 해상도 형식이면 rgb.mp4 는 가로 1920 으로 줄여 녹화 (내부 파라미터도 환산)
        let captureSize = config.videoFormat.imageResolution
        var outputSize: CGSize?
        if hiresMode && hiresSource == .videoFrame && captureSize.width > 1920 {
            let scale = 1920 / captureSize.width
            var scaledHeight = (captureSize.height * scale).rounded()
            if Int(scaledHeight) % 2 == 1 {
                scaledHeight -= 1
            }
            outputSize = CGSize(width: 1920, height: scaledHeight)
        }
        recordVideoSize = outputSize ?? captureSize
        datasetEncoder = DatasetEncoder(arConfiguration: config, fpsDivider: FpsDividers[chosenFpsSetting],
                                        outputVideoSize: outputSize, recordGnss: trenchMode)
        statsLabel.isHidden = false
        hiresRecorder = nil
        hiresAccepting = false
        hiresInFlight = false
        hiresCount = 0
        hiresWritten = 0
        hiresSkipped = 0
        lastHiresTransform = nil
        lastHiresRequestTime = 0
        if hiresMode, let encoder = datasetEncoder {
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
        qualityMonitor.resetStats()
        rotationDetector.reset()
        markRow?.isHidden = false
        updateMarkButtons()
        resetTrenchProgress()
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
        markRow?.isHidden = true
        cancelPendingLine()
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
            pointAccumulator = nil
            showError(message: "녹화된 프레임이 없습니다. 트래킹이 잡힌 뒤 조금 더 길게 녹화해 주세요.", popOnDismiss: false)
            return
        }
        switch encoder.status {
            case .allGood:
                var stats = guide.summary()
                applyQualityStats(&stats)
                applyTrenchStats(&stats)
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
                hiresWritten = hiresRecorder?.finish(surface: trenchMode ? "trench" : areaSurface,
                                                     formatRecommended: hiresFormatRecommended,
                                                     source: hiresSourceName, format: hiresFormatLabel,
                                                     videoSize: videoSizeText) ?? 0
                hiresRecorder = nil
                finishRecording(started: started, encoder: encoder, directory: directory, stats: stats, mesh: mesh)
            case .videoEncodingError, .directoryCreationError:
                showError(message: "영상 인코딩 중 오류가 났습니다. 다시 녹화해 주세요.")
        }
    }

    private func finishRecording(started: Date, encoder: DatasetEncoder, directory: URL, stats: CaptureStats,
                                 mesh: MeshSnapshot?) {
        // 균열·관 표시가 있으면 marks.json (odometry.csv 와 같은 폴더, 같은 ARKit 월드 좌표)
        if (areaMode || trenchMode) && !crackMarks.isEmpty {
            do {
                try CrackMarks.write(crackMarks, to: directory)
            } catch {
                print("marks.json 저장 실패: \(error.localizedDescription)")
            }
        }
        saveRecording(started, encoder)
        writeMeta(started: started, encoder: encoder, directory: directory, stats: stats)
        if let accumulator = pointAccumulator {
            var pointCrop: PreviewCrop?
            if objectMode, let center = objectTracker.center {
                pointCrop = PreviewCrop(center: center, radius: objectTracker.radius)
            }
            PreviewBuilder.shared.startPoints(directory: directory, accumulator: accumulator, crop: pointCrop,
                                              start: firstPointTransform)
        }
        pointAccumulator = nil
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
                                 hiresFormatRecommended: hiresFormatRecommended, hiresSource: hiresSourceName,
                                 hiresFormat: hiresFormatLabel, videoSize: videoSizeText,
                                 crackMode: crackMode ? true : nil,
                                 crackMarks: crackMarks.isEmpty ? nil : crackMarks.count)
        } else if trenchMode {
            meta.capture = "trench"
            meta.trench = TrenchInfo(mode: 1, hires: hiresWritten, hiresSkipped: hiresSkipped, hiresSource: hiresSourceName,
                                     hiresFormat: hiresFormatLabel, videoSize: videoSizeText,
                                     passes: passCounter.legsIncludingCurrent, markersPlaced: trenchMarkersPlaced,
                                     startContext: trenchStartContext, endContext: trenchEndContext,
                                     utilityMarks: crackMarks.count, gnssRows: gnssRows,
                                     rtkRatio: gnssRows > 0 ? Float(gnssRTKRows) / Float(gnssRows) : nil,
                                     gnssAccessory: gnssAccessorySeen ? true : nil)
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
            var text: String
            if hiresMode {
                megabytes += Double(hiresCount) * 3.5
                text = String(format: "%d 프레임 · 고해상도 %d장 · ≈%.0f MB", frames, hiresCount, megabytes)
            } else {
                text = String(format: "%d 프레임 · ≈%.0f MB", frames, megabytes)
            }
            if !crackMarks.isEmpty {
                text += " · 표시 \(crackMarks.count)"
            }
            if seconds >= CaptureTuning.longCaptureStart {
                text += " · \(Int(CaptureTuning.longCaptureStart / 60))분 넘음"
            }
            if thermalThrottled {
                text += " · 발열: 미리보기 수집 줄임"
            }
            statsLabel.text = text
        }
    }

    // MARK: - 메시 오버레이 / 탭

    @objc func viewTapped(_ gesture: UITapGestureRecognizer) {
        if objectMode {
            designateObject(at: gesture.location(in: sceneView))
        } else if areaMode || trenchMode {
            handleMarkTap(at: gesture.location(in: sceneView))
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
            qualityMonitor.reset()
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
        guard let c = worldPoint(at: point, frame: frame)?.position else {
            showNotice("물체를 찾지 못했습니다 — 조금 더 가까이에서 다시 탭하세요")
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

    /// 화면 점의 월드 좌표: ARKit raycast(추정 면 → 감지된 면) → LiDAR 깊이 역투영. source = raycast | depth
    private func worldPoint(at point: CGPoint, frame: ARFrame) -> (position: simd_float3, source: String)? {
        if let query = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
           let hit = session.raycast(query).first {
            return (simd_make_float3(hit.worldTransform.columns.3), "raycast")
        }
        if let query = sceneView.raycastQuery(from: point, allowing: .existingPlaneGeometry, alignment: .any),
           let hit = session.raycast(query).first {
            return (simd_make_float3(hit.worldTransform.columns.3), "raycast")
        }
        if let depthPoint = unproject(viewPoint: point, frame: frame) {
            return (depthPoint, "depth")
        }
        return nil
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
        if !formatReady {
            checkSilentFormat(frame: frame)
            if frameCounter % 6 == 0 {
                updateGuidance(frame: frame, capturing: false)
            }
            return
        }
        if !intrinsicsChecked, case .normal = frame.camera.trackingState {
            intrinsicsChecked = true
            if CameraIntrinsics.cached() == nil, let format = arConfiguration?.videoFormat,
               format.captureDeviceType == .builtInWideAngleCamera, FormatCatalog.isFourThree(format) {
                CameraIntrinsics.store(CameraIntrinsics(frame: frame))
            }
        }
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
        // 흔들림 예측은 프레임마다 (frame_quality.csv 한 행 + '천천히' + 색 점 누적 판단)
        var blurDepth = lastCenterDepth
        if objectMode, objectTracker.isSet {
            blurDepth = objectTracker.distance
        }
        let quality = qualityMonitor.update(frame: frame, depth: blurDepth, recording: capturing)
        lastQuality = quality
        if capturing, qualityMonitor.shaking, frame.timestamp - lastShakeHaptic >= CaptureTuning.hapticInterval {
            lastShakeHaptic = frame.timestamp
            shakeHaptic.impactOccurred()
        }
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
        var gnss: GnssSample?
        if trenchMode {
            // 굴착 기록: 프레임마다 그 순간의 위치 (RTK 수신기를 연결했으면 그 값) → gnss.csv
            let sample = GnssSample(location: LocationService.shared.location)
            gnssRows += 1
            if sample.isRTK {
                gnssRTKRows += 1
            }
            if sample.source == "accessory" {
                gnssAccessorySeen = true
            }
            gnss = sample
        }
        encoder.add(frame: frame, quality: quality, gnss: gnss)
        considerThumbnail(frame: frame, directory: encoder.directory.absoluteURL.standardizedFileURL)
        considerColorKeyframe(frame: frame)
        considerPointSample(frame: frame)
        considerHighResolution(frame: frame)
    }

    /// 색 점 미리보기 샘플: 0.25초마다, 또는 8 cm 이동·8° 회전 때 (최소 0.1초 간격, 앞 샘플을 합치는 중이면 건너뜀).
    /// 흔들림 예측이 8 px 를 넘는 프레임은 빼고, 발열이 serious 이상이면 0.75초·20 cm·20° 로 늘린다 (값은 CaptureTuning)
    private func considerPointSample(frame: ARFrame) {
        guard let accumulator = pointAccumulator, frame.sceneDepth != nil else { return }
        guard case .normal = frame.camera.trackingState else { return }
        if let quality = lastQuality, quality.blurPx > qualityMonitor.limits.skipAbove {
            return
        }
        let elapsed = frame.timestamp - lastPointSampleTime
        guard elapsed >= (thermalThrottled ? CaptureTuning.hotPointMinInterval : CaptureTuning.pointMinInterval) else { return }
        let transform = frame.camera.transform
        var due = elapsed >= (thermalThrottled ? CaptureTuning.hotPointInterval : CaptureTuning.pointInterval)
        if !due, let last = lastPointSampleTransform {
            let moved = simd_distance(transform.columns.3, last.columns.3)
            let delta = simd_quatf(transform) * simd_quatf(last).inverse
            var turned = delta.angle * 180 / Float.pi
            if turned > 180 {
                turned = 360 - turned
            }
            due = moved >= (thermalThrottled ? CaptureTuning.hotPointMove : CaptureTuning.pointMove)
                || turned >= (thermalThrottled ? CaptureTuning.hotPointTurn : CaptureTuning.pointTurn)
        }
        guard due else { return }
        var crop: PreviewCrop?
        if objectMode, let center = objectTracker.center {
            crop = PreviewCrop(center: center, radius: objectTracker.radius)
        }
        if accumulator.add(frame: frame, crop: crop) {
            lastPointSampleTime = frame.timestamp
            lastPointSampleTransform = transform
            if firstPointTransform == nil {
                firstPointTransform = transform
            }
        }
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
        guard hiresMode, hiresAccepting, !hiresInFlight, hiresCount < HiresRecorder.maxShots else { return }
        guard case .normal = frame.camera.trackingState else { return }
        guard frame.timestamp - lastHiresRequestTime >= CaptureTuning.hiresMinInterval else { return }
        let transform = frame.camera.transform
        if let last = lastHiresTransform {
            let moved = simd_distance(transform.columns.3, last.columns.3)
            let delta = simd_quatf(transform) * simd_quatf(last).inverse
            var turned = delta.angle * 180 / Float.pi
            if turned > 180 {
                turned = 360 - turned
            }
            // 균열 근접 모드는 간격을 절반으로 (겹침을 늘린다), 굴착 기록은 약 1 m·15° (근경·원경)
            let minMove = crackMode ? CaptureTuning.crackHiresMove
                : (trenchMode ? CaptureTuning.trenchHiresMove : CaptureTuning.hiresMove)
            let minTurn = crackMode ? CaptureTuning.crackHiresTurn
                : (trenchMode ? CaptureTuning.trenchHiresTurn : CaptureTuning.hiresTurn)
            guard moved >= minMove || turned >= minTurn else { return }
        }
        // 균열 근접 모드는 흔들림이 아주 작을 때만 (옮기고 잠깐 멈추면 찍힌다)
        let blurLimit = crackMode ? CaptureTuning.crackStillMaxBlur : qualityMonitor.limits.skipAbove
        let blurred = (lastQuality?.blurPx ?? 0) > blurLimit
        if lastGuidanceSpeed > CaptureTuning.hiresSkipSpeed || lastGuidanceRotation > CaptureTuning.hiresSkipRotation
            || blurred {
            if frame.timestamp - lastShakeSkipTime >= 1 {
                lastShakeSkipTime = frame.timestamp
                hiresSkipped += 1
            }
            return
        }
        lastHiresRequestTime = frame.timestamp
        if hiresSource == .videoFrame {
            // 무음: 이 영상 프레임을 그대로 정지 사진으로 (픽셀은 바로 복사, 저장은 백그라운드)
            guard let recorder = hiresRecorder else { return }
            hiresCount += 1
            lastHiresTransform = transform
            recorder.add(frame: frame, index: hiresCount, source: "video_frame")
            if crackMode {
                stillHaptic.selectionChanged()
            }
            return
        }
        hiresInFlight = true
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
        hiresStillWidth = CVPixelBufferGetWidth(frame.capturedImage)
        if hiresFormatLabel.isEmpty {
            hiresFormatLabel = "\(CVPixelBufferGetWidth(frame.capturedImage))x\(CVPixelBufferGetHeight(frame.capturedImage)) still"
        }
        recorder.add(frame: frame, index: hiresCount, source: "high_res_capture")
        if crackMode {
            stillHaptic.selectionChanged()
        }
    }

    private var areaSilentRequested: Bool {
        (UserDefaults.standard.string(forKey: KgeoDefaults.areaStillModeKey) ?? "silent") == "silent"
    }

    private var hiresSourceName: String {
        hiresSource == .videoFrame ? "video_frame" : "high_res_capture"
    }

    private var videoSizeText: String {
        "\(Int(recordVideoSize.width))x\(Int(recordVideoSize.height))"
    }

    /// 셔터음 방식 (captureHighResolutionFrame)
    private func useShutterStills(_ config: ARWorldTrackingConfiguration) {
        preferHighResolutionStillFormat(config)
        hiresSource = .highResCapture
        hiresFormatLabel = ""
    }

    /// 무음 후보 형식을 하나씩 켜 본다. 이미 시험해서 안 된다고 저장된 형식은 건너뛴다
    private func beginSilentFormatSearch(_ config: ARWorldTrackingConfiguration) {
        formatCandidates = FormatCatalog.silentCandidates().filter { format in
            if let known = FormatCatalog.result(for: format), known.tested {
                return known.usableForArea
            }
            return true
        }
        formatReady = false
        recordButton.isUserInteractionEnabled = false
        tryNextSilentFormat(config)
    }

    private func tryNextSilentFormat(_ config: ARWorldTrackingConfiguration) {
        guard !formatCandidates.isEmpty else {
            // 무음으로 쓸 형식이 없다 → 기본 형식 + 셔터음 방식
            testingFormat = nil
            if let original = defaultVideoFormat {
                config.videoFormat = original
            }
            useShutterStills(config)
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
            finishFormatSearch()
            return
        }
        let candidate = formatCandidates.removeFirst()
        testingFormat = candidate
        let token = Date()
        formatTestStarted = token
        config.videoFormat = candidate
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        // 프레임이 아예 오지 않는 형식
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self, self.testingFormat != nil, self.formatTestStarted == token,
                  let config = self.arConfiguration else { return }
            var failed = FormatCatalog.makeResult(candidate, frame: nil)
            failed.tested = true
            FormatCatalog.store(failed)
            self.testingFormat = nil
            self.tryNextSilentFormat(config)
        }
    }

    /// 시험 중인 형식의 첫 프레임들: 깊이가 오고 RGB·깊이 비율이 같으면 채택
    private func checkSilentFormat(frame: ARFrame) {
        guard let candidate = testingFormat, let config = arConfiguration else { return }
        let elapsed = Date().timeIntervalSince(formatTestStarted)
        let width = CVPixelBufferGetWidth(frame.capturedImage)
        let height = CVPixelBufferGetHeight(frame.capturedImage)
        if (width != Int(candidate.imageResolution.width) || height != Int(candidate.imageResolution.height)) && elapsed < 3 {
            return   // 앞 형식의 프레임
        }
        if frame.sceneDepth == nil && elapsed < 2.5 {
            return   // 깊이는 첫 몇 프레임 뒤에 오기도 한다
        }
        var result = FormatCatalog.makeResult(candidate, frame: frame)
        result.tested = true
        FormatCatalog.store(result)
        testingFormat = nil
        if result.usableForArea {
            hiresSource = .videoFrame
            hiresFormatLabel = FormatCatalog.shortKey(candidate)
            hiresFormatRecommended = candidate.isRecommendedForHighResolutionFrameCapturing
            finishFormatSearch()
        } else {
            tryNextSilentFormat(config)
        }
    }

    private func finishFormatSearch() {
        formatReady = true
        recordButton.isUserInteractionEnabled = true
        updateFpsSetting()
        scheduleExposureApply()
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
        var count = hiresCount > 0 ? " · 고해상도 \(hiresCount)장" : ""
        if !crackMarks.isEmpty {
            count += " · 균열 표시 \(crackMarks.count)개"
        }
        if crackMode {
            let near = Int((CaptureTuning.crackAdviceNear * 100).rounded())
            let far = Int((CaptureTuning.crackAdviceFar * 100).rounded())
            let step = Int((CaptureTuning.crackHiresMove * 100).rounded())
            let marking = startedRecording != nil ? " 균열을 탭하면 표시, 길게 누르면 선." : ""
            return "균열 근접: \(crackSurfaceWord)에서 \(near)~\(far) cm, \(step) cm 옮길 때마다 잠깐 멈추면 선명한 사진이 찍힙니다."
                + marking + count
        }
        if startedRecording != nil {
            count += " · 탭: 균열 표시"
        }
        switch areaSurface {
        case "floor":
            return "폰을 아래로 향해 바닥(트렌치)을 내려다보며 40 cm~1.2 m 거리로 천천히 지그재그로 겹치게 훑으세요" + count
        case "wall":
            return "벽을 정면으로 보며 40 cm~1.2 m 거리로 천천히 지그재그로 겹치게 훑으세요" + count
        default:
            return "대상 면에서 40 cm~1.2 m 거리로 천천히 지그재그로 겹치게 훑으세요" + count
        }
    }

    /// 미리보기 정점 색용 키프레임 (트래킹 정상이고 흔들리지 않은 프레임만, 발열 때는 1.5초 이상 간격)
    private func considerColorKeyframe(frame: ARFrame) {
        let interval = thermalThrottled ? max(keyframeInterval, CaptureTuning.hotKeyframeInterval) : keyframeInterval
        guard meshSupported, frame.timestamp - lastKeyframeTime >= interval else { return }
        guard case .normal = frame.camera.trackingState else { return }
        if let quality = lastQuality, quality.blurPx > qualityMonitor.limits.skipAbove {
            return
        }
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
        lastCenterDepth = guidance.centerDepth
        trackingLabel.text = guidance.trackingText
        trackingLabel.backgroundColor = guidance.trackingOK
            ? UIColor.black.withAlphaComponent(0.55)
            : UIColor.systemOrange.withAlphaComponent(0.85)
        updateDistanceBadge(frame: frame, depth: guidance.centerDepth)
        updateTrenchProgress(frame: frame, depth: guidance.centerDepth, capturing: capturing)
        updateThermalState()
        // 제자리 회전 (방 모드, 녹화 중)
        let rotatingInPlace = capturing && inPlaceCheck
            && rotationDetector.update(transform: frame.camera.transform, timestamp: frame.timestamp)

        if !formatReady {
            let label = testingFormat.map { FormatCatalog.label($0) } ?? ""
            guideLabel.text = "무음 고해상도 사진용 카메라 형식 확인 중… \(label)"
            guideLabel.isHidden = false
            guideLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            return
        }
        if awaitingFrameFix { return }

        var text: String?
        var isNotice = false
        if !guidance.trackingOK {
            text = guidance.warning
        } else if let notice = activeNotice() {
            text = notice
            isNotice = true
        } else if capturing, qualityMonitor.shaking {
            text = String(format: "천천히 — 흔들림 %.0f px", lastQuality?.blurPx ?? 0)
            guide.countWarning("shake")
        } else if let notice = captureTimeNotice(capturing: capturing) {
            text = notice
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
        } else if trenchMode, capturing, let tilt = trenchTiltWarning(frame: frame, depth: guidance.centerDepth) {
            text = tilt
            guide.countWarning("tilt")
        } else if rotatingInPlace {
            text = "옆으로 걸으면서 찍어 주세요 — 제자리에서 돌기만 하면 3D 가 비어요"
            guide.countWarning("in_place")
        } else {
            text = guidance.warning
        }
        let isWarning = text != nil
        if text == nil {
            if let hint = siteHint() {
                text = hint
            } else if objectMode {
                text = objectTracker.hint(recording: startedRecording != nil)
            } else if areaMode {
                text = areaHint()
            } else if trenchMode {
                text = trenchHint()
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
        if isNotice {
            guideLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        } else {
            guideLabel.backgroundColor = isWarning
                ? UIColor.systemOrange.withAlphaComponent(0.9)
                : UIColor.black.withAlphaComponent(0.55)
        }
    }

    // MARK: - 균열 표시 (면 촬영 녹화 중)

    /// 녹화가 시작돼 월드 원점이 고정된 뒤에만 표시한다 (좌표 = odometry.csv 와 같은 월드)
    private var markingActive: Bool {
        (areaMode || trenchMode) && startedRecording != nil && !awaitingTracking
    }

    /// marks.json 의 frame: 마지막으로 저장된 프레임 번호
    private var currentFrameNumber: Int {
        max(0, (datasetEncoder?.savedFrameCount ?? 1) - 1)
    }

    private var crackSurfaceWord: String {
        switch areaSurface {
        case "wall":
            return "벽"
        case "floor":
            return "바닥"
        default:
            return "면"
        }
    }

    private func handleMarkTap(at point: CGPoint) {
        guard markingActive else {
            showNotice(trenchMode ? "녹화를 시작한 뒤 관을 탭하면 종류가 표시됩니다 (아래 '관:' 에서 종류 고르기)"
                       : "녹화를 시작한 뒤 균열을 탭하면 위치가 표시됩니다 (길게 누르면 선)")
            return
        }
        guard let frame = session.currentFrame, let hit = worldPoint(at: point, frame: frame) else {
            showNotice("그 자리의 위치를 찾지 못했습니다 — 조금 더 가까이에서 다시 탭하세요")
            return
        }
        if trenchMode {
            // 굴착 기록: 고른 관 종류로 표시 (서버는 이 표시를 색 추정보다 우선한다)
            let mark = CrackMarks.utility(id: nextMarkID, at: hit.position, utilityClass: utilityClass,
                                          t: frame.timestamp, frame: currentFrameNumber, source: hit.source)
            addMark(mark, node: CrackMarks.makePinNode(at: hit.position, color: utilityClass.color))
            return
        }
        switch lineStage {
        case .off:
            let mark = CrackMarks.point(id: nextMarkID, at: hit.position, t: frame.timestamp,
                                        frame: currentFrameNumber, source: hit.source)
            addMark(mark, node: CrackMarks.makePinNode(at: hit.position, color: .systemPink))
        case .needStart:
            beginLine(at: hit.position, source: hit.source)
        case .needEnd(let start, let startSource, let startNode):
            startNode.removeFromParentNode()
            lineStage = .off
            let source = startSource == "raycast" && hit.source == "raycast" ? "raycast" : "depth"
            let mark = CrackMarks.line(id: nextMarkID, from: start, to: hit.position, t: frame.timestamp,
                                       frame: currentFrameNumber, source: source)
            addMark(mark, node: CrackMarks.makeLineNode(from: start, to: hit.position, color: .systemYellow))
        }
    }

    private func addMark(_ mark: CrackMark, node: SCNNode) {
        nextMarkID += 1
        crackMarks.append(mark)
        sceneView.scene.rootNode.addChildNode(node)
        markNodes.append(node)
        markHaptic.impactOccurred()
        let what: String
        switch mark.kind {
        case "crack_line":
            what = "균열 선 표시"
        case "utility":
            what = "관 표시 (" + (UtilityClass(rawValue: mark.utilityClass ?? "")?.label ?? "모름") + ")"
        default:
            what = "균열 표시"
        }
        showNotice(what + " — 모두 \(crackMarks.count)개")
        updateMarkButtons()
        updateChecklist()
    }

    /// 선의 시작점 (흰 핀). 다음 탭이 끝점
    private func beginLine(at position: SIMD3<Float>, source: String) {
        cancelPendingLine()
        let node = CrackMarks.makePinNode(at: position, color: .white)
        sceneView.scene.rootNode.addChildNode(node)
        lineStage = .needEnd(start: position, source: source, node: node)
        markHaptic.impactOccurred()
        showNotice("선: 균열의 다른 쪽 끝을 탭하세요")
        updateMarkButtons()
    }

    /// 찍다 만 선 (시작점 핀) 을 지운다
    private func cancelPendingLine() {
        if case .needEnd(_, _, let node) = lineStage {
            node.removeFromParentNode()
        }
        lineStage = .off
    }

    private func clearMarks() {
        cancelPendingLine()
        for node in markNodes {
            node.removeFromParentNode()
        }
        markNodes = []
        crackMarks = []
        nextMarkID = 1
        updateMarkButtons()
    }

    @objc private func viewLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, areaMode else { return }
        guard markingActive else {
            showNotice("녹화를 시작한 뒤 길게 누르면 균열 선의 시작점이 됩니다")
            return
        }
        guard let frame = session.currentFrame,
              let hit = worldPoint(at: gesture.location(in: sceneView), frame: frame) else {
            showNotice("그 자리의 위치를 찾지 못했습니다 — 조금 더 가까이에서 다시 눌러 주세요")
            return
        }
        beginLine(at: hit.position, source: hit.source)
    }

    @objc private func markLineTapped() {
        switch lineStage {
        case .off:
            lineStage = .needStart
            showNotice("선: 균열의 한쪽 끝을 탭하세요")
            updateMarkButtons()
        case .needStart, .needEnd:
            cancelPendingLine()
            updateMarkButtons()
        }
    }

    @objc private func markUndoTapped() {
        switch lineStage {
        case .needStart, .needEnd:
            cancelPendingLine()
            showNotice("선 그리기를 취소했습니다")
        case .off:
            guard !crackMarks.isEmpty else { return }
            crackMarks.removeLast()
            markNodes.removeLast().removeFromParentNode()
            showNotice("마지막 표시를 지웠습니다 — 남은 표시 \(crackMarks.count)개")
        }
        updateMarkButtons()
        updateChecklist()
    }

    private func updateMarkButtons() {
        switch lineStage {
        case .off:
            markLineButton.setTitle("선", for: .normal)
        case .needStart:
            markLineButton.setTitle("선: 첫 점", for: .normal)
        case .needEnd:
            markLineButton.setTitle("선: 끝점", for: .normal)
        }
        markUndoButton.setTitle(crackMarks.isEmpty ? "되돌리기" : "되돌리기 (\(crackMarks.count))", for: .normal)
        if trenchMode {
            utilityButton.setTitle("관: \(utilityClass.label) ▾", for: .normal)
            utilityButton.menu = makeUtilityMenu()
        }
    }

    /// 잠깐(CaptureTuning.noticeSeconds) 보여 주는 파란 안내
    private func showNotice(_ text: String) {
        noticeText = text
        noticeUntil = Date().addingTimeInterval(CaptureTuning.noticeSeconds)
        guideLabel.text = text
        guideLabel.isHidden = false
        guideLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
    }

    private func activeNotice() -> String? {
        guard let text = noticeText, Date() < noticeUntil else { return nil }
        return text
    }

    /// 거리 배지: 화면 중앙 깊이(물체 모드는 물체까지)를 모드별 권장 범위와 비교 (방 1~2 m, 물체 0.35~0.9 m,
    /// 현장조사 0.4~1.5 m, 면 촬영은 정지 사진 0.6 mm/px 가 되는 거리까지)
    private func updateDistanceBadge(frame: ARFrame, depth: Float?) {
        var distance = depth
        var prefix = ""
        let advice: DistanceAdvice
        if areaMode && crackMode {
            // 균열 근접: 예상 해상도 mm/px (정지 사진 fx 기준) 로 색
            advice = DistanceAdvice.crack(distance: depth, stillFx: areaStillFx(frame: frame), surface: crackSurfaceWord)
        } else {
            let band: DistanceAdvice.Band
            if areaMode {
                band = DistanceAdvice.area(stillFx: areaStillFx(frame: frame))
            } else if trenchMode {
                band = DistanceAdvice.trench
            } else if objectMode {
                band = DistanceAdvice.object
                if objectTracker.isSet {
                    distance = objectTracker.distance
                    prefix = "물체 "
                }
            } else if (scanMeta?.mode ?? .home) == .survey {
                band = DistanceAdvice.survey
            } else {
                band = DistanceAdvice.room
            }
            advice = DistanceAdvice.evaluate(distance: distance, band: band)
        }
        distanceLabel.text = prefix + advice.text
            + (trenchMode ? " · 기울기 \(Int(trenchTilt(frame: frame).rounded()))°" : "")
        distanceLabel.textColor = advice.tone == .yellow ? .black : .white
        switch advice.tone {
        case .green:
            distanceLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.8)
        case .yellow:
            distanceLabel.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.9)
        case .orange:
            distanceLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.85)
        case .red:
            distanceLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        case .gray:
            distanceLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        }
    }

    /// 면 촬영 정지 사진의 fx (px): 무음은 영상 프레임 그대로, 셔터음은 고해상도 사진 크기로 환산 (모르면 가로 4032)
    private func areaStillFx(frame: ARFrame) -> Float {
        let fx = frame.camera.intrinsics.columns.0.x
        guard hiresSource == .highResCapture else { return fx }
        let width = Float(frame.camera.imageResolution.width)
        let stillWidth = Float(hiresStillWidth ?? 4032)
        return width > 0 ? fx * max(1, stillWidth / width) : fx
    }

    /// 발열이 serious 이상이면 색 점·색 키프레임 수집 간격을 늘리고 화면 갱신을 15 fps 로 낮춘다 (녹화 데이터는 그대로)
    private func updateThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        let hot = state == .serious || state == .critical
        guard hot != thermalThrottled else { return }
        thermalThrottled = hot
        sceneView.preferredFramesPerSecond = hot ? CaptureTuning.hotViewFPS : CaptureTuning.viewFPS
    }

    /// 녹화 3분부터 2분마다 6초씩: 나눠 찍기 권장 (녹화는 멈추지 않는다, 값은 CaptureTuning)
    private func captureTimeNotice(capturing: Bool) -> String? {
        guard capturing, let began = captureStartedAt else { return nil }
        let elapsed = Date().timeIntervalSince(began)
        guard elapsed >= CaptureTuning.longCaptureStart,
              (elapsed - CaptureTuning.longCaptureStart).truncatingRemainder(dividingBy: CaptureTuning.longCaptureRepeat)
                < CaptureTuning.longCaptureShow else { return nil }
        let minutes = Int(elapsed / 60)
        if inPlaceCheck {
            return "\(minutes)분째 녹화 중 — 방 단위로 나눠 찍기를 권장합니다 (녹화는 계속됩니다)"
        }
        return "\(minutes)분째 녹화 중 — 길면 처리가 오래 걸립니다. 나눠 찍기를 권장합니다 (녹화는 계속됩니다)"
    }

    /// 흔들림·추적 불안정·제자리 회전 통계를 촬영 요약에 넣는다
    private func applyQualityStats(_ stats: inout CaptureStats) {
        if let summary = qualityMonitor.summary() {
            let limit = qualityMonitor.limits.warnOn
            stats.blurFrameRatio = summary.blurredRatio
            stats.blurMedianPx = summary.medianBlur
            stats.blurLimitPx = limit
            stats.trackingUnstableSeconds = summary.unstableSeconds
            if summary.blurredRatio > CaptureTuning.summaryBlurRatio {
                stats.warnings.append(String(format: "흔들린 프레임 %.0f%% (%.0f px 이상) — 더 천천히, 특히 돌 때 천천히",
                                             summary.blurredRatio * 100, limit))
            }
            if summary.unstableSeconds >= CaptureTuning.summaryUnstableSeconds {
                stats.warnings.append(String(format: "추적 불안정 %.0f초 — 무늬가 있는 곳을 비추며 천천히",
                                             summary.unstableSeconds))
            }
        }
        if inPlaceCheck {
            stats.inPlaceRotations = rotationDetector.events
            if rotationDetector.events >= CaptureTuning.summaryInPlaceCount {
                stats.warnings.append("제자리 회전 \(rotationDetector.events)회 — 옆으로 걸으면서 찍어야 3D 가 잘 나옵니다")
            }
        }
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
            geoLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            return
        }
        // RTK 배지: 수평 정확도 5 cm 이하 (외부 MFi 수신기를 연결하면 iOS 위치가 그 값으로 바뀐다)
        if let location = LocationService.shared.location, location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= CaptureTuning.rtkHorizontalAccuracy {
            let external = location.sourceInformation?.isProducedByAccessory == true ? " · 외부 수신기" : ""
            geoLabel.text = String(format: "RTK ±%.0f cm", location.horizontalAccuracy * 100) + external
            geoLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.8)
        } else {
            geoLabel.text = LocationService.shared.shortStatus
            geoLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        }
    }

    private func updateFpsSetting() {
        // 영상 형식이 30 fps 면 실제 저장 fps 도 그 기준
        let base = arConfiguration?.videoFormat.framesPerSecond ?? 60
        let fps = max(1, base / FpsDividers[chosenFpsSetting])
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
