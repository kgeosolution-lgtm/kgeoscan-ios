//
//  ObjectTracker.swift
//  kgeoScan
//
//  물체 모드: 물체 중심·반경(자를 영역), 카메라 방위각 36칸 커버리지, 고도 3단, 거리·회전 속도 안내.
//  (Stray Scanner 포크에 추가된 파일) 좌표는 ARKit 월드 = odometry.csv 와 같은 좌표계다.
//

import ARKit
import SceneKit
import UIKit
import simd

final class ObjectTracker {
    enum Band: Int, CaseIterable {
        case low = 0
        case mid = 1
        case high = 2

        var key: String {
            switch self {
            case .low: return "low"
            case .mid: return "mid"
            case .high: return "high"
            }
        }

        var label: String {
            switch self {
            case .low: return "낮음"
            case .mid: return "중간"
            case .high: return "위"
            }
        }
    }

    static let bins = 36
    static let minDistance: Float = 0.35
    static let maxDistance: Float = 0.9
    static let fullCircleBins = 33   // 330° 이상
    static let minRadius: Float = 0.1
    static let maxRadius: Float = 0.6

    private(set) var center: simd_float3?
    var radius: Float = 0.25
    private(set) var setBy: String = "auto"
    private(set) var coveredBins = Set<Int>()
    private(set) var bandBins: [Set<Int>] = [[], [], []]
    private var lastAzimuth: Float?
    private var lastAzimuthTime: TimeInterval = 0
    private(set) var orbitSpeed: Float = 0     // deg/s (EMA)
    private(set) var distance: Float = 0
    private(set) var currentBand: Band = .low
    private(set) var fullCircleReached = false
    /// 한 바퀴(330°)가 처음 채워질 때 (메인 스레드)
    var didReachFullCircle: (() -> Void)?

    var isSet: Bool { center != nil }

    func setCenter(_ newCenter: simd_float3, setBy: String) {
        center = newCenter
        self.setBy = setBy
        resetCoverage()
    }

    func clear() {
        center = nil
        setBy = "auto"
        resetCoverage()
    }

    func resetCoverage() {
        coveredBins.removeAll()
        bandBins = [[], [], []]
        lastAzimuth = nil
        orbitSpeed = 0
        fullCircleReached = false
    }

    var coveragePercent: Float {
        Float(coveredBins.count) / Float(ObjectTracker.bins) * 100
    }

    func bandPercent(_ band: Band) -> Float {
        Float(bandBins[band.rawValue].count) / Float(ObjectTracker.bins) * 100
    }

    var elevationBands: [String: Float] {
        var result: [String: Float] = [:]
        for band in Band.allCases {
            result[band.key] = bandPercent(band)
        }
        return result
    }

    /// 10 Hz 로 카메라 위치를 넣는다. recording 중에만 커버리지를 쌓는다.
    func update(cameraTransform: simd_float4x4, timestamp: TimeInterval, recording: Bool) {
        guard let c = center else { return }
        let p = simd_float3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let v = p - c
        distance = simd_length(v)
        let horizontal = max(sqrt(v.x * v.x + v.z * v.z), 1e-4)
        let elevation = atan2(v.y, horizontal) * 180 / Float.pi
        currentBand = elevation < 20 ? .low : (elevation > 45 ? .high : .mid)
        let azimuth = atan2(v.x, v.z)   // -π..π
        if let last = lastAzimuth, timestamp > lastAzimuthTime {
            var delta = azimuth - last
            while delta > Float.pi { delta -= 2 * Float.pi }
            while delta < -Float.pi { delta += 2 * Float.pi }
            let speed = abs(delta) * 180 / Float.pi / Float(timestamp - lastAzimuthTime)
            orbitSpeed = 0.6 * orbitSpeed + 0.4 * speed
        }
        lastAzimuth = azimuth
        lastAzimuthTime = timestamp
        guard recording else { return }
        let bin = Int(((azimuth + Float.pi) / (2 * Float.pi)) * Float(ObjectTracker.bins)) % ObjectTracker.bins
        coveredBins.insert(bin)
        bandBins[currentBand.rawValue].insert(bin)
        if !fullCircleReached && coveredBins.count >= ObjectTracker.fullCircleBins {
            fullCircleReached = true
            didReachFullCircle?()
        }
    }

    /// 거리·회전 속도 경고. nil 이면 없음
    func warning() -> String? {
        guard center != nil else { return nil }
        if distance < ObjectTracker.minDistance {
            return String(format: "물체에 너무 가깝습니다 (%.2f m) — 35 cm 이상 떨어지세요", distance)
        }
        if distance > ObjectTracker.maxDistance {
            return String(format: "물체에서 너무 멉니다 (%.2f m) — 90 cm 이내로", distance)
        }
        if orbitSpeed > 60 {
            return String(format: "너무 빨리 돕니다 (%.0f°/s) — 한 바퀴에 20~30초", orbitSpeed)
        }
        return nil
    }

