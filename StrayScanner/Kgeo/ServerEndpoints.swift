//
//  ServerEndpoints.swift
//  kgeoScan
//
//  업로드 백엔드 주소 계산. (Stray Scanner 포크에 추가된 파일)
//
//  base      = https://kgeodata.com/app/3dupload
//  upload    = base/upload.py           POST multipart
//  status    = base/status.py?job_id=   GET
//  viewer    = https://kgeodata.com/app/3dscan/?select=<scene_item_id>
//

import Foundation

struct ServerEndpoints {
    let base: URL

    init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        base = url
    }

    /// 뒤 슬래시를 뗀 정규화된 문자열. 저장된 upload.server 와 비교할 때 쓴다.
    var normalized: String { base.absoluteString }

    var uploadURL: URL {
        base.appendingPathComponent("upload.py")
    }

    func statusURL(jobId: String) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("status.py"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "job_id", value: jobId)]
        return components.url!
    }

    /// 결과 뷰어 폴더: .../app/3dupload → .../app/3dscan
    var viewerURL: URL {
        base.deletingLastPathComponent().appendingPathComponent("3dscan")
    }

    func resultURL(sceneItemId: String?) -> URL {
        var components = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false)!
        if !components.path.hasSuffix("/") { components.path += "/" }
        if let id = sceneItemId, !id.isEmpty {
            components.queryItems = [URLQueryItem(name: "select", value: id)]
        }
        return components.url!
    }
}
