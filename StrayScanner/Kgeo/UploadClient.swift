//
//  UploadClient.swift
//  kgeoScan
//
//  upload.py 로 멀티파트 업로드, status.py 상태 조회. (Stray Scanner 포크에 추가된 파일)
//
//  전송 방식 두 가지:
//  - foreground(기본): 앱을 열어 둔 채 보낸다. 끊기면 바로 오류가 나고 자동 재전송은 없다.
//  - background(실험, 설정 화면 토글): iOS(nsurlsessiond)가 대신 보낸다. 화면을 꺼도 이어지지만, 응답을 못 받으면
//    시스템이 처음부터 다시 보낼 수 있다 (진행 막대가 0 으로 되돌아가는 현상). 앱이 종료된 채 끝나면
//    task.taskDescription(녹화 폴더 경로)을 보고 meta.json 에 job_id 를 기록한다.
//  모든 단계는 log 콜백으로 업로드 화면 로그와 녹화 폴더의 upload.log 에 남는다.
//

import Foundation

enum UploadError: LocalizedError {
    case local(String)
    case server(String)
    case http(Int, String)
    /// 네트워크 연결 문제 (재시도 대상)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .local(let m): return m
        case .server(let m): return "서버 응답: \(m)"
        case .http(let code, let body):
            return "HTTP \(code)" + (body.isEmpty ? "" : " — \(body)")
        case .connection(let m): return "연결 문제: \(m)"
        }
    }

    /// 연결이 끊긴 종류의 오류인지 (서버에 본문이 도착했을 수도 있으므로 find_job 으로 확인 뒤 재시도)
    static func isRetryable(_ error: Error) -> Bool {
        if let e = error as? UploadError {
            switch e {
            case .connection: return true
            case .http(let code, _): return code == 502 || code == 503 || code == 504
            default: return false
            }
        }
        if let e = error as? URLError {
            switch e.code {
            case .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        return false
    }
}

/// 전송 방식
enum UploadTransport: String {
    case http1 = "http1"           // HTTP/1.1 직접 연결 (기본)
    case system = "system"         // URLSession (서버가 HTTP/2 면 HTTP/2)
    case background = "background" // 백그라운드 URLSession (실험)

    var label: String {
        switch self {
        case .http1: return "HTTP/1.1 직접 연결"
        case .system: return "시스템 URLSession"
        case .background: return "백그라운드 (실험)"
        }
    }
}

/// upload.py 응답: {"job_id": "...", "mode": "stray", "scan_type": "home", "duplicate": true} 또는 {"error": "..."}
struct UploadReply: Decodable {
    var jobId: String?
    var mode: String?
    var scanType: String?
    var duplicate: Bool?
    var error: String?
}

/// status.py 응답
struct JobStatus: Decodable, Equatable {
    var jobId: String?
    var status: String?       // pending | processing | done | failed (서버 큐 파일 그대로)
    var step: Int?            // 0..7
    var stepName: String?
    var message: String?
    var title: String?
    var mode: String?
    var scanType: String?     // home | survey
    var thumbUrl: String?     // 처리 뒤 대표 이미지(JPEG) 주소
    var sceneItemId: String?
    var glbUrl: String?
    var updatedAt: String?
    var errorDetail: String?
    var error: String?

    var isDone: Bool { status == "done" }
    var isFailed: Bool { status == "failed" }
}

final class UploadClient: NSObject, URLSessionDataDelegate {
    static let shared = UploadClient()
    static let sessionIdentifier = "com.kgeosolution.kgeoscan.upload"

    typealias Completion = (Result<(Int, Data), Error>) -> Void
    typealias ProgressHandler = (Int64, Int64) -> Void
    typealias LogHandler = (String) -> Void

    /// AppDelegate 가 handleEventsForBackgroundURLSession 에서 넣어 준다.
    var backgroundCompletionHandler: (() -> Void)?

    private let lock = NSLock()
    private var http1Uploader: Http1Uploader?
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var completions: [ObjectIdentifier: Completion] = [:]
    private var progressHandlers: [ObjectIdentifier: ProgressHandler] = [:]
    private var logHandlers: [ObjectIdentifier: LogHandler] = [:]
    private var lastSent: [ObjectIdentifier: Int64] = [:]

    /// 앱을 열어 둔 채 전송. 연결이 끊기면 그대로 오류가 올라온다 (POST 는 시스템이 재시도하지 않는다).
    private lazy var foregroundSession: URLSession = makeForegroundSession(allowsCellular: true)
    /// Wi-Fi 에서만: 셀룰러면 Wi-Fi 가 잡힐 때까지 기다린다 (taskIsWaitingForConnectivity 로 로그에 남는다)
    private lazy var foregroundWifiOnlySession: URLSession = makeForegroundSession(allowsCellular: false)

    private func makeForegroundSession(allowsCellular: Bool) -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60
        config.allowsCellularAccess = allowsCellular
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// iOS 가 대신 전송 (화면을 꺼도 계속). 실패하면 시스템이 처음부터 다시 보낼 수 있다.
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: UploadClient.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 2 * 60 * 60
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    /// 백그라운드 세션을 (다시) 연결한다. 앱이 백그라운드 이벤트로 깨어났을 때 부른다.
    func reconnect() {
        _ = backgroundSession
    }

    /// 모든 진행 중 전송을 취소한다.
    func cancelAll() {
        lock.lock()
        let uploader = http1Uploader
        lock.unlock()
        uploader?.cancel()
        for session in [foregroundSession, foregroundWifiOnlySession, backgroundSession] {
            session.getAllTasks { tasks in
                tasks.forEach { $0.cancel() }
            }
        }
    }

    /// bodyFile 을 그대로 POST 한다. 반환: (HTTP 상태 코드, 응답 본문)
    func upload(request: URLRequest, bodyFile: URL, taskDescription: String, transport: UploadTransport, wifiOnly: Bool = false,
                log: @escaping LogHandler, progress: @escaping ProgressHandler) async throws -> (Int, Data) {
        if transport == .http1 {
            guard let url = request.url else { throw UploadError.local("주소가 없습니다") }
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            let uploader = Http1Uploader()
            lock.lock()
            http1Uploader = uploader
            lock.unlock()
            defer {
                lock.lock()
                if http1Uploader === uploader { http1Uploader = nil }
                lock.unlock()
            }
            return try await withCheckedThrowingContinuation { continuation in
                uploader.upload(url: url, bodyFile: bodyFile, contentType: contentType, wifiOnly: wifiOnly,
                                log: log, progress: progress) { result in
                    continuation.resume(with: result)
                }
            }
        }
        let session = transport == .background ? backgroundSession : (wifiOnly ? foregroundWifiOnlySession : foregroundSession)
        let task = session.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = taskDescription
        let key = ObjectIdentifier(task)
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            completions[key] = { continuation.resume(with: $0) }
            progressHandlers[key] = progress
            logHandlers[key] = log
            lastSent[key] = 0
            lock.unlock()
            log("전송 시작 (\(transport.label)) → \(request.url?.absoluteString ?? "?")")
            task.resume()
        }
    }

    /// 서버에 이 client_id 로 만들어진 작업이 있는지 묻는다 (find_job.py). 없거나 조회 실패면 nil
    static func findJob(endpoints: ServerEndpoints, clientId: String) async -> (jobId: String, status: String?)? {
        var request = URLRequest(url: endpoints.findJobURL(clientId: clientId))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let reply = try? ScanMeta.decoder.decode(JobStatus.self, from: data),
              let jobId = reply.jobId, !jobId.isEmpty else { return nil }
        return (jobId, reply.status)
    }

    /// 응답에서 job_id 를 꺼낸다. duplicate = 서버가 같은 스캔의 기존 작업을 돌려준 경우.
    static func parseUploadReply(code: Int, data: Data) throws -> (jobId: String, duplicate: Bool) {
        if let reply = try? ScanMeta.decoder.decode(UploadReply.self, from: data) {
            if let id = reply.jobId, !id.isEmpty { return (id, reply.duplicate ?? false) }
            if let err = reply.error, !err.isEmpty { throw UploadError.server(err) }
        }
        let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
        throw UploadError.http(code, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func fetchStatus(_ url: URL) async throws -> JobStatus {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let status = try? ScanMeta.decoder.decode(JobStatus.self, from: data) {
            if let err = status.error, status.status == nil { throw UploadError.server(err) }
            return status
        }
        let text = String(data: data.prefix(200), encoding: .utf8) ?? ""
        throw UploadError.http(code, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func log(_ task: URLSessionTask, _ message: String) {
        lock.lock()
        let handler = logHandlers[ObjectIdentifier(task)]
        lock.unlock()
        handler?(message)
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        log(task, "리다이렉트 HTTP \(response.statusCode) → \(request.url?.absoluteString ?? "?") (따라가며 본문을 다시 보냄)")
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        log(task, "네트워크 연결을 기다리는 중")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let key = ObjectIdentifier(task)
        lock.lock()
        let previous = lastSent[key] ?? 0
        lastSent[key] = totalBytesSent
        let progress = progressHandlers[key]
        let logHandler = logHandlers[key]
        lock.unlock()
        if totalBytesSent < previous {
            logHandler?("경고: 보낸 바이트가 \(previous) → \(totalBytesSent) 로 줄었습니다. 처음부터 다시 보내는 중 (시스템 재시도 또는 리다이렉트)")
        } else {
            let step = max(totalBytesExpectedToSend / 10, 1)
            if previous / step != totalBytesSent / step || totalBytesSent == totalBytesExpectedToSend {
                logHandler?("보냄 \(totalBytesSent) / \(totalBytesExpectedToSend) 바이트")
            }
        }
        progress?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        var lines = ["네트워크 지표: 트랜잭션 \(metrics.transactionMetrics.count)개, 리다이렉트 \(metrics.redirectCount)회, 총 \(String(format: "%.1f", metrics.taskInterval.duration))초"]
        for (index, t) in metrics.transactionMetrics.enumerated() {
            let proto = t.networkProtocolName ?? "?"
            let code = (t.response as? HTTPURLResponse).map { String($0.statusCode) } ?? "-"
            var wait = "-"
            if let requestEnd = t.requestEndDate, let responseStart = t.responseStartDate {
                wait = String(format: "%.1f초", responseStart.timeIntervalSince(requestEnd))
            }
            lines.append("  #\(index + 1) \(proto) 연결재사용=\(t.isReusedConnection) 보냄=\(t.countOfRequestBodyBytesSent) 받음=\(t.countOfResponseBodyBytesReceived) 응답=\(code) 본문→응답 대기=\(wait)")
        }
        for line in lines {
            log(task, line)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = ObjectIdentifier(task)
        lock.lock()
        let data = buffers.removeValue(forKey: key) ?? Data()
        let completion = completions.removeValue(forKey: key)
        let logHandler = logHandlers.removeValue(forKey: key)
        progressHandlers.removeValue(forKey: key)
        lastSent.removeValue(forKey: key)
        lock.unlock()

        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if let error = error {
            let ns = error as NSError
            logHandler?("전송 종료: 오류 \(ns.domain) \(ns.code) — \(error.localizedDescription)")
        } else {
            logHandler?("전송 종료: HTTP \(code), 응답 \(data.count) 바이트")
        }
        if let completion = completion {
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success((code, data)))
            }
        } else {
            // 앱이 죽어 있는 동안 끝난 전송: 녹화 폴더의 meta.json 에 결과를 남긴다
            recordOrphanCompletion(task: task, code: code, data: data, error: error)
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            log(dataTask, "응답 헤더: HTTP \(http.statusCode), 길이 \(http.expectedContentLength), 서버 \(http.value(forHTTPHeaderField: "Server") ?? "-")")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[ObjectIdentifier(dataTask), default: Data()].append(data)
        lock.unlock()
        log(dataTask, "응답 본문 \(data.count) 바이트 수신")
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    private func recordOrphanCompletion(task: URLSessionTask, code: Int, data: Data, error: Error?) {
        guard let path = task.taskDescription, !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let logURL = directory.appendingPathComponent(KgeoDefaults.uploadLogFileName, isDirectory: false)
        let note: String
        if let error = error {
            note = "앱이 꺼진 사이 전송 종료: 오류 \(error.localizedDescription)"
        } else {
            note = "앱이 꺼진 사이 전송 종료: HTTP \(code) \(String(data: data.prefix(200), encoding: .utf8) ?? "")"
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((note + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((note + "\n").utf8).write(to: logURL)
        }
        guard error == nil, var meta = ScanMeta.load(from: directory) else { return }
        guard let reply = try? UploadClient.parseUploadReply(code: code, data: data) else { return }
        let serverString = task.originalRequest?.url?.deletingLastPathComponent().absoluteString ?? meta.serverBase
        let server = ServerEndpoints(string: serverString)?.normalized ?? serverString
        meta.upload = UploadRecord(server: server, jobId: reply.jobId, uploadedAt: Date(), status: "pending", step: 0)
        meta.lastAttempt?.finishedAt = Date()
        meta.lastAttempt?.httpStatus = code
        meta.lastAttempt?.jobId = reply.jobId
        meta.lastAttempt?.duplicate = reply.duplicate
        try? meta.save(to: directory)
    }
}
