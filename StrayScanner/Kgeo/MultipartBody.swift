//
//  MultipartBody.swift
//  kgeoScan
//
//  multipart/form-data 본문을 임시 파일로 만든다. (Stray Scanner 포크에 추가된 파일)
//  zip 이 수백 MB 라 메모리에 올리지 않고 1 MB 씩 흘려 쓴다.
//

import Foundation

struct MultipartBody {
    let boundary: String = "kgeoScan-" + UUID().uuidString
    private var fields: [(name: String, value: String)] = []

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        fields.append((name: name, value: value))
    }

    /// 텍스트 필드 + 파일 하나를 outURL 에 쓴다.
    func write(fileField: String, fileURL: URL, fileName: String, mimeType: String, to outURL: URL) throws {
        try? FileManager.default.removeItem(at: outURL)
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil) else {
            throw UploadError.local("임시 파일을 만들 수 없습니다: \(outURL.lastPathComponent)")
        }
        let out = try FileHandle(forWritingTo: outURL)
        defer { try? out.close() }

        var head = Data()
        for field in fields {
            head.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n".utf8))
            head.append(Data(field.value.utf8))
            head.append(Data("\r\n".utf8))
        }
        head.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        try out.write(contentsOf: head)

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}
