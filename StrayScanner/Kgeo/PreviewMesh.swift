//
//  PreviewMesh.swift
//  kgeoScan
//
//  녹화 미리보기용 3D: 녹화 끝에 ARKit sceneReconstruction 메시(ARMeshAnchor)를 월드 좌표로 합치고,
//  녹화 중 모은 색 키프레임(0.7초마다 240 px 폭 RGB + LiDAR 깊이)에서 정점 색을 뽑아
//  녹화 폴더의 preview/preview_mesh.ply (binary PLY, odometry.csv 와 같은 월드 좌표, 미터)로 저장한다.
//  물체 모드면 지정한 구 안만 남긴다. 표시용이며 서버로 보내지 않는다 (preview/ 폴더는 zip 에서 빠진다).
//  (Stray Scanner 포크에 추가된 파일)
//

import ARKit
import SceneKit
import ModelIO
import SceneKit.ModelIO
import simd
import UIKit

// MARK: - 녹화 중 모으는 데이터

/// 정점 색 샘플링용 키프레임: 작은 RGB 영상 + LiDAR 깊이 + 카메라 자세·내부 파라미터
struct ColorKeyframe {
    let width: Int
    let height: Int
    let rgb: [UInt8]
    let depthWidth: Int
    let depthHeight: Int
    let depth: [Float]
    let worldToCamera: simd_float4x4
    let position: SIMD3<Float>
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float

