//
//  SessionRow.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/15/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//
//  kgeoScan 변경: 썸네일, 제목, 용량, 업로드 상태 배지.
//

import SwiftUI

struct SessionRow: View {
    var session: Recording

    var body: some View {
        let directory = session.directoryPath()?.absoluteURL.standardizedFileURL
        let meta = directory.flatMap { ScanMeta.load(from: $0) }
        let badge = SessionRow.uploadBadge(meta)
        HStack(spacing: 10) {
            thumbnail(directory: directory, meta: meta)
            VStack(alignment: .leading, spacing: 3) {
                Text(rowTitle())
                    .multilineTextAlignment(.leading)
                    .lineLimit(1)
                Text(subtitle(meta: meta))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(badge.text)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(badge.color.opacity(0.18))
                .foregroundColor(badge.color)
                .cornerRadius(8)
        }
    }

    @ViewBuilder
    private func thumbnail(directory: URL?, meta: ScanMeta?) -> some View {
        if let directory = directory, let file = meta?.thumbFile,
           let image = UIImage(contentsOfFile: directory.appendingPathComponent(file).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipped()
                .cornerRadius(6)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.2))
                Image(systemName: "cube.transparent").foregroundColor(.secondary)
            }
            .frame(width: 56, height: 56)
        }
    }

    private func rowTitle() -> String {
        if let name = session.name, !name.isEmpty {
            return name
        }
        return sessionDate()
    }

    private func subtitle(meta: ScanMeta?) -> String {
        var parts = [sessionDate(), String(format: "%d초", Int(round(session.duration)))]
        if let meta = meta {
            parts.append(meta.mode.label)
            if let bytes = meta.folderBytes {
                parts.append(SessionRow.formatBytes(bytes))
            }
            if let frames = meta.savedFrames {
                parts.append("\(frames) 프레임")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func sessionDate() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        if let created = session.createdAt {
            return dateFormatter.string(from: created)
        } else {
            return "Session"
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }

    /// 미업로드 / 업로드 중 / 처리 중 / 완료 / 실패
    static func uploadBadge(_ meta: ScanMeta?) -> (text: String, color: Color) {
        guard let meta = meta else { return ("미업로드", .gray) }
        if let upload = meta.upload {
            switch upload.status {
            case "done": return ("완료", .green)
            case "failed": return ("실패", .red)
            default: return ("처리 중", .orange)
            }
        }
        if let attempt = meta.lastAttempt {
            if attempt.finishedAt == nil { return ("업로드 중", .blue) }
            if attempt.error != nil { return ("실패", .red) }
        }
        return ("미업로드", .gray)
    }
}
