//
//  VideoFormats.swift
//  kgeoScan
//
//  ARKit 영상 형식 목록·진단, 그리고 면 촬영(무음 정지 사진)에 쓸 형식 고르기.
//  무음 정지 사진 = 높은 해상도 영상 형식에서 ARFrame.capturedImage 를 떼어 저장 (captureHighResolutionFrame 은
//  한국판 아이폰에서 셔터음이 강제된다). 형식마다 sceneDepth 가 오는지, 깊이 맵과 RGB 비율이 같은지는 켜 봐야 알 수 있어
//  결과를 기기별로 저장해 둔다. (Stray Scanner 포크에 추가된 파일)
//

import SwiftUI
import ARKit
import AVFoundation
import UIKit

/// 한 영상 형식을 실제로 켜 본 결과
struct FormatProbeResult: Codable, Hashable {
    var key: String
    var width: Int
    var height: Int
    var fps: Int
    var device: String
    var recommended4K: Bool
    var recommendedStills: Bool
    /// 실제로 켜 봤는지
    var tested: Bool
    var sceneDepth: Bool
    var imageWidth: Int
    var imageHeight: Int
    var depthWidth: Int
    var depthHeight: Int
    /// RGB 와 깊이 맵의 가로세로 비율이 같은지 (같으면 화각이 같다고 본다)
    var aspectMatch: Bool
    var fx: Double
    var testedAt: Date?

    /// 면 촬영 무음 모드에 쓸 수 있는지: 깊이가 오고 RGB·깊이 비율이 같다
    var usableForArea: Bool { tested && sceneDepth && aspectMatch }

    /// 수평 화각 (도)
    var horizontalFOV: Double {
        guard fx > 0, imageWidth > 0 else { return 0 }
        return 2 * atan(Double(imageWidth) / (2 * fx)) * 180 / Double.pi
    }

    var title: String {
        var flags: [String] = []
        if recommended4K { flags.append("4K권장") }
        if recommendedStills { flags.append("정지사진권장") }
        return "\(width)×\(height) \(fps)fps \(device)" + (flags.isEmpty ? "" : " [" + flags.joined(separator: ",") + "]")
    }

    var detail: String {
        guard tested else { return "아직 시험 안 함" }
        if imageWidth == 0 { return "프레임이 오지 않음 (이 설정에서 못 씀)" }
        let depthText = sceneDepth ? "깊이 \(depthWidth)×\(depthHeight)" : "깊이 없음"
        let aspectText = sceneDepth ? (aspectMatch ? "비율 일치" : "비율 다름") : "-"
        return "\(depthText) · \(aspectText) · 영상 \(imageWidth)×\(imageHeight) · 수평화각 \(String(format: "%.1f", horizontalFOV))°"
            + (usableForArea ? " · 무음 면 촬영 가능" : "")
    }

    var tableLine: String {
        let depthText = tested ? (sceneDepth ? "\(depthWidth)x\(depthHeight)" : "없음") : "미시험"
        let aspectText = tested && sceneDepth ? (aspectMatch ? "일치" : "다름") : "-"
        return "\(width)x\(height) | \(fps) | \(device) | \(recommended4K ? "예" : "") | \(recommendedStills ? "예" : "") | \(depthText) | \(aspectText) | \(String(format: "%.1f", horizontalFOV)) | \(usableForArea ? "가능" : "")"
    }
}

enum FormatCatalog {
    /// "3840x2880@30 wide"
    static func key(_ format: ARConfiguration.VideoFormat) -> String {
        "\(shortKey(format)) \(deviceName(format.captureDeviceType))"
    }

    /// "3840x2880@30"
    static func shortKey(_ format: ARConfiguration.VideoFormat) -> String {
        let r = format.imageResolution
        return "\(Int(r.width))x\(Int(r.height))@\(format.framesPerSecond)"
    }

    static func label(_ format: ARConfiguration.VideoFormat) -> String {
        let r = format.imageResolution
        return "\(Int(r.width))×\(Int(r.height)) \(format.framesPerSecond)fps"
    }