    /// 메인 스레드(ARSession delegate)에서 부른다. 1~2 ms.
    init?(frame: ARFrame, outputWidth: Int = 240) {
        let image = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(image) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(image, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(image, 1) else { return nil }
        let fullWidth = CVPixelBufferGetWidthOfPlane(image, 0)
        let fullHeight = CVPixelBufferGetHeightOfPlane(image, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(image, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(image, 1)
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        guard fullWidth > 0, fullHeight > 0, chromaWidth > 0, chromaHeight > 0 else { return nil }

        let outWidth = outputWidth
        let outHeight = max(1, outputWidth * fullHeight / fullWidth)
        let lumaPixels = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chromaPixels = chromaBase.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 0, count: outWidth * outHeight * 3)
        for oy in 0..<outHeight {
            let sy = min(fullHeight - 1, (2 * oy + 1) * fullHeight / (2 * outHeight))
            let chromaY = min(chromaHeight - 1, sy * chromaHeight / fullHeight)
            for ox in 0..<outWidth {
                let sx = min(fullWidth - 1, (2 * ox + 1) * fullWidth / (2 * outWidth))
                let chromaX = min(chromaWidth - 1, sx * chromaWidth / fullWidth)
                let luma = Float(lumaPixels[sy * lumaRowBytes + sx])
                let cb = Float(chromaPixels[chromaY * chromaRowBytes + chromaX * 2]) - 128
                let cr = Float(chromaPixels[chromaY * chromaRowBytes + chromaX * 2 + 1]) - 128
                let red = luma + 1.402 * cr
                let green = luma - 0.344136 * cb - 0.714136 * cr
                let blue = luma + 1.772 * cb
                let o = (oy * outWidth + ox) * 3
                rgb[o] = UInt8(max(0, min(255, red)))
                rgb[o + 1] = UInt8(max(0, min(255, green)))
                rgb[o + 2] = UInt8(max(0, min(255, blue)))
            }
        }

        var depthValues: [Float] = []
        var depthW = 0
        var depthH = 0
        if let depthMap = frame.sceneDepth?.depthMap,
           CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 {
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(depthMap) {
                depthW = CVPixelBufferGetWidth(depthMap)
                depthH = CVPixelBufferGetHeight(depthMap)
                let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
                depthValues = [Float](repeating: 0, count: depthW * depthH)
                for row in 0..<depthH {
                    let source = base.advanced(by: row * rowBytes).assumingMemoryBound(to: Float.self)
                    for col in 0..<depthW {
                        depthValues[row * depthW + col] = source[col]
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        let intrinsics = frame.camera.intrinsics
        let scaleX = Float(outWidth) / Float(fullWidth)
        let scaleY = Float(outHeight) / Float(fullHeight)
        let transform = frame.camera.transform
        self.width = outWidth
        self.height = outHeight
        self.rgb = rgb
        self.depthWidth = depthW
        self.depthHeight = depthH
        self.depth = depthValues
        self.worldToCamera = transform.inverse
        self.position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        self.fx = intrinsics.columns.0.x * scaleX
        self.fy = intrinsics.columns.1.y * scaleY
        self.cx = intrinsics.columns.2.x * scaleX
        self.cy = intrinsics.columns.2.y * scaleY
    }
}

/// 녹화 끝의 ARKit 메시 (월드 좌표로 합친 것)
struct MeshSnapshot {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var faces: [UInt32] = []

    var isEmpty: Bool { faces.isEmpty }

    /// 메인 스레드에서 부른다. ARMeshAnchor 버퍼를 월드 좌표 배열로 복사한다.
    static func capture(from frame: ARFrame?) -> MeshSnapshot? {
        guard let frame = frame else { return nil }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        guard !anchors.isEmpty else { return nil }
        var snapshot = MeshSnapshot()
        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let faces = geometry.faces
            guard faces.indexCountPerPrimitive == 3 else { continue }
            let base = UInt32(snapshot.positions.count)

            let vertices = geometry.vertices
            let vertexPointer = vertices.buffer.contents()
            for i in 0..<vertices.count {
                let offset = vertices.offset + vertices.stride * i
                let x = vertexPointer.load(fromByteOffset: offset, as: Float.self)
                let y = vertexPointer.load(fromByteOffset: offset + 4, as: Float.self)
                let z = vertexPointer.load(fromByteOffset: offset + 8, as: Float.self)
                let world = transform * SIMD4<Float>(x, y, z, 1)
                snapshot.positions.append(SIMD3<Float>(world.x, world.y, world.z))
            }

            let normals = geometry.normals
            let normalPointer = normals.buffer.contents()
            for i in 0..<vertices.count {
                guard i < normals.count else {
                    snapshot.normals.append(SIMD3<Float>(0, 1, 0))
                    continue
                }
                let offset = normals.offset + normals.stride * i
                let nx = normalPointer.load(fromByteOffset: offset, as: Float.self)
                let ny = normalPointer.load(fromByteOffset: offset + 4, as: Float.self)
                let nz = normalPointer.load(fromByteOffset: offset + 8, as: Float.self)
                let rotated = transform * SIMD4<Float>(nx, ny, nz, 0)
                let normal = SIMD3<Float>(rotated.x, rotated.y, rotated.z)
                let length = simd_length(normal)
                snapshot.normals.append(length > 1e-6 ? normal / length : SIMD3<Float>(0, 1, 0))
            }

            let facePointer = faces.buffer.contents()
            let indexCount = faces.count * 3
            for k in 0..<indexCount {
                let index: UInt32
                if faces.bytesPerIndex == 2 {
                    index = UInt32(facePointer.load(fromByteOffset: k * 2, as: UInt16.self))
                } else {
                    index = facePointer.load(fromByteOffset: k * 4, as: UInt32.self)
                }
                snapshot.faces.append(base + index)
            }
        }
        return snapshot.isEmpty ? nil : snapshot
    }
}

/// 물체 모드: 이 구 안의 삼각형만 남긴다
struct PreviewCrop {
    let center: SIMD3<Float>
    let radius: Float
}

/// 정점 색이 있는 메시
struct ColoredMesh {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    /// 정점마다 r, g, b
    var colors: [UInt8]
    var faces: [UInt32]

    var triangleCount: Int { faces.count / 3 }
}

enum PreviewError: LocalizedError {
    case empty
    case badFile(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "메시가 비어 있습니다 (스캔된 면이 없거나 물체 영역 밖)"
        case .badFile(let message): return message
        }
    }
}

// MARK: - 만들기

final class PreviewBuilder: ObservableObject {
    static let shared = PreviewBuilder()
    static let folderName = "preview"
    static let meshFileName = "preview_mesh.ply"
    static let pointsFileName = "points.ply"

    /// 녹화 폴더 이름 → 진행률(0~1). 만드는 중일 때만 들어 있다 (메인 스레드에서만 바뀐다)
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var failures: [String: String] = [:]
    /// 색 점 미리보기 저장 중 (녹화 폴더 이름 → 0)
    @Published private(set) var pointsProgress: [String: Double] = [:]
    @Published private(set) var pointsFailures: [String: String] = [:]
    private let queue = DispatchQueue(label: "kgeo.preview.build", qos: .userInitiated)

    static func pointsURL(for directory: URL) -> URL {
        directory.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(pointsFileName, isDirectory: false)
    }

    /// 메인 스레드에서 부른다
    func isBuildingPoints(_ directory: URL) -> Bool {
        pointsProgress[directory.lastPathComponent] != nil
    }

    /// 메인 스레드에서 부른다. 녹화 중 모은 색 점을 평균내 preview/points.ply 로 저장한다 (메시보다 먼저 끝난다)
    func startPoints(directory: URL, accumulator: PointCloudAccumulator, crop: PreviewCrop?, start: simd_float4x4?) {
        let key = directory.lastPathComponent
        pointsProgress[key] = 0
        pointsFailures[key] = nil
        let voxel = accumulator.voxelSize
        queue.async {
            let cloud = accumulator.finish(crop: crop)
            var message: String?
            if cloud.isEmpty {
                message = "점이 없습니다 (깊이가 잡히지 않았거나 물체 영역 밖)"
            } else if FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try PreviewBuilder.writePointsPLY(cloud, voxel: voxel, start: start,
                                                      to: PreviewBuilder.pointsURL(for: directory))
                } catch {
                    message = error.localizedDescription
                }
            }
            DispatchQueue.main.async {
                self.pointsProgress[key] = nil
                if let message = message {
                    self.pointsFailures[key] = message
                }
            }
        }
    }

    static func meshURL(for directory: URL) -> URL {
        directory.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(meshFileName, isDirectory: false)
    }

    /// 메인 스레드에서 부른다
    func isBuilding(_ directory: URL) -> Bool {
        progress[directory.lastPathComponent] != nil
    }

    /// 메인 스레드에서 부른다. 백그라운드에서 색을 입히고 PLY 로 저장한다.
    func start(directory: URL, mesh: MeshSnapshot, keyframes: [ColorKeyframe], crop: PreviewCrop?) {
        let key = directory.lastPathComponent
        progress[key] = 0
        failures[key] = nil
        queue.async {
            var lastReported = 0.0
            let report: (Double) -> Void = { fraction in
                guard fraction - lastReported >= 0.05 || fraction >= 1 else { return }
                lastReported = fraction
                DispatchQueue.main.async {
                    if self.progress[key] != nil {
                        self.progress[key] = fraction
                    }
                }
            }
            do {
                let colored = PreviewBuilder.build(mesh: mesh, keyframes: keyframes, crop: crop, progress: report)
                guard colored.triangleCount > 0 else { throw PreviewError.empty }
                // '다시 찍기'로 폴더가 이미 지워졌으면 쓰지 않는다
                if FileManager.default.fileExists(atPath: directory.path) {
                    try PreviewBuilder.writePLY(colored, to: PreviewBuilder.meshURL(for: directory))
                }
                DispatchQueue.main.async {
                    self.progress[key] = nil
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self.progress[key] = nil
                    self.failures[key] = message
                }
            }
        }
    }

    /// 자르기 → 정점 색 입히기
    static func build(mesh: MeshSnapshot, keyframes: [ColorKeyframe], crop: PreviewCrop?,
                      progress: (Double) -> Void) -> ColoredMesh {
        var positions = mesh.positions
        var normals = mesh.normals
        var faces = mesh.faces

        if let crop = crop {
            let radiusSquared = crop.radius * crop.radius
            let inside = positions.map { simd_distance_squared($0, crop.center) <= radiusSquared }
            var remap = [Int](repeating: -1, count: positions.count)
            var newPositions: [SIMD3<Float>] = []
            var newNormals: [SIMD3<Float>] = []
            var newFaces: [UInt32] = []
            func keep(_ corner: Int) {
                if remap[corner] < 0 {
                    remap[corner] = newPositions.count
                    newPositions.append(positions[corner])
                    newNormals.append(corner < normals.count ? normals[corner] : SIMD3<Float>(0, 1, 0))
                }
                newFaces.append(UInt32(remap[corner]))
            }
            var t = 0
            while t + 2 < faces.count {
                let a = Int(faces[t])
                let b = Int(faces[t + 1])
                let c = Int(faces[t + 2])
                t += 3
                guard a < inside.count, b < inside.count, c < inside.count,
                      inside[a], inside[b], inside[c] else { continue }
                keep(a)
                keep(b)
                keep(c)
            }
            positions = newPositions
            normals = newNormals
            faces = newFaces
        }

        var colors = [UInt8](repeating: 170, count: positions.count * 3)
        if !keyframes.isEmpty {
            let total = max(positions.count, 1)
            for i in 0..<positions.count {
                if i % 5000 == 0 {
                    progress(Double(i) / Double(total))
                }
                let point = positions[i]
                let normal = i < normals.count ? normals[i] : SIMD3<Float>(0, 1, 0)
                var bestScore: Float = 0
                var bestIndex = -1
                var bestFrame = -1
                for (frameIndex, keyframe) in keyframes.enumerated() {
                    let cameraPoint = keyframe.worldToCamera * SIMD4<Float>(point.x, point.y, point.z, 1)
                    let distance = -cameraPoint.z
                    if distance < 0.05 { continue }
                    let u = keyframe.fx * cameraPoint.x / distance + keyframe.cx
                    let v = keyframe.fy * (-cameraPoint.y) / distance + keyframe.cy
                    if u < 0 || v < 0 || u >= Float(keyframe.width - 1) || v >= Float(keyframe.height - 1) { continue }
                    let toCamera = simd_normalize(keyframe.position - point)
                    let facing = simd_dot(normal, toCamera)
                    if facing < 0.15 { continue }
                    if !keyframe.depth.isEmpty {
                        let du = min(keyframe.depthWidth - 1, Int(u * Float(keyframe.depthWidth) / Float(keyframe.width)))
                        let dv = min(keyframe.depthHeight - 1, Int(v * Float(keyframe.depthHeight) / Float(keyframe.height)))
                        let measured = keyframe.depth[dv * keyframe.depthWidth + du]
                        if measured > 0 && abs(measured - distance) > 0.03 + 0.03 * measured { continue }
                    }
                    let score = facing / (0.3 + distance)
                    if score > bestScore {
                        bestScore = score
                        bestIndex = (Int(v) * keyframe.width + Int(u)) * 3
                        bestFrame = frameIndex
                    }
                }
                if bestFrame >= 0 {
                    let rgb = keyframes[bestFrame].rgb
                    colors[i * 3] = rgb[bestIndex]
                    colors[i * 3 + 1] = rgb[bestIndex + 1]
                    colors[i * 3 + 2] = rgb[bestIndex + 2]
                }
            }
        }
        progress(1)
        return ColoredMesh(positions: positions, normals: normals, colors: colors, faces: faces)
    }

    // MARK: PLY (binary little endian, 정점 x y z nx ny nz r g b / 면 3 a b c)

    static func writePLY(_ mesh: ColoredMesh, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = [
            "ply",
            "format binary_little_endian 1.0",
            "comment kgeoScan preview mesh (ARKit world = odometry.csv frame, metres)",
            "element vertex \(mesh.positions.count)",
            "property float x",
            "property float y",
            "property float z",
            "property float nx",
            "property float ny",
            "property float nz",
            "property uchar red",
            "property uchar green",
            "property uchar blue",
            "element face \(mesh.triangleCount)",
            "property list uchar int vertex_indices",
            "end_header",
        ].joined(separator: "\n") + "\n"
        var bytes = [UInt8](header.utf8)
        bytes.reserveCapacity(bytes.count + mesh.positions.count * 27 + mesh.triangleCount * 13)
        for i in 0..<mesh.positions.count {
            let p = mesh.positions[i]
            let n = i < mesh.normals.count ? mesh.normals[i] : SIMD3<Float>(0, 1, 0)
            appendValue(&bytes, p.x)
            appendValue(&bytes, p.y)
            appendValue(&bytes, p.z)
            appendValue(&bytes, n.x)
            appendValue(&bytes, n.y)
            appendValue(&bytes, n.z)
            bytes.append(mesh.colors[i * 3])
            bytes.append(mesh.colors[i * 3 + 1])
            bytes.append(mesh.colors[i * 3 + 2])
        }
        for f in 0..<mesh.triangleCount {
            bytes.append(3)
            appendValue(&bytes, Int32(bitPattern: mesh.faces[f * 3]))
            appendValue(&bytes, Int32(bitPattern: mesh.faces[f * 3 + 1]))
            appendValue(&bytes, Int32(bitPattern: mesh.faces[f * 3 + 2]))
        }
        try Data(bytes).write(to: url, options: .atomic)
    }

    @inline(__always)
    private static func appendValue<T>(_ bytes: inout [UInt8], _ value: T) {
        var copy = value
        withUnsafeBytes(of: &copy) { bytes.append(contentsOf: $0) }
    }

    /// writePLY 가 쓴 형식만 읽는다
    static func readPLY(_ url: URL) throws -> ColoredMesh {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let range = data.range(of: Data("end_header\n".utf8)) else {
            throw PreviewError.badFile("PLY 머리말이 없습니다")
        }
        let headerText = String(decoding: data[data.startIndex..<range.upperBound], as: UTF8.self)
        var vertexCount = 0
        var faceCount = 0
        for line in headerText.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "element" else { continue }
            if parts[1] == "vertex" { vertexCount = Int(parts[2]) ?? 0 }
            if parts[1] == "face" { faceCount = Int(parts[2]) ?? 0 }
        }
        let start = range.upperBound - data.startIndex
        guard data.count >= start + vertexCount * 27 + faceCount * 13 else {
            throw PreviewError.badFile("PLY 파일이 잘렸습니다")
        }
        var mesh = ColoredMesh(positions: [], normals: [], colors: [], faces: [])
        mesh.positions.reserveCapacity(vertexCount)
        mesh.normals.reserveCapacity(vertexCount)
        mesh.colors.reserveCapacity(vertexCount * 3)
        mesh.faces.reserveCapacity(faceCount * 3)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var o = start
            for _ in 0..<vertexCount {
                let x = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                let y = raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self)
                let z = raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)
                let nx = raw.loadUnaligned(fromByteOffset: o + 12, as: Float.self)
                let ny = raw.loadUnaligned(fromByteOffset: o + 16, as: Float.self)
                let nz = raw.loadUnaligned(fromByteOffset: o + 20, as: Float.self)
                mesh.positions.append(SIMD3<Float>(x, y, z))
                mesh.normals.append(SIMD3<Float>(nx, ny, nz))
                mesh.colors.append(raw[o + 24])
                mesh.colors.append(raw[o + 25])
                mesh.colors.append(raw[o + 26])
                o += 27
            }
            for _ in 0..<faceCount {
                let a = raw.loadUnaligned(fromByteOffset: o + 1, as: Int32.self)
                let b = raw.loadUnaligned(fromByteOffset: o + 5, as: Int32.self)
                let c = raw.loadUnaligned(fromByteOffset: o + 9, as: Int32.self)
                mesh.faces.append(UInt32(bitPattern: a))
                mesh.faces.append(UInt32(bitPattern: b))
                mesh.faces.append(UInt32(bitPattern: c))
                o += 13
            }
        }
        return mesh
    }
}

