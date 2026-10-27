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

    /// client_id 로 이미 만들어진 작업 찾기 (서버 find_job.py). 없으면 404
    func findJobURL(clientId: String) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("find_job.py"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "client_id", value: clientId)]
        return components.url!
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

    /// 결과 페이지. scene_item_id 가 있으면 ?select=, 없으면 ?job= (사이트가 진행 상황·결과를 이어서 보여 준다)
    func resultURL(sceneItemId: String?, jobId: String? = nil) -> URL {
        var components = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false)!
        if !components.path.hasSuffix("/") { components.path += "/" }
        if let id = sceneItemId, !id.isEmpty {
            components.queryItems = [URLQueryItem(name: "select", value: id)]
        } else if let job = jobId, !job.isEmpty {
            components.queryItems = [URLQueryItem(name: "job", value: job)]
        }
        return components.url!
    }

    /// 진행 상황 페이지: .../3dscan/?job=<job_id> — 7단계 진행을 보여 주고 끝나면 확대 버튼이 뜬다
    func jobURL(jobId: String) -> URL {
        var components = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false)!
        if !components.path.hasSuffix("/") { components.path += "/" }
        components.queryItems = [URLQueryItem(name: "job", value: jobId)]
        return components.url!
    }
}
