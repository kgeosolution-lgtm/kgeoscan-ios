//
//  HiresRecorder.swift
//  kgeoScan
//
//  면 촬영(정사영상): 녹화 중 정지 사진을 녹화 폴더의 hires/000001.jpg … 로 저장하고, 끝에 hires/poses.json 을 쓴다.
//  정지 사진 출처 두 가지:
//  - video_frame (무음, 기본): 높은 해상도 영상 형식의 ARFrame.capturedImage 를 그 자리에서 복사해 저장
//  - high_res_capture: ARSession.captureHighResolutionFrame (한국판 아이폰은 셔터음이 강제된다)
//  자세는 odometry.csv 와 같은 월드·같은 카메라 규약(OdometryEncoder.cameraToWorld, OpenCV 카메라)이고
//  timestamp 도 odometry.csv 와 같은 ARFrame.timestamp 시간축이다. 내부 파라미터는 그 ARFrame 의 camera.intrinsics 를
//  저장한 JPEG 해상도로 환산한 값 (intrinsics_source "arframe"). JPEG 는 센서 방향 그대로 (EXIF 회전 미적용, Orientation 1),
//  EXIF 에는 ARFrame.exifData (초점거리 등) 와 Make/Model 을 넣는다. (Stray Scanner 포크에 추가된 파일)
//

import ARKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
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

    /// 메인 스레드에서 부른다. 픽셀을 바로 복사해 ARKit 버퍼·ARFrame 을 붙잡지 않고, JPEG 저장은 백그라운드에서 한다.
    /// index 는 1부터, source 는 video_frame | high_res_capture
    func add(frame: ARFrame, index: Int, source: String) {
        guard let pixelBuffer = HiresRecorder.copy(frame.capturedImage) else {
            queue.async { self.failures += 1 }
            return
        }
        let transform = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let timestamp = frame.timestamp
        let exif = frame.exifData
        queue.async {
            self.write(pixelBuffer: pixelBuffer, transform: transform, intrinsics: intrinsics, timestamp: timestamp,
                       exif: exif, index: index, source: source)
        }
    }

    private func write(pixelBuffer: CVPixelBuffer, transform: simd_float4x4, intrinsics: simd_float3x3,
                       timestamp: TimeInterval, exif: [String: Any], index: Int, source: String) {
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
        }
        let name = String(format: "%06d.jpg", index)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let rect = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        guard let cgImage = context.createCGImage(image, from: rect),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            failures += 1
            return
        }
        let fx = Double(intrinsics.columns.0.x) * scale
        let fy = Double(intrinsics.columns.1.y) * scale
        let cx = Double(intrinsics.columns.2.x) * scale
        let cy = Double(intrinsics.columns.2.y) * scale
        let properties = HiresRecorder.metadata(exif: exif, width: outWidth, height: outHeight, fx: fx)
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            failures += 1
            return
        }
        let m = OdometryEncoder.cameraToWorld(transform)
        let entry: [String: Any] = [
            "file": "hires/" + name,
            "timestamp": timestamp,
            "transform": HiresRecorder.columnMajor(m),
            "fx": fx,
            "fy": fy,
            "cx": cx,
            "cy": cy,
            "width": outWidth,
            "height": outHeight,
            "source_width": width,
            "source_height": height,
            "exif_orientation": HiresRecorder.portraitOrientation,
            "intrinsics_source": "arframe",
            "still_source": source,
        ]
        entries.append(entry)
    }

    /// JPEG 메타데이터: ARFrame.exifData + Make/Model, 픽셀 크기, Orientation 1
    static func metadata(exif: [String: Any], width: Int, height: Int, fx: Double) -> [String: Any] {
        var exifDictionary: [String: Any]
        var tiffDictionary: [String: Any] = [:]
        if let nested = exif[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exifDictionary = nested
            tiffDictionary = exif[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        } else {
            exifDictionary = exif
        }
        exifDictionary.removeValue(forKey: kCGImagePropertyOrientation as String)
        exifDictionary[kCGImagePropertyExifPixelXDimension as String] = width
        exifDictionary[kCGImagePropertyExifPixelYDimension as String] = height
        if exifDictionary[kCGImagePropertyExifFocalLenIn35mmFilm as String] == nil, fx > 0 {
            let diagonal = sqrt(Double(width * width + height * height))
            exifDictionary[kCGImagePropertyExifFocalLenIn35mmFilm as String] = Int((fx * 43.2666 / diagonal).rounded())
        }
        tiffDictionary[kCGImagePropertyTIFFOrientation as String] = 1
        if tiffDictionary[kCGImagePropertyTIFFMake as String] == nil {
            tiffDictionary[kCGImagePropertyTIFFMake as String] = "Apple"
        }
        if tiffDictionary[kCGImagePropertyTIFFModel as String] == nil {
            tiffDictionary[kCGImagePropertyTIFFModel as String] = ScanMeta.marketingName()
        }
        tiffDictionary[kCGImagePropertyTIFFSoftware as String] = "kgeoScan"
        return [
            kCGImagePropertyExifDictionary as String: exifDictionary,
            kCGImagePropertyTIFFDictionary as String: tiffDictionary,
            kCGImagePropertyOrientation as String: 1,
            kCGImageDestinationLossyCompressionQuality as String: jpegQuality,
        ]
    }

    /// 픽셀 버퍼 깊은 복사 (ARKit 버퍼 풀을 붙잡지 않도록)
    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &output) == kCVReturnSuccess,
              let copy = output else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let to = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { return nil }
                let rows = CVPixelBufferGetHeightOfPlane(source, plane)
                let fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let toStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
                let rowBytes = min(fromStride, toStride)
                for row in 0..<rows {
                    memcpy(to.advanced(by: row * toStride), from.advanced(by: row * fromStride), rowBytes)
                }
            }
        } else {
            guard let from = CVPixelBufferGetBaseAddress(source),
                  let to = CVPixelBufferGetBaseAddress(copy) else { return nil }
            let fromStride = CVPixelBufferGetBytesPerRow(source)
            let toStride = CVPixelBufferGetBytesPerRow(copy)
            let rowBytes = min(fromStride, toStride)
            for row in 0..<height {
                memcpy(to.advanced(by: row * toStride), from.advanced(by: row * fromStride), rowBytes)
            }
        }
        CVBufferPropagateAttachments(source, copy)
        return copy
    }

    static func columnMajor(_ m: simd_float4x4) -> [Float] {
        let c0 = m.columns.0
        let c1 = m.columns.1
        let c2 = m.columns.2
        let c3 = m.columns.3
        return [c0.x, c0.y, c0.z, c0.w, c1.x, c1.y, c1.z, c1.w, c2.x, c2.y, c2.z, c2.w, c3.x, c3.y, c3.z, c3.w]
    }

    /// 메인 스레드에서 부른다: 남은 저장을 기다린 뒤 hires/poses.json 을 쓰고 저장된 장수를 돌려준다
    func finish(surface: String, formatRecommended: Bool, source: String, format: String, videoSize: String) -> Int {
        var written = 0
        queue.sync {
            let sorted = entries.sorted { ($0["file"] as? String ?? "") < ($1["file"] as? String ?? "") }
            let document: [String: Any] = [
                "frame": "odometry",
                "units": "m",
                "surface": surface,
                "hires_source": source,
                "hires_format": format,
                "video_size": videoSize,
                "intrinsics_source": "arframe",
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
