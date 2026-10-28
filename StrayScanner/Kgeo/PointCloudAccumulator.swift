//
//  PointCloudAccumulator.swift
//  kgeoScan
//
//  촬영 직후 폰 미리보기용 촘촘한 색 점: 녹화 중 ARFrame.sceneDepth 를 역투영해 월드 점을 만들고,
//  색은 같은 프레임의 capturedImage 원본 해상도에서 그 점 위치 픽셀을 YCbCr→RGB 로 직접 샘플한다.
//  점은 복셀 해시(기본 1 cm, 물체 모드 3 mm)로 합치고 복셀마다 위치·색을 평균한다 (여러 프레임 평균색, 이음매 없음).
//  깊이 규칙은 서버와 같다: 4 m 초과는 버리고, 2 m 초과는 confidence 2 만, 2 m 이하는 confidence 1 이상.
//  메인 스레드에서는 깊이·신뢰도·깊이 해상도 RGB 만 복사하고 합치기는 백그라운드에서 한다 (ARFrame 을 붙잡지 않는다).
//  (Stray Scanner 포크에 추가된 파일)
//

import ARKit
import simd

/// 미리보기 색 점 (복셀 평균)
struct ColoredPoints {
    var positions: [SIMD3<Float>] = []
    /// 점마다 r, g, b
    var colors: [UInt8] = []

    var isEmpty: Bool { positions.isEmpty }
}

final class PointCloudAccumulator {
    static let maxPoints = 2_000_000
    static let maxDepth: Float = 4.0
    static let farDepth: Float = 2.0
    static let minConfidenceNear: UInt8 = 1

    let voxelSize: Float
    private let queue = DispatchQueue(label: "kgeo.points", qos: .utility)

    // queue 에서만 다룬다
    private var index: [Int64: Int32] = [:]
    private var sumX: [Float] = []
    private var sumY: [Float] = []
    private var sumZ: [Float] = []
    private var sumR: [UInt32] = []
    private var sumG: [UInt32] = []
    private var sumB: [UInt32] = []
    private var counts: [UInt16] = []

    // 메인 스레드에서만 다룬다
    private var busy = false
    private(set) var pointCount = 0
    private(set) var samples = 0

    init(voxelSize: Float) {
        self.voxelSize = voxelSize
    }

    private struct Sample {
        let width: Int
        let height: Int
        let depth: [Float]
        let confidence: [UInt8]
        let colors: [UInt8]
        let transform: simd_float4x4
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
        let crop: PreviewCrop?
    }

