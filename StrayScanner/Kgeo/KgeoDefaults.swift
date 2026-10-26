//
//  KgeoDefaults.swift
//  kgeoScan
//
//  kgeoScan 공통 기본값. (Stray Scanner 포크에 추가된 파일)
//

import Foundation

enum KgeoDefaults {
    /// 업로드 백엔드 기본 주소. 이 아래에 upload.py / status.py 가 있다.
    static let serverBase = "https://kgeodata.com/app/3dupload"

    /// 서버 처리 상태 조회 주기 (초)
    static let pollIntervalSeconds: UInt64 = 3

    /// UserDefaults 키
    static let serverBaseKey = "kgeo.serverBase"
    static let modeKey = "kgeo.mode"

    /// 저장된 서버 주소 (없으면 기본값)
    static var storedServerBase: String {
        let s = UserDefaults.standard.string(forKey: serverBaseKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? serverBase : s
    }

    /// "0.1.0 (1)" 형태의 앱 버전
    static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}
