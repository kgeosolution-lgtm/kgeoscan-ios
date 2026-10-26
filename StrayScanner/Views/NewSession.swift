//
//  NewSession.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//
//  kgeoScan 변경: 녹화 화면에 ScanMeta 를 넘기고, 녹화가 끝나면 폴더 URL 을 돌려받는다.
//

import SwiftUI

struct NavigationConfigurator: UIViewControllerRepresentable {
    var configure: (UINavigationController) -> Void = { _ in }

    func makeUIViewController(context: UIViewControllerRepresentableContext<NavigationConfigurator>) -> UIViewController {
        UIViewController()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: UIViewControllerRepresentableContext<NavigationConfigurator>) {
        if let nc = uiViewController.navigationController {
            self.configure(nc)
        }
    }
}

struct RecordSessionManager: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    let meta: ScanMeta
    let onFinished: (URL) -> Void

    func makeUIViewController(context: Context) -> RecordSessionViewController {
        let viewController = RecordSessionViewController(nibName: "RecordSessionView", bundle: nil)
        viewController.scanMeta = meta
        viewController.onFinished = onFinished
        viewController.setDismissFunction {
            presentationMode.wrappedValue.dismiss()
            viewController.setDismissFunction(Optional.none)
        }
        return viewController
    }

    func updateUIViewController(_ uiViewController: RecordSessionViewController, context: Context) {}
}

/// 녹화 화면. 녹화가 끝나면 onFinished(녹화 폴더) 가 불린다.
struct RecordScreen: View {
    let meta: ScanMeta
    let onFinished: (URL) -> Void

    var body: some View {
        RecordSessionManager(meta: meta, onFinished: onFinished)
            .padding(.vertical, 0.0)
            .navigationTitle(meta.title)
            .navigationBarTitleDisplayMode(.inline)
            .edgesIgnoringSafeArea(.all)
            .background(NavigationConfigurator { nc in
                nc.navigationBar.barTintColor = UIColor(named: "BackgroundColor")
            })
    }
}
