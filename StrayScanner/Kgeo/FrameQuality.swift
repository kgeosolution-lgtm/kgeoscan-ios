//
//  FrameQuality.swift
//  kgeoScan
//
//  촬영 품질 계산. 화면 표시와 떼어 두어 녹화 중 실시간 오버레이(2단계)에서도 그대로 쓴다.
//  기준값은 모두 맨 위 CaptureTuning 한곳에 있다 (실기기 결과를 보고 여기서만 고친다).
//  - FrameQualityMonitor: 프레임마다 연속 카메라 자세로 회전 ω·이동 v 를 구하고 노출 시간으로 흔들림을 예측한다.
//      blur_px ≈ (|ω|·fx + |v|·fx / z) × 노출 시간. fx 는 1920 / 캡처 가로 해상도로 환산해 픽셀은 가로 1920 px 영상 기준
//      (4K 형식과 기본 형식에서 같은 뜻), z 는 화면 중앙 깊이 중앙값.
//      '천천히' 는 6 px 이상이 0.5초 넘게 이어지면 켜고 4 px 아래로 0.5초 이상 내려가면 끈다 (면 촬영은 4 px 에서 켬).
//      8 px 를 넘는 프레임은 색 점 미리보기 누적에서 뺀다.
//  - FrameQualityWriter: 녹화 폴더의 frame_quality.csv (frame,timestamp,blur_px,tracking,omega_dps,speed_mps).
//      frame 은 odometry.csv · depth/ · rgb.mp4 와 같은 번호다. 서버가 흔들린·추적 불량 프레임을 덜 쓰는 데 쓴다.
//  - InPlaceRotationDetector: 최근 3초 동안 방향은 45° 넘게 바뀌었는데 위치는 0.3 m 안이면 '제자리 회전' (방 모드).
//  - DistanceAdvice: 화면 중앙 깊이로 모드별 권장 거리 배지 (면 촬영은 정지 사진 0.6 mm/px 기준).
//  (Stray Scanner 포크에 추가된 파일)
//

import ARKit
import simd

/// 촬영 안내 기준값 (2026-10-29 1단계). 흔들림 px 은 가로 1920 px 영상 기준.
/// 거리·속도 경고의 기존 기준값은 CaptureGuide.Thresholds 에 있다.
enum CaptureTuning {
    // MARK: 흔들림 '천천히' (집 스캔 63b563ec: 1/60 s 노출 원본 fx 기준 중앙값 8 px → 1.5 px 기준은 늘 켜짐)
    /// 켜기: 이 값 이상이 blurSustain 초 넘게 이어지면 (방·물체·현장조사)
    static let blurWarnOn: Float = 6
    /// 끄기: 이 값 아래로 blurRelease 초 이상 내려가면
    static let blurWarnOff: Float = 4
    /// 면 촬영(정사영상)은 더 엄격하게
    static let areaBlurWarnOn: Float = 4
    static let areaBlurWarnOff: Float = 2.7
    static let blurSustain: TimeInterval = 0.5
    static let blurRelease: TimeInterval = 0.5
    /// 켜고 끄기 판단용 짧은 이동 평균의 새 값 가중치 (프레임 하나의 잡음으로 타이머가 끊기지 않게)
    static let blurSmoothing: Float = 0.3
    /// 이 값을 넘는 프레임은 색 점·색 키프레임·면 정지 사진에서 뺀다
    static let blurSkipAbove: Float = 8
    /// 흔들림 계산: 깊이를 모를 때의 z, z 하한 (m)
    static let blurDefaultDepth: Float = 2.0
    static let blurMinDepth: Float = 0.25
    /// 노출 시간을 모를 때 (초)
    static let defaultExposure: Float = 1.0 / 60
    /// 가벼운 햅틱 최소 간격 (초)
    static let hapticInterval: TimeInterval = 1.0

    // MARK: 제자리 회전 (방 모드만)
    static let inPlaceWindow: TimeInterval = 3
    /// 켜기: 창 안의 방향 변화 45° 이상 + 위치 변화 0.3 m 미만. 끄기: 30° 미만 또는 0.4 m 초과
    static let inPlaceTurnOn: Float = 45
    static let inPlaceTurnOff: Float = 30
    static let inPlaceTravelOn: Float = 0.3
    static let inPlaceTravelOff: Float = 0.4

