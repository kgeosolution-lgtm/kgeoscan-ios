//
//  HiresRecorder.swift
//  kgeoScan
//
//  면 촬영(정사영상): 녹화 중 ARSession.captureHighResolutionFrame 로 받은 고해상도 정지 사진을
//  녹화 폴더의 hires/000001.jpg … 로 저장하고, 끝에 hires/poses.json 을 쓴다.
//  자세는 odometry.csv 와 같은 월드·같은 카메라 규약(OdometryEncoder.cameraToWorld, OpenCV 카메라)이고
//  timestamp 도 odometry.csv 와 같은 ARFrame.timestamp 시간축이다. 내부 파라미터는 저장한 JPEG 해상도 기준.
//  JPEG 는 센서 방향 그대로 (EXIF 회전 미적용). (Stray Scanner 포크에 추가된 파일)
//

import ARKit
import CoreImage
import ImageIO
import simd

final class HiresRecorder {
    static let maxShots = 200
    static let maxSide = 4032
    static let jpegQuality = 0.9
    /// 세로로 든 화면에서 센서 영상을 바로 세우는 EXIF 방향 (시계 방향 90° 회전 = 6)
    static let portraitOrientation = 6

    let directory: URL
    private let queue = DispatchQueue(label: "kgeo.hires", qos: .userInitiated)
    private let context = CIContext()
    /// queue 에서만 다룬다
    private var entries: [[String: Any]] = []
    private var failures = 0

    init(datasetDirectory: URL) throws {
        directory = datasetDirectory.appendingPathComponent("hires", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 메인 스레드에서 부른다. index 는 1부터. JPEG 저장은 백그라운드.
    func add(frame: ARFrame, index: Int) {
        let pixelBuffer = frame.capturedImage
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let timestamp = frame.timestamp
        queue.async {
            self.write(pixelBuffer: pixelBuffer, transform: transform, intrinsics: intrinsics,
                       timestamp: timestamp, index: index)
        }
    }

    private func write(pixelBuffer: CVPixelBuffer, transform: simd_float4x4, intrinsics: simd_float3x3,
                       timestamp: TimeInterval, index: Int) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            failures += 1
            return
        }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let longSide = max(width, height)
        let scale = longSide > HiresRecorder.maxSide ? Double(HiresRecorder.maxSide) / Double(longSide) : 1.0
        let outWidth = Int((Double(width) * scale).rounded())
        let outHeight = Int((Double(height) * scale).rounded())
        if scale < 1 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0,
            ])
            image = image.cropped(to: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        }
        let name = String(format: "%06d.jpg", index)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let options: [CIImageRepresentationOption: Any] = [qualityKey: HiresRecorder.jpegQuality]
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
            failures += 1
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            failures += 1
            return
        }
        let m = OdometryEncoder.cameraToWorld(transform)
        let entry: [String: Any] = [
            "file": "hires/" + name,
            "timestamp": timestamp,
            "transform": HiresRecorder.columnMajor(m),
            "fx": Double(intrinsics.columns.0.x) * scale,
            "fy": Double(intrinsics.columns.1.y) * scale,
            "cx": Double(intrinsics.columns.2.x) * scale,
            "cy": Double(intrinsics.columns.2.y) * scale,
            "width": outWidth,
            "height": outHeight,
            "source_width": width,
            "source_height": height,
            "exif_orientation": HiresRecorder.portraitOrientation,
        ]
        entries.append(entry)
    }

    static func columnMajor(_ m: simd_float4x4) -> [Float] {
        let c0 = m.columns.0
        let c1 = m.columns.1
        let c2 = m.columns.2
        let c3 = m.columns.3
        return [c0.x, c0.y, c0.z, c0.w, c1.x, c1.y, c1.z, c1.w, c2.x, c2.y, c2.z, c2.w, c3.x, c3.y, c3.z, c3.w]
    }

    /// 메인 스레드에서 부른다: 남은 저장을 기다린 뒤 hires/poses.json 을 쓰고 저장된 장수를 돌려준다
    func finish(surface: String, formatRecommended: Bool) -> Int {
        var written = 0
        queue.sync {
            let sorted = entries.sorted { ($0["file"] as? String ?? "") < ($1["file"] as? String ?? "") }
            let document: [String: Any] = [
                "frame": "odometry",
                "units": "m",
                "surface": surface,
                "transform_convention": "column-major 4x4 camera-to-world, identical to odometry.csv rows (x,y,z + qx,qy,qz,qw; OpenCV camera: x right, y down, z forward)",
                "timestamp_clock": "ARFrame.timestamp, same clock as odometry.csv timestamp",
                "image_orientation": "sensor orientation; EXIF orientation not applied (exif_orientation 6 = rotate 90° clockwise for portrait display)",
                "video_format_recommended_for_stills": formatRecommended,
                "failed": failures,
                "images": sorted,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: document,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? data.write(to: directory.appendingPathComponent("poses.json", isDirectory: false), options: .atomic)
            }
            written = sorted.count
        }
        return written
    }
}
