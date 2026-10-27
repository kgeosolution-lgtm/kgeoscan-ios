//
//  ZipPackager.swift
//  kgeoScan
//
//  녹화 폴더를 zip 으로 묶는다 (ZIPFoundation, SPM). (Stray Scanner 포크에 추가된 파일)
//  mp4·png·jpg 는 이미 압축돼 있어 저장(store) 방식으로 담기만 한다 — 빠르고 서버는 똑같이 읽는다.
//  zip 안에는 폴더 이름이 최상위로 들어간다 (<hash>/rgb.mp4 …). 서버는 odometry.csv(또는 poses.json)가 있는 폴더를 찾아 쓴다.
//  폰에서만 쓰는 폴더(preview/, heic/, checkpoint/)는 빼고 묶는다: 임시 폴더에 하드 링크로 똑같이 만든 뒤 zip.
//

import Foundation
import ZIPFoundation

enum ZipPackager {
    /// 업로드하지 않는 최상위 폴더: 미리보기, Object Capture 원본 HEIC, 체크포인트
    static let excludedTopLevel: Set<String> = ["preview", "heic", "checkpoint"]

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
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-staging-" + UUID().uuidString, isDirectory: true)
        let staging = stagingRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        try mirror(source, into: staging, depth: 0)
        try FileManager.default.zipItem(at: staging, to: destination, shouldKeepParent: true,
                                        compressionMethod: .none, progress: progress)
        return destination
    }

    /// 제외 폴더를 빼고 하드 링크(안 되면 복사)로 폴더 구조를 똑같이 만든다
    private static func mirror(_ source: URL, into target: URL, depth: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])
        for item in items {
            let name = item.lastPathComponent
            if depth == 0 && excludedTopLevel.contains(name) { continue }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let destination = target.appendingPathComponent(name, isDirectory: isDirectory)
            if isDirectory {
                try mirror(item, into: destination, depth: depth + 1)
            } else {
                do {
                    try fm.linkItem(at: item, to: destination)
                } catch {
                    try fm.copyItem(at: item, to: destination)
                }
            }
        }
    }

    /// 업로드될 바이트 (제외 폴더 빼고)
    static func uploadSize(of directory: URL) -> Int64 {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        var total: Int64 = 0
        for item in items where !excludedTopLevel.contains(item.lastPathComponent) {
            total += treeSize(item)
        }
        return total
    }

    private static func treeSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                                                  options: [.skipsHiddenFiles]) else { return 0 }
            var total: Int64 = 0
            for case let file as URL in enumerator {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }
        return Int64(values?.fileSize ?? 0)
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