    // MARK: 거리 배지 (m)
    static let roomDistance: (near: Float, far: Float) = (1.0, 2.0)
    /// 물체: 물체 경고 기준(ObjectTracker·CaptureGuide.object 0.35~0.9 m)과 같게
    static let objectDistance: (near: Float, far: Float) = (0.35, 0.9)
    static let surveyDistance: (near: Float, far: Float) = (0.4, 1.5)
    /// 면 촬영: 가까운 쪽 한계, 먼 쪽 상한 (안내 기준 1.2 m), 목표 지상 해상도 0.6 mm/px
    static let areaNear: Float = 0.4
    static let areaFarCap: Float = 1.2
    static let areaTargetGSD: Float = 0.0006

    // MARK: 긴 녹화 안내
    /// 3분부터 2분마다 6초씩 '나눠 찍기 권장' (녹화는 계속)
    static let longCaptureStart: TimeInterval = 180
    static let longCaptureRepeat: TimeInterval = 120
    static let longCaptureShow: TimeInterval = 6

    // MARK: 촬영 요약 경고
    static let summaryBlurRatio: Float = 0.2
    static let summaryUnstableSeconds: Float = 3
    static let summaryInPlaceCount = 3

    // MARK: 발열 (ProcessInfo.thermalState serious 이상)
    /// 색 점 샘플: 보통 0.25초 또는 8 cm·8°(최소 0.1초) → 발열 때 0.75초 또는 20 cm·20°(최소 0.4초)
    static let pointInterval: TimeInterval = 0.25
    static let pointMinInterval: TimeInterval = 0.1
    static let pointMove: Float = 0.08
    static let pointTurn: Float = 8
    static let hotPointInterval: TimeInterval = 0.75
    static let hotPointMinInterval: TimeInterval = 0.4
    static let hotPointMove: Float = 0.2
    static let hotPointTurn: Float = 20
    /// 메시 색 키프레임 최소 간격 (발열 때)
    static let hotKeyframeInterval: TimeInterval = 1.5
    /// 녹화 화면(ARSCNView) 갱신 fps: 보통 / 발열
    static let viewFPS = 30
    static let hotViewFPS = 15
}

/// 한 프레임의 촬영 품질 (frame_quality.csv 한 행)
struct FrameQualitySample {
    var timestamp: TimeInterval
    /// 노출 동안의 예측 흔들림 (가로 1920 px 영상 기준 px)
    var blurPx: Float
    /// normal | excessiveMotion | insufficientFeatures | initializing | relocalizing | notAvailable
    var tracking: String
    /// 회전 속도 (°/s)
    var omegaDps: Float
    /// 이동 속도 (m/s)
    var speedMps: Float

    var trackingNormal: Bool { tracking == "normal" }

    static func trackingName(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing:
                return "initializing"
            case .excessiveMotion:
                return "excessiveMotion"
            case .insufficientFeatures:
                return "insufficientFeatures"
            case .relocalizing:
                return "relocalizing"
            @unknown default:
                return "notAvailable"
            }
        }
    }
}

/// 연속 ARFrame 의 카메라 자세로 흔들림을 예측한다. 메인 스레드(ARSession delegate)에서 프레임마다 부른다.
final class FrameQualityMonitor {
    struct Limits {
        /// 이 값 이상이 blurSustain 초 넘게 이어지면 '천천히'
        var warnOn: Float
        /// 이 값 아래로 blurRelease 초 이상 내려가면 해제
        var warnOff: Float
        /// 이 값을 넘는 프레임은 색 점 미리보기 누적에서 뺀다
        var skipAbove: Float
    }

    static let standard = Limits(warnOn: CaptureTuning.blurWarnOn, warnOff: CaptureTuning.blurWarnOff,
                                 skipAbove: CaptureTuning.blurSkipAbove)
    /// 면 촬영 (정사영상): 더 엄격하게
    static let area = Limits(warnOn: CaptureTuning.areaBlurWarnOn, warnOff: CaptureTuning.areaBlurWarnOff,
                             skipAbove: CaptureTuning.blurSkipAbove)
    static let referenceWidth: Float = 1920

    struct Summary {
        var frames: Int
        /// warnOn 이상인 프레임 비율
        var blurredRatio: Float
        var medianBlur: Float
        /// 트래킹이 normal 이 아니었던 시간 (초)
        var unstableSeconds: Float
    }

    var limits = FrameQualityMonitor.standard

    private var lastTransform: simd_float4x4?
    private var lastTimestamp: TimeInterval = 0
    private(set) var latest: FrameQualitySample?
    /// '천천히' 경고가 켜져 있는지 (녹화 중이 아니어도 계산은 한다)
    private(set) var shaking = false
    private var smoothedBlur: Float = 0
    private var overSince: TimeInterval?
    private var underSince: TimeInterval?

    // 녹화 중 통계
    private var recordedFrames = 0
    private var blurredFrames = 0
    private var blurValues: [Float] = []
    private var unstableSeconds: Double = 0