    static func deviceName(_ type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInWideAngleCamera: return "wide"
        case .builtInUltraWideCamera: return "ultrawide"
        case .builtInTelephotoCamera: return "tele"
        default: return type.rawValue
        }
    }

    static func isFourThree(_ format: ARConfiguration.VideoFormat) -> Bool {
        let r = format.imageResolution
        guard r.height > 0 else { return false }
        return abs(Double(r.width / r.height) - 4.0 / 3.0) < 0.02
    }

    static func isRecommended4K(_ format: ARConfiguration.VideoFormat) -> Bool {
        guard let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution else { return false }
        return key(fourK) == key(format)
    }

    private static var storageKey: String { "kgeo.videoFormatTests." + ScanMeta.deviceModel() }

    /// 저장된 시험 결과 (형식 key → 결과)
    static func results() -> [String: FormatProbeResult] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: FormatProbeResult].self, from: data) else { return [:] }
        return decoded
    }

    static func result(for format: ARConfiguration.VideoFormat) -> FormatProbeResult? {
        results()[key(format)]
    }

    static func store(_ result: FormatProbeResult) {
        var all = results()
        all[result.key] = result
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// 형식 정보 + (있으면) 켜 본 프레임의 실제 값
    static func makeResult(_ format: ARConfiguration.VideoFormat, frame: ARFrame?) -> FormatProbeResult {
        let r = format.imageResolution
        var result = FormatProbeResult(key: key(format), width: Int(r.width), height: Int(r.height),
                                       fps: format.framesPerSecond, device: deviceName(format.captureDeviceType),
                                       recommended4K: isRecommended4K(format),
                                       recommendedStills: format.isRecommendedForHighResolutionFrameCapturing,
                                       tested: false, sceneDepth: false, imageWidth: 0, imageHeight: 0,
                                       depthWidth: 0, depthHeight: 0, aspectMatch: false, fx: 0, testedAt: nil)
        if let frame = frame {
            let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
            let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)
            result.imageWidth = imageWidth
            result.imageHeight = imageHeight
            result.fx = Double(frame.camera.intrinsics.columns.0.x)
            result.testedAt = Date()
            if let depth = frame.sceneDepth?.depthMap {
                let depthWidth = CVPixelBufferGetWidth(depth)
                let depthHeight = CVPixelBufferGetHeight(depth)
                result.sceneDepth = true
                result.depthWidth = depthWidth
                result.depthHeight = depthHeight
                if imageHeight > 0, depthHeight > 0 {
                    let imageAspect = Double(imageWidth) / Double(imageHeight)
                    let depthAspect = Double(depthWidth) / Double(depthHeight)
                    result.aspectMatch = abs(imageAspect - depthAspect) / imageAspect < 0.02
                }
            }
        }
        return result
    }

    /// 면 촬영 무음 후보 (우선순위 순): 1) 4:3 · 가로 3000 px 이상 (광각, 30 fps 우선)  2) 16:9 4K 권장 형식
    static func silentCandidates() -> [ARConfiguration.VideoFormat] {
        let fourThree = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter { isFourThree($0) && $0.imageResolution.width >= 3000 }
            .sorted { a, b in
                let aWide = a.captureDeviceType == .builtInWideAngleCamera ? 0 : 1
                let bWide = b.captureDeviceType == .builtInWideAngleCamera ? 0 : 1
                if aWide != bWide { return aWide < bWide }
                let a30 = a.framesPerSecond == 30 ? 0 : 1
                let b30 = b.framesPerSecond == 30 ? 0 : 1
                if a30 != b30 { return a30 < b30 }
                return a.imageResolution.width > b.imageResolution.width
            }
        var list = fourThree
        if let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution,
           !list.contains(where: { key($0) == key(fourK) }) {
            list.append(fourK)
        }
        return list
    }

    /// 설정 화면에 보여 줄 무음 면 촬영 상태
    static func silentStatus() -> String {
        let candidates = silentCandidates()
        if candidates.isEmpty {
            return "이 기기에는 4:3 고해상도(가로 3000 px 이상)나 4K 영상 형식이 없어 셔터음 방식(고해상도 사진)으로 찍습니다."
        }
        let saved = results()
        if let usable = candidates.first(where: { saved[key($0)]?.usableForArea == true }) {
            return "무음 면 촬영 형식: \(label(usable)) (깊이·비율 확인됨). 영상(rgb.mp4)은 가로 1920 으로 줄여 녹화합니다."
        }
        let untested = candidates.filter { saved[key($0)]?.tested != true }
        if !untested.isEmpty {
            return "무음 후보: " + untested.map { label($0) }.joined(separator: ", ")
                + " — 첫 면 촬영 때(또는 아래 진단에서) 깊이가 오는지 확인합니다. 안 되면 셔터음 방식으로 찍습니다."
        }
        return "후보 형식에서 깊이가 오지 않거나 깊이·RGB 비율이 달라 셔터음 방식(고해상도 사진)으로 찍습니다."
    }
}

// MARK: - 진단 화면

