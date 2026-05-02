//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit

// MARK: - Protocol

protocol ScanDraftStorageService {
    func createDraft() throws -> UUID
    func writeOriginalPage(
        draftId: UUID,
        pageIndex: Int,
        image: UIImage,
        quad: Quad<VisionSpace>?
    ) throws -> UUID
    func writeCorrectedImage(pageId: UUID, image: UIImage) throws
    func deletePage(pageId: UUID) throws
    func deleteDraft(draftId: UUID) throws
    func fetchActiveDraft() throws -> DraftInfo?
    func loadCorrectedImages(for draftId: UUID) throws -> [UIImage]
    func fetchDraftPageInfos(for draftId: UUID) throws -> [DraftPageInfo]
    func loadOriginalImage(pageId: UUID) throws -> UIImage?
}

struct DraftInfo {
    let id: UUID
    let createdAt: Date
    let pageCount: Int
}

struct DraftPageInfo {
    let pageId: UUID
    let pageIndex: Int
    let quad: Quad<VisionSpace>?
}

// MARK: - Errors

enum ScanDraftStorageError: LocalizedError {
    case imageEncodingFailed
    case draftNotFound(UUID)
    case pageNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Failed to encode scanned page"
        case .draftNotFound(let id):
            return "Scan draft not found: \(id.uuidString)"
        case .pageNotFound(let id):
            return "Scan draft page not found: \(id.uuidString)"
        }
    }
}

// MARK: - FileBackedScanDraftStorage

final class FileBackedScanDraftStorage: ScanDraftStorageService {

    private enum Constants {
        static let jpegQuality: CGFloat = 0.8
        static let rootFolder = "document-scanning/drafts"
        static let manifestFileName = "manifest.json"
    }

    private struct DraftManifest: Codable {
        var id: UUID
        var createdAt: Date
        var pages: [DraftPageManifest]
    }

    private struct DraftPageManifest: Codable {
        var id: UUID
        var pageIndex: Int
        var originalImagePath: String
        var correctedImagePath: String?
        var quad: CodableVisionQuad?
    }

    private struct CodableVisionQuad: Codable {
        var topLeftX: CGFloat
        var topLeftY: CGFloat
        var topRightX: CGFloat
        var topRightY: CGFloat
        var bottomRightX: CGFloat
        var bottomRightY: CGFloat
        var bottomLeftX: CGFloat
        var bottomLeftY: CGFloat

        init(_ quad: Quad<VisionSpace>) {
            topLeftX = quad.topLeft.x
            topLeftY = quad.topLeft.y
            topRightX = quad.topRight.x
            topRightY = quad.topRight.y
            bottomRightX = quad.bottomRight.x
            bottomRightY = quad.bottomRight.y
            bottomLeftX = quad.bottomLeft.x
            bottomLeftY = quad.bottomLeft.y
        }

        var quad: Quad<VisionSpace> {
            Quad<VisionSpace>(
                topLeft: CGPoint(x: topLeftX, y: topLeftY),
                topRight: CGPoint(x: topRightX, y: topRightY),
                bottomRight: CGPoint(x: bottomRightX, y: bottomRightY),
                bottomLeft: CGPoint(x: bottomLeftX, y: bottomLeftY)
            )
        }
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let queue = DispatchQueue(label: "com.zyna.document-scanning.drafts")

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let appSupport = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
            self.rootURL = appSupport
                .appendingPathComponent("zyna", isDirectory: true)
                .appendingPathComponent(Constants.rootFolder, isDirectory: true)
        }

