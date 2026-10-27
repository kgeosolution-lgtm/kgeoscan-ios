//
//  Http1Uploader.swift
//  kgeoScan
//
//  HTTP/1.1 전용 업로더 (Network.framework). TLS 옵션에 ALPN(h2)을 넣지 않으므로 서버가 HTTP/2 를 고를 수 없다.
//  iOS URLSession 이 IIS 와 HTTP/2 로 붙었을 때 서버는 본문을 다 받고 응답까지 보냈는데 클라이언트에는
//  '연결이 끊어졌습니다'(-1005)로 보이는 문제를 피하기 위한 경로. (Stray Scanner 포크에 추가된 파일)
//
//  동작: 연결 → 요청 헤더(Content-Length, Connection: close) → 본문 파일을 256 KB 씩 전송(진행률) →
//  응답 헤더/본문 수신(Content-Length 또는 chunked 또는 연결 종료까지) → (상태 코드, 본문) 반환.
//

import Foundation
import Network

final class Http1Uploader {
    typealias ProgressHandler = (Int64, Int64) -> Void
    typealias LogHandler = (String) -> Void
    typealias Completion = (Result<(Int, Data), Error>) -> Void

    private let queue = DispatchQueue(label: "kgeo.http1upload")
    private var connection: NWConnection?
    private var finished = false
    private var completion: Completion?
    private var responseBuffer = Data()
    private var headerEnd: Int?
    private var statusCode = 0
    private var contentLength: Int?
    private var chunked = false
    private var bodyStart = 0
    private var inactivityTimer: DispatchSourceTimer?
    private var lastActivity = Date()
    private let inactivityTimeout: TimeInterval = 120
    private var sentBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var fileHandle: FileHandle?
    private var log: LogHandler = { _ in }
    private var progress: ProgressHandler = { _, _ in }
    private let chunkSize = 256 * 1024

    func cancel() {
        queue.async {
            self.finish(.failure(URLError(.cancelled)))
        }
    }

    func upload(url: URL, bodyFile: URL, contentType: String, wifiOnly: Bool,
                log: @escaping LogHandler, progress: @escaping ProgressHandler, completion: @escaping Completion) {
        queue.async {
            self.log = log
            self.progress = progress
            self.completion = completion
            self.start(url: url, bodyFile: bodyFile, contentType: contentType, wifiOnly: wifiOnly)
        }
    }