// MARK: - 색 점 PLY (binary little endian, 점 x y z r g b)

extension PreviewBuilder {
    static func writePointsPLY(_ cloud: ColoredPoints, voxel: Float, start: simd_float4x4?, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var header = [
            "ply",
            "format binary_little_endian 1.0",
            "comment kgeoScan preview points (ARKit world = odometry.csv frame, metres)",
            String(format: "comment voxel %.4f", voxel),
        ]
        if let start = start {
            let p = start.columns.3
            let f = -start.columns.2
            header.append(String(format: "comment start_camera %.4f %.4f %.4f %.4f %.4f %.4f", p.x, p.y, p.z, f.x, f.y, f.z))
        }
        header.append(contentsOf: [
            "element vertex \(cloud.positions.count)",
            "property float x",
            "property float y",
            "property float z",
            "property uchar red",
            "property uchar green",
            "property uchar blue",
            "end_header",
        ])
        var bytes = [UInt8]((header.joined(separator: "\n") + "\n").utf8)
        bytes.reserveCapacity(bytes.count + cloud.positions.count * 15)
        for i in 0..<cloud.positions.count {
            let p = cloud.positions[i]
            var x = p.x
            var y = p.y
            var z = p.z
            withUnsafeBytes(of: &x) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: &y) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: &z) { bytes.append(contentsOf: $0) }
            bytes.append(cloud.colors[i * 3])
            bytes.append(cloud.colors[i * 3 + 1])
            bytes.append(cloud.colors[i * 3 + 2])
        }
        try Data(bytes).write(to: url, options: .atomic)
    }

    /// writePointsPLY 가 쓴 형식만 읽는다. 녹화 시작 카메라(위치·정면)와 복셀 크기도 함께
    static func readPointsPLY(_ url: URL) throws -> (cloud: ColoredPoints, eye: SIMD3<Float>?, voxel: Float) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let range = data.range(of: Data("end_header\n".utf8)) else {
            throw PreviewError.badFile("PLY 머리말이 없습니다")
        }
        let headerText = String(decoding: data[data.startIndex..<range.upperBound], as: UTF8.self)
        var count = 0
        var eye: SIMD3<Float>?
        var voxel: Float = 0.01
        for line in headerText.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 3, parts[0] == "element", parts[1] == "vertex" {
                count = Int(parts[2]) ?? 0
            } else if parts.count == 3, parts[0] == "comment", parts[1] == "voxel" {
                voxel = Float(parts[2]) ?? 0.01
            } else if parts.count == 8, parts[0] == "comment", parts[1] == "start_camera",
                      let x = Float(parts[2]), let y = Float(parts[3]), let z = Float(parts[4]) {
                eye = SIMD3<Float>(x, y, z)
            }
        }
        let start = range.upperBound - data.startIndex
        guard data.count >= start + count * 15 else {
            throw PreviewError.badFile("PLY 파일이 잘렸습니다")
        }
        var cloud = ColoredPoints()
        cloud.positions.reserveCapacity(count)
        cloud.colors.reserveCapacity(count * 3)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var o = start
            for _ in 0..<count {
                let x = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                let y = raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self)
                let z = raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)
                cloud.positions.append(SIMD3<Float>(x, y, z))
                cloud.colors.append(raw[o + 12])
                cloud.colors.append(raw[o + 13])
                cloud.colors.append(raw[o + 14])
                o += 15
            }
        }
        return (cloud, eye, voxel)
    }
}

