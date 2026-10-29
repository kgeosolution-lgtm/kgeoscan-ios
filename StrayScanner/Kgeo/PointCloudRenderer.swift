//
//  PointCloudRenderer.swift
//  kgeoScan
//
//  촬영 뒤 색 점 미리보기를 Metal(MTKView)로 그린다. SceneKit 은 WWDC25 에서 soft-deprecated 됐고
//  점 모양·후처리를 직접 다루려고 이 화면만 Metal 로 그린다.
//  - 월드 크기 점: 지름 = 복셀 × 1.3 (m) 을 화면 px 로 바꿔 [[point_size]] 로 준다 (반지름 1~24 px, 레티나 배율 반영).
//    가까이 가면 점이 커져 구멍이 메워진다.
//  - 둥근 점: fragment 에서 [[point_coord]] 가 중심에서 0.5 밖이면 버린다.
//  - EDL(eye-dome lighting): 1차 패스에서 색과 시선 깊이를 따로 그리고, 2차 패스에서 이웃 8개의 log2 깊이와 비교해
//    음영을 넣는다 (조명 없는 점에 입체감, Potree·CloudCompare 와 같은 방식). 끄면 색만 그대로 보여 준다.
//  - 한 손가락: 돌리기(턴테이블), 두 손가락: 확대·이동, 두 번 탭: 처음 시점.
//  셰이더는 실행 중에 소스로 컴파일한다 (빌드에 Metal 도구가 없어도 되게). CI 가 같은 소스를 xcrun metal 로 미리 검사한다.
//  Metal 을 못 쓰면 PointCloudView 가 SceneKit 점으로 대신 보여 준다.
//  (Stray Scanner 포크에 추가된 파일)
//

import MetalKit
import SceneKit
import SwiftUI
import UIKit
import simd

/// 셰이더 소스. CI(build-ipa.yml)가 아래 msl-begin·msl-end 표시 줄 사이를 잘라 xcrun metal 로 검사한다.
enum PointCloudShaders {
    static let source = """
    // kgeo-msl-begin
    #include <metal_stdlib>
    using namespace metal;

    struct PointVertex {
        packed_float3 position;
        uchar4 color;
    };

    struct PointUniforms {
        float4x4 viewProjection;
        float4x4 view;
        float pointSize;
        float projScale;
        float minDiameter;
        float maxDiameter;
    };

    struct PointOut {
        float4 position [[position]];
        float size [[point_size]];
        float3 color;
        float viewDepth;
    };

    struct PointTargets {
        float4 color [[color(0)]];
        float4 depth [[color(1)]];
    };

    vertex PointOut pointVertex(const device PointVertex *points [[buffer(0)]],
                                constant PointUniforms &u [[buffer(1)]],
                                uint vid [[vertex_id]]) {
        PointVertex p = points[vid];
        float4 world = float4(float3(p.position), 1.0);
        float4 eye = u.view * world;
        float depth = max(-eye.z, 0.0001f);
        PointOut out;
        out.position = u.viewProjection * world;
        out.size = clamp(u.pointSize * u.projScale / depth, u.minDiameter, u.maxDiameter);
        out.color = float3(p.color.xyz) / 255.0;
        out.viewDepth = depth;
        return out;
    }

    fragment PointTargets pointFragment(PointOut in [[stage_in]],
                                        float2 pointCoord [[point_coord]]) {
        float2 d = pointCoord - float2(0.5);
        if (dot(d, d) > 0.25) {
            discard_fragment();
        }
        PointTargets out;
        out.color = float4(in.color, 1.0);
        out.depth = float4(in.viewDepth, 0.0, 0.0, 1.0);
        return out;
    }

    struct QuadOut {
        float4 position [[position]];
    };

    vertex QuadOut edlVertex(uint vid [[vertex_id]]) {
        float2 corner = float2(float((vid << 1) & 2u), float(vid & 2u));
        QuadOut out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    struct EDLUniforms {
        float strength;
        float radius;
        float outline;
        int enabled;
    };

    constant float2 kNeighbours[8] = {
        float2(1.0, 0.0), float2(0.7071, 0.7071), float2(0.0, 1.0), float2(-0.7071, 0.7071),
        float2(-1.0, 0.0), float2(-0.7071, -0.7071), float2(0.0, -1.0), float2(0.7071, -0.7071)
    };

    fragment float4 edlFragment(QuadOut in [[stage_in]],
                                texture2d<float> colorTexture [[texture(0)]],
                                texture2d<float> depthTexture [[texture(1)]],
                                constant EDLUniforms &u [[buffer(0)]]) {
        int2 size = int2(int(colorTexture.get_width()), int(colorTexture.get_height()));
        int2 p = clamp(int2(in.position.xy), int2(0), size - 1);
        float4 color = colorTexture.read(uint2(p));
        if (u.enabled == 0) {
            return float4(color.rgb, 1.0);
        }
        float d = depthTexture.read(uint2(p)).r;
        float centre = d > 0.0f ? log2(d) : 0.0f;
        float sum = 0.0;
        int filled = 0;
        for (int i = 0; i < 8; i++) {
            int2 q = clamp(p + int2(round(kNeighbours[i] * u.radius)), int2(0), size - 1);
            float nd = depthTexture.read(uint2(q)).r;
            if (nd > 0.0) {
                filled += 1;
                sum += d > 0.0f ? max(0.0f, centre - log2(nd)) : 100.0f;
            }
        }
        if (d <= 0.0) {
            return filled > 0 ? float4(color.rgb * u.outline, 1.0) : float4(color.rgb, 1.0);
        }
        float shade = exp(-(sum / 8.0) * 300.0 * u.strength);
        return float4(color.rgb * shade, 1.0);
    }
    // kgeo-msl-end
    """
}

