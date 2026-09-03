//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import UniformTypeIdentifiers

struct AttachmentFileRow: View {

    let item: AttachmentItem
    /// nil when idle; -1 for indeterminate.
    let progress: Double?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.appAccent.opacity(0.15))
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.appAccent)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename.isEmpty ? String(localized: "File") : item.filename)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if progress != nil {
                ProgressView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch item.kind {
        case .voice: return "mic.fill"
        case .audio: return "waveform"
        case .video: return "film"
        case .image: return "photo"
        case .file:
            let type = item.mimetype.flatMap { UTType(mimeType: $0) }
                ?? UTType(filenameExtension: (item.filename as NSString).pathExtension)
            if let type {
                if type.conforms(to: .pdf) { return "doc.richtext" }
                if type.conforms(to: .archive) { return "doc.zipper" }
                if type.conforms(to: .image) { return "photo" }
                if type.conforms(to: .audio) { return "waveform" }
                if type.conforms(to: .movie) { return "film" }
                if type.conforms(to: .text) || type.conforms(to: .plainText) { return "doc.text" }
            }
            return "doc"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let sizeBytes = item.sizeBytes {
            parts.append(Self.byteFormatter.string(fromByteCount: Int64(sizeBytes)))
        }
        if item.kind == .audio || item.kind == .voice {
            parts.append(AttachmentGridTile.durationText(item.durationSeconds))
        }
        parts.append(item.date.formatted(date: .abbreviated, time: .omitted))
        if let senderName = item.senderName, !senderName.isEmpty {
            parts.append(senderName)
        }
        return parts.joined(separator: " · ")
    }
}
