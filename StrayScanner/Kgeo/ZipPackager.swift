//
//  ZipPackager.swift
//  kgeoScan
//
//  녹화 폴더를 zip 으로 묶는다 (ZIPFoundation, SPM). (Stray Scanner 포크에 추가된 파일)
//  mp4·png 는 이미 압축돼 있어 저장(store) 방식으로 담기만 한다 — 빠르고 서버는 똑같이 읽는다.
//  zip 안에는 폴더 이름이 최상위로 들어간다 (<hash>/rgb.mp4 …). 서버는 odometry.csv 가 있는 폴더를 찾아 쓴다.
//

import Foundation
import ZIPFoundation

enum ZipPackager {
    static func zipURL(for directory: URL) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(directory.lastPathComponent, isDirectory: false)
            .appendingPathExtension("zip")
    }

    /// 동기 함수. 백그라운드 스레드에서 부른다. progress.fractionCompleted 로 진행률을 볼 수 있다.
    static func makeZip(of directory: URL, progress: Progress) throws -> URL {
        let source = directory.absoluteURL.standardizedFileURL
        let destination = zipURL(for: source)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.zipItem(at: source, to: destination, shouldKeepParent: true,
                                        compressionMethod: .none, progress: progress)
        return destination
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