/// 색 점을 그리는 Metal 렌더러 + 턴테이블 카메라
final class PointCloudRenderer: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
    private struct PointUniforms {
        var viewProjection: simd_float4x4
        var view: simd_float4x4
        var pointSize: Float
        var projScale: Float
        var minDiameter: Float
        var maxDiameter: Float
    }

    private struct EDLUniforms {
        var strength: Float
        var radius: Float
        var outline: Float
        var enabled: Int32
    }

    /// 점 지름 = 복셀 × 1.3 (월드 크기), 화면 반지름 1~24 px
    static let pointScale: Float = 1.3
    static let minRadiusPx: Float = 1
    static let maxRadiusPx: Float = 24
    static let fieldOfView: Float = 50 * Float.pi / 180
    static let background: Double = 0.13
    static let maxPitch: Float = 1.45

    private static var cachedLibrary: MTLLibrary?
    /// Metal 준비 실패 이유 (SceneKit 으로 대신 보여 줄 때 화면에 적는다)
    private(set) static var lastError: String?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pointPipeline: MTLRenderPipelineState
    private let edlPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let pointCount: Int
    private let pointSize: Float
    private var colorTarget: MTLTexture?
    private var depthTarget: MTLTexture?
    private var depthBuffer: MTLTexture?
    private weak var view: MTKView?

    // 카메라: target 을 중심으로 yaw(월드 y 축)·pitch·distance
    private let sceneRadius: Float
    private var target: SIMD3<Float>
    private var yaw: Float
    private var pitch: Float
    private var distance: Float
    private let homeTarget: SIMD3<Float>
    private let homeYaw: Float
    private let homePitch: Float
    private let homeDistance: Float
    private var orbitStart: (yaw: Float, pitch: Float) = (0, 0)
    private var pinchStart: Float = 1
    private var panStart = SIMD3<Float>(0, 0, 0)

    var edlEnabled = true {
        didSet {
            if edlEnabled != oldValue {
                view?.setNeedsDisplay()
            }
        }
    }

    init?(cloud: PreviewPointCloud) {
        let count = cloud.points.positions.count
        guard count > 0, cloud.points.colors.count >= count * 3 else {
            PointCloudRenderer.lastError = "점이 없습니다"
            return nil
        }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            PointCloudRenderer.lastError = "Metal 장치를 열 수 없습니다"
            return nil
        }
        let pointPipeline: MTLRenderPipelineState
        let edlPipeline: MTLRenderPipelineState
        do {
            let library: MTLLibrary
            if let cached = PointCloudRenderer.cachedLibrary {
                library = cached
            } else {
                library = try device.makeLibrary(source: PointCloudShaders.source, options: nil)
                PointCloudRenderer.cachedLibrary = library
            }
            let pointDescriptor = MTLRenderPipelineDescriptor()
            pointDescriptor.vertexFunction = library.makeFunction(name: "pointVertex")
            pointDescriptor.fragmentFunction = library.makeFunction(name: "pointFragment")
            pointDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pointDescriptor.colorAttachments[1].pixelFormat = .r32Float
            pointDescriptor.depthAttachmentPixelFormat = .depth32Float
            pointPipeline = try device.makeRenderPipelineState(descriptor: pointDescriptor)
            let edlDescriptor = MTLRenderPipelineDescriptor()
            edlDescriptor.vertexFunction = library.makeFunction(name: "edlVertex")
            edlDescriptor.fragmentFunction = library.makeFunction(name: "edlFragment")
            edlDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            edlPipeline = try device.makeRenderPipelineState(descriptor: edlDescriptor)
        } catch {
            PointCloudRenderer.lastError = "셰이더 준비 실패: \(error.localizedDescription)"
            return nil
        }
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        let vertexStride = 16
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor),
              let buffer = device.makeBuffer(length: count * vertexStride, options: .storageModeShared) else {
            PointCloudRenderer.lastError = "점 버퍼를 만들 수 없습니다"
            return nil
        }
        // 점마다 16 바이트: float x, y, z + r, g, b, 255 (셰이더의 PointVertex)
        let raw = buffer.contents()
        cloud.points.positions.withUnsafeBufferPointer { positions in
            cloud.points.colors.withUnsafeBufferPointer { colors in
                for i in 0..<count {
                    let p = positions[i]
                    let o = i * vertexStride
                    raw.storeBytes(of: p.x, toByteOffset: o, as: Float.self)
                    raw.storeBytes(of: p.y, toByteOffset: o + 4, as: Float.self)
                    raw.storeBytes(of: p.z, toByteOffset: o + 8, as: Float.self)
                    raw.storeBytes(of: colors[i * 3], toByteOffset: o + 12, as: UInt8.self)
                    raw.storeBytes(of: colors[i * 3 + 1], toByteOffset: o + 13, as: UInt8.self)
                    raw.storeBytes(of: colors[i * 3 + 2], toByteOffset: o + 14, as: UInt8.self)
                    raw.storeBytes(of: UInt8(255), toByteOffset: o + 15, as: UInt8.self)
                }
            }
        }

        // 처음 시점: 녹화 시작 자리에서 중심을 본다. 그 자리가 중심과 거의 같으면 정면 반대쪽으로 물러나서, 없으면 위쪽 비스듬히
        let radius = max(cloud.radius, 0.05)
        var offset = SIMD3<Float>(0, radius * 0.8, radius * 2.6)
        if let eye = cloud.eye {
            let fromCenter = eye - cloud.center
            if simd_length(fromCenter) >= radius * 0.3 {
                offset = fromCenter
            } else if let forward = cloud.forward, simd_length(forward) > 0.1 {
                offset = -simd_normalize(forward) * radius * 1.2 + SIMD3<Float>(0, radius * 0.3, 0)
            }
        }
        let startDistance = max(simd_length(offset), 0.05)
        let startYaw = atan2f(offset.x, offset.z)
        let startPitch = min(max(asinf(max(-1, min(1, offset.y / startDistance))), -PointCloudRenderer.maxPitch),
                             PointCloudRenderer.maxPitch)

        self.device = device
        self.queue = queue
        self.pointPipeline = pointPipeline
        self.edlPipeline = edlPipeline
        self.depthState = depthState
        self.vertexBuffer = buffer
        self.pointCount = count
        self.pointSize = max(cloud.voxel, 0.001) * PointCloudRenderer.pointScale
        self.sceneRadius = radius
        self.target = cloud.center
        self.yaw = startYaw
        self.pitch = startPitch
        self.distance = startDistance
        self.homeTarget = cloud.center
        self.homeYaw = startYaw
        self.homePitch = startPitch
        self.homeDistance = startDistance
        super.init()
    }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        let gray = PointCloudRenderer.background
        view.clearColor = MTLClearColor(red: gray, green: gray, blue: gray, alpha: 1)
        view.backgroundColor = UIColor(white: CGFloat(gray), alpha: 1)
        view.delegate = self
        self.view = view

        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let reset = UITapGestureRecognizer(target: self, action: #selector(handleReset(_:)))
        reset.numberOfTapsRequired = 2
        let recognizers: [UIGestureRecognizer] = [orbit, pan, pinch, reset]
        for recognizer in recognizers {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
        view.setNeedsDisplay()
        return view
    }

    // MARK: - 손가락

    /// 같은 뷰의 두 손가락 이동과 확대는 함께 (바깥 스크롤과는 함께 하지 않는다)
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.view === otherGestureRecognizer.view
            && !(gestureRecognizer is UITapGestureRecognizer)
            && !(otherGestureRecognizer is UITapGestureRecognizer)
    }

    @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        if gesture.state == .began {
            orbitStart = (yaw, pitch)
        }
        let t = gesture.translation(in: view)
        yaw = orbitStart.yaw - Float(t.x) * 0.008
        pitch = min(max(orbitStart.pitch + Float(t.y) * 0.008, -PointCloudRenderer.maxPitch), PointCloudRenderer.maxPitch)
        view.setNeedsDisplay()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            pinchStart = distance
        }
        let scale = max(Float(gesture.scale), 0.01)
        distance = min(max(pinchStart / scale, sceneRadius * 0.02), sceneRadius * 20)
        gesture.view?.setNeedsDisplay()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        if gesture.state == .began {
            panStart = target
        }
        let t = gesture.translation(in: view)
        let height = max(Float(view.bounds.height), 1)
        let unitsPerPoint = 2 * distance * tanf(PointCloudRenderer.fieldOfView / 2) / height
        let basis = cameraBasis()
        target = panStart - basis.right * (Float(t.x) * unitsPerPoint) + basis.up * (Float(t.y) * unitsPerPoint)
        view.setNeedsDisplay()
    }

    @objc private func handleReset(_ gesture: UITapGestureRecognizer) {
        target = homeTarget
        yaw = homeYaw
        pitch = homePitch
        distance = homeDistance
        gesture.view?.setNeedsDisplay()
    }

    // MARK: - 카메라

    private func eyePosition() -> SIMD3<Float> {
        let cp = cosf(pitch)
        return target + SIMD3<Float>(cp * sinf(yaw), sinf(pitch), cp * cosf(yaw)) * distance
    }

    private func cameraBasis() -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let forward = simd_normalize(target - eyePosition())
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)
        return (right, up)
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
    }

    /// 오른손 좌표, 카메라는 -z 를 본다. Metal 클립 z 는 0~1
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tanf(fovY * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)))
    }

    // MARK: - 그리기

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    /// 1차 패스용 색·깊이 텍스처 (드로어블과 같은 크기)
    private func ensureTargets(width: Int, height: Int) -> Bool {
        if let color = colorTarget, color.width == width, color.height == height,
           depthTarget != nil, depthBuffer != nil {
            return true
        }
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                       height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .private
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width,
                                                                       height: height, mipmapped: false)
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private
        let bufferDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width,
                                                                        height: height, mipmapped: false)
        bufferDescriptor.usage = [.renderTarget]
        bufferDescriptor.storageMode = .memoryless
        colorTarget = device.makeTexture(descriptor: colorDescriptor)
        depthTarget = device.makeTexture(descriptor: depthDescriptor)
        depthBuffer = device.makeTexture(descriptor: bufferDescriptor)
        return colorTarget != nil && depthTarget != nil && depthBuffer != nil
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0, ensureTargets(width: width, height: height),
              let colorTarget = colorTarget, let depthTarget = depthTarget, let depthBuffer = depthBuffer,
              let screenPass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        let eye = eyePosition()
        let viewMatrix = PointCloudRenderer.lookAt(eye: eye, target: target)
        let near = max(0.003, distance * 0.01)
        let far = distance + sceneRadius * 4 + 1
        let projection = PointCloudRenderer.perspective(fovY: PointCloudRenderer.fieldOfView,
                                                        aspect: Float(width) / Float(height), near: near, far: far)
        let pixelScale = max(1, Float(view.contentScaleFactor) / 2)
        var uniforms = PointUniforms(viewProjection: projection * viewMatrix, view: viewMatrix,
                                     pointSize: pointSize,
                                     projScale: Float(height) / (2 * tanf(PointCloudRenderer.fieldOfView / 2)),
                                     minDiameter: 2 * PointCloudRenderer.minRadiusPx * pixelScale,
                                     maxDiameter: 2 * PointCloudRenderer.maxRadiusPx * pixelScale)

        let gray = PointCloudRenderer.background
        let pointPass = MTLRenderPassDescriptor()
        pointPass.colorAttachments[0].texture = colorTarget
        pointPass.colorAttachments[0].loadAction = .clear
        pointPass.colorAttachments[0].storeAction = .store
        pointPass.colorAttachments[0].clearColor = MTLClearColor(red: gray, green: gray, blue: gray, alpha: 1)
        pointPass.colorAttachments[1].texture = depthTarget
        pointPass.colorAttachments[1].loadAction = .clear
        pointPass.colorAttachments[1].storeAction = .store
        pointPass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pointPass.depthAttachment.texture = depthBuffer
        pointPass.depthAttachment.loadAction = .clear
        pointPass.depthAttachment.storeAction = .dontCare
        pointPass.depthAttachment.clearDepth = 1
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pointPass) {
            encoder.setRenderPipelineState(pointPipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<PointUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
            encoder.endEncoding()
        }

        var edl = EDLUniforms(strength: 0.4, radius: max(1.4, Float(view.contentScaleFactor) * 0.7),
                              outline: 0.35, enabled: edlEnabled ? 1 : 0)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: screenPass) {
            encoder.setRenderPipelineState(edlPipeline)
            encoder.setFragmentTexture(colorTarget, index: 0)
            encoder.setFragmentTexture(depthTarget, index: 1)
            encoder.setFragmentBytes(&edl, length: MemoryLayout<EDLUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// 색 점 미리보기 뷰: Metal 렌더러, 안 되면 SceneKit 점 (EDL·둥근 점 없이 월드 크기 점만) + 이유 한 줄
struct PointCloudView: UIViewRepresentable {
    let cloud: PreviewPointCloud
    let edl: Bool

    final class Coordinator {
        var renderer: PointCloudRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        if let renderer = PointCloudRenderer(cloud: cloud) {
            renderer.edlEnabled = edl
            context.coordinator.renderer = renderer
            return renderer.makeView()
        }
        let result = PreviewSceneLoader.makePointScene(cloud.points, eye: cloud.eye, voxel: cloud.voxel)
        let container = UIView()
        let sceneView = PreviewSceneView.makeView(result)
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sceneView)
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 11)
        label.textColor = UIColor(white: 0.85, alpha: 1)
        label.numberOfLines = 2
        label.text = "기본 점 표시 (음영 없음): " + (PointCloudRenderer.lastError ?? "Metal 을 쓸 수 없습니다")
        container.addSubview(label)
        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: container.topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.renderer?.edlEnabled = edl
    }
}
