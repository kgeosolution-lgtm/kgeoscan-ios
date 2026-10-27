//
//  UploadView.swift
//  kgeoScan
//
//  녹화 폴더 압축 → upload.py 전송(진행률) → status.py 폴링(단계 표시) → 결과 페이지 열기.
//  (Stray Scanner 포크에 추가된 파일)
//
//  중복 방지: 한 녹화는 client_id 를 한 번만 만들고, job_id 를 받은 뒤에는 다시 올리지 않고 상태만 조회한다.
//  모든 단계가 화면의 로그와 녹화 폴더의 upload.log, meta.json(last_attempt, upload_log) 에 남는다.
//

import SwiftUI
import Combine
import UIKit

/// 상태는 모두 메인 스레드에서만 바꾼다: 바꾸는 메서드마다 @MainActor 를 붙였다
/// (클래스 전체를 @MainActor 로 하면 init 이 격리돼 StateObject 생성과 충돌한다).
final class UploadViewModel: ObservableObject {
    enum Stage: Int, Comparable {
        case idle = 0
        case zipping = 1
        case uploading = 2
        case processing = 3
        case done = 4

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    @Published var stage: Stage = .idle
    @Published var errorMessage: String?
    @Published var zipFraction: Double = 0
    @Published var bytesSent: Int64 = 0
    @Published var bytesTotal: Int64 = 0
    @Published var status: JobStatus?
    @Published var pollError: String?
    @Published var meta: ScanMeta
    @Published var log: [String] = []
    /// 보낸 바이트가 줄어든(처음부터 다시 보낸) 횟수
    @Published var restarts: Int = 0
    @Published var transport: String = ""
    /// 진행 섹션에 보여 줄 한 줄 상태 (서버 접수 확인 중 등)
    @Published var statusNote: String?

    let directory: URL
    private var runTask: Task<Void, Never>?
    private var zipObserver: AnyCancellable?
    private var lastStatusLine = ""
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(directory: URL) {
        self.directory = directory
        let loaded = ScanMeta.load(from: directory)
        self.meta = loaded
            ?? ScanMeta(title: directory.lastPathComponent, note: "", mode: .home,
                        serverBase: KgeoDefaults.storedServerBase)
        self.log = loaded?.uploadLog ?? []
        self.restarts = loaded?.lastAttempt?.restarts ?? 0
        self.transport = loaded?.lastAttempt?.transport ?? ""
    }

    var isRunning: Bool { errorMessage == nil && stage != .idle && stage != .done }
    var hasPreviousUpload: Bool { meta.upload != nil }
    var endpoints: ServerEndpoints? { ServerEndpoints(string: meta.serverBase) }

    var resultURL: URL? {
        guard let endpoints = endpoints else { return nil }
        if let saved = meta.upload?.resultUrl, let url = URL(string: saved) { return url }
        return endpoints.resultURL(sceneItemId: status?.sceneItemId ?? meta.upload?.sceneItemId,
                                   jobId: meta.upload?.jobId)
    }

    /// 사이트의 진행 상황 페이지 (?job=). 업로드가 끝나 job_id 가 있을 때만.
    var jobURL: URL? {
        guard let endpoints = endpoints, let jobId = meta.upload?.jobId else { return nil }
        return endpoints.jobURL(jobId: jobId)
    }

    var thumbURL: URL? {
        guard let thumb = status?.thumbUrl ?? meta.upload?.thumbUrl, !thumb.isEmpty else { return nil }
        return URL(string: thumb, relativeTo: endpoints?.base)?.absoluteURL
    }

    /// 복사용 전체 로그 (머리말 포함)
    var fullLogText: String {
        let header = [
            "kgeoScan \(KgeoDefaults.appVersion) 업로드 로그",
            "스캔: \(meta.title) / 폴더 \(directory.lastPathComponent) / client_id \(meta.clientId ?? "-")",
            "서버: \(meta.serverBase)",
            "기기: \(meta.device ?? "?") iOS \(meta.systemVersion ?? "?")",
            "",
        ]
        return (header + log).joined(separator: "\n")
    }

    @MainActor
    func appendLog(_ message: String, persist: Bool = false) {
        let line = "\(timeFormatter.string(from: Date())) \(message)"
        log.append(line)
        if log.count > 400 {
            log.removeFirst(log.count - 400)
        }
        appendToLogFile(line)
        if persist {
            meta.uploadLog = Array(log.suffix(150))
            try? meta.save(to: directory)
        }
    }