// MARK: - 보여 주기 (SceneKit)

struct PreviewSceneResult {
    let scene: SCNScene
    let center: SCNVector3
    let radius: Float
    let triangles: Int
    /// 화면에 보여 줄 출처 설명
    let kind: String
    /// 처음 카메라 위치 (색 점: 녹화 시작 위치). 없으면 위쪽 비스듬히
    var eye: SCNVector3? = nil
    var pointCount: Int = 0
}

enum PreviewSceneLoader {
    /// 녹화 폴더에서 보여 줄 3D 를 찾는다: Object Capture 모델(model/*.obj) → preview/model.usdz → ARKit 메시 PLY.
    /// 없으면 nil. 백그라운드 스레드에서 불러도 된다.
    static func load(directory: URL) throws -> PreviewSceneResult? {
        let modelDirectory = directory.appendingPathComponent("model", isDirectory: true)
        if let obj = firstFile(in: modelDirectory, extension: "obj") {
            return try loadModelIO(obj, kind: "Object Capture 모델 (폰에서 생성)")
        }
        let usdz = directory.appendingPathComponent(PreviewBuilder.folderName, isDirectory: true)
            .appendingPathComponent("model.usdz", isDirectory: false)
        if FileManager.default.fileExists(atPath: usdz.path) {
            return try loadModelIO(usdz, kind: "Object Capture 모델 (USDZ)")
        }
        let ply = PreviewBuilder.meshURL(for: directory)
        if FileManager.default.fileExists(atPath: ply.path) {
            return makeScene(try PreviewBuilder.readPLY(ply))
        }
        return nil
    }

