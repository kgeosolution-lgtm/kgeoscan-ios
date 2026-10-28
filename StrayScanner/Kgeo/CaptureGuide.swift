//
//  CaptureGuide.swift
//  kgeoScan
//
//  촬영 안내: 트래킹 상태, LiDAR 중앙 거리, 깊이 신뢰도, 움직임 속도, 영상 선명도를 계산해 경고 문구를 만들고
//  녹화 중 통계를 모은다. (Stray Scanner 포크에 추가된 파일) 프레임마다가 아니라 10 Hz 정도로 부른다.
//
//  기준값 (2026-10-27 컵 녹화 분석): 깊이 중앙값 0.21 m 는 LiDAR 하한(0.25~0.3 m) 아래, 소형 물체는 0.4~0.8 m 권장,
//  순간 속도 1.66 m/s 는 과함(0.3 m/s 이하 권장), 라플라시안 선명도가 자리 스캔의 1/3 → 모션블러.
//

import ARKit
import simd

struct CaptureGuidance {
    var trackingText: String
    var trackingOK: Bool
    /// 트래킹·거리·속도·선명도·신뢰도 경고 (없으면 nil)
    var warning: String?
    var centerDepth: Float?
    var confidenceRatio: Float?
    var speed: Float          // m/s (EMA)
    var rotationSpeed: Float  // deg/s (EMA)
    var sharpness: Float      // 상대값 (라플라시안 분산, 1/8 축소 휘도)
}

/// 녹화 1건의 촬영 통계 (meta.json capture_stats)
struct CaptureStats: Codable, Hashable {
    var samples: Int
    var avgDistance: Float?
    var minDistance: Float?
    var avgSpeed: Float
    var maxSpeed: Float
    var speedOverLimitRatio: Float
    var highConfidenceRatio: Float?
    var sharpnessMedian: Float
    var sharpnessMax: Float
    var warnings: [String]
    /// 물체 모드: 방위 커버리지 % 와 고도 3단 %
    var coveragePct: Float? = nil
    var elevationBands: [String: Float]? = nil
    /// 경고 종류별 샘플 수 (10 Hz): tracking, close, far, no_depth, fast, blur, low_confidence, object
    var warningCounts: [String: Int]? = nil

    var isPoor: Bool { !warnings.isEmpty }
}

final class CaptureGuide {
    struct Thresholds {
        var minDistance: Float
        var maxDistance: Float
        var maxSpeed: Float       // m/s
        var maxRotation: Float    // deg/s
        var tooCloseText: String
        var tooFarText: String
    }

    static let survey = Thresholds(minDistance: 0.4, maxDistance: 1.5, maxSpeed: 0.5, maxRotation: 60,
                                   tooCloseText: "너무 가깝습니다 (%.2f m) — 40 cm 이상 떨어지세요",
                                   tooFarText: "너무 멉니다 (%.1f m) — 물체에서 40~80 cm 가 좋습니다")
    static let home = Thresholds(minDistance: 0.3, maxDistance: 3.0, maxSpeed: 0.7, maxRotation: 60,
                                 tooCloseText: "너무 가깝습니다 (%.2f m) — 30 cm 이상 떨어지세요",
                                 tooFarText: "너무 멉니다 (%.1f m) — 3 m 이내로 다가가세요")
    /// 면 촬영(정사영상): 대상 면까지 0.4~1.2 m, 천천히
    static let area = Thresholds(minDistance: 0.4, maxDistance: 1.2, maxSpeed: 0.4, maxRotation: 40,
                                 tooCloseText: "대상 면에 너무 가깝습니다 (%.2f m) — 40 cm 이상 떨어지세요",
                                 tooFarText: "대상 면에서 너무 멉니다 (%.1f m) — 1.2 m 이내로")
    /// 물체 모드: 물체까지 35~90 cm
    static let object = Thresholds(minDistance: 0.35, maxDistance: 0.9, maxSpeed: 0.5, maxRotation: 60,
                                   tooCloseText: "너무 가깝습니다 (%.2f m) — 35 cm 이상 떨어지세요",
                                   tooFarText: "너무 멉니다 (%.1f m) — 90 cm 이내로")

