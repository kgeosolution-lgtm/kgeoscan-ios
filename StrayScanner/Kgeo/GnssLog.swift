//
//  GnssLog.swift
//  kgeoScan
//
//  굴착 기록 모드: 녹화 중 저장되는 프레임마다 그 순간의 Core Location 위치를 gnss.csv 로 남긴다
//  (DatasetEncoder 의 인코더 큐에서 odometry.csv 와 같은 프레임 번호로 쓴다).
//  MFi GNSS 수신기(Emlid Reach RX2, Bad Elf Flex 등)를 연결하면 iOS 가 위치를 그 수신기 값으로 바꾸므로 같은 코드로
//  RTK 위치가 남는다 (CLLocation.sourceInformation.isProducedByAccessory → source=accessory). 장비가 없으면 폰 GPS 값.
//  frame,timestamp,lat,lon,alt,ell_alt,h_acc,v_acc,loc_unix,age_s,source  (모르는 값은 빈 칸)
//  (Stray Scanner 포크에 추가된 파일)
//

import CoreLocation
import Foundation

/// 한 프레임 시점의 위치 (gnss.csv 한 행)
struct GnssSample {
    var lat: Double?
    var lon: Double?
    /// 평균해수면 고도 (CLLocation.altitude), 타원체고 (ellipsoidalAltitude) — 수직 정확도를 모르면 nil
    var alt: Double?
    var ellipsoidalAlt: Double?
    var hAcc: Double?
    var vAcc: Double?
    /// 위치가 측정된 시각 (Unix 초)과 그 뒤 지난 시간 (초)
    var locUnix: Double?
    var age: Double?
    /// accessory (외부 수신기) | device (폰) | simulated | none (위치 없음)
    var source: String

    init(location: CLLocation?, now: Date = Date()) {
        guard let loc = location, loc.horizontalAccuracy >= 0 else {
            source = "none"
            return
        }
        lat = loc.coordinate.latitude
        lon = loc.coordinate.longitude
        hAcc = loc.horizontalAccuracy
        if loc.verticalAccuracy >= 0 {
            alt = loc.altitude
            ellipsoidalAlt = loc.ellipsoidalAltitude
            vAcc = loc.verticalAccuracy
        }
        locUnix = loc.timestamp.timeIntervalSince1970
        age = now.timeIntervalSince(loc.timestamp)
        if let info = loc.sourceInformation {
            source = info.isProducedByAccessory ? "accessory" : (info.isSimulatedBySoftware ? "simulated" : "device")
        } else {
            source = "device"
        }
    }

    /// 수평 정확도 5 cm 이하 (CaptureTuning.rtkHorizontalAccuracy)
    var isRTK: Bool {
        guard let accuracy = hAcc else { return false }
        return accuracy <= CaptureTuning.rtkHorizontalAccuracy
    }
}

/// 녹화 폴더의 gnss.csv. DatasetEncoder 의 인코더 큐에서 부른다
final class GnssWriter {
    static let fileName = "gnss.csv"
    static let header = "frame,timestamp,lat,lon,alt,ell_alt,h_acc,v_acc,loc_unix,age_s,source\n"

    private var handle: FileHandle?

    init(directory: URL) {
        let url = directory.appendingPathComponent(GnssWriter.fileName, isDirectory: false)
        do {
            try "".write(to: url, atomically: true, encoding: .utf8)
            let handle = try FileHandle(forWritingTo: url)
            handle.write(Data(GnssWriter.header.utf8))
            self.handle = handle
        } catch {
            print("gnss.csv 를 만들 수 없습니다: \(error.localizedDescription)")
            handle = nil
        }
    }

    func add(_ sample: GnssSample, frame: Int, timestamp: TimeInterval) {
        guard let handle = handle else { return }
        func cell(_ value: Double?, _ format: String) -> String {
            guard let value = value, value.isFinite else { return "" }
            return String(format: format, value)
        }
        let cells = [
            cell(sample.lat, "%.9f"), cell(sample.lon, "%.9f"), cell(sample.alt, "%.3f"),
            cell(sample.ellipsoidalAlt, "%.3f"), cell(sample.hAcc, "%.3f"), cell(sample.vAcc, "%.3f"),
            cell(sample.locUnix, "%.3f"), cell(sample.age, "%.3f"),
        ]
        let line = "\(frame),\(timestamp)," + cells.joined(separator: ",") + "," + sample.source + "\n"
        handle.write(Data(line.utf8))
    }

    func done() {
        try? handle?.close()
        handle = nil
    }
}
