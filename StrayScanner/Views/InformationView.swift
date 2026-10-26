//
//  InformationView.swift
//  StrayScanner
//
//  Created by Kenneth Blomqvist on 2/28/21.
//  Copyright © 2021 Stray Robots. All rights reserved.
//
//  kgeoScan 변경: 한국어 안내, 출처(Stray Scanner, MIT) 표기.
//

import SwiftUI

struct InformationView: View {
    let paddingLeftRight: CGFloat = 15
    let paddingTextTop: CGFloat = 10

    var body: some View {
        ZStack {
            Color("BackgroundColor").ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading) {
                    Text("kgeoScan").font(.title)
                        .fontWeight(.bold)
                    Text("버전 \(KgeoDefaults.appVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Group {
                        bodyText("""
LiDAR 아이폰으로 깊이·영상·자세를 녹화하고, 제목만 적으면 kgeodata.com 서버로 올려 3D 스캔(메시·사진 텍스처·LAS·Scene 서비스)을 자동으로 만드는 앱입니다.
""")
                        heading("사용 순서")
                        bodyText("""
1. '새 스캔' — 제목, 비고, 모드(홈스캔/현장조사)를 적습니다. GPS 와 나침반이 잡힐 때까지 잠시 기다립니다.
2. '녹화 화면으로' — 빨간 버튼을 누르는 순간 그 자리가 원점, 카메라가 향한 방향이 기준 방위가 됩니다. 천천히 움직이며 대상을 여러 방향에서 비춥니다.
3. 버튼을 다시 눌러 끝내면 자동으로 압축·업로드되고 서버 처리 단계가 표시됩니다. 끝나면 '결과 보기'로 지도에서 확인합니다.
""")
                        heading("데이터")
                        bodyText("""
녹화 폴더는 Stray Scanner 형식 그대로입니다 (rgb.mp4, depth/, confidence/, odometry.csv, imu.csv, camera_matrix.csv). 여기에 meta.json(제목·모드·위치·방위·업로드 결과)이 더해집니다. 파일 앱 > 나의 iPhone > kgeoScan 에서 폴더를 직접 꺼낼 수도 있고, 각 스캔의 '공유 (zip)' 으로 내보낼 수도 있습니다.
""")
                    }
                    Group {
                        heading("출처")
                        bodyText("이 앱은 Stray Robots 의 오픈소스 Stray Scanner (MIT 라이선스) 를 포크해 만들었습니다. 녹화 코어는 원본과 같고, 설정 화면·위치 기록·서버 업로드가 추가됐습니다.")
                        link(text: "kgeoScan 소스 (GitHub)", destination: "https://github.com/kgeosolution-lgtm/kgeoscan-ios")
                        link(text: "Stray Scanner 원본 (GitHub)", destination: "https://github.com/strayrobots/scanner")
                        link(text: "kgeodata.com 3D 스캔 지도", destination: "https://kgeodata.com/app/3dscan/")
                    }
                    Group {
                        heading("고지")
                        bodyText("Copyright 2023 Stray Robots, Inc. (MIT License)\n이 소프트웨어는 있는 그대로 제공되며, 사용으로 인한 어떤 책임도 지지 않습니다.")
                        Spacer()
                    }
                }.padding(.all, paddingLeftRight)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .fontWeight(.bold)
            .padding(.top, 20)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .multilineTextAlignment(.leading)
            .lineSpacing(1.25)
            .padding(.top, paddingTextTop)
    }

    private func link(text: String, destination: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundColor(Color.blue)
            .padding(.top, paddingTextTop)
            .onTapGesture {
                let url = URL.init(string: destination)
                guard let destinationUrl = url else { return }
                UIApplication.shared.open(destinationUrl)
            }
    }
}

struct InformationView_Previews: PreviewProvider {
    static var previews: some View {
        InformationView()
    }
}
