//
//  OdometryEncoder.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 1/31/21.
//  Copyright © 2021 Stray Robots. All rights reserved.
//

import Foundation
import Accelerate
import ARKit
import AVFoundation

class OdometryEncoder {
    let path: URL
    let q_AC = OdometryEncoder.cameraAxisFlip

    // kgeoScan: odometry.csv 와 hires/poses.json 이 똑같은 자세를 쓰도록 변환을 한곳에 모았다 (값은 원본과 같다).
    /// ARKit 카메라(x 오른쪽, y 위, -z 앞) → odometry.csv 카메라(OpenCV: x 오른쪽, y 아래, z 앞): x 축 180° 회전
    static let cameraAxisFlip = simd_quatf(ix: 1.0, iy: 0.0, iz: 0.0, r: 0.0)

    /// odometry.csv 한 행의 자세: (월드 위치 x y z, 카메라→월드 회전 qx qy qz qw)
    static func pose(of transform: simd_float4x4) -> (translation: vector_float3, rotation: simd_quatf) {
        let t = transform[3]
        return (vector_float3(t.x, t.y, t.z), simd_quatf(transform) * cameraAxisFlip)
    }

    /// 같은 자세를 4×4 카메라→월드 행렬로 (열 우선)
    static func cameraToWorld(_ transform: simd_float4x4) -> simd_float4x4 {
        let p = pose(of: transform)
        var m = simd_float4x4(p.rotation)
        m.columns.3 = SIMD4<Float>(p.translation.x, p.translation.y, p.translation.z, 1)
        return m
    }
    var transforms: [simd_float4x4] = []
    let fileHandle: FileHandle
    
    /// kgeoScan: rgb.mp4 를 촬영 해상도보다 줄여 녹화할 때 fx, fy, cx, cy 에 곱하는 비율 (기본 1 = 원본과 같음)
    let intrinsicsScale: Float

    init(url: URL, intrinsicsScale: Float = 1) {
        self.intrinsicsScale = intrinsicsScale
        self.path = url
        do {
            try "".write(to: self.path, atomically: true, encoding: .utf8)
            self.fileHandle = try FileHandle(forWritingTo: self.path)
            self.fileHandle.write("timestamp, frame, x, y, z, qx, qy, qz, qw, fx, fy, cx, cy, distortion_center_x, distortion_center_y\n".data(using: .utf8)!)
        } catch let error {
            print("Can't create file \(self.path.absoluteString). \(error.localizedDescription)")
            preconditionFailure("Can't open odometry file for writing.")
        }
        
    }

    func add(frame: ARFrame, currentFrame: Int) {
        let transform = frame.camera.transform
        transforms.append(transform)
        let pose = OdometryEncoder.pose(of: transform)
        let xyz: vector_float3 = pose.translation
        let q: vector_float4 = pose.rotation.vector
        let frameNumber = String(format: "%06d", currentFrame)

        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x * intrinsicsScale
        let fy = intrinsics.columns.1.y * intrinsicsScale
        let cx = intrinsics.columns.2.x * intrinsicsScale
        let cy = intrinsics.columns.2.y * intrinsicsScale

        let distortionCenter = frame.capturedDepthData?.cameraCalibrationData?.lensDistortionCenter
        let dcx = distortionCenter.map { "\($0.x)" } ?? ""
        let dcy = distortionCenter.map { "\($0.y)" } ?? ""

        let line = "\(frame.timestamp), \(frameNumber), \(xyz.x), \(xyz.y), \(xyz.z), \(q.x), \(q.y), \(q.z), \(q.w), \(fx), \(fy), \(cx), \(cy), \(dcx), \(dcy)\n"
        self.fileHandle.write(line.data(using: .utf8)!)
    }

    func done() {
        do {
            try self.fileHandle.close()
        } catch let error {
            print("Can't close odometry file \(self.path.absoluteString). \(error.localizedDescription)")
        }
    }

    private func getTranslation(T: simd_float4x4) -> vector_float3 {
        let t = T[3]
        return vector_float3(t.x, t.y, t.z)
    }
}
