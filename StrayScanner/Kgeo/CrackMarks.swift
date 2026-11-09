//
//  CrackMarks.swift
//  kgeoScan
//
//  균열 위치 표시 (면 촬영 녹화 중 화면 탭). 탭한 곳의 월드 좌표(ARKit raycast → LiDAR 깊이)를 점, 또는 두 점 선분으로 모아
//  녹화 폴더(odometry.csv 와 같은 폴더) 에 marks.json 으로 쓴다. 좌표는 odometry.csv 와 같은 ARKit 월드(m).
//  표시가 없으면 파일을 만들지 않는다. 화면의 핀·선은 같은 월드 좌표에 놓은 SceneKit 노드다.
//  (Stray Scanner 포크에 추가된 파일)
//
//  {"version":1,"coord":"arkit_world","marks":[
//    {"id":1,"kind":"crack","x":..,"y":..,"z":..,"t":66351.18,"frame":123,"label":"","source":"raycast"},
//    {"id":2,"kind":"crack_line","p0":[x,y,z],"p1":[x,y,z],"t":..,"frame":..,"label":"","source":"depth"}]}
//

import SceneKit
import UIKit
import simd

/// marks.json 의 표시 하나. crack 은 x y z, crack_line 은 p0 p1 (m, 소수 4자리)
struct CrackMark: Codable {
    var id: Int
    /// crack | crack_line
    var kind: String
    var x: Double? = nil
    var y: Double? = nil
    var z: Double? = nil
    var p0: [Double]? = nil
    var p1: [Double]? = nil
    /// 표시한(선은 끝점을 찍은) 순간의 ARFrame 시간 (odometry.csv timestamp 와 같은 시간축)
    var t: Double
    /// 그때 마지막으로 저장된 프레임 번호 (odometry.csv frame)
    var frame: Int
    var label: String = ""
    /// 좌표를 구한 방법: raycast (ARKit 추정·감지 면) | depth (LiDAR 깊이 역투영). 선은 두 점 중 덜 정확한 쪽
    var source: String
}

struct CrackMarksFile: Codable {
    var version: Int = 1
    var coord: String = "arkit_world"
    var marks: [CrackMark]
}

enum CrackMarks {
    static let fileName = "marks.json"

    static func rounded(_ value: Float) -> Double {
        (Double(value) * 10000).rounded() / 10000
    }

    static func point(id: Int, at position: SIMD3<Float>, t: TimeInterval, frame: Int, source: String) -> CrackMark {
        CrackMark(id: id, kind: "crack", x: rounded(position.x), y: rounded(position.y), z: rounded(position.z),
                  t: t, frame: frame, source: source)
    }

    static func line(id: Int, from start: SIMD3<Float>, to end: SIMD3<Float>, t: TimeInterval, frame: Int,
                     source: String) -> CrackMark {
        CrackMark(id: id, kind: "crack_line",
                  p0: [rounded(start.x), rounded(start.y), rounded(start.z)],
                  p1: [rounded(end.x), rounded(end.y), rounded(end.z)],
                  t: t, frame: frame, source: source)
    }

    /// 녹화 폴더에 marks.json. 표시가 없으면 쓰지 않는다
    static func write(_ marks: [CrackMark], to directory: URL) throws {
        guard !marks.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(CrackMarksFile(marks: marks))
        try data.write(to: directory.appendingPathComponent(fileName, isDirectory: false), options: .atomic)
    }

    // MARK: - 화면 표시 (녹화 화면 ARSCNView 의 루트 노드에 월드 좌표로)

    private static func material(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color
        material.lightingModel = .constant
        // 메시 오버레이·벽에 가리지 않게 늘 위에 그린다
        material.readsFromDepthBuffer = false
        return material
    }

    static func makePinNode(at position: SIMD3<Float>, color: UIColor) -> SCNNode {
        let sphere = SCNSphere(radius: CGFloat(CaptureTuning.markPinRadius))
        sphere.materials = [material(color)]
        let node = SCNNode(geometry: sphere)
        node.simdPosition = position
        node.renderingOrder = 100
        return node
    }

    /// 선분 (원기둥 + 양 끝 핀)
    static func makeLineNode(from start: SIMD3<Float>, to end: SIMD3<Float>, color: UIColor) -> SCNNode {
        let container = SCNNode()
        let length = simd_distance(start, end)
        let cylinder = SCNCylinder(radius: CGFloat(CaptureTuning.markLineRadius), height: CGFloat(max(length, 0.001)))
        cylinder.materials = [material(color)]
        let bar = SCNNode(geometry: cylinder)
        bar.simdPosition = (start + end) / 2
        // SCNCylinder 는 y 축 방향이라 start → end 로 돌린다
        let direction = length > 0 ? (end - start) / length : SIMD3<Float>(0, 1, 0)
        bar.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
        bar.renderingOrder = 100
        container.addChildNode(bar)
        container.addChildNode(makePinNode(at: start, color: color))
        container.addChildNode(makePinNode(at: end, color: color))
        return container
    }
}