    var thresholds: Thresholds = CaptureGuide.home

    private var lastTransform: simd_float4x4?
    private var lastTimestamp: TimeInterval = 0
    private var speedEMA: Float = 0
    private var rotationEMA: Float = 0
    private var sharpnessMax: Float = 0
    private(set) var lastSharpness: Float = 0

    // 녹화 중 통계
    private var depthSamples: [Float] = []
    private var confidenceSamples: [Float] = []
    private var speedSamples: [Float] = []
    private var sharpnessSamples: [Float] = []
    private var warningCounter: [String: Int] = [:]

    /// 녹화 중 화면에 뜬 경고를 센다 (물체 모드 경고 등 바깥에서 판단한 것)
    func countWarning(_ key: String) {
        warningCounter[key, default: 0] += 1
    }

    func reset() {
        lastTransform = nil
        lastTimestamp = 0
        speedEMA = 0
        rotationEMA = 0
        sharpnessMax = 0
        lastSharpness = 0
        resetStats()
    }

    func resetStats() {
        depthSamples.removeAll()
        confidenceSamples.removeAll()
        speedSamples.removeAll()
        sharpnessSamples.removeAll()
        warningCounter.removeAll()
    }

    /// recording = true 면 이 샘플을 통계에 넣는다.
    func evaluate(frame: ARFrame, recording: Bool) -> CaptureGuidance {
        // 트래킹
        var trackingOK = false
        var trackingWarning: String?
        let trackingText: String
        switch frame.camera.trackingState {
        case .normal:
            trackingText = "트래킹 정상"
            trackingOK = true
        case .notAvailable:
            trackingText = "트래킹 불가"
            trackingWarning = "트래킹이 되지 않습니다"
        case .limited(let reason):
            switch reason {
            case .initializing:
                trackingText = "트래킹 초기화 중"
                trackingWarning = "잠시 멈춰 주세요 — 트래킹 초기화 중"
            case .excessiveMotion:
                trackingText = "움직임 과다"
                trackingWarning = "너무 빨리 움직입니다 — 천천히"
            case .insufficientFeatures:
                trackingText = "특징 부족"
                trackingWarning = "특징이 부족합니다 — 무늬가 있는 곳을 비추세요"
            case .relocalizing:
                trackingText = "위치 다시 찾는 중"
                trackingWarning = "위치를 다시 찾는 중 — 이전에 찍은 곳을 비추세요"
            @unknown default:
                trackingText = "트래킹 제한"
                trackingWarning = "트래킹이 제한됩니다"
            }
        }

        // 거리·신뢰도 (LiDAR 깊이맵 중앙)
        var depth: Float?
        var confidence: Float?
        var distanceWarning: String?
        var confidenceWarning: String?
        if let sceneDepth = frame.sceneDepth {
            depth = CaptureGuide.centerDepth(sceneDepth.depthMap)
            if let map = sceneDepth.confidenceMap {
                confidence = CaptureGuide.centerHighConfidenceRatio(map)
            }
            if let d = depth {
                if d < thresholds.minDistance {
                    distanceWarning = String(format: thresholds.tooCloseText, d)
                } else if d > thresholds.maxDistance {
                    distanceWarning = String(format: thresholds.tooFarText, d)
                }
            } else {
                distanceWarning = "깊이를 잴 수 없습니다 — 너무 멀거나 반사·투명한 면입니다"
            }
            if let c = confidence, c < 0.5, distanceWarning == nil {
                confidenceWarning = "깊이 신뢰도가 낮습니다 — 거리·각도를 바꿔 보세요"
            }
        }

        // 속도 (카메라 자세 변화)
        let timestamp = frame.timestamp
        let transform = frame.camera.transform
        if let last = lastTransform, timestamp > lastTimestamp {
            let dt = Float(timestamp - lastTimestamp)
            let linear = simd_distance(transform.columns.3, last.columns.3) / dt
            let delta = simd_quatf(transform) * simd_quatf(last).inverse
            let angular = abs(delta.angle) * 180 / Float.pi / dt
            speedEMA = 0.6 * speedEMA + 0.4 * linear
            rotationEMA = 0.6 * rotationEMA + 0.4 * angular
        }
        lastTransform = transform
        lastTimestamp = timestamp
        var speedWarning: String?
        if speedEMA > thresholds.maxSpeed || rotationEMA > thresholds.maxRotation {
            speedWarning = String(format: "너무 빠릅니다 (%.1f m/s) — 0.3 m/s 이하로 천천히", speedEMA)
        }

        // 선명도 (상대값): 지금까지 최대의 40% 아래면 흐림
        let sharpness = CaptureGuide.sharpness(frame.capturedImage)
        lastSharpness = sharpness
        sharpnessMax = max(sharpnessMax, sharpness)
        var blurWarning: String?
        if sharpnessMax > 0, sharpness < 0.4 * sharpnessMax {
            blurWarning = "화면이 흐립니다 — 멈췄다가 천천히 움직이세요"
        }

        if recording {
            if let d = depth { depthSamples.append(d) }
            if let c = confidence { confidenceSamples.append(c) }
            speedSamples.append(speedEMA)
            sharpnessSamples.append(sharpness)
            var counted: String?
            if trackingWarning != nil {
                counted = "tracking"
            } else if distanceWarning != nil {
                if let d = depth {
                    counted = d < thresholds.minDistance ? "close" : "far"
                } else {
                    counted = "no_depth"
                }
            } else if speedWarning != nil {
                counted = "fast"
            } else if blurWarning != nil {
                counted = "blur"
            } else if confidenceWarning != nil {
                counted = "low_confidence"
            }
            if let key = counted {
                warningCounter[key, default: 0] += 1
            }
        }

        let warning = trackingWarning ?? distanceWarning ?? speedWarning ?? blurWarning ?? confidenceWarning
        return CaptureGuidance(trackingText: trackingText, trackingOK: trackingOK, warning: warning,
                               centerDepth: depth, confidenceRatio: confidence, speed: speedEMA,
                               rotationSpeed: rotationEMA, sharpness: sharpness)
    }

