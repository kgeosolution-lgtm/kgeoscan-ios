//
//  SiteClient.swift
//  kgeoScan
//
//  관리 대상(장소) API — 서버 {base}/sites.py (3dscan_upgrade/docs/hazards_contract.md 4절).
//  같은 벽·구역을 날짜별로 다시 찍어 위험요소 변화를 비교하려고 스캔마다 장소(site_id)를 붙인다.
//  - 근처 장소: GET sites.py?lat=&lon=&radius_m=300 → {"sites":[{site_id, name, distance_m, scans, last_scan_at,
//    last_job_id, last_thumb_url, marker_ids, ...}]}
//  - 새 장소: POST sites.py (multipart/form-data: name, lat, lon, note) → {"site_id", "name"}.
//    서버가 400/415 로 받지 않으면 한 번만 application/x-www-form-urlencoded 로 다시 보낸다.
//  sites.py 가 아직 없거나(404) 오프라인이어도 앱은 막히지 않는다: 이름만 저장해 두고 업로드 직전에 만든다.
//  (Stray Scanner 포크에 추가된 파일)
//

import Foundation

/// 근처 장소 목록의 한 줄
struct SiteSummary: Identifiable, Hashable {
    let siteId: String
    let name: String
    let distanceM: Double?
    let scans: Int?
    let lastScanAt: String?
    let lastJobId: String?
    let lastThumbUrl: String?
    let markerIds: [Int]

    var id: String { siteId }

    /// "2026-11-09" (ISO 시각 앞 10자)
    var lastScanDay: String? {
        guard let text = lastScanAt, text.count >= 10 else { return lastScanAt }
        return String(text.prefix(10))
    }

    /// meta.json 에 넣을 참조 (고를 때의 마지막 점검 작업·썸네일 포함)
    var ref: SiteRef {
        SiteRef(id: siteId, name: name, lastJobId: lastJobId, lastThumbUrl: lastThumbUrl)
    }
}

enum SiteError: LocalizedError {
    case notDeployed
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notDeployed:
            return "서버에 장소 기능(sites.py)이 아직 없습니다"
        case .http(let code, let message):
            return "서버 응답 \(code)" + (message.isEmpty ? "" : ": " + message)
        case .badResponse(let message):
            return "서버 응답을 읽을 수 없습니다 (\(message))"
        }
    }
}

enum SiteClient {
    /// 근처 장소 (가까운 순)
    static func nearby(endpoints: ServerEndpoints, lat: Double, lon: Double,
                       radiusMeters: Double = CaptureTuning.siteSearchRadius) async throws -> [SiteSummary] {
        var request = URLRequest(url: endpoints.nearbySitesURL(lat: lat, lon: lon, radiusMeters: radiusMeters))
        request.timeoutInterval = CaptureTuning.siteRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let object = try await send(request)
        guard let list = object["sites"] as? [[String: Any]] else {
            throw SiteError.badResponse("sites 목록이 없습니다")
        }
        return list.compactMap(parseSite).sorted {
            ($0.distanceM ?? .greatestFiniteMagnitude) < ($1.distanceM ?? .greatestFiniteMagnitude)
        }
    }

    /// 새 장소를 만들고 site_id 를 받는다
    static func create(endpoints: ServerEndpoints, name: String, lat: Double?, lon: Double?,
                       note: String) async throws -> SiteRef {
        var fields: [(String, String)] = [("name", name), ("note", note)]
        if let lat = lat, let lon = lon {
            fields.append(("lat", String(format: "%.8f", lat)))
            fields.append(("lon", String(format: "%.8f", lon)))
        }
        var multipart = MultipartBody()
        for field in fields {
            multipart.addField(field.0, field.1)
        }
        var request = URLRequest(url: endpoints.sitesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = CaptureTuning.siteRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.fieldsData()
        let object: [String: Any]
        do {
            object = try await send(request)
        } catch SiteError.http(let code, _) where code == 400 || code == 415 {
            // 서버가 multipart 를 받지 않으면 한 번만 urlencoded 로
            var retry = request
            retry.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            retry.httpBody = formEncoded(fields)
            object = try await send(retry)
        }
        guard let siteId = string(object["site_id"]), !siteId.isEmpty else {
            throw SiteError.badResponse("site_id 가 없습니다")
        }
        return SiteRef(id: siteId, name: string(object["name"]) ?? name)
    }

    /// 서버가 준 썸네일 주소 (상대 경로면 서버 기준)
    static func thumbURL(_ text: String?, endpoints: ServerEndpoints?) -> URL? {
        guard let text = text, !text.isEmpty else { return nil }
        return URL(string: text, relativeTo: endpoints?.base)?.absoluteURL
    }

    /// 화면·로그용 짧은 이유
    static func describe(_ error: Error) -> String {
        if let siteError = error as? SiteError {
            return siteError.errorDescription ?? "장소 요청 실패"
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                return "인터넷 연결이 없습니다"
            case NSURLErrorTimedOut:
                return "서버 응답이 늦습니다"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "서버에 연결할 수 없습니다"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    // MARK: - 내부

    /// JSON 객체 응답. 404 = sites.py 없음, 그 밖의 HTTP 오류는 {"error"} 문구와 함께
    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if code == 404 {
            throw SiteError.notDeployed
        }
        guard (200..<300).contains(code) else {
            throw SiteError.http(code, string(object?["error"]) ?? "")
        }
        guard let result = object else {
            throw SiteError.badResponse(String(decoding: data.prefix(120), as: UTF8.self))
        }
        if let message = string(result["error"]), !message.isEmpty {
            throw SiteError.http(code, message)
        }
        return result
    }

    /// 형식이 조금 달라도(숫자가 문자열 등) 읽는다
    private static func parseSite(_ item: [String: Any]) -> SiteSummary? {
        guard let siteId = string(item["site_id"]), !siteId.isEmpty else { return nil }
        let markers = (item["marker_ids"] as? [Any])?.compactMap { int($0) } ?? []
        return SiteSummary(siteId: siteId, name: string(item["name"]) ?? siteId,
                           distanceM: double(item["distance_m"]), scans: int(item["scans"]),
                           lastScanAt: string(item["last_scan_at"]), lastJobId: string(item["last_job_id"]),
                           lastThumbUrl: string(item["last_thumb_url"]), markerIds: markers)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        if let text = value as? String {
            return text
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String {
            return Double(text)
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = double(value), number.isFinite else { return nil }
        return Int(number)
    }

    private static func formEncoded(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.map { pair in
            pair.0 + "=" + (pair.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
