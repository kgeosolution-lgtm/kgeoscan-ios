//
//  ExposureController.swift
//  kgeoScan
//
//  녹화 중 모션블러를 줄이기 위한 노출 설정. (Stray Scanner 포크에 추가된 파일)
//  iOS 16 의 ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera 로 ARKit 이 쓰는
//  카메라 장치를 받아 셔터를 짧게(1/250 s) 고정하고, 밝기는 ISO 로 맞춘다 (0.5 초마다 노출 목표 오차를 보고 보정).
//  녹화 데이터 형식에는 영향이 없다 — 영상이 덜 번지고 노이즈가 조금 늘 뿐이다.
//

import AVFoundation
import ARKit

final class ExposureController {
    enum Mode: String, CaseIterable, Identifiable {
        case auto = "auto"
        case fastShutter = "fast"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "자동"
            case .fastShutter: return "빠른 셔터 1/250"
            }
        }
    }

    static let modeKey = "kgeo.exposure"

    static var currentMode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .auto
    }

    private var timer: Timer?
    private let targetDuration = CMTime(value: 1, timescale: 250)

    /// 세션이 돌고 있을 때 부른다 (session.run 뒤 0.5 초쯤). 모드가 auto 면 자동 노출로 되돌린다.
    func apply() {
        stop()
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            print("ExposureController: 카메라 장치를 가져올 수 없습니다 (세션이 아직 안 돌거나 iOS 16 미만)")
            return
        }
        switch ExposureController.currentMode {
        case .auto:
            configure(device) { d in
                if d.isExposureModeSupported(.continuousAutoExposure) {
                    d.exposureMode = .continuousAutoExposure
                }
            }
        case .fastShutter:
            guard device.isExposureModeSupported(.custom) else { return }
            adjust(device: device, initial: true)
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.adjust(device: device, initial: false)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func adjust(device: AVCaptureDevice, initial: Bool) {
        let format = device.activeFormat
        let duration = CMTimeMaximum(targetDuration, format.minExposureDuration)
        var iso: Float
        if initial {
            // 지금 자동 노출과 같은 밝기가 되도록 ISO 를 환산: ISO' = ISO × (현재 셔터 / 목표 셔터)
            let current = CMTimeGetSeconds(device.exposureDuration)
            let target = CMTimeGetSeconds(duration)
            iso = device.iso * Float(max(current, 0.0001) / max(target, 0.0001))
        } else {
            // 목표 밝기와의 차이(EV)만큼 ISO 보정
            let offset = device.exposureTargetOffset
            if abs(offset) < 0.25 { return }
            iso = device.iso * powf(2, -offset)
        }
        iso = min(max(iso, format.minISO), format.maxISO)
        configure(device) { d in
            d.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
        }
    }

    private func configure(_ device: AVCaptureDevice, _ block: (AVCaptureDevice) -> Void) {
        do {
            try device.lockForConfiguration()
            block(device)
            device.unlockForConfiguration()
        } catch {
            print("ExposureController: lockForConfiguration 실패 \(error.localizedDescription)")
        }
    }
}
