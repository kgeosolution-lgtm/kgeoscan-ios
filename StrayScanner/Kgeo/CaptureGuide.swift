//
//  CaptureGuide.swift
//  kgeoScan
//
//  촬영 안내: 트래킹 상태, LiDAR 중앙 거리, 움직임 속도를 계산해 한 줄 경고 문구로 만든다.
//  (Stray Scanner 포크에 추가된 파일) 프레임마다가 아니라 10 Hz 정도로 부른다.
//

import ARKit
import simd

struct CaptureGuidance {
    var trackingText: String
    var trackingOK: Bool
    /// 트래킹·거리·속도 경고 (없으면 nil)
    var warning: String?
    /// 화면 중앙 거리 (m). 깊이가 없으면 nil
    var centerDepth: Float?
    var speed: Float          // m/s (EMA)
    var rotationSpeed: Float  // deg/s (EMA)
}

final class CaptureGuide {
    static let minDistance: Float = 0.3
    static let maxDistance: Float = 3.0
    static let maxSpeed: Float = 1.0        // m/s
    static let maxRotation: Float = 60      // deg/s

    private var lastTransform: simd_float4x4?
    private var lastTimestamp: TimeInterval = 0
    private var speedEMA: Float = 0
    private var rotationEMA: Float = 0

    func reset() {
        lastTransform = nil
        lastTimestamp = 0
        speedEMA = 0
        rotationEMA = 0
    }

    func evaluate(frame: ARFrame) -> CaptureGuidance {
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

        // 거리 (LiDAR 깊이맵 중앙)
        var depth: Float?
        var distanceWarning: String?
        if let sceneDepth = frame.sceneDepth {
            depth = CaptureGuide.centerDepth(sceneDepth.depthMap)
            if let d = depth {
                if d < CaptureGuide.minDistance {
                    distanceWarning = String(format: "너무 가깝습니다 (%.1f m) — 0.3 m 이상 떨어지세요", d)
                } else if d > CaptureGuide.maxDistance {
                    distanceWarning = String(format: "너무 멉니다 (%.1f m) — 3 m 이내로 다가가세요", d)
                }
            } else {
                distanceWarning = "깊이를 잴 수 없습니다 — 너무 멀거나 반사·투명한 면입니다"
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
        if speedEMA > CaptureGuide.maxSpeed || rotationEMA > CaptureGuide.maxRotation {
            speedWarning = "너무 빠릅니다 — 천천히 움직이세요"
        }

        let warning = trackingWarning ?? distanceWarning ?? speedWarning
        return CaptureGuidance(trackingText: trackingText, trackingOK: trackingOK, warning: warning,
                               centerDepth: depth, speed: speedEMA, rotationSpeed: rotationEMA)
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
}
