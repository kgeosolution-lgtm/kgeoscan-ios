//
//  SessionRow.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/15/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//
//  kgeoScan 변경: 제목(스캔 이름)과 업로드 상태 배지.
//

import SwiftUI

struct SessionRow: View {
    var session: Recording

    var body: some View {
        let duration = String(format: "%d초", Int(round(session.duration)))
        let meta = session.directoryPath().flatMap { ScanMeta.load(from: $0) }
        let badge = uploadBadge(meta)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle())
                    .multilineTextAlignment(.leading)
                Text(subtitle(meta: meta, duration: duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
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

    private func rowTitle() -> String {
        if let name = session.name, !name.isEmpty {
            return name
        }
        return sessionDate()
    }

    private func subtitle(meta: ScanMeta?, duration: String) -> String {
        var parts = [sessionDate(), duration]
        if let meta = meta {
            parts.append(meta.mode.label)
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

    private func uploadBadge(_ meta: ScanMeta?) -> (text: String, color: Color) {
        guard let upload = meta?.upload else { return ("미업로드", .gray) }
        switch upload.status {
        case "done": return ("완료", .green)
        case "failed": return ("실패", .red)
        default: return ("처리 중", .orange)
        }
    }
}
