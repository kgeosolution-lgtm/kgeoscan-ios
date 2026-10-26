//
//  UploadView.swift
//  kgeoScan
//
//  녹화 폴더 압축 → upload.py 전송(진행률) → status.py 폴링(단계 표시) → 결과 페이지 열기.
//  (Stray Scanner 포크에 추가된 파일)
//

import SwiftUI
import Combine

@MainActor
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

    let directory: URL
    private var runTask: Task<Void, Never>?
    private var zipObserver: AnyCancellable?

    nonisolated init(directory: URL) {
        self.directory = directory
        self.meta = ScanMeta.load(from: directory)
            ?? ScanMeta(title: directory.lastPathComponent, note: "", mode: .home,
                        serverBase: KgeoDefaults.storedServerBase)
    }

    var isRunning: Bool { errorMessage == nil && stage != .idle && stage != .done }
    var hasPreviousUpload: Bool { meta.upload != nil }
    var endpoints: ServerEndpoints? { ServerEndpoints(string: meta.serverBase) }

    var resultURL: URL? {
        guard let endpoints = endpoints else { return nil }
        if let saved = meta.upload?.resultUrl, let url = URL(string: saved) { return url }
        return endpoints.resultURL(sceneItemId: status?.sceneItemId ?? meta.upload?.sceneItemId)
    }

    func start(forceReupload: Bool = false) {
        runTask?.cancel()
        errorMessage = nil
        pollError = nil
        runTask = Task { await run(forceReupload: forceReupload) }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if stage == .uploading {
            UploadClient.shared.cancelAll()
        }
        stage = .idle
    }

    /// 화면을 떠날 때: 폴링만 멈춘다. 진행 중인 전송은 백그라운드 세션이 이어서 끝내고 meta.json 에 기록한다.
    func stopPolling() {
        runTask?.cancel()
        runTask = nil
    }

    private func fail(_ message: String) {
        errorMessage = message
    }

    private func run(forceReupload: Bool) async {
        guard let endpoints = endpoints else {
            fail("서버 주소가 올바르지 않습니다: \(meta.serverBase)")
            return
        }

        // 이미 올린 스캔이면 상태 조회만 다시 한다
        if !forceReupload, let previous = meta.upload, previous.status != "failed",
           ServerEndpoints(string: previous.server)?.normalized == endpoints.normalized {
            stage = .processing
            await poll(endpoints: endpoints, jobId: previous.jobId)
            return
        }

        if meta.fix == nil {
            if let fix = LocationService.shared.snapshot() {
                meta.fix = fix
                try? meta.save(to: directory)
            } else {
                stage = .idle
                fail("위치 정보가 없습니다. 위치 권한을 허용하고 GPS 가 잡힌 뒤 다시 시도하세요.")
                return
            }
        }

        var zipURL: URL?
        var bodyURL: URL?
        defer {
            if let z = zipURL { try? FileManager.default.removeItem(at: z) }
            if let b = bodyURL { try? FileManager.default.removeItem(at: b) }
        }

        do {
            // 1. 압축
            stage = .zipping
            zipFraction = 0
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
            try Task.checkCancellation()

            // 2. 업로드
            stage = .uploading
            bytesSent = 0
            bytesTotal = ZipPackager.fileSize(zip)
            var body = MultipartBody()
            body.addField("title", meta.title)
            body.addField("note", meta.note)
            body.addField("mode", "stray")
            body.addField("scan_mode", meta.mode.rawValue)
            body.addField("app", "kgeoScan \(KgeoDefaults.appVersion)")
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
            var request = URLRequest(url: endpoints.uploadURL)
            request.httpMethod = "POST"
            request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (code, data) = try await UploadClient.shared.upload(
                request: request, bodyFile: bodyFile, taskDescription: directory.path
            ) { [weak self] sent, total in
                Task { @MainActor in
                    self?.bytesSent = sent
                    if total > 0 { self?.bytesTotal = total }
                }
            }
            let jobId = try UploadClient.parseUploadReply(code: code, data: data)
            meta.upload = UploadRecord(server: endpoints.normalized, jobId: jobId, uploadedAt: Date(),
                                       status: "pending", step: 0)
            try? meta.save(to: directory)
            if Task.isCancelled { return }

            // 3. 서버 처리
            stage = .processing
            await poll(endpoints: endpoints, jobId: jobId)
        } catch is CancellationError {
            stage = .idle
        } catch let error as URLError where error.code == .cancelled {
            stage = .idle
        } catch {
            zipObserver = nil
            fail(error.localizedDescription)
        }
    }

    private func poll(endpoints: ServerEndpoints, jobId: String) async {
        while !Task.isCancelled {
            do {
                let s = try await UploadClient.fetchStatus(endpoints.statusURL(jobId: jobId))
                status = s
                pollError = nil
                if meta.upload?.jobId == jobId {
                    meta.upload?.status = s.status
                    meta.upload?.step = s.step
                    meta.upload?.stepName = s.stepName
                    meta.upload?.message = s.message
                    if let id = s.sceneItemId, !id.isEmpty { meta.upload?.sceneItemId = id }
                    if let glb = s.glbUrl, !glb.isEmpty { meta.upload?.glbUrl = glb }
                }
                if s.isDone {
                    meta.upload?.resultUrl = endpoints.resultURL(sceneItemId: s.sceneItemId).absoluteString
                    try? meta.save(to: directory)
                    stage = .done
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
                    Text("\(megabytes(vm.bytesSent)) / \(megabytes(vm.bytesTotal)) MB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                stepRow("3. 서버 처리", stage: .processing)
                if let s = vm.status, vm.stage >= .processing {
                    Text(statusLine(s))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let e = vm.pollError {
                    Text("상태 조회 오류: \(e)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if let e = vm.errorMessage {
                    Text(e).foregroundColor(.red)
                }
            }

            Section {
                if vm.stage == .done {
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
