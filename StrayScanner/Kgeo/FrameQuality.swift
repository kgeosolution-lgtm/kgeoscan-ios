//
//  FrameQuality.swift
//  kgeoScan
//
//  촬영 품질 계산. 화면 표시와 떼어 두어 녹화 중 실시간 오버레이(2단계)에서도 그대로 쓴다.
//  - FrameQualityMonitor: 프레임마다 연속 카메라 자세로 회전 ω·이동 v 를 구하고 노출 시간으로 흔들림을 예측한다.
//      blur_px ≈ (|ω|·fx + |v|·fx / z) × 노출 시간. 픽셀은 가로 1920 px 영상 기준, z 는 화면 중앙 깊이 중앙값.
//      '천천히' 는 기준 이상이 0.5초 이어지면 켜고 해제 기준 아래로 내려오면 끈다 (6 → 4 px, 면 촬영 4 → 2.7 px).
//      8 px 를 넘는 프레임은 색 점 미리보기 누적에서 뺀다.
//  - FrameQualityWriter: 녹화 폴더의 frame_quality.csv (frame,timestamp,blur_px,tracking,omega_dps,speed_mps).
//      frame 은 odometry.csv · depth/ · rgb.mp4 와 같은 번호다. 서버가 흔들린·추적 불량 프레임을 덜 쓰는 데 쓴다.
//  - InPlaceRotationDetector: 최근 3초 동안 방향은 45° 넘게 바뀌었는데 위치는 0.3 m 안이면 '제자리 회전' (방 모드).
//  - DistanceAdvice: 화면 중앙 깊이로 모드별 권장 거리 배지 (면 촬영은 정지 사진 0.6 mm/px 기준).
//  (Stray Scanner 포크에 추가된 파일)
//

import ARKit
import simd

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
        /// 이 값 이상이 0.5초 이어지면 '천천히'
        var warnOn: Float
        /// 이 값 아래로 내려오면 해제
        var warnOff: Float
        /// 이 값을 넘는 프레임은 색 점 미리보기 누적에서 뺀다
        var accumulate: Float
    }

    static let standard = Limits(warnOn: 6, warnOff: 4, accumulate: 8)
    /// 면 촬영 (정사영상): 더 엄격하게
    static let area = Limits(warnOn: 4, warnOff: 2.7, accumulate: 8)
    static let referenceWidth: Float = 1920
    static let sustain: TimeInterval = 0.5
    static let releaseHold: TimeInterval = 0.25

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

        let width = Float(camera.imageResolution.width)
        let fx = camera.intrinsics.columns.0.x * (width > 0 ? FrameQualityMonitor.referenceWidth / width : 1)
        var exposure = Float(camera.exposureDuration)
        if !(exposure > 0) {
            exposure = 1.0 / 60
        }
        exposure = min(exposure, 0.1)
        let z = max(depth ?? 2.0, 0.25)
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

    /// 히스테리시스: 짧은 EMA 가 warnOn 이상으로 0.5초 → 켬, warnOff 아래로 0.25초 → 끔
    private func updateShaking(blur: Float, timestamp: TimeInterval) {
        smoothedBlur = 0.7 * smoothedBlur + 0.3 * blur
        let value = smoothedBlur
        if value >= limits.warnOn {
            underSince = nil
            if overSince == nil {
                overSince = timestamp
            }
            if !shaking, let since = overSince, timestamp - since >= FrameQualityMonitor.sustain {
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
            if let since = underSince, timestamp - since >= FrameQualityMonitor.releaseHold {
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
    static let window: TimeInterval = 3
    /// 켜기: 3초 안의 방향 변화 45° 이상 + 위치 변화 0.3 m 미만. 끄기: 30° 미만 또는 0.4 m 초과
    static let turnOn: Float = 45
    static let turnOff: Float = 30
    static let travelOn: Float = 0.3
    static let travelOff: Float = 0.4

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
        while let first = samples.first, timestamp - first.time > InPlaceRotationDetector.window {
            samples.removeFirst()
        }
        guard let first = samples.first, timestamp - first.time >= InPlaceRotationDetector.window * 0.8 else {
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
            if turn < InPlaceRotationDetector.turnOff || travel > InPlaceRotationDetector.travelOff {
                active = false
            }
        } else if turn >= InPlaceRotationDetector.turnOn && travel < InPlaceRotationDetector.travelOn {
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

    /// 방 1~2 m, 물체 0.35~0.9 m (물체 경고 기준과 같게), 현장조사 일반 0.4~1.5 m
    static let room = Band(near: 1.0, far: 2.0)
    static let object = Band(near: 0.35, far: 0.9)
    static let survey = Band(near: 0.4, far: 1.5)
    /// 면 촬영 목표 지상 해상도 (m/px)
    static let areaTargetGSD: Float = 0.0006

    /// 면 촬영: 0.6 mm/px 가 되는 거리까지 (안내 상한 1.2 m 이내). 가까운 쪽은 LiDAR·한 장의 넓이로 0.4 m
    static func area(stillFx: Float) -> Band {
        let reach = (areaTargetGSD * stillFx * 10).rounded(.down) / 10
        return Band(near: 0.4, far: min(1.2, max(0.5, reach)), stillFx: stillFx)
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
