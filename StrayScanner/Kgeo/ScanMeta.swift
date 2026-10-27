//
//  ScanMeta.swift
//  kgeoScan
//
//  녹화 폴더에 함께 저장하는 meta.json 모델. (Stray Scanner 포크에 추가된 파일)
//  키는 snake_case, 날짜는 ISO 8601 로 기록한다 — 서버(Python)가 그대로 읽을 수 있게.
//

import Foundation
import UIKit

/// 스캔 모드. 지금은 라벨만 저장한다 (서버 처리 분기는 다음 단계).
enum ScanMode: String, Codable, CaseIterable, Identifiable {
    case home
    case survey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "홈스캔"
        case .survey: return "현장조사"
        }
    }
}

/// 녹화 시작 순간의 위치·방위 스냅샷 (CoreLocation)
struct GeoFix: Codable, Hashable {
    var lat: Double
    var lon: Double
    /// CLLocation.altitude (m). 정확도를 알 수 없으면 nil
    var alt: Double?
    var ellipsoidalAlt: Double?
    var hAcc: Double?
    var vAcc: Double?
    var fixTime: Date
    /// 진북 기준 방위 (도, 시계 방향). 위치 서비스가 꺼져 있으면 nil
    var trueHeading: Double?
    var magneticHeading: Double?
    var headingAccuracy: Double?
    var headingTime: Date?

    /// 서버 heading 필드로 보낼 값: 진북 → 자북 → 없음
    var headingForUpload: Double? { trueHeading ?? magneticHeading }
}

/// 서버 업로드 결과 (job_id 와 마지막으로 확인한 상태)
struct UploadRecord: Codable, Hashable {
    var server: String
    var jobId: String
    var uploadedAt: Date
    var status: String?
    var step: Int?
    var stepName: String?
    var message: String?
    var sceneItemId: String?
    var glbUrl: String?
    var thumbUrl: String?
    var resultUrl: String?
}

/// 전송 시도 1회의 기록 (원인 추적용). meta.json 의 last_attempt
struct UploadAttempt: Codable, Hashable {
    var startedAt: Date
    var clientId: String
    /// foreground | background
    var transport: String
    var bodyBytes: Int64
    var finishedAt: Date?
    var httpStatus: Int?
    /// 보낸 바이트가 줄어든(처음부터 다시 보낸) 횟수
    var restarts: Int?
    var jobId: String?
    var duplicate: Bool?
    var error: String?
}

struct ScanMeta: Codable, Hashable {
    static let fileName = "meta.json"

    var app = "kgeoScan"
    var appVersion = KgeoDefaults.appVersion
    /// 녹화 데이터 형식. Stray Scanner 규약 그대로 (docs/format.md)
    var format = "stray"
    var title: String
    var note: String
    var mode: ScanMode
    var serverBase: String
    var createdAt: Date?
    var durationSeconds: Double?
    var fpsDivider: Int?
    var savedFrames: Int?
    var device: String?
    var systemVersion: String?
    /// ARKit 월드 정렬. gravity = y 위, -z 는 녹화 시작 시 카메라 정면
    var arWorldAlignment = "gravity"
    /// 녹화 시작 시 트래킹을 리셋해 월드 원점을 녹화 시작 지점으로 맞췄는지
    var trackingResetAtRecordStart = true
    var fix: GeoFix?
    var upload: UploadRecord?
    /// 이 녹화의 업로드 식별자. 앱이 한 번 만들어 재시도해도 같은 값을 upload 필드 client_id 로 보낸다
    var clientId: String?
    var attemptCount: Int?
    var lastAttempt: UploadAttempt?
    /// 업로드 화면 로그의 마지막 부분 (전체는 녹화 폴더의 upload.log)
    var uploadLog: [String]?

    init(title: String, note: String, mode: ScanMode, serverBase: String) {
        self.title = title
        self.note = note
        self.mode = mode
        self.serverBase = serverBase
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func load(from directory: URL) -> ScanMeta? {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else { return nil }
        return try? decoder.decode(ScanMeta.self, from: data)
    }

    func save(to directory: URL) throws {
        let data = try ScanMeta.encoder.encode(self)
        try data.write(to: ScanMeta.fileURL(in: directory), options: .atomic)
    }

    /// 기기 모델 식별자 (예: iPhone16,1)
    static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let size = MemoryLayout.size(ofValue: systemInfo.machine)
        return withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }
    }
}
