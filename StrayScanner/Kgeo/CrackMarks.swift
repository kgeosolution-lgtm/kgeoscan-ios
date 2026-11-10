//
//  CrackMarks.swift
//  kgeoScan
//
//  위치 표시 (녹화 중 화면 탭): 면 촬영은 균열(점·두 점 선분), 굴착 기록은 관 종류(utility, class = gas|water|sewer|power|
//  telecom|heat|unknown — 서버는 이 표시를 색 추정보다 우선한다). 탭한 곳의 월드 좌표(ARKit raycast → LiDAR 깊이)를 모아
//  녹화 폴더(odometry.csv 와 같은 폴더) 에 marks.json 으로 쓴다. 좌표는 odometry.csv 와 같은 ARKit 월드(m).
//  표시가 없으면 파일을 만들지 않는다. 화면의 핀·선은 같은 월드 좌표에 놓은 SceneKit 노드다.
//  (Stray Scanner 포크에 추가된 파일)
//
//  {"version":1,"coord":"arkit_world","marks":[
//    {"id":1,"kind":"crack","x":..,"y":..,"z":..,"t":66351.18,"frame":123,"label":"","source":"raycast"},
//    {"id":2,"kind":"crack_line","p0":[x,y,z],"p1":[x,y,z],"t":..,"frame":..,"label":"","source":"depth"},
//    {"id":3,"kind":"utility","class":"gas","x":..,"y":..,"z":..,"t":..,"frame":..,"label":"","source":"raycast"}]}
//

import SceneKit
import UIKit
import simd

/// 관 종류 (marks.json kind=utility 의 class, 서버 utilities.json 의 class 와 같은 값)
enum UtilityClass: String, CaseIterable {
    case gas
    case water
    case sewer
    case power
    case telecom
    case heat
    case unknown

    var label: String {
        switch self {
        case .gas:
            return "가스"
        case .water:
            return "상수"
        case .sewer:
            return "하수"
        case .power:
            return "전력"
        case .telecom:
            return "통신"
        case .heat:
            return "난방"
        case .unknown:
            return "모름"
        }
    }

    /// 화면 핀 색 (표시용일 뿐 — 국내는 가스 말고는 통일된 관 색 규정이 없다)
    var color: UIColor {
        switch self {
        case .gas:
            return .systemYellow
        case .water:
            return .systemBlue
        case .sewer:
            return .brown
        case .power:
            return .systemRed
        case .telecom:
            return .systemGreen
        case .heat:
            return .systemOrange
        case .unknown:
            return .systemGray
        }
    }
}

/// marks.json 의 표시 하나. crack·utility 는 x y z, crack_line 은 p0 p1 (m, 소수 4자리)
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
    /// kind=utility 의 관 종류 (JSON 키 "class")
    var utilityClass: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case x
        case y
        case z
        case p0
        case p1
        case t
        case frame
        case label
        case source
        case utilityClass = "class"
    }
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

    static func utility(id: Int, at position: SIMD3<Float>, utilityClass: UtilityClass, t: TimeInterval, frame: Int,
                        source: String) -> CrackMark {
        CrackMark(id: id, kind: "utility", x: rounded(position.x), y: rounded(position.y), z: rounded(position.z),
                  t: t, frame: frame, source: source, utilityClass: utilityClass.rawValue)
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