    private func appendToLogFile(_ line: String) {
        let url = directory.appendingPathComponent(KgeoDefaults.uploadLogFileName, isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    @MainActor
    func start(forceReupload: Bool = false) {
        runTask?.cancel()
        errorMessage = nil
        pollError = nil
        appendLog(forceReupload ? "사용자가 '처음부터 다시 업로드'를 눌렀습니다" : "업로드 시작")
        runTask = Task { await run(forceReupload: forceReupload) }
    }

    @MainActor
    func cancel() {
        runTask?.cancel()
        runTask = nil
        if stage == .uploading {
            UploadClient.shared.cancelAll()
        }
        stage = .idle
        appendLog("사용자가 취소했습니다", persist: true)
    }

    /// 화면을 떠날 때: 폴링만 멈춘다. 진행 중인 전송은 세션이 이어서 끝내고 결과를 기록한다.
    @MainActor
    func stopPolling() {
        runTask?.cancel()
        runTask = nil
    }

    @MainActor
    private func fail(_ message: String) {
        errorMessage = message
        appendLog("실패: \(message)", persist: true)
    }

    @MainActor
    private func run(forceReupload: Bool) async {
        guard let endpoints = endpoints else {
            fail("서버 주소가 올바르지 않습니다: \(meta.serverBase)")
            return
        }
        let transportMode = UploadTransport(rawValue: KgeoDefaults.uploadTransport) ?? .system
        let isBackground = transportMode == .background
        let wifiOnly = UserDefaults.standard.bool(forKey: KgeoDefaults.wifiOnlyKey)
        transport = transportMode.label + (wifiOnly ? " (Wi-Fi 전용)" : "")

        // 이미 job_id 를 받은 스캔은 다시 올리지 않고 상태만 조회한다
        if !forceReupload, let previous = meta.upload, previous.status != "failed",
           ServerEndpoints(string: previous.server)?.normalized == endpoints.normalized {
            appendLog("이미 올린 작업 \(previous.jobId) 의 상태를 조회합니다 (다시 올리지 않음)")
            stage = .processing
            await poll(endpoints: endpoints, jobId: previous.jobId)
            return
        }

        if meta.clientId == nil {
            meta.clientId = UUID().uuidString.lowercased()
        }
        if let previous = meta.lastAttempt, previous.finishedAt == nil, previous.jobId == nil {
            appendLog("이전 전송(\(timeFormatter.string(from: previous.startedAt)) 시작)이 끝나지 않은 채 중단됐습니다. 서버가 같은 스캔을 중복 방지하므로 다시 보냅니다.")
        }

        if meta.fix == nil {
            if let fix = LocationService.shared.snapshot() {
                meta.fix = fix
                try? meta.save(to: directory)
                appendLog("위치 기록이 없어 현재 위치를 씁니다: \(fix.lat), \(fix.lon)")
            } else {
                stage = .idle
                fail("위치 정보가 없습니다. 위치 권한을 허용하고 GPS 가 잡힌 뒤 다시 시도하세요.")
                return
            }
        }
        // 서버가 400 을 낼 조건은 미리 거른다 (HTTP/2 경로에서는 400 응답조차 못 받는다)
        guard !meta.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stage = .idle
            fail("제목이 비어 있습니다. 스캔 상세에서 제목을 확인해 주세요.")
            return
        }
        if let fix = meta.fix, !(fix.lat.isFinite && fix.lon.isFinite && abs(fix.lat) <= 90 && abs(fix.lon) <= 180) {
            stage = .idle
            fail(String(format: "위치 좌표가 올바르지 않습니다 (%.5f, %.5f)", fix.lat, fix.lon))
            return
        }
        appendLog("사전 검사 통과: 제목·위치·모드(\(meta.mode.rawValue))")

        var zipURL: URL?
        var bodyURL: URL?
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            if let z = zipURL { try? FileManager.default.removeItem(at: z) }
            if let b = bodyURL { try? FileManager.default.removeItem(at: b) }
        }

        do {
            // 1. 압축
            stage = .zipping
            zipFraction = 0
            restarts = 0
            let zipStart = Date()
            appendLog("압축 시작: \(directory.lastPathComponent)")
            let progress = Progress()
            zipObserver = progress.publisher(for: \.fractionCompleted)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in self?.zipFraction = value }
            let dir = directory
            let zip = try await Task.detached(priority: .userInitiated) {
                try ZipPackager.makeZip(of: dir, progress: progress)
            }.value
            zipObserver = nil
            zipFraction = 1
            zipURL = zip
            appendLog("압축 완료: \(ZipPackager.fileSize(zip)) 바이트, \(String(format: "%.1f", Date().timeIntervalSince(zipStart)))초")
            try Task.checkCancellation()

            // 2. 업로드
            stage = .uploading
            bytesSent = 0
            bytesTotal = ZipPackager.fileSize(zip)
            var body = MultipartBody()
            body.addField("title", meta.title)
            body.addField("note", meta.note)
            // mode: stray (영상·깊이, Stray 형식) | objcap (Object Capture: model/, images/, poses.json)
            body.addField("mode", meta.isObjcap ? "objcap" : "stray")
            body.addField("scan_type", meta.isObjcap ? ScanMode.survey.rawValue : meta.mode.rawValue)
            body.addField("client_id", meta.clientId ?? "")
            body.addField("app", "kgeoScan \(KgeoDefaults.appVersion)")
            if meta.objectMode == true && !meta.isObjcap {
                // 물체 모드: 서버가 obj_center 반경 obj_radius 안만 잘라 복원한다. 중심이 없으면 서버가 자동 계산
                body.addField("object_mode", "1")
                if let object = meta.object {
                    if let center = object.center, center.count == 3 {
                        body.addField("obj_center", String(format: "%.4f,%.4f,%.4f", center[0], center[1], center[2]))
                    }
                    body.addField("obj_radius", String(format: "%.2f", object.radius))
                    if let coverage = object.coveragePct {
                        body.addField("obj_coverage", String(format: "%.0f", coverage))
                    }
                }
            }
            if let fix = meta.fix {
                body.addField("lon", String(format: "%.8f", fix.lon))
                body.addField("lat", String(format: "%.8f", fix.lat))
                if let alt = fix.alt {
                    body.addField("elev", String(format: "%.2f", alt))
                }
                if let heading = fix.headingForUpload {
                    body.addField("heading", String(format: "%.1f", heading))
                }
            }
            let bodyFile = FileManager.default.temporaryDirectory
                .appendingPathComponent(directory.lastPathComponent + ".multipart", isDirectory: false)
            try body.write(fileField: "scan_zip", fileURL: zip, fileName: directory.lastPathComponent + ".zip",
                           mimeType: "application/zip", to: bodyFile)
            bodyURL = bodyFile
            let bodyBytes = ZipPackager.fileSize(bodyFile)
            var attempt = UploadAttempt(startedAt: Date(), clientId: meta.clientId ?? "", transport: transport, bodyBytes: bodyBytes)
            meta.lastAttempt = attempt
            meta.attemptCount = (meta.attemptCount ?? 0) + 1
            appendLog("multipart 본문 \(bodyBytes) 바이트를 \(transport) 세션으로 \(endpoints.uploadURL.absoluteString) 에 보냅니다 (시도 \(meta.attemptCount ?? 1)회째)", persist: true)

            var request = URLRequest(url: endpoints.uploadURL)
            request.httpMethod = "POST"
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            // 전송. 연결이 끊기면 서버에 작업이 생겼는지(client_id) 먼저 묻고, 없을 때만 최대 3회 다시 보낸다
            let maxAttempts = 3
            var sendAttempt = 0
            var code = 0
            var data = Data()
            while true {
                sendAttempt += 1
                bytesSent = 0
                do {
                    (code, data) = try await UploadClient.shared.upload(
                        request: request, bodyFile: bodyFile, taskDescription: directory.path, transport: transportMode,
                        wifiOnly: wifiOnly,
                        log: { [weak self] line in
                            Task { @MainActor in self?.appendLog(line) }
                        },
                        progress: { [weak self] sent, total in
                            Task { @MainActor in
                                guard let self = self else { return }
                                if sent < self.bytesSent {
                                    self.restarts += 1
                                    if isBackground {
                                        // iOS 가 응답을 못 받고 본문을 처음부터 다시 보내려는 것 — 서버 중복을 막기 위해 끊는다
                                        self.appendLog("iOS 가 본문을 처음부터 다시 보내려 합니다 — 중복 업로드를 막기 위해 전송을 멈춥니다", persist: true)
                                        UploadClient.shared.cancelAll()
                                        self.fail("서버 응답을 받지 못해 iOS 가 다시 보내려 해서 전송을 멈췄습니다. 서버에 이미 도착했을 수 있으니 '업로드 시작'을 다시 누르면 같은 작업으로 이어집니다 (서버 중복 방지).")
                                    }
                                }
                                self.bytesSent = sent
                                if total > 0 { self.bytesTotal = total }
                            }
                        })
                    break
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        throw error
                    }
                    guard UploadError.isRetryable(error) else { throw error }
                    let h2Hint = (transportMode != .http1 && (error as? URLError)?.code == .networkConnectionLost)
                        ? "서버 응답이 HTTP/2 에서 끊김 → " : ""
                    appendLog("\(h2Hint)연결 오류: \(error.localizedDescription) — 서버 접수 여부를 확인합니다 (find_job, 3초 간격 최대 60초)", persist: true)
                    if let clientId = meta.clientId, let found = await waitForServerJob(endpoints: endpoints, clientId: clientId) {
                        statusNote = nil
                        appendLog("서버가 접수했습니다: 작업 \(found.jobId) (\(found.status ?? "pending")) — 다시 올리지 않고 상태 조회로 넘어갑니다", persist: true)
                        attempt.finishedAt = Date()
                        attempt.jobId = found.jobId
                        attempt.duplicate = true
                        attempt.error = error.localizedDescription
                        attempt.restarts = restarts
                        meta.lastAttempt = attempt
                        meta.upload = UploadRecord(server: endpoints.normalized, jobId: found.jobId, uploadedAt: Date(),
                                                   status: found.status ?? "pending", step: 0)
                        try? meta.save(to: directory)
                        stage = .processing
                        await poll(endpoints: endpoints, jobId: found.jobId)
                        return
                    }
                    statusNote = nil
                    guard sendAttempt < maxAttempts else {
                        appendLog("60초 동안 서버에 작업이 없었고 재시도 \(maxAttempts)회를 모두 썼습니다", persist: true)
                        throw error
                    }
                    let delay = [3, 10, 30][min(sendAttempt - 1, 2)]
                    appendLog("서버에 작업이 없습니다. \(delay)초 뒤 같은 client_id 로 다시 보냅니다 (\(sendAttempt + 1)/\(maxAttempts))", persist: true)
                    try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    meta.attemptCount = (meta.attemptCount ?? 0) + 1
                    attempt.startedAt = Date()
                }
            }
            statusNote = nil
            let bodyText = String(data: data.prefix(300), encoding: .utf8) ?? "(UTF-8 아님, \(data.count) 바이트)"
            appendLog("응답: HTTP \(code) \(bodyText)")
            attempt.finishedAt = Date()
            attempt.httpStatus = code
            attempt.restarts = restarts
            let reply: (jobId: String, duplicate: Bool)
            do {
                reply = try UploadClient.parseUploadReply(code: code, data: data)
            } catch {
                attempt.error = error.localizedDescription
                meta.lastAttempt = attempt
                throw error
            }
            attempt.jobId = reply.jobId
            attempt.duplicate = reply.duplicate
            meta.lastAttempt = attempt
            meta.upload = UploadRecord(server: endpoints.normalized, jobId: reply.jobId, uploadedAt: Date(),
                                       status: "pending", step: 0)
            appendLog(reply.duplicate
                      ? "서버에 같은 스캔의 작업이 이미 있어 그 작업 \(reply.jobId) 으로 이어집니다 (duplicate)"
                      : "작업 ID \(reply.jobId) 받음", persist: true)
            if Task.isCancelled { return }

