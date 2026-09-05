//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UniformTypeIdentifiers

/// Stable categories stored by the room attachments projection.
///
/// Keep these independent from the current SwiftUI tabs: presentation may
/// combine categories differently without rewriting the persisted index.
enum RoomAttachmentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case image
    case video
    case file
    case audio
    case voice

    var isVisual: Bool { self == .image || self == .video }

    var defaultFilename: String {
        switch self {
        case .image: return "image.jpg"
        case .video: return "video.mp4"
        case .file: return "file"
        case .audio: return "audio"
        case .voice: return "voice.m4a"
        }
    }

    var defaultMimetype: String {
        switch self {
        case .image: return "image/jpeg"
        case .video: return "video/mp4"
        case .file, .audio: return "application/octet-stream"
        case .voice: return "audio/mp4"
        }
    }
}

/// The one place where ambiguous Matrix message shapes are assigned to an
/// attachment category. Both the chat timeline and the attachments timeline
/// feed the same projection through this classifier.
enum RoomAttachmentClassifier {

    static func kindForFile(filename: String, mimetype: String?) -> RoomAttachmentKind {
        if isLikelyVideoFile(filename: filename, mimetype: mimetype) {
            return .video
        }
        if mimetype?.lowercased().hasPrefix("audio/") == true {
            return .audio
        }
        if let type = UTType(filenameExtension: (filename as NSString).pathExtension),
           type.conforms(to: .audio) {
            return .audio
        }
        return .file
    }

    static func kindForAudio(isVoice: Bool) -> RoomAttachmentKind {
        isVoice ? .voice : .audio
    }

    /// Used when migrating the already-materialized chat database. New SDK
    /// events are classified from their typed `MessageType` instead.
    static func kindForStoredMessage(
        contentType: String,
        filename: String?,
        mimetype: String?
    ) -> RoomAttachmentKind? {
        switch contentType {
        case "image": return .image
        case "video": return .video
        case "file": return kindForFile(filename: filename ?? "", mimetype: mimetype)
        case "audio": return .audio
        case "voice": return .voice
        default: return nil
        }
    }

    static func isLikelyVideoFile(filename: String, mimetype: String?) -> Bool {
        if mimetype?.lowercased().hasPrefix("video/") == true { return true }
        guard let type = UTType(filenameExtension: (filename as NSString).pathExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }
}
