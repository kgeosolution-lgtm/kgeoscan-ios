//
//  UploadClient.swift
//  kgeoScan
//
//  upload.py 로 멀티파트 업로드, status.py 상태 조회. (Stray Scanner 포크에 추가된 파일)
//
//  백그라운드 URLSession 을 써서 업로드 중 화면을 꺼도 전송이 이어진다. 앱이 종료된 채 전송이 끝나면
//  task.taskDescription(녹화 폴더 경로)을 보고 meta.json 에 job_id 를 기록해 둔다.
//

import Foundation

enum UploadError: LocalizedError {
    case local(String)
    case server(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .local(let m): return m
        case .server(let m): return "서버 응답: \(m)"
        case .http(let code, let body):
            return "HTTP \(code)" + (body.isEmpty ? "" : " — \(body)")
        }
    }
}

/// upload.py 응답: {"job_id": "...", "mode": "stray", "scan_type": "home"} 또는 {"error": "..."}
struct UploadReply: Decodable {
    var jobId: String?
    var mode: String?
    var scanType: String?
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

    /// AppDelegate 가 handleEventsForBackgroundURLSession 에서 넣어 준다.
    var backgroundCompletionHandler: (() -> Void)?

    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    private var completions: [Int: Completion] = [:]
    private var progressHandlers: [Int: ProgressHandler] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: UploadClient.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
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
        _ = session
    }

    /// 모든 진행 중 전송을 취소한다.
    func cancelAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    /// bodyFile 을 그대로 POST 한다. 반환: (HTTP 상태 코드, 응답 본문)
    func upload(request: URLRequest, bodyFile: URL, taskDescription: String,
                progress: @escaping ProgressHandler) async throws -> (Int, Data) {
        let task = session.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = taskDescription
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            completions[task.taskIdentifier] = { continuation.resume(with: $0) }
            progressHandlers[task.taskIdentifier] = progress
            lock.unlock()
            task.resume()
        }
    }

    static func parseUploadReply(code: Int, data: Data) throws -> String {
        if let reply = try? ScanMeta.decoder.decode(UploadReply.self, from: data) {
            if let id = reply.jobId, !id.isEmpty { return id }
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

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        let handler = progressHandlers[task.taskIdentifier]
        lock.unlock()
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        let completion = completions.removeValue(forKey: task.taskIdentifier)
        progressHandlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
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

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }

    private func recordOrphanCompletion(task: URLSessionTask, code: Int, data: Data, error: Error?) {
        guard error == nil, let path = task.taskDescription, !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard var meta = ScanMeta.load(from: directory) else { return }
        guard let jobId = try? UploadClient.parseUploadReply(code: code, data: data) else { return }
        let serverString = task.originalRequest?.url?.deletingLastPathComponent().absoluteString ?? meta.serverBase
        let server = ServerEndpoints(string: serverString)?.normalized ?? serverString
        meta.upload = UploadRecord(server: server, jobId: jobId, uploadedAt: Date(), status: "pending", step: 0)
        try? meta.save(to: directory)
    }
}
