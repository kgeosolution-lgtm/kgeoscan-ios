//
//  SessionDetailView.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 12/30/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//
//  kgeoScan 변경: meta.json(제목·모드·위치·업로드 상태) 표시, 서버 업로드 버튼, 한국어.
//

import SwiftUI
import AVKit
import CoreData

class SessionDetailViewModel: ObservableObject {
    private var dataContext: NSManagedObjectContext?

    init() {
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        self.dataContext = appDelegate?.persistentContainer.viewContext
    }

    func title(recording: Recording) -> String {
        if let name = recording.name, !name.isEmpty {
            return name
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        if let created = recording.createdAt {
            return dateFormatter.string(from: created)
        }
        return "Recording"
    }

    func delete(recording: Recording) {
        recording.deleteFiles()
        self.dataContext?.delete(recording)
        do {
            try self.dataContext?.save()
        } catch let error as NSError {
            print("Could not save recording. \(error), \(error.userInfo)")
        }
    }
}

struct SessionDetailView: View {
    @ObservedObject var viewModel = SessionDetailViewModel()
    var recording: Recording
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showingShareSheet = false
    @State private var tempPackageURL: URL?
    @State private var isCreatingPackage = false
    @State private var player: AVPlayer?
    @State private var shareError: String?
    @State private var meta: ScanMeta?
    @State private var showDeleteConfirm = false

    let defaultUrl = URL(fileURLWithPath: "")

    private var directoryURL: URL? {
        recording.directoryPath()?.absoluteURL.standardizedFileURL
    }

    var body: some View {
        let width = UIScreen.main.bounds.size.width
        let height = width * 0.75
        ZStack {
            Color("BackgroundColor")
                .edgesIgnoringSafeArea(.all)
            ScrollView {
                VStack(spacing: 16) {
                    VideoPlayer(player: player ?? AVPlayer(url: defaultUrl))
                        .frame(width: width, height: height)
                        .padding(.horizontal, 0.0)
                        .onAppear {
                            if player == nil {
                                player = AVPlayer(url: recording.absoluteRgbPath() ?? defaultUrl)
                            }
                        }

                    infoBlock
                        .padding(.horizontal, 16)

                    if let directory = directoryURL {
                        NavigationLink(destination: UploadView(directory: directory, autoStart: false)) {
                            Label(uploadButtonTitle, systemImage: "icloud.and.arrow.up")
                                .font(.headline)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                                .background(Color("TextColor"))
                                .foregroundColor(Color("LightColor"))
                                .cornerRadius(12)
                        }
                        .padding(.horizontal, 16)
                    }

                    if let result = meta?.upload?.resultUrl, let url = URL(string: result) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("결과 보기 (웹)", systemImage: "safari")
                        }
                    }

                    HStack(spacing: 30) {
                        Button(action: shareItem) {
                            HStack {
                                if isCreatingPackage {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                Text(isCreatingPackage ? "준비 중…" : "공유 (zip)")
                                    .fixedSize()
                            }
                            .foregroundColor(isCreatingPackage ? .gray : .blue)
                            .frame(minWidth: 100)
                        }
                        .disabled(isCreatingPackage)

                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("삭제").foregroundColor(Color("DangerColor"))
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                }
            }
        }
        .navigationTitle(viewModel.title(recording: recording))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color("BackgroundColor"))
        .onAppear {
            meta = directoryURL.flatMap { ScanMeta.load(from: $0) }
        }
        .confirmationDialog("이 스캔을 삭제할까요? 녹화 파일도 함께 지워집니다.",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { deleteItem() }
            Button("취소", role: .cancel) {}
        }
        .sheet(isPresented: $showingShareSheet) {
            if let packageURL = tempPackageURL {
                ShareSheet(activityItems: [packageURL]) { activityType, completed, returnedItems, activityError in
                    DispatchQueue.main.async {
                        // Clean up temporary package after sharing
                        try? FileManager.default.removeItem(at: packageURL)
                        tempPackageURL = nil
                        showingShareSheet = false
                    }
                }
            }
        }
        .alert("내보내기 실패", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("확인", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "")
        }
    }

    private var uploadButtonTitle: String {
        guard let upload = meta?.upload else { return "서버에 업로드" }
        switch upload.status {
        case "done": return "업로드 상태 보기 (완료)"
        case "failed": return "다시 업로드 (실패)"
        default: return "업로드 상태 보기"
        }
    }

    @ViewBuilder
    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("녹화", value: recordingSummary)
            if let meta = meta {
                detailRow("모드", value: meta.mode.label)
                if !meta.note.isEmpty {
                    detailRow("비고", value: meta.note)
                }
                if let fix = meta.fix {
                    detailRow("위치", value: String(format: "%.6f, %.6f (±%.0f m)", fix.lat, fix.lon, fix.hAcc ?? -1))
                    detailRow("방위", value: fix.headingForUpload.map { String(format: "%.0f°", $0) } ?? "없음")
                } else {
                    detailRow("위치", value: "기록 없음")
                }
                if let upload = meta.upload {
                    detailRow("업로드", value: uploadSummary(upload))
                } else {
                    detailRow("업로드", value: "아직 안 함")
                }
            } else {
                detailRow("meta.json", value: "없음 (kgeoScan 이전 녹화)")
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .foregroundColor(Color("TextColor"))
            Spacer()
        }
    }

    private var recordingSummary: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let date = recording.createdAt.map { formatter.string(from: $0) } ?? "-"
        var text = "\(date) · \(Int(round(recording.duration)))초"
        if let frames = meta?.savedFrames {
            text += " · \(frames) 프레임"
        }
        return text
    }

    private func uploadSummary(_ upload: UploadRecord) -> String {
        var parts: [String] = ["작업 \(upload.jobId)"]
        if let status = upload.status { parts.append(status) }
        if let step = upload.step, let name = upload.stepName { parts.append("\(step)/7 \(name)") }
        if let id = upload.sceneItemId, !id.isEmpty { parts.append("scene \(id)") }
        return parts.joined(separator: " · ")
    }

    func deleteItem() {
        viewModel.delete(recording: recording)
        dismiss()
    }

    func shareItem() {
        isCreatingPackage = true

        Task {
            do {
                let packageURL = try await ShareUtility.createShareableArchive(for: recording)
                await MainActor.run {
                    tempPackageURL = packageURL
                    isCreatingPackage = false
                    showingShareSheet = true
                }
            } catch {
                await MainActor.run {
                    isCreatingPackage = false
                    shareError = error.localizedDescription
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil
    let completionWithItemsHandler: UIActivityViewController.CompletionWithItemsHandler?

    init(activityItems: [Any], completionHandler: UIActivityViewController.CompletionWithItemsHandler? = nil) {
        self.activityItems = activityItems
        self.completionWithItemsHandler = completionHandler
    }

    func makeUIViewController(context: UIViewControllerRepresentableContext<ShareSheet>) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        controller.completionWithItemsHandler = completionWithItemsHandler
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: UIViewControllerRepresentableContext<ShareSheet>) {
    }
}
