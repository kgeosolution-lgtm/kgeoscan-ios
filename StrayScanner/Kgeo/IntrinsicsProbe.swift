//
//  IntrinsicsProbe.swift
//  kgeoScan
//
//  ARKit 광각 카메라의 실제 내부 파라미터(fx, fy, cx, cy @ 영상 해상도)를 읽어 기기별로 저장한다.
//  Object Capture 사진(HEIC)에는 보정값이 없을 때가 있어, 같은 카메라·같은 4:3 전체 화각인 ARKit 값을
//  사진 해상도로 환산해 poses.json 에 쓴다 (EXIF 35mm 환산값은 반올림 때문에 약 4% 짧게 나왔다 — 2026-10-28 SfM 검증).
//  (Stray Scanner 포크에 추가된 파일)
//

import ARKit

struct CameraIntrinsics: Codable, Sendable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var width: Double
    var height: Double

    init(fx: Double, fy: Double, cx: Double, cy: Double, width: Double, height: Double) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    init(frame: ARFrame) {
        let k = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        self.init(fx: Double(k.columns.0.x), fy: Double(k.columns.1.y),
                  cx: Double(k.columns.2.x), cy: Double(k.columns.2.y),
                  width: Double(resolution.width), height: Double(resolution.height))
    }

    var dictionary: [String: Any] {
        ["fx": fx, "fy": fy, "cx": cx, "cy": cy, "width": width, "height": height]
    }

    private static var storageKey: String { "kgeo.arkitIntrinsics." + ScanMeta.deviceModel() }

    /// 이 기기에서 전에 읽어 둔 값
    static func cached() -> CameraIntrinsics? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(CameraIntrinsics.self, from: data)
    }

    static func store(_ value: CameraIntrinsics) {
        guard value.fx > 0, value.width > 0, value.height > 0,
              let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

/// ARSession 을 잠깐 돌려 첫 프레임의 내부 파라미터를 읽는다 (Object Capture 시작 전, 저장값이 없을 때만)
final class IntrinsicsProbe: NSObject, ARSessionDelegate {
    private let session = ARSession()
    private var continuation: CheckedContinuation<CameraIntrinsics?, Never>?

    static func measure(timeout: TimeInterval = 2.5) async -> CameraIntrinsics? {
        guard ARWorldTrackingConfiguration.isSupported else { return nil }
        let probe = IntrinsicsProbe()
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                probe.begin(continuation: continuation, timeout: timeout)
            }
        }
    }

    private func begin(continuation: CheckedContinuation<CameraIntrinsics?, Never>, timeout: TimeInterval) {
        self.continuation = continuation
        session.delegate = self
        session.run(ARWorldTrackingConfiguration())
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            self.finish(nil)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        finish(CameraIntrinsics(frame: frame))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        finish(nil)
    }

    private func finish(_ result: CameraIntrinsics?) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        session.pause()
        session.delegate = nil
        continuation.resume(returning: result)
    }
}