    /// 진행 안내 (경고가 없을 때)
    func hint(recording: Bool) -> String {
        guard center != nil else { return "조준점을 물체에 맞추고 화면을 탭하세요 (물체 지정)" }
        guard recording else { return "녹화를 시작하고 35~90 cm 거리에서 천천히 한 바퀴 도세요" }
        let overall = coveragePercent
        if overall < 92 {
            return String(format: "한 바퀴 %.0f%% — 계속 도세요", overall)
        }
        if bandPercent(.high) < 50 {
            return "이제 위에서(45° 이상 내려다보며) 한 바퀴 더"
        }
        return "좋습니다 — 필요하면 낮은 각도도 보강하세요"
    }

    /// 물체 영역을 보여 주는 반투명 구 노드
    static func makeNode(center: simd_float3, radius: Float) -> SCNNode {
        let sphere = SCNSphere(radius: CGFloat(radius))
        sphere.segmentCount = 36
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 1.0, green: 0.75, blue: 0.1, alpha: 0.28)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.name = "kgeo.object"
        node.simdPosition = center
        let wire = SCNSphere(radius: CGFloat(radius))
        wire.segmentCount = 18
        let wireMaterial = SCNMaterial()
        wireMaterial.diffuse.contents = UIColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 0.7)
        wireMaterial.lightingModel = .constant
        wireMaterial.fillMode = .lines
        wireMaterial.isDoubleSided = true
        wireMaterial.writesToDepthBuffer = false
        wire.materials = [wireMaterial]
        node.addChildNode(SCNNode(geometry: wire))
        let dot = SCNSphere(radius: 0.012)
        let dotMaterial = SCNMaterial()
        dotMaterial.diffuse.contents = UIColor.systemRed
        dotMaterial.lightingModel = .constant
        dot.materials = [dotMaterial]
        node.addChildNode(SCNNode(geometry: dot))
        return node
    }

    static func setRadius(_ radius: Float, on node: SCNNode) {
        (node.geometry as? SCNSphere)?.radius = CGFloat(radius)
        for child in node.childNodes {
            if let sphere = child.geometry as? SCNSphere, sphere.radius > 0.02 {
                sphere.radius = CGFloat(radius)
            }
        }
    }
}

/// 방위 36칸 링 + 고도 3단 막대 게이지
final class CoverageRingView: UIView {
    var covered = Set<Int>() { didSet { setNeedsDisplay() } }
    var percentText = "0%" { didSet { setNeedsDisplay() } }
    var bandPercents: [Float] = [0, 0, 0] { didSet { setNeedsDisplay() } }
    var complete = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let ringSize = rect.width
        let center = CGPoint(x: ringSize / 2, y: ringSize / 2)
        let radius = ringSize / 2 - 5
        ctx.setLineWidth(7)
        ctx.setLineCap(.butt)
        for i in 0..<ObjectTracker.bins {
            let start = CGFloat(i) / CGFloat(ObjectTracker.bins) * 2 * .pi - .pi / 2
            let end = start + 2 * .pi / CGFloat(ObjectTracker.bins) - 0.025
            let color = covered.contains(i) ? UIColor.systemGreen : UIColor.white.withAlphaComponent(0.25)
            ctx.setStrokeColor(color.cgColor)
            ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            ctx.strokePath()
        }
        let text = complete ? "✓" : percentText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: complete ? 26 : 15, weight: .bold),
            .foregroundColor: complete ? UIColor.systemGreen : UIColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)

        let labels = ["낮", "중", "위"]
        let barTop = ringSize + 4
        let smallAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: UIColor.white,
        ]
        for (i, pct) in bandPercents.prefix(3).enumerated() {
            let slot = rect.width / 3
            let x = CGFloat(i) * slot
            let width = slot - 3
            let barRect = CGRect(x: x, y: barTop, width: width, height: 6)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.25).cgColor)
            ctx.fill(barRect)
            ctx.setFillColor(UIColor.systemGreen.cgColor)
            ctx.fill(CGRect(x: x, y: barTop, width: width * CGFloat(min(max(pct, 0), 100) / 100), height: 6))
            (labels[i] as NSString).draw(at: CGPoint(x: x, y: barTop + 8), withAttributes: smallAttributes)
        }
    }
}

/// 화면 가운데 조준점
final class ReticleView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.addArc(center: center, radius: rect.width / 2 - 2, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()
        let gap: CGFloat = 6
        let arm: CGFloat = rect.width / 2 - 2
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            ctx.move(to: CGPoint(x: center.x + CGFloat(dx) * gap, y: center.y + CGFloat(dy) * gap))
            ctx.addLine(to: CGPoint(x: center.x + CGFloat(dx) * arm, y: center.y + CGFloat(dy) * arm))
        }
        ctx.strokePath()
        ctx.setFillColor(UIColor.systemRed.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
    }
}
