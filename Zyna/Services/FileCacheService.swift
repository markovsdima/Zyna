//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

/// Persistent file cache in Application Support/zyna/media-cache/.
/// Files survive app restarts. Keyed by mxc:// URL.
final class FileCacheService {

    static let shared = FileCacheService()

    private var activeUserId: String?
    private var cacheDir: URL
    private var metadataURL: URL
    private let queue = DispatchQueue(label: "com.zyna.filecache", qos: .userInitiated)

    /// Maps mxc URL → CachedFile (filename on disk + original name).
    private var metadata: [String: CachedFile] = [:]

    private struct CachedFile: Codable {
        let diskName: String
        let originalFilename: String
    }

    private init() {
        activeUserId = UserDefaults.standard.string(forKey: "com.zyna.matrix.lastUserId")
        cacheDir = LocalDataProtection.mediaCacheDirectory(for: activeUserId)
        metadataURL = cacheDir.appendingPathComponent(".cache-metadata.json")

        _ = try? LocalDataProtection.createProtectedDirectory(
            at: cacheDir,
            protection: .sensitive,
            excludeFromBackup: true
        )

        loadMetadata()
    }

    // MARK: - Public

    /// Returns local file URL if cached, nil otherwise.
    func cachedURL(for source: MediaSource) -> URL? {
        queue.sync {
            guard let entry = metadata[source.url()] else { return nil }
            let url = cacheDir.appendingPathComponent(entry.diskName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Downloads file from Matrix, caches it, returns local URL.
    /// Calls `onProgress` on main queue with 0.0–1.0 (or -1 for
    /// indeterminate when SDK doesn't report progress).
    func downloadFile(
        source: MediaSource,
        filename: String,
        mimetype: String?,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        // Check cache first
        if let cached = cachedURL(for: source) {
            return cached
        }

        guard let client = MatrixClientService.shared.client else {
            throw FileCacheError.noClient
        }

        // Indeterminate progress — SDK doesn't give per-byte callbacks
        await MainActor.run { onProgress(-1) }

        let handle = try await client.getMediaFile(
            mediaSource: source,
            filename: filename,
            mimeType: mimetype ?? "application/octet-stream",
            useCache: true,
            tempDir: nil
        )

        let tempPath = try handle.path()
        let tempURL = URL(fileURLWithPath: tempPath)

        // Generate stable disk name from mxc URL
        let ext = (filename as NSString).pathExtension
        let diskName = stableFilename(for: source.url(), ext: ext)
        let destURL = queue.sync { cacheDir.appendingPathComponent(diskName) }

        // Persist: copy from SDK temp → our cache
        let persisted = (try? handle.persist(path: destURL.path)) ?? false
        if !persisted {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
        }
        try? LocalDataProtection.applyProtection(to: destURL, protection: .sensitive)

        let entry = CachedFile(diskName: diskName, originalFilename: filename)
        queue.sync {
            metadata[source.url()] = entry
        }
        saveMetadata()

        await MainActor.run { onProgress(1.0) }

        return destURL
    }

    /// Original filename for a cached source (for share sheets).
    func originalFilename(for source: MediaSource) -> String? {
        queue.sync { metadata[source.url()]?.originalFilename }
    }

    func activate(userId: String?) {
        queue.sync {
            guard activeUserId != userId else { return }
            activeUserId = userId
            cacheDir = LocalDataProtection.mediaCacheDirectory(for: userId)
            metadataURL = cacheDir.appendingPathComponent(".cache-metadata.json")
            metadata.removeAll()
            _ = try? LocalDataProtection.createProtectedDirectory(
                at: cacheDir,
                protection: .sensitive,
                excludeFromBackup: true
            )
            loadMetadata()
        }
    }

    /// Removes all cached files and metadata. Call on logout.
    func clearAll(userId: String? = nil) {
        queue.sync {
            metadata.removeAll()
        }
        let dir = LocalDataProtection.mediaCacheDirectory(for: userId ?? activeUserId)
        try? FileManager.default.removeItem(at: dir)
        _ = try? LocalDataProtection.createProtectedDirectory(
            at: dir,
            protection: .sensitive,
            excludeFromBackup: true
        )
    }

    // MARK: - Private

    private func stableFilename(for mxcUrl: String, ext: String) -> String {
        var hash: UInt64 = 5381
        for byte in mxcUrl.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let name = String(format: "%016llx", hash)
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let dict = try? JSONDecoder().decode(
                [String: CachedFile].self, from: data)
        else { return }
        metadata = dict
    }

    private func saveMetadata() {
        queue.async { [weak self] in
            guard let self else { return }
            let dict = self.metadata
            guard let data = try? JSONEncoder().encode(dict) else { return }
            try? LocalDataProtection.writeProtectedData(
                data,
                to: self.metadataURL,
                protection: .sensitive
            )
        }
    }
}

enum FileCacheError: Error {
    case noClient
}