            // 3. 서버 처리
            stage = .processing
            await poll(endpoints: endpoints, jobId: reply.jobId)
        } catch is CancellationError {
            stage = .idle
            appendLog("취소됨", persist: true)
        } catch let error as URLError where error.code == .cancelled {
            stage = .idle
            appendLog("전송이 취소됐습니다", persist: true)
        } catch {
            zipObserver = nil
            if meta.lastAttempt != nil, meta.lastAttempt?.finishedAt == nil {
                meta.lastAttempt?.finishedAt = Date()
                meta.lastAttempt?.error = error.localizedDescription
                meta.lastAttempt?.restarts = restarts
            }
            if let urlError = error as? URLError {
                fail("\(error.localizedDescription) (URLError \(urlError.code.rawValue))")
            } else {
                fail(error.localizedDescription)
            }
        }
    }

    /// 전송이 끊긴 뒤 서버가 이 client_id 의 작업을 만들었는지 3초 간격으로 최대 60초 확인한다
    @MainActor
    private func waitForServerJob(endpoints: ServerEndpoints, clientId: String) async -> (jobId: String, status: String?)? {
        let started = Date()
        var tries = 0
        while Date().timeIntervalSince(started) < 60, !Task.isCancelled {
            tries += 1
            let elapsed = Int(Date().timeIntervalSince(started))
            statusNote = "서버 접수 확인 중 (\(elapsed)/60초)…"
            if let found = await UploadClient.findJob(endpoints: endpoints, clientId: clientId) {
                return found
            }
            if tries % 5 == 0 {
                appendLog("아직 서버에 작업이 없습니다 (\(elapsed)초)")
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return nil
    }

    @MainActor
    private func poll(endpoints: ServerEndpoints, jobId: String) async {
        while !Task.isCancelled {
            do {
                let s = try await UploadClient.fetchStatus(endpoints.statusURL(jobId: jobId))
                status = s
                pollError = nil
                let line = "\(s.status ?? "?") · 단계 \(s.step ?? 0) \(s.stepName ?? "") \(s.message ?? "")"
                if line != lastStatusLine {
                    lastStatusLine = line
                    appendLog("서버: \(line)")
                }
                if meta.upload?.jobId == jobId {
                    meta.upload?.status = s.status
                    meta.upload?.step = s.step
                    meta.upload?.stepName = s.stepName
                    meta.upload?.message = s.message
                    if let id = s.sceneItemId, !id.isEmpty { meta.upload?.sceneItemId = id }
                    if let glb = s.glbUrl, !glb.isEmpty { meta.upload?.glbUrl = glb }
                    if let thumb = s.thumbUrl, !thumb.isEmpty { meta.upload?.thumbUrl = thumb }
                }
                if s.isDone {
                    meta.upload?.resultUrl = endpoints.resultURL(sceneItemId: s.sceneItemId, jobId: jobId).absoluteString
                    stage = .done
                    appendLog("서버 처리 완료: \(meta.upload?.resultUrl ?? "")", persist: true)
                    return
                }
                if s.isFailed {
                    try? meta.save(to: directory)
                    fail(s.message ?? s.errorDetail ?? "서버 처리 실패")
                    return
                }
                try? meta.save(to: directory)
            } catch {
                pollError = error.localizedDescription
                appendLog("상태 조회 오류: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: KgeoDefaults.pollIntervalSeconds * 1_000_000_000)
        }
    }
}

struct UploadView: View {
    @StateObject private var vm: UploadViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private let autoStart: Bool

    init(directory: URL, autoStart: Bool = true) {
        _vm = StateObject(wrappedValue: UploadViewModel(directory: directory))
        self.autoStart = autoStart
    }

    var body: some View {
        Form {
            Section("스캔") {
                LabeledContent("제목", value: vm.meta.title)
                LabeledContent("모드", value: vm.meta.mode.label)
                if let frames = vm.meta.savedFrames, let duration = vm.meta.durationSeconds {
                    LabeledContent("녹화", value: String(format: "%.0f초 · %d 프레임", duration, frames))
                }
                if let info = vm.meta.objcap {
                    LabeledContent("사진", value: "\(info.images)장 · 폰 3D " + (info.reconstruction == "device" ? "완료" : "없음"))
                }
                if let fix = vm.meta.fix {
                    LabeledContent("위치", value: String(format: "%.6f, %.6f", fix.lat, fix.lon))
                    LabeledContent("방위", value: fix.headingForUpload.map { String(format: "%.0f°", $0) } ?? "없음 (북쪽으로 가정)")
                } else {
                    Text("위치 정보 없음 — 업로드할 때 현재 위치를 씁니다")
                        .foregroundColor(.orange)
                }
                LabeledContent("서버", value: vm.meta.serverBase)
                if let job = vm.meta.upload?.jobId {
                    LabeledContent("작업 ID", value: job)
                }
            }

            Section("진행") {
                stepRow("1. 압축", stage: .zipping)
                if vm.stage == .zipping {
                    ProgressView(value: vm.zipFraction)
                }
                stepRow("2. 업로드", stage: .uploading)
                if vm.stage == .uploading {
                    ProgressView(value: uploadFraction)
                    Text("\(megabytes(vm.bytesSent)) / \(megabytes(vm.bytesTotal)) MB · \(vm.transport)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(vm.transport.hasPrefix("백그라운드")
                         ? "iOS 가 대신 보냅니다. 응답을 못 받고 다시 보내려 하면 앱이 전송을 멈춥니다."
                         : "업로드 중에는 앱을 열어 두세요 (화면 자동 잠금은 꺼 두었습니다). 끊기면 서버 확인 뒤 최대 3회 다시 보냅니다.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if vm.restarts > 0 {
                        Text("전송이 \(vm.restarts)회 처음부터 다시 시작됐습니다 — 서버 응답을 받지 못한 것 같습니다.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                stepRow("3. 서버 처리", stage: .processing)
                if let s = vm.status, vm.stage >= .processing {
                    Text(statusLine(s))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let note = vm.statusNote {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(note).font(.caption).foregroundColor(.secondary)
                    }
                }
                if let e = vm.pollError {
                    Text("상태 조회 오류: \(e)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if let e = vm.errorMessage {
                    Text(e).foregroundColor(.red)
                }
                if vm.stage != .done, let job = vm.jobURL {
                    Button {
                        openURL(job)
                    } label: {
                        Label("웹에서 진행 보기", systemImage: "safari")
                    }
                }
            }

            Section {
                if vm.stage == .done {
                    if let thumb = vm.thumbURL {
                        AsyncImage(url: thumb) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            ProgressView()
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .cornerRadius(8)
                    }
                    Button {
                        if let url = vm.resultURL { openURL(url) }
                    } label: {
                        Label("결과 보기 (웹)", systemImage: "safari")
                    }
                    if let url = vm.resultURL {
                        Text(url.absoluteString)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else if vm.isRunning {
                    Button(role: .destructive) {
                        vm.cancel()
                    } label: {
                        Label("취소", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        vm.start()
                    } label: {
                        Label(vm.hasPreviousUpload ? "상태 다시 확인" : "업로드 시작", systemImage: "icloud.and.arrow.up")
                    }
                    if vm.hasPreviousUpload {
                        Button {
                            vm.start(forceReupload: true)
                        } label: {
                            Label("처음부터 다시 업로드", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
                Button {
                    vm.stopPolling()
                    dismiss()
                } label: {
                    Label("목록으로", systemImage: "list.bullet")
                }
            }

            Section("로그 (\(vm.log.count)줄)") {
                if let attempt = vm.meta.lastAttempt {
                    Text(attemptSummary(attempt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(Array(vm.log.suffix(40).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(4)
                }
                Button {
                    UIPasteboard.general.string = vm.fullLogText
                } label: {
                    Label("로그 복사", systemImage: "doc.on.doc")
                }
                Text("전체 로그는 녹화 폴더의 upload.log (파일 앱 > 나의 iPhone > kgeoScan)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("서버 업로드")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(vm.isRunning)
        .onAppear {
            if vm.meta.fix == nil {
                LocationService.shared.start()
            }
            if autoStart && vm.stage == .idle && vm.errorMessage == nil {
                vm.start()
            }
        }
        .onDisappear {
            vm.stopPolling()
        }
    }

    private var uploadFraction: Double {
        vm.bytesTotal > 0 ? min(1.0, Double(vm.bytesSent) / Double(vm.bytesTotal)) : 0
    }

    private func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    private func statusLine(_ s: JobStatus) -> String {
        var parts: [String] = []
        if let step = s.step { parts.append("단계 \(step)/7") }
        if let name = s.stepName, !name.isEmpty { parts.append(name) }
        if let message = s.message, !message.isEmpty { parts.append(message) }
        if let st = s.status { parts.append("[\(st)]") }
        return parts.joined(separator: " · ")
    }

    private func attemptSummary(_ attempt: UploadAttempt) -> String {
        var parts = ["마지막 시도 \(attempt.transport) \(attempt.bodyBytes / 1_048_576) MB"]
        if let code = attempt.httpStatus { parts.append("HTTP \(code)") }
        if let restarts = attempt.restarts, restarts > 0 { parts.append("재시작 \(restarts)회") }
        if let job = attempt.jobId { parts.append("job \(job)" + ((attempt.duplicate ?? false) ? " (기존)" : "")) }
        if let error = attempt.error { parts.append("오류: \(error)") }
        if attempt.finishedAt == nil { parts.append("끝나지 않음") }
        return parts.joined(separator: " · ")
    }

    private func stepRow(_ title: String, stage: UploadViewModel.Stage) -> some View {
        HStack {
            stepIcon(for: stage)
            Text(title)
            Spacer()
        }
    }

    @ViewBuilder
    private func stepIcon(for stage: UploadViewModel.Stage) -> some View {
        if vm.stage > stage {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        } else if vm.stage == stage {
            if vm.errorMessage != nil {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        } else {
            Image(systemName: "circle").foregroundColor(.secondary)
        }
    }
}
