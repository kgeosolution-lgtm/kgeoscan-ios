//
//  SessionList.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/15/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//
//  kgeoScan 변경: NavigationStack 으로 '새 스캔 → 설정 → 녹화 → 업로드' 흐름을 잇고, 설정 화면·스와이프 삭제를 더했다.
//

import SwiftUI
import CoreData

/// 새 스캔 흐름의 화면들
enum ScanRoute: Hashable {
    case setup
    case record(ScanMeta)
    case preview(URL)
    case upload(URL)
    case settings
}

class SessionListViewModel: ObservableObject {
    private var dataContext: NSManagedObjectContext?
    @Published var sessions: [Recording] = []

    init() {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        dataContext = appDelegate.persistentContainer.viewContext
        self.sessions = []
        NotificationCenter.default.addObserver(self, selector: #selector(sessionsChanged), name: NSNotification.Name("sessionsChanged"), object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func fetchSessions() {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let fetched: [NSManagedObject] = try dataContext?.fetch(request) ?? []
            sessions = fetched.map { session in
                return session as! Recording
            }
        } catch let error as NSError {
            print("Something went wrong. Error: \(error), \(error.userInfo)")
        }
    }

    /// 스와이프 삭제: 녹화 파일과 항목을 함께 지운다
    func delete(at offsets: IndexSet) {
        for index in offsets {
            guard index < sessions.count else { continue }
            let recording = sessions[index]
            recording.deleteFiles()
            dataContext?.delete(recording)
        }
        do {
            try dataContext?.save()
        } catch let error as NSError {
            print("Could not delete recording. \(error), \(error.userInfo)")
        }
        fetchSessions()
    }

    @objc func sessionsChanged() {
        fetchSessions()
    }
}

struct SessionList: View {
    @ObservedObject var viewModel = SessionListViewModel()
    @State private var showingInfo = false
    @State private var path: [ScanRoute] = []
    @AppStorage(KgeoDefaults.skipPreviewKey) private var skipPreview: Bool = false

    /// 촬영이 끝나면: 미리보기(기본) 또는 바로 업로드. 촬영 화면은 경로에서 뺀다
    private func afterCapture(_ directory: URL) {
        path = skipPreview ? [.upload(directory)] : [.preview(directory)]
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading) {
                HStack {
                    Text("kgeoScan")
                        .foregroundColor(Color("TextColor"))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .padding([.top, .leading], 15.0)
                    Spacer()
                    Button(action: {
                        path.append(.settings)
                    }, label: {
                        Image(systemName: "gearshape")
                            .resizable()
                            .frame(width: 25, height: 25, alignment: .center)
                            .padding(.top, 17)
                            .padding(.trailing, 16)
                            .foregroundColor(Color("TextColor"))
                    })
                    Button(action: {
                        showingInfo.toggle()
                    }, label: {
                        Image(systemName: "info.circle")
                            .resizable()
                            .frame(width: 25, height: 25, alignment: .center)
                            .padding(.top, 17)
                            .padding(.trailing, 20)
                            .foregroundColor(Color("TextColor"))
                    }).sheet(isPresented: $showingInfo) {
                        InformationView()
                    }
                }

                if !viewModel.sessions.isEmpty {
                    List {
                        ForEach(viewModel.sessions, id: \.objectID) { recording in
                            NavigationLink(destination: SessionDetailView(recording: recording)) {
                                SessionRow(session: recording)
                            }
                        }
                        .onDelete { offsets in
                            viewModel.delete(at: offsets)
                        }
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    Spacer()
                    Text("아직 스캔이 없습니다.\n'새 스캔'을 눌러 녹화하면 여기에 나타납니다.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40.0)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }

                HStack {
                    Spacer()
                    Button(action: {
                        path.append(.setup)
                    }, label: {
                        Label("새 스캔", systemImage: "plus.viewfinder")
                            .font(.title3)
                            .padding(20)
                            .background(Color("TextColor"))
                            .foregroundColor(Color("LightColor"))
                            .cornerRadius(35)
                            .padding(20)
                    })
                    Spacer()
                }
            }
            .navigationBarHidden(true)
            .background(Color("BackgroundColor").ignoresSafeArea())
            .navigationDestination(for: ScanRoute.self) { route in
                switch route {
                case .setup:
                    ScanSetupView { meta in
                        path.append(.record(meta))
                    }
                case .record(let meta):
                    RecordScreen(meta: meta) { directory in
                        afterCapture(directory)
                    }
                case .preview(let directory):
                    PreviewView(directory: directory, context: .afterCapture,
                                onUpload: { path = [.upload(directory)] },
                                onRetake: { fresh in path = [.setup, .record(fresh)] },
                                onLater: { path = [] })
                case .upload(let directory):
                    UploadView(directory: directory)
                case .settings:
                    SettingsView()
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    viewModel.fetchSessions()
                }
                let delegate = UIApplication.shared.delegate as! AppDelegate
                delegate.appDaemon?.removeDeletedEntries()
            }
        }
        .background(Color("BackgroundColor").edgesIgnoringSafeArea(.all))
    }
}