    /// 트래킹 리셋 때: 앞 자세와 비교하지 않는다
    func reset() {
        lastTransform = nil
        lastTimestamp = 0
        latest = nil
        shaking = false
        smoothedBlur = 0
        overSince = nil
        underSince = nil
        resetStats()
    }

    func resetStats() {
        recordedFrames = 0
        blurredFrames = 0
        blurValues.removeAll()
        unstableSeconds = 0
    }

    /// depth = 화면 중앙 깊이 중앙값 (m, 모르면 nil). recording = 이 프레임을 통계에 넣을지
    @discardableResult
    func update(frame: ARFrame, depth: Float?, recording: Bool) -> FrameQualitySample {
        let camera = frame.camera
        let timestamp = frame.timestamp
        let transform = camera.transform
        var omega: Float = 0   // rad/s
        var speed: Float = 0   // m/s
        var dt: Float = 0
        if let last = lastTransform, timestamp > lastTimestamp {
            dt = Float(timestamp - lastTimestamp)
            if dt < 0.5 {
                let delta = simd_quatf(transform) * simd_quatf(last).inverse
                let w = min(1, abs(delta.real))
                omega = min(2 * acos(w) / dt, 20)
                speed = min(simd_distance(transform.columns.3, last.columns.3) / dt, 5)
            } else if let previous = latest {
                omega = previous.omegaDps * Float.pi / 180
                speed = previous.speedMps
            }
        }
        lastTransform = transform
        lastTimestamp = timestamp

        // fx 를 가로 1920 px 기준으로 (4K 형식이면 절반)
        let width = Float(camera.imageResolution.width)
        let fx = camera.intrinsics.columns.0.x * (width > 0 ? FrameQualityMonitor.referenceWidth / width : 1)
        var exposure = Float(camera.exposureDuration)
        if !(exposure > 0) {
            exposure = CaptureTuning.defaultExposure
        }
        exposure = min(exposure, 0.1)
        let z = max(depth ?? CaptureTuning.blurDefaultDepth, CaptureTuning.blurMinDepth)
        let blur = min((omega * fx + speed * fx / z) * exposure, 999)
        let sample = FrameQualitySample(timestamp: timestamp, blurPx: blur,
                                        tracking: FrameQualitySample.trackingName(camera.trackingState),
                                        omegaDps: omega * 180 / Float.pi, speedMps: speed)
        latest = sample
        updateShaking(blur: blur, timestamp: timestamp)
        if recording {
            recordedFrames += 1
            blurValues.append(blur)
            if blur >= limits.warnOn {
                blurredFrames += 1
            }
            if !sample.trackingNormal {
                unstableSeconds += Double(min(dt, 0.2))
            }
        }
        return sample
    }

    /// 히스테리시스: 짧은 이동 평균이 warnOn 이상으로 blurSustain 초 넘게 → 켬, warnOff 아래로 blurRelease 초 이상 → 끔
    private func updateShaking(blur: Float, timestamp: TimeInterval) {
        let weight = CaptureTuning.blurSmoothing
        smoothedBlur = (1 - weight) * smoothedBlur + weight * blur
        let value = smoothedBlur
        if value >= limits.warnOn {
            underSince = nil
            if overSince == nil {
                overSince = timestamp
            }
            if !shaking, let since = overSince, timestamp - since >= CaptureTuning.blurSustain {
                shaking = true
            }
            return
        }
        overSince = nil
        guard shaking else { return }
        if value < limits.warnOff {
            if underSince == nil {
                underSince = timestamp
            }
            if let since = underSince, timestamp - since >= CaptureTuning.blurRelease {
                shaking = false
                underSince = nil
            }
        } else {
            underSince = nil
        }
    }

    /// 녹화 중 모은 통계 (프레임이 없으면 nil)
    func summary() -> Summary? {
        guard recordedFrames > 0, !blurValues.isEmpty else { return nil }
        let sorted = blurValues.sorted()
        return Summary(frames: recordedFrames,
                       blurredRatio: Float(blurredFrames) / Float(recordedFrames),
                       medianBlur: sorted[sorted.count / 2],
                       unstableSeconds: Float(unstableSeconds))
    }
}

/// 녹화 폴더의 frame_quality.csv. DatasetEncoder 의 인코더 큐에서 부른다 (프레임 번호 = odometry.csv 의 frame)
final class FrameQualityWriter {
    static let fileName = "frame_quality.csv"
    static let header = "frame,timestamp,blur_px,tracking,omega_dps,speed_mps\n"

    private var handle: FileHandle?