    /// 녹화 중 모은 샘플의 요약과 경고 목록
    func summary() -> CaptureStats {
        let avgDepth = depthSamples.isEmpty ? nil : depthSamples.reduce(0, +) / Float(depthSamples.count)
        let minDepth = depthSamples.min()
        let avgSpeed = speedSamples.isEmpty ? 0 : speedSamples.reduce(0, +) / Float(speedSamples.count)
        let maxSpeed = speedSamples.max() ?? 0
        let overLimit = speedSamples.isEmpty ? 0
            : Float(speedSamples.filter { $0 > thresholds.maxSpeed }.count) / Float(speedSamples.count)
        let avgConfidence = confidenceSamples.isEmpty ? nil : confidenceSamples.reduce(0, +) / Float(confidenceSamples.count)
        let sortedSharpness = sharpnessSamples.sorted()
        let sharpnessMedian = sortedSharpness.isEmpty ? 0 : sortedSharpness[sortedSharpness.count / 2]
        let sharpnessMaxValue = sortedSharpness.last ?? 0

        var warnings: [String] = []
        if let d = avgDepth, d < thresholds.minDistance {
            warnings.append(String(format: "평균 거리 %.2f m — 너무 가까움 (%.1f m 이상 권장)", d, thresholds.minDistance))
        }
        if overLimit > 0.2 {
            warnings.append(String(format: "움직임이 빠름 — 최대 %.1f m/s, 기준 초과 %.0f%%", maxSpeed, overLimit * 100))
        }
        if let c = avgConfidence, c < 0.5 {
            warnings.append(String(format: "깊이 신뢰도 낮음 — 높은 신뢰 비율 %.0f%%", c * 100))
        }
        if sharpnessMaxValue > 0, sharpnessMedian < 0.4 * sharpnessMaxValue {
            warnings.append("영상이 흐린 프레임이 많음 — 모션블러")
        }
        return CaptureStats(samples: speedSamples.count, avgDistance: avgDepth, minDistance: minDepth,
                            avgSpeed: avgSpeed, maxSpeed: maxSpeed, speedOverLimitRatio: overLimit,
                            highConfidenceRatio: avgConfidence, sharpnessMedian: sharpnessMedian,
                            sharpnessMax: sharpnessMaxValue, warnings: warnings,
                            warningCounts: warningCounter.isEmpty ? nil : warningCounter)
    }

