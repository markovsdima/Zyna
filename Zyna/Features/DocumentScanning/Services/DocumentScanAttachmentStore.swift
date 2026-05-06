//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit

struct DocumentScanAttachment {
    let fileURL: URL
    let previewImage: UIImage?
    let filename: String
    let pageCount: Int
    let byteCount: UInt64

    var accessibilityLabel: String {
        "Scanned document, \(pageCount) page\(pageCount == 1 ? "" : "s")"
    }
}

final class DocumentScanAttachmentStore {

    private enum Constants {
        static let rootFolder = "document-scanning/attachments"
        static let previewMaxDimension: CGFloat = 320
        static let maxFileAge: TimeInterval = 24 * 60 * 60
    }

    private let fileManager: FileManager
    private let rootURL: URL

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let caches = fileManager
                .urls(for: .cachesDirectory, in: .userDomainMask)
                .first!
            self.rootURL = caches
                .appendingPathComponent("zyna", isDirectory: true)
                .appendingPathComponent(Constants.rootFolder, isDirectory: true)
        }

        try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        cleanupExpiredFiles()
    }

    func writePDFData(_ data: Data, filename: String) throws -> URL {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let sanitized = sanitizedFilename(filename)
        let url = uniqueURL(for: sanitized)
        try data.write(to: url, options: .atomic)
        return url
    }

    func makePreviewImage(from image: UIImage) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > Constants.previewMaxDimension else { return image }

        let scale = Constants.previewMaxDimension / maxSide
        let targetSize = CGSize(
            width: floor(size.width * scale),
            height: floor(size.height * scale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func cleanupExpiredFiles() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Constants.maxFileAge)
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let parts = filename.components(separatedBy: disallowed)
        let sanitized = parts.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Scan.pdf" : sanitized
    }

    private func uniqueURL(for filename: String) -> URL {
        let baseURL = rootURL.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: baseURL.path) else { return baseURL }

        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let uniqueName = ext.isEmpty
            ? "\(name)-\(UUID().uuidString)"
            : "\(name)-\(UUID().uuidString).\(ext)"
        return rootURL.appendingPathComponent(uniqueName)
    }
}