        try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        excludeFromBackup(self.rootURL)
    }

    func createDraft() throws -> UUID {
        try queue.sync {
            let draftId = UUID()
            let dir = draftDirectoryURL(for: draftId)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest = DraftManifest(id: draftId, createdAt: Date(), pages: [])
            try saveManifest(manifest, to: dir)
            return draftId
        }
    }

    func writeOriginalPage(
        draftId: UUID,
        pageIndex: Int,
        image: UIImage,
        quad: Quad<VisionSpace>?
    ) throws -> UUID {
        try queue.sync {
            let dir = draftDirectoryURL(for: draftId)
            guard fileManager.fileExists(atPath: dir.path) else {
                throw ScanDraftStorageError.draftNotFound(draftId)
            }

            guard let data = image.jpegData(compressionQuality: Constants.jpegQuality) else {
                throw ScanDraftStorageError.imageEncodingFailed
            }

            let pageId = UUID()
            let fileName = "\(pageId.uuidString)_original.jpg"
            try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)

            var manifest = try loadManifest(from: dir)
            manifest.pages.append(DraftPageManifest(
                id: pageId,
                pageIndex: pageIndex,
                originalImagePath: fileName,
                correctedImagePath: nil,
                quad: quad.map(CodableVisionQuad.init)
            ))
            try saveManifest(manifest, to: dir)
            return pageId
        }
    }

    func writeCorrectedImage(pageId: UUID, image: UIImage) throws {
        try queue.sync {
            guard let location = try findPage(pageId: pageId) else {
                throw ScanDraftStorageError.pageNotFound(pageId)
            }

            guard let data = image.jpegData(compressionQuality: Constants.jpegQuality) else {
                throw ScanDraftStorageError.imageEncodingFailed
            }

            var manifest = location.manifest
            var page = manifest.pages[location.pageIndex]
            let fileName = "\(pageId.uuidString)_corrected.jpg"
            try data.write(to: location.draftURL.appendingPathComponent(fileName), options: .atomic)
            page.correctedImagePath = fileName
            manifest.pages[location.pageIndex] = page
            try saveManifest(manifest, to: location.draftURL)
        }
    }

    func deletePage(pageId: UUID) throws {
        try queue.sync {
            guard let location = try findPage(pageId: pageId) else { return }
            var manifest = location.manifest
            let page = manifest.pages[location.pageIndex]

            try? fileManager.removeItem(
                at: location.draftURL.appendingPathComponent(page.originalImagePath)
            )
            if let corrected = page.correctedImagePath {
                try? fileManager.removeItem(
                    at: location.draftURL.appendingPathComponent(corrected)
                )
            }

            manifest.pages.remove(at: location.pageIndex)
            try saveManifest(manifest, to: location.draftURL)
        }
    }

    func deleteDraft(draftId: UUID) throws {
        try queue.sync {
            let dir = draftDirectoryURL(for: draftId)
            guard fileManager.fileExists(atPath: dir.path) else { return }
            try fileManager.removeItem(at: dir)
        }
    }

    func fetchActiveDraft() throws -> DraftInfo? {
        try queue.sync {
            try allDraftManifests()
                .compactMap { _, manifest -> DraftInfo? in
                    let pageCount = manifest.pages.filter { $0.correctedImagePath != nil }.count
                    guard pageCount > 0 else { return nil }
                    return DraftInfo(
                        id: manifest.id,
                        createdAt: manifest.createdAt,
                        pageCount: pageCount
                    )
                }
                .sorted { $0.createdAt > $1.createdAt }
                .first
        }
    }

    func loadCorrectedImages(for draftId: UUID) throws -> [UIImage] {
        try queue.sync {
            let dir = draftDirectoryURL(for: draftId)
            guard fileManager.fileExists(atPath: dir.path) else {
                throw ScanDraftStorageError.draftNotFound(draftId)
            }

            let manifest = try loadManifest(from: dir)
            return manifest.pages
                .sorted { $0.pageIndex < $1.pageIndex }
                .compactMap { page in
                    guard let correctedPath = page.correctedImagePath else { return nil }
                    return UIImage(contentsOfFile: dir.appendingPathComponent(correctedPath).path)
                }
        }
    }

    func fetchDraftPageInfos(for draftId: UUID) throws -> [DraftPageInfo] {
        try queue.sync {
            let dir = draftDirectoryURL(for: draftId)
            guard fileManager.fileExists(atPath: dir.path) else {
                throw ScanDraftStorageError.draftNotFound(draftId)
            }

            let manifest = try loadManifest(from: dir)
            return manifest.pages
                .sorted { $0.pageIndex < $1.pageIndex }
                .map {
                    DraftPageInfo(
                        pageId: $0.id,
                        pageIndex: $0.pageIndex,
                        quad: $0.quad?.quad
                    )
                }
        }
    }

    func loadOriginalImage(pageId: UUID) throws -> UIImage? {
        try queue.sync {
            guard let location = try findPage(pageId: pageId) else {
                throw ScanDraftStorageError.pageNotFound(pageId)
            }
            let page = location.manifest.pages[location.pageIndex]
            let url = location.draftURL.appendingPathComponent(page.originalImagePath)
            return UIImage(contentsOfFile: url.path)
        }
    }

    // MARK: - Private

    private struct PageLocation {
        let draftURL: URL
        let manifest: DraftManifest
        let pageIndex: Int
    }

    private func draftDirectoryURL(for draftId: UUID) -> URL {
        rootURL.appendingPathComponent(draftId.uuidString, isDirectory: true)
    }

    private func manifestURL(in draftURL: URL) -> URL {
        draftURL.appendingPathComponent(Constants.manifestFileName)
    }

    private func loadManifest(from draftURL: URL) throws -> DraftManifest {
        let data = try Data(contentsOf: manifestURL(in: draftURL))
        return try JSONDecoder().decode(DraftManifest.self, from: data)
    }

    private func saveManifest(_ manifest: DraftManifest, to draftURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(in: draftURL), options: .atomic)
    }

    private func allDraftManifests() throws -> [(URL, DraftManifest)] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let manifest = try? loadManifest(from: url) else {
                return nil
            }
            return (url, manifest)
        }
    }

    private func findPage(pageId: UUID) throws -> PageLocation? {
        for (draftURL, manifest) in try allDraftManifests() {
            guard let index = manifest.pages.firstIndex(where: { $0.id == pageId }) else {
                continue
            }
            return PageLocation(draftURL: draftURL, manifest: manifest, pageIndex: index)
        }
        return nil
    }

    private func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
