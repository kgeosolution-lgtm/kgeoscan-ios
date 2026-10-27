//
//  MeshOverlay.swift
//  kgeoScan
//
//  ARKit sceneReconstruction 의 ARMeshAnchor 를 반투명 면 + 흰 윤곽선으로 카메라 화면 위에 그린다.
//  (Stray Scanner 포크에 추가된 파일) 녹화 데이터에는 아무 영향이 없다 — 표시만 한다.
//  ARMeshGeometry 의 MTLBuffer 를 복사 없이 SceneKit 지오메트리 소스로 쓴다.
//

import ARKit
import SceneKit
import UIKit

final class MeshOverlayDelegate: NSObject, ARSCNViewDelegate {
    static let fillColor = UIColor(red: 0.25, green: 0.65, blue: 1.0, alpha: 0.35)
    static let lineColor = UIColor(white: 1.0, alpha: 0.22)
    static let nodeName = "kgeo.mesh"

    /// 새로 만들어지는 노드에 적용된다. 기존 노드는 setHidden(_:in:) 으로 바꾼다.
    var isEnabled = true

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        let node = SCNNode()
        node.name = MeshOverlayDelegate.nodeName
        node.isHidden = !isEnabled
        MeshOverlayDelegate.update(node: node, with: meshAnchor)
        return node
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        MeshOverlayDelegate.update(node: node, with: meshAnchor)
    }

    /// 메인 스레드에서 부른다.
    static func setHidden(_ hidden: Bool, in sceneView: ARSCNView) {
        sceneView.scene.rootNode.enumerateChildNodes { node, _ in
            if node.name == MeshOverlayDelegate.nodeName {
                node.isHidden = hidden
            }
        }
    }

    private static func update(node: SCNNode, with anchor: ARMeshAnchor) {
        let fill = makeGeometry(anchor.geometry)
        fill.materials = [fillMaterial()]
        node.geometry = fill

        let lines = makeGeometry(anchor.geometry)
        lines.materials = [lineMaterial()]
        if let child = node.childNodes.first {
            child.geometry = lines
        } else {
            node.addChildNode(SCNNode(geometry: lines))
        }
    }

    private static func makeGeometry(_ geometry: ARMeshGeometry) -> SCNGeometry {
        let vertices = SCNGeometrySource(buffer: geometry.vertices.buffer,
                                         vertexFormat: geometry.vertices.format,
                                         semantic: .vertex,
                                         vertexCount: geometry.vertices.count,
                                         dataOffset: geometry.vertices.offset,
                                         dataStride: geometry.vertices.stride)
        let normals = SCNGeometrySource(buffer: geometry.normals.buffer,
                                        vertexFormat: geometry.normals.format,
                                        semantic: .normal,
                                        vertexCount: geometry.normals.count,
                                        dataOffset: geometry.normals.offset,
                                        dataStride: geometry.normals.stride)
        let faces = geometry.faces
        let element = SCNGeometryElement(buffer: faces.buffer,
                                         primitiveType: .triangles,
                                         primitiveCount: faces.count,
                                         bytesPerIndex: faces.bytesPerIndex)
        return SCNGeometry(sources: [vertices, normals], elements: [element])
    }

    private static func fillMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = fillColor
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        return material
    }

    private static func lineMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = lineColor
        material.lightingModel = .constant
        material.fillMode = .lines
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        return material
    }
}

/// 안쪽 여백이 있는 라벨 (화면 위 상태·안내 문구용)
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right,
                      height: size.height + insets.top + insets.bottom)
    }
}
