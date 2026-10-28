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
    /// true 면 백그라운드 URLSession 으로 전송 (실험). 기본 false = 앱을 열어 둔 채 전송
    static let backgroundUploadKey = "kgeo.backgroundUpload"
    /// 전송 방식: system (기본, URLSession·HTTP/2) | http1 (HTTP/1.1 직접 연결, 예비) | background (실험)
    static let uploadTransportKey = "kgeo.uploadTransport"
    /// true 면 Wi-Fi 에서만 업로드 (셀룰러 차단, 기본 false)
    static let wifiOnlyKey = "kgeo.wifiOnly"
    /// 메시 오버레이 색 이름(red|orange|blue|green)과 불투명도(0.2~0.8)
    static let meshColorKey = "kgeo.meshColor"
    static let meshOpacityKey = "kgeo.meshOpacity"

    /// 저장된 전송 방식 (예전 '백그라운드' 토글과 호환). 기본은 시스템 URLSession —
    /// 2026-10-27 서버(IIS CGI 의 stderr 경고가 응답 헤더에 섞여 HTTP/2 스트림이 끊기던 문제)가 고쳐져 h2 로도 정상 응답한다.
    static var uploadTransport: String {
        if let raw = UserDefaults.standard.string(forKey: uploadTransportKey), !raw.isEmpty { return raw }
        return UserDefaults.standard.bool(forKey: backgroundUploadKey) ? "background" : "system"
    }
    /// 녹화가 끝나면 바로 업로드 화면으로 (기본 true)
    static let autoUploadKey = "kgeo.autoUpload"
    /// 위치 입력 방식: gps | map
    static let locationSourceKey = "kgeo.locationSource"
    /// 현장조사에서 물체 모드 (기본 켬)
    static let objectModeKey = "kgeo.objectMode"
    /// 녹화 뒤 미리보기 없이 바로 업로드 (기본 false = 미리보기 먼저)
    static let skipPreviewKey = "kgeo.skipPreview"
    /// 물체 모드 촬영 방식: objcap (고화질 사진, 기본) | video
    static let captureMethodKey = "kgeo.captureMethod"
    /// 현장조사 촬영 대상: object (물체 360°) | area (면, 정사영상) | plain (일반 영상)
    static let surveyStyleKey = "kgeo.surveyStyle"
    /// 면 촬영 대상: floor | wall | auto
    static let areaSurfaceKey = "kgeo.areaSurface"
    /// 면 촬영 정지 사진: silent (영상 프레임, 무음, 기본) | shutter (captureHighResolutionFrame, 셔터음)
    static let areaStillModeKey = "kgeo.areaStillMode"

    static var objectModeDefault: Bool {
        UserDefaults.standard.object(forKey: objectModeKey) == nil ? true : UserDefaults.standard.bool(forKey: objectModeKey)
    }

    static var autoUpload: Bool {
        UserDefaults.standard.object(forKey: autoUploadKey) == nil ? true : UserDefaults.standard.bool(forKey: autoUploadKey)
    }

    /// 녹화 용량 어림값: 저장 프레임당 바이트 (영상 + 깊이·신뢰도 PNG). 2026-10-27 컵 녹화 24 MB / 503 프레임
    static let bytesPerFrameEstimate: Int64 = 48_000

    /// 녹화 폴더에 쌓는 업로드 로그 파일
    static let uploadLogFileName = "upload.log"

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