    init(directory: URL) {
        let url = directory.appendingPathComponent(FrameQualityWriter.fileName, isDirectory: false)
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            let handle = try FileHandle(forWritingTo: url)
            handle.write(Data(FrameQualityWriter.header.utf8))
            self.handle = handle
        } catch {
            print("frame_quality.csv 를 만들 수 없습니다: \(error.localizedDescription)")
            handle = nil
        }
    }

    func add(_ sample: FrameQualitySample, frame: Int) {
        guard let handle = handle else { return }
        let line = "\(frame),\(sample.timestamp)," + String(format: "%.2f", sample.blurPx) + ",\(sample.tracking),"
            + String(format: "%.1f,%.3f", sample.omegaDps, sample.speedMps) + "\n"
        handle.write(Data(line.utf8))
    }

    func done() {
        try? handle?.close()
        handle = nil
    }
}

/// 제자리 회전 감지 (방 모드). 회전만 하면 시차가 없어 3D 가 비므로 옆으로 걸으며 찍게 한다. 10 Hz 정도로 부른다.
final class InPlaceRotationDetector {
    private struct Sample {
        let time: TimeInterval
        let position: SIMD3<Float>
        let forward: SIMD3<Float>
    }

    private var samples: [Sample] = []
    private(set) var active = false
    /// 켜진 횟수 (녹화 요약)
    private(set) var events = 0

    func reset() {
        samples.removeAll()
        active = false
        events = 0
    }

    /// 지금 '제자리 회전' 이면 true
    func update(transform: simd_float4x4, timestamp: TimeInterval) -> Bool {
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        samples.append(Sample(time: timestamp, position: position, forward: forward))
        while let first = samples.first, timestamp - first.time > CaptureTuning.inPlaceWindow {
            samples.removeFirst()
        }
        guard let first = samples.first, timestamp - first.time >= CaptureTuning.inPlaceWindow * 0.8 else {
            return active
        }
        var turn: Float = 0
        var travel: Float = 0
        for sample in samples {
            let cosine = max(-1, min(1, simd_dot(sample.forward, forward)))
            turn = max(turn, acos(cosine) * 180 / Float.pi)
            travel = max(travel, simd_distance(sample.position, position))
        }
        if active {
            if turn < CaptureTuning.inPlaceTurnOff || travel > CaptureTuning.inPlaceTravelOff {
                active = false
            }
        } else if turn >= CaptureTuning.inPlaceTurnOn && travel < CaptureTuning.inPlaceTravelOn {
            active = true
            events += 1
        }
        return active
    }
}

/// 거리 배지: 화면 중앙 깊이(물체 모드는 물체까지)를 모드별 권장 범위와 비교
struct DistanceAdvice {
    enum State {
        case good
        case near
        case far
        case unknown
    }

    struct Band {
        var near: Float
        var far: Float
        /// 면 촬영: 정지 사진의 fx (px). 있으면 지상 해상도(mm/px)도 보여 준다
        var stillFx: Float? = nil
    }

    static let room = Band(near: CaptureTuning.roomDistance.near, far: CaptureTuning.roomDistance.far)
    static let object = Band(near: CaptureTuning.objectDistance.near, far: CaptureTuning.objectDistance.far)
    static let survey = Band(near: CaptureTuning.surveyDistance.near, far: CaptureTuning.surveyDistance.far)

    /// 면 촬영: 목표 지상 해상도(0.6 mm/px)가 되는 거리까지 (안내 상한 1.2 m 이내). 가까운 쪽은 LiDAR·한 장의 넓이로 0.4 m
    static func area(stillFx: Float) -> Band {
        let reach = (CaptureTuning.areaTargetGSD * stillFx * 10).rounded(.down) / 10
        let far = min(CaptureTuning.areaFarCap, max(CaptureTuning.areaNear + 0.1, reach))
        return Band(near: CaptureTuning.areaNear, far: far, stillFx: stillFx)
    }

    let state: State
    let text: String

    static func evaluate(distance: Float?, band: Band) -> DistanceAdvice {
        guard let d = distance, d.isFinite, d > 0 else {
            return DistanceAdvice(state: .unknown, text: "거리 —")
        }
        var text = String(format: "거리 %.2f m", d)
        if let fx = band.stillFx, fx > 0 {
            text += String(format: " · %.2f mm/px", d / fx * 1000)
        }
        let range = String(format: "%g~%g m", band.near, band.far)
        if d < band.near {
            return DistanceAdvice(state: .near, text: text + " · 가까움 (" + range + ")")
        }
        if d > band.far {
            return DistanceAdvice(state: .far, text: text + " · 멂 (" + range + ")")
        }
        return DistanceAdvice(state: .good, text: text + " · 좋음")
    }
}