    private func start(url: URL, bodyFile: URL, contentType: String, wifiOnly: Bool) {
        guard let host = url.host, !host.isEmpty else {
            finish(.failure(UploadError.local("주소에 호스트가 없습니다")))
            return
        }
        let isTLS = (url.scheme ?? "https").lowercased() == "https"
        let port = UInt16(url.port ?? (isTLS ? 443 : 80))
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            target += "?" + query
        }
        do {
            fileHandle = try FileHandle(forReadingFrom: bodyFile)
        } catch {
            finish(.failure(UploadError.local("본문 파일을 열 수 없습니다: \(error.localizedDescription)")))
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: bodyFile.path)
        totalBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let parameters: NWParameters
        if isTLS {
            parameters = NWParameters(tls: NWProtocolTLS.Options())   // ALPN 없음 → HTTP/1.1
        } else {
            parameters = NWParameters.tcp
        }
        if wifiOnly {
            parameters.prohibitedInterfaceTypes = [.cellular]
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            finish(.failure(UploadError.local("포트 오류")))
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        connection = conn
        let head = "POST \(target) HTTP/1.1\r\n"
            + "Host: \(host)\r\n"
            + "User-Agent: kgeoScan/\(KgeoDefaults.appVersion)\r\n"
            + "Accept: application/json\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(totalBytes)\r\n"
            + "Connection: close\r\n\r\n"
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log("HTTP/1.1 직접 연결됨 (\(host):\(port), TLS \(isTLS ? "켜짐" : "꺼짐"))")
                self.touch()
                self.receiveLoop()
                conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        self.finish(.failure(UploadError.connection("요청 헤더 전송 실패: \(error)")))
                        return
                    }
                    self.sendNextChunk()
                })
            case .waiting(let error):
                self.log("연결 대기 중: \(error)" + (wifiOnly ? " (Wi-Fi 전용)" : ""))
            case .failed(let error):
                self.finish(.failure(UploadError.connection("연결 실패: \(error)")))
            case .cancelled:
                self.finish(.failure(UploadError.connection("연결이 닫혔습니다")))
            default:
                break
            }
        }
        startInactivityTimer()
        conn.start(queue: queue)
    }

    private func sendNextChunk() {
        guard !finished, let handle = fileHandle, let conn = connection else { return }
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: chunkSize) ?? Data()
        } catch {
            finish(.failure(UploadError.local("본문 파일 읽기 실패: \(error.localizedDescription)")))
            return
        }
        if chunk.isEmpty {
            log("본문 전송 완료 (\(sentBytes) 바이트), 응답 대기")
            return
        }
        let count = Int64(chunk.count)
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.finished else { return }
            if let error = error {
                self.finish(.failure(UploadError.connection("본문 전송 중 끊김 (\(self.sentBytes)/\(self.totalBytes) 바이트): \(error)")))
                return
            }
            self.sentBytes += count
            self.touch()
            self.progress(self.sentBytes, self.totalBytes)
            self.sendNextChunk()
        })
    }

    private func receiveLoop() {
        guard !finished, let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.finished else { return }
            if let data = data, !data.isEmpty {
                self.responseBuffer.append(data)
                self.touch()
                if self.tryFinishResponse(isComplete: isComplete) { return }
            }
            if let error = error {
                self.finish(.failure(UploadError.connection("응답 수신 중 끊김 (받은 \(self.responseBuffer.count) 바이트): \(error)")))
                return
            }
            if isComplete {
                if self.tryFinishResponse(isComplete: true) { return }
                self.finish(.failure(UploadError.connection("응답을 받기 전에 서버가 연결을 닫았습니다 (보낸 \(self.sentBytes)/\(self.totalBytes), 받은 \(self.responseBuffer.count) 바이트)")))
                return
            }
            self.receiveLoop()
        }
    }

    /// 헤더가 다 왔고 본문이 갖춰졌으면 완료 처리하고 true
    private func tryFinishResponse(isComplete: Bool) -> Bool {
        if headerEnd == nil {
            guard let range = responseBuffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
            let headerData = responseBuffer.subdata(in: 0..<range.lowerBound)
            let headerText = String(data: headerData, encoding: .isoLatin1) ?? ""
            let lines = headerText.components(separatedBy: "\r\n")
            let statusParts = (lines.first ?? "").split(separator: " ", maxSplits: 2)
            statusCode = statusParts.count >= 2 ? (Int(statusParts[1]) ?? 0) : 0
            contentLength = nil
            chunked = false
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                if name == "content-length" { contentLength = Int(value) }
                if name == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
            }
            if statusCode == 100 {
                // 중간 응답: 버리고 다음 헤더를 기다린다
                responseBuffer = responseBuffer.subdata(in: range.upperBound..<responseBuffer.count)
                return false
            }
            headerEnd = range.upperBound
            bodyStart = range.upperBound
            log("응답 헤더: HTTP \(statusCode), 길이 \(contentLength.map(String.init) ?? (chunked ? "chunked" : "?"))")
        }
        let available = responseBuffer.count - bodyStart
        if chunked {
            if let decoded = Http1Uploader.decodeChunked(responseBuffer.subdata(in: bodyStart..<responseBuffer.count)) {
                finish(.success((statusCode, decoded)))
                return true
            }
            if isComplete {
                finish(.success((statusCode, responseBuffer.subdata(in: bodyStart..<responseBuffer.count))))
                return true
            }
            return false
        }
        if let length = contentLength {
            if available >= length {
                finish(.success((statusCode, responseBuffer.subdata(in: bodyStart..<(bodyStart + length)))))
                return true
            }
            if isComplete {
                finish(.success((statusCode, responseBuffer.subdata(in: bodyStart..<responseBuffer.count))))
                return true
            }
            return false
        }
        if isComplete {
            finish(.success((statusCode, responseBuffer.subdata(in: bodyStart..<responseBuffer.count))))
            return true
        }
        return false
    }

    /// chunked 본문 해석. 아직 다 안 왔으면 nil
    static func decodeChunked(_ data: Data) -> Data? {
        var result = Data()
        var index = 0
        let bytes = [UInt8](data)
        while true {
            guard let lineEnd = Http1Uploader.findCRLF(bytes, from: index) else { return nil }
            let sizeText = String(bytes: bytes[index..<lineEnd], encoding: .ascii)?
                .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16) else { return nil }
            index = lineEnd + 2
            if size == 0 { return result }
            guard bytes.count >= index + size + 2 else { return nil }
            result.append(contentsOf: bytes[index..<(index + size)])
            index += size + 2
        }
    }

    private static func findCRLF(_ bytes: [UInt8], from start: Int) -> Int? {
        var i = start
        while i + 1 < bytes.count {
            if bytes[i] == 13 && bytes[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }

    private func touch() {
        lastActivity = Date()
    }

    private func startInactivityTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.finished else { return }
            if Date().timeIntervalSince(self.lastActivity) > self.inactivityTimeout {
                self.finish(.failure(UploadError.connection("\(Int(self.inactivityTimeout))초 동안 진행이 없어 중단했습니다 (보낸 \(self.sentBytes)/\(self.totalBytes) 바이트)")))
            }
        }
        timer.resume()
        inactivityTimer = timer
    }

    private func finish(_ result: Result<(Int, Data), Error>) {
        guard !finished else { return }
        finished = true
        inactivityTimer?.cancel()
        inactivityTimer = nil
        try? fileHandle?.close()
        fileHandle = nil
        connection?.cancel()
        let handler = completion
        completion = nil
        handler?(result)
    }
}