    /// 깊이맵 중앙 40% 영역을 16×12 로 샘플링한 중앙값 (m). 유효 값이 적으면 nil
    static func centerDepth(_ map: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var values: [Float] = []
        values.reserveCapacity(16 * 12)
        for j in 0..<12 {
            let y = min(height - 1, Int(Float(height) * (0.3 + 0.4 * (Float(j) + 0.5) / 12)))
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for i in 0..<16 {
                let x = min(width - 1, Int(Float(width) * (0.3 + 0.4 * (Float(i) + 0.5) / 16)))
                let value = row[x]
                if value.isFinite && value > 0 {
                    values.append(value)
                }
            }
        }
        guard values.count >= 20 else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    /// 깊이맵의 (x, y) 주변 5×5 창의 중앙값 (m). 유효 값이 없으면 nil
    static func depth(atX x: Int, y: Int, in map: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        guard width > 0, height > 0 else { return nil }
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        var values: [Float] = []
        for j in max(0, cy - 2)...min(height - 1, cy + 2) {
            let row = base.advanced(by: j * rowBytes).assumingMemoryBound(to: Float.self)
            for i in max(0, cx - 2)...min(width - 1, cx + 2) {
                let value = row[i]
                if value.isFinite && value > 0 {
                    values.append(value)
                }
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    /// 신뢰도맵(0,1,2) 중앙 40% 영역에서 값 2(높음)의 비율
    static func centerHighConfidenceRatio(_ map: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var high = 0
        var total = 0
        for j in 0..<12 {
            let y = min(height - 1, Int(Float(height) * (0.3 + 0.4 * (Float(j) + 0.5) / 12)))
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for i in 0..<16 {
                let x = min(width - 1, Int(Float(width) * (0.3 + 0.4 * (Float(i) + 0.5) / 16)))
                total += 1
                if row[x] >= 2 { high += 1 }
            }
        }
        return total > 0 ? Float(high) / Float(total) : nil
    }

    /// 카메라 영상 휘도 평면을 8픽셀 간격으로 훑은 라플라시안 분산 (클수록 선명). 상대 비교용.
    static func sharpness(_ image: CVPixelBuffer) -> Float {
        guard CVPixelBufferGetPlaneCount(image) >= 1 else { return 0 }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return 0 }
        let width = CVPixelBufferGetWidthOfPlane(image, 0)
        let height = CVPixelBufferGetHeightOfPlane(image, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let step = 8
        guard width > 3 * step, height > 3 * step else { return 0 }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var sum: Float = 0
        var sumSquares: Float = 0
        var count: Float = 0
        var y = step
        while y < height - step {
            var x = step
            while x < width - step {
                let center = Float(pixels[y * rowBytes + x])
                let left = Float(pixels[y * rowBytes + x - step])
                let right = Float(pixels[y * rowBytes + x + step])
                let up = Float(pixels[(y - step) * rowBytes + x])
                let down = Float(pixels[(y + step) * rowBytes + x])
                let laplacian = left + right + up + down - 4 * center
                sum += laplacian
                sumSquares += laplacian * laplacian
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }
}