    /// 메인 스레드에서 부른다. 앞 샘플을 아직 합치는 중이면 건너뛰고 false.
    @discardableResult
    func add(frame: ARFrame, crop: PreviewCrop?) -> Bool {
        guard !busy, let sceneDepth = frame.sceneDepth else { return false }
        let depthMap = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return false }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0,
              let depth = PointCloudAccumulator.copyFloats(depthMap),
              let colors = PointCloudAccumulator.sampleColors(frame.capturedImage, width: width, height: height)
        else { return false }
        let confidence = sceneDepth.confidenceMap.flatMap {
            PointCloudAccumulator.copyBytes($0, width: width, height: height)
        } ?? []
        let imageWidth = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageHeight = Float(CVPixelBufferGetHeight(frame.capturedImage))
        guard imageWidth > 0, imageHeight > 0 else { return false }
        let k = frame.camera.intrinsics
        let sx = Float(width) / imageWidth
        let sy = Float(height) / imageHeight
        let sample = Sample(width: width, height: height, depth: depth, confidence: confidence, colors: colors,
                            transform: frame.camera.transform,
                            fx: k.columns.0.x * sx, fy: k.columns.1.y * sy,
                            cx: k.columns.2.x * sx, cy: k.columns.2.y * sy, crop: crop)
        busy = true
        samples += 1
        queue.async {
            let count = self.integrate(sample)
            DispatchQueue.main.async {
                self.busy = false
                self.pointCount = count
            }
        }
        return true
    }

    private func integrate(_ s: Sample) -> Int {
        let inverseVoxel = 1 / voxelSize
        let transform = s.transform
        let limit = PointCloudAccumulator.maxPoints
        for y in 0..<s.height {
            let v = Float(y) + 0.5
            for x in 0..<s.width {
                let i = y * s.width + x
                let d = s.depth[i]
                if !(d > 0.05 && d <= PointCloudAccumulator.maxDepth) { continue }
                let confidence: UInt8 = s.confidence.isEmpty ? 2 : s.confidence[i]
                if d > PointCloudAccumulator.farDepth {
                    if confidence < 2 { continue }
                } else if confidence < PointCloudAccumulator.minConfidenceNear {
                    continue
                }
                let u = Float(x) + 0.5
                let cameraPoint = SIMD4<Float>((u - s.cx) / s.fx * d, -(v - s.cy) / s.fy * d, -d, 1)
                let world = transform * cameraPoint
                let point = SIMD3<Float>(world.x, world.y, world.z)
                if let crop = s.crop, simd_distance_squared(point, crop.center) > crop.radius * crop.radius {
                    continue
                }
                let ix = Int64((point.x * inverseVoxel).rounded(.down)) & 0x1FFFFF
                let iy = Int64((point.y * inverseVoxel).rounded(.down)) & 0x1FFFFF
                let iz = Int64((point.z * inverseVoxel).rounded(.down)) & 0x1FFFFF
                let key = (ix << 42) | (iy << 21) | iz
                let o = i * 3
                if let existing = index[key] {
                    let n = Int(existing)
                    if counts[n] == UInt16.max { continue }
                    sumX[n] += point.x
                    sumY[n] += point.y
                    sumZ[n] += point.z
                    sumR[n] += UInt32(s.colors[o])
                    sumG[n] += UInt32(s.colors[o + 1])
                    sumB[n] += UInt32(s.colors[o + 2])
                    counts[n] += 1
                } else if sumX.count < limit {
                    index[key] = Int32(sumX.count)
                    sumX.append(point.x)
                    sumY.append(point.y)
                    sumZ.append(point.z)
                    sumR.append(UInt32(s.colors[o]))
                    sumG.append(UInt32(s.colors[o + 1]))
                    sumB.append(UInt32(s.colors[o + 2]))
                    counts.append(1)
                }
            }
        }
        return sumX.count
    }

    /// 남은 합치기를 기다린 뒤 평균 점을 돌려주고 메모리를 비운다. 메인이 아닌 큐에서 부른다.
    /// crop 이 있으면 그 구 안의 점만 (녹화 중에 물체를 정한 경우 그 전 점을 걸러 낸다).
    func finish(crop: PreviewCrop?) -> ColoredPoints {
        var result = ColoredPoints()
        queue.sync {
            let n = sumX.count
            result.positions.reserveCapacity(n)
            result.colors.reserveCapacity(n * 3)
            let radiusSquared = crop.map { $0.radius * $0.radius } ?? 0
            for k in 0..<n {
                let count = Float(counts[k])
                let point = SIMD3<Float>(sumX[k] / count, sumY[k] / count, sumZ[k] / count)
                if let crop = crop, simd_distance_squared(point, crop.center) > radiusSquared { continue }
                let c = UInt32(counts[k])
                result.positions.append(point)
                result.colors.append(UInt8(min(255, sumR[k] / c)))
                result.colors.append(UInt8(min(255, sumG[k] / c)))
                result.colors.append(UInt8(min(255, sumB[k] / c)))
            }
            index.removeAll()
            sumX.removeAll()
            sumY.removeAll()
            sumZ.removeAll()
            sumR.removeAll()
            sumG.removeAll()
            sumB.removeAll()
            counts.removeAll()
        }
        return result
    }

    // MARK: 버퍼 복사

    static func copyFloats(_ buffer: CVPixelBuffer) -> [Float]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBufferPointer { out in
            for row in 0..<height {
                let source = base.advanced(by: row * rowBytes).assumingMemoryBound(to: Float.self)
                for col in 0..<width {
                    out[row * width + col] = source[col]
                }
            }
        }
        return values
    }

    static func copyBytes(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [UInt8](repeating: 0, count: width * height)
        values.withUnsafeMutableBufferPointer { out in
            for row in 0..<height {
                let source = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
                for col in 0..<width {
                    out[row * width + col] = source[col]
                }
            }
        }
        return values
    }

    /// 깊이 맵 각 픽셀 중심에 해당하는 원본 영상 픽셀을 YCbCr(풀 레인지) → RGB 로 샘플 (깊이 해상도 크기의 RGB)
    static func sampleColors(_ image: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        guard CVPixelBufferGetPlaneCount(image) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return nil }
        let fullWidth = CVPixelBufferGetWidthOfPlane(image, 0)
        let fullHeight = CVPixelBufferGetHeightOfPlane(image, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(image, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(image, 1)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        guard fullWidth > 0, fullHeight > 0, chromaWidth > 0, chromaHeight > 0 else { return nil }
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgb.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let sy = min(fullHeight - 1, (2 * y + 1) * fullHeight / (2 * height))
                let chromaY = min(chromaHeight - 1, sy * chromaHeight / fullHeight)
                for x in 0..<width {
                    let sx = min(fullWidth - 1, (2 * x + 1) * fullWidth / (2 * width))
                    let chromaX = min(chromaWidth - 1, sx * chromaWidth / fullWidth)
                    let l = Float(luma[sy * lumaRow + sx])
                    let cb = Float(chroma[chromaY * chromaRow + chromaX * 2]) - 128
                    let cr = Float(chroma[chromaY * chromaRow + chromaX * 2 + 1]) - 128
                    let red = l + 1.402 * cr
                    let green = l - 0.344136 * cb - 0.714136 * cr
                    let blue = l + 1.772 * cb
                    let o = (y * width + x) * 3
                    out[o] = UInt8(max(0, min(255, red)))
                    out[o + 1] = UInt8(max(0, min(255, green)))
                    out[o + 2] = UInt8(max(0, min(255, blue)))
                }
            }
        }
        return rgb
    }
}
