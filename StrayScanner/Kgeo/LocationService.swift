//
//  LocationService.swift
//  kgeoScan
//
//  녹화 시작 지점의 위도·경도·고도와 나침반 방위를 잡아 두는 서비스. (Stray Scanner 포크에 추가된 파일)
//

import Foundation
import CoreLocation
import Combine

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLHeading?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    private let manager = CLLocationManager()
    private var wantsUpdates = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 1
        manager.headingOrientation = .portrait
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// 권한을 요청하고 위치·방위 갱신을 시작한다. 여러 번 불러도 된다.
    func start() {
        wantsUpdates = true
        switch authorization {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            break
        }
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    private func beginUpdates() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    /// 지금 알고 있는 위치·방위를 meta.json 용 구조체로 복사한다. 위치가 없으면 nil.
    func snapshot() -> GeoFix? {
        guard let loc = location else { return nil }
        let hasVertical = loc.verticalAccuracy >= 0
        var fix = GeoFix(lat: loc.coordinate.latitude,
                         lon: loc.coordinate.longitude,
                         alt: hasVertical ? loc.altitude : nil,
                         ellipsoidalAlt: hasVertical ? loc.ellipsoidalAltitude : nil,
                         hAcc: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
                         vAcc: hasVertical ? loc.verticalAccuracy : nil,
                         fixTime: loc.timestamp)
        if let h = heading {
            fix.trueHeading = h.trueHeading >= 0 ? h.trueHeading : nil
            fix.magneticHeading = h.magneticHeading >= 0 ? h.magneticHeading : nil
            fix.headingAccuracy = h.headingAccuracy >= 0 ? h.headingAccuracy : nil
            fix.headingTime = h.timestamp
        }
        return fix
    }

    /// 녹화 화면 상단에 보여 줄 한 줄 요약
    var shortStatus: String {
        if isDenied { return "위치 권한 꺼짐" }
        var parts: [String] = []
        if let loc = location, loc.horizontalAccuracy >= 0 {
            parts.append(String(format: "GPS ±%.0fm", loc.horizontalAccuracy))
        } else {
            parts.append("GPS 대기 중")
        }
        if let h = heading {
            if h.trueHeading >= 0 {
                parts.append(String(format: "방위 %.0f°", h.trueHeading))
            } else if h.magneticHeading >= 0 {
                parts.append(String(format: "자북 %.0f°", h.magneticHeading))
            }
        } else {
            parts.append("나침반 대기 중")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            self.authorization = status
            if self.wantsUpdates && self.isAuthorized {
                self.beginUpdates()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        DispatchQueue.main.async {
            self.location = last
            self.lastError = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        DispatchQueue.main.async {
            self.heading = newHeading
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.lastError = error.localizedDescription
        }
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}