/// 모든 영상 형식을 하나씩 켜서 sceneDepth·비율을 확인한다
final class FormatDiagnostics: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var rows: [FormatProbeResult] = []
    @Published private(set) var running = false
    @Published private(set) var current: String?

    private let session = ARSession()
    private var pending: [ARConfiguration.VideoFormat] = []
    private var testing: ARConfiguration.VideoFormat?
    private var started = Date()

    func loadRows() {
        let saved = FormatCatalog.results()
        rows = ARWorldTrackingConfiguration.supportedVideoFormats.map { format in
            saved[FormatCatalog.key(format)] ?? FormatCatalog.makeResult(format, frame: nil)
        }
    }

    func runAll() {
        guard !running else { return }
        running = true
        pending = ARWorldTrackingConfiguration.supportedVideoFormats
        session.delegate = self
        next()
    }

    func stop() {
        pending.removeAll()
        testing = nil
        session.pause()
        running = false
        current = nil
    }

    private func next() {
        guard !pending.isEmpty else {
            stop()
            return
        }
        let format = pending.removeFirst()
        testing = format
        current = FormatCatalog.label(format)
        let token = Date()
        started = token
        let configuration = ARWorldTrackingConfiguration()
        configuration.videoFormat = format
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        // 프레임이 아예 오지 않는 형식
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self, self.testing != nil, self.started == token else { return }
            self.record(nil)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let format = testing else { return }
        let width = CVPixelBufferGetWidth(frame.capturedImage)
        let height = CVPixelBufferGetHeight(frame.capturedImage)
        let elapsed = Date().timeIntervalSince(started)
        // 앞 형식의 프레임은 무시
        if width != Int(format.imageResolution.width) || height != Int(format.imageResolution.height) {
            if elapsed < 3 { return }
        }
        // 깊이는 첫 몇 프레임 뒤에 오기도 한다
        if frame.sceneDepth == nil && elapsed < 2.5 { return }
        record(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        record(nil)
    }

    private func record(_ frame: ARFrame?) {
        guard let format = testing else { return }
        testing = nil
        var result = FormatCatalog.makeResult(format, frame: frame)
        result.tested = true
        FormatCatalog.store(result)
        if let index = rows.firstIndex(where: { $0.key == result.key }) {
            rows[index] = result
        } else {
            rows.append(result)
        }
        next()
    }

    /// 보고용 표 (복사)
    var reportText: String {
        var lines = ["kgeoScan 카메라 형식 진단 — \(ScanMeta.deviceModel()) iOS \(UIDevice.current.systemVersion)", ""]
        lines.append("recommendedVideoFormatFor4KResolution: "
                     + (ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution.map { FormatCatalog.key($0) } ?? "없음"))
        lines.append("recommendedVideoFormatForHighResolutionFrameCapturing: "
                     + (ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing.map { FormatCatalog.key($0) } ?? "없음"))
        lines.append("기본 형식: " + FormatCatalog.key(ARWorldTrackingConfiguration().videoFormat))
        lines.append("")
        lines.append("해상도 | fps | 카메라 | 4K권장 | 정지사진권장 | 깊이 | 비율 | 수평화각 | 무음면촬영")
        lines.append(contentsOf: rows.map { $0.tableLine })
        lines.append("")
        lines.append(FormatCatalog.silentStatus())
        return lines.joined(separator: "\n")
    }
}

struct FormatDiagnosticsView: View {
    @StateObject private var diagnostics = FormatDiagnostics()

    var body: some View {
        List {
            Section {
                Text("이 기기(\(ScanMeta.deviceModel()))의 ARKit 영상 형식입니다. '깊이 시험' 을 누르면 형식마다 2~3초씩 카메라를 켜서 LiDAR 깊이(sceneDepth)가 오는지, 깊이 맵과 RGB 의 가로세로 비율이 같은지 확인합니다. 면 촬영 무음 모드는 여기서 '무음 면 촬영 가능' 으로 나온 형식을 씁니다.")
                    .font(.caption)
                LabeledContent("4K 권장", value: ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution
                    .map { FormatCatalog.label($0) } ?? "없음")
                LabeledContent("정지사진 권장", value: ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing
                    .map { FormatCatalog.label($0) } ?? "없음")
                LabeledContent("기본", value: FormatCatalog.label(ARWorldTrackingConfiguration().videoFormat))
            }
            Section("형식") {
                ForEach(diagnostics.rows, id: \.key) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(.system(.subheadline, design: .monospaced))
                        Text(row.detail)
                            .font(.caption)
                            .foregroundColor(row.usableForArea ? .green : .secondary)
                    }
                }
            }
            Section {
                Button {
                    diagnostics.runAll()
                } label: {
                    if diagnostics.running {
                        Label("시험 중… \(diagnostics.current ?? "")", systemImage: "hourglass")
                    } else {
                        Label("깊이 시험 (모든 형식)", systemImage: "camera.metering.matrix")
                    }
                }
                .disabled(diagnostics.running)
                Button {
                    UIPasteboard.general.string = diagnostics.reportText
                } label: {
                    Label("결과 표 복사", systemImage: "doc.on.doc")
                }
                Text(FormatCatalog.silentStatus())
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("카메라 형식 진단")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            diagnostics.loadRows()
        }
        .onDisappear {
            diagnostics.stop()
        }
    }
}