    /// 정점 색(sRGB 바이트) → SceneKit 선형 색. 그대로 넣으면 화면에서 색이 허옇게 뜬다
    static let srgbToLinear: [Float] = (0..<256).map { value in
        let c = Float(value) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// 녹화 폴더의 색 점 미리보기 (preview/points.ply). 없으면 nil
    static func loadPoints(directory: URL) throws -> PreviewSceneResult? {
        let url = PreviewBuilder.pointsURL(for: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let loaded = try PreviewBuilder.readPointsPLY(url)
        return makePointScene(loaded.cloud, eye: loaded.eye, voxel: loaded.voxel)
    }

    /// 조명 없는 점 (SCNGeometryElement .point), 점 크기는 복셀 크기 기준이고 화면에서 반지름 1~3 px
    static func makePointScene(_ cloud: ColoredPoints, eye: SIMD3<Float>?, voxel: Float) -> PreviewSceneResult {
        let count = cloud.positions.count
        let vertexSource = SCNGeometrySource(vertices: cloud.positions.map { SCNVector3($0.x, $0.y, $0.z) })
        var colorFloats = [Float](repeating: 0, count: cloud.colors.count)
        for i in 0..<cloud.colors.count {
            colorFloats[i] = srgbToLinear[Int(cloud.colors[i])]
        }
        let colorData = colorFloats.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: count,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                            dataStride: MemoryLayout<Float>.size * 3)
        let indices = Array(0..<UInt32(count))
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .point, primitiveCount: count,
                                         bytesPerIndex: MemoryLayout<UInt32>.size)
        element.pointSize = CGFloat(voxel * 1.5)
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 3
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.isDoubleSided = true
        geometry.materials = [material]
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))

        var minPoint = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var sum = SIMD3<Float>(0, 0, 0)
        for p in cloud.positions {
            minPoint = simd_min(minPoint, p)
            maxPoint = simd_max(maxPoint, p)
            sum += p
        }
        let center = count > 0 ? sum / Float(count) : SIMD3<Float>(0, 0, 0)
        let radius = count > 0 ? max(simd_length(maxPoint - minPoint) / 2, 0.05) : 1
        var result = PreviewSceneResult(scene: scene, center: SCNVector3(center.x, center.y, center.z), radius: radius,
                                        triangles: 0, kind: "색 점 (녹화 중 깊이 + 원본 영상 색)")
        if let eye = eye {
            result.eye = SCNVector3(eye.x, eye.y, eye.z)
        }
        result.pointCount = count
        return result
    }

    static func firstFile(in directory: URL, extension ext: String) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return items.filter { $0.pathExtension.lowercased() == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    static func loadModelIO(_ url: URL, kind: String) throws -> PreviewSceneResult {
        let asset = MDLAsset(url: url)
        guard asset.count > 0 else {
            throw PreviewError.badFile("모델을 읽을 수 없습니다: \(url.lastPathComponent)")
        }
        asset.loadTextures()
        let scene = SCNScene(mdlAsset: asset)
        let box = asset.boundingBox
        let minBounds = box.minBounds
        let maxBounds = box.maxBounds
        let center = (minBounds + maxBounds) / 2
        let radius = max(simd_length(maxBounds - minBounds) / 2, 0.01)
        return PreviewSceneResult(scene: scene, center: SCNVector3(center.x, center.y, center.z),
                                  radius: radius, triangles: 0, kind: kind)
    }

    static func makeScene(_ mesh: ColoredMesh) -> PreviewSceneResult {
        let vertexSource = SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) })
        let normalSource = SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) })
        var colorFloats = [Float](repeating: 0, count: mesh.colors.count)
        for i in 0..<mesh.colors.count {
            colorFloats[i] = srgbToLinear[Int(mesh.colors[i])]
        }
        let colorData = colorFloats.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: mesh.positions.count,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                            dataStride: MemoryLayout<Float>.size * 3)
        let indexData = mesh.faces.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles,
                                         primitiveCount: mesh.triangleCount, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource], elements: [element])
        let material = SCNMaterial()
        // 정점 색에 이미 실제 밝기가 들어 있으므로 조명 없이 그대로 보여 준다
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.isDoubleSided = true
        geometry.materials = [material]
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))

        var minPoint = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for p in mesh.positions {
            minPoint = simd_min(minPoint, p)
            maxPoint = simd_max(maxPoint, p)
        }
        let center = mesh.positions.isEmpty ? SIMD3<Float>(0, 0, 0) : (minPoint + maxPoint) / 2
        let radius = mesh.positions.isEmpty ? 1 : max(simd_length(maxPoint - minPoint) / 2, 0.01)
        return PreviewSceneResult(scene: scene, center: SCNVector3(center.x, center.y, center.z), radius: radius,
                                  triangles: mesh.triangleCount, kind: "ARKit 메시 (녹화 중 폰이 만든 것)")
    }
}
