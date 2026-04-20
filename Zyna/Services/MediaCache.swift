//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import MatrixRustSDK

/// Two-tier image cache: NSCache (memory) → Caches/ (disk) → SDK fetch.
///
/// Thread-safe: `cachedImage(for:)` returns synchronously from memory
/// — safe to call from Texture's background node init. Async methods
/// check disk then network, deduplicating in-flight requests so
/// multiple cells for the same mxc URL share one fetch Task.
final class MediaCache {

    static let shared = MediaCache()

    // MARK: - Memory

    private let memory = NSCache<NSString, UIImage>()

    // MARK: - Disk

    private let diskDir: URL
    private let ioQueue = DispatchQueue(label: "com.zyna.mediacache.io", qos: .utility)

    // MARK: - Request deduplication

    private let inflightLock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    // MARK: - Init

    private init() {
        memory.countLimit = 300

        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDir = caches.appendingPathComponent("zyna-thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: diskDir, withIntermediateDirectories: true
        )
    }

    // MARK: - Cache keys

    /// Cache entries are keyed by (url, requested pixel size). Without
    /// the size, a 44pt avatar fetched for a list cell would satisfy a
    /// 100pt detail-screen lookup — and the user sees an upscaled
    /// blurry image. Including the size means each display context
    /// gets its own properly-sized thumbnail.
    private static func cacheKey(url: String, size: Int) -> String {
        "\(url)|s\(size)"
    }

    private static func cacheKey(url: String, width: Int, height: Int) -> String {
        // Square requests share keys with the size-only variant so a
        // sync `cachedImage(forUrl:size:)` can hit on a thumbnail that
        // was originally fetched with width==height.
        if width == height { return cacheKey(url: url, size: width) }
        return "\(url)|\(width)x\(height)"
    }

    // MARK: - Synchronous (memory only, safe from any thread)

    /// Returns image from memory cache if available. Does not hit
    /// disk or network. Call from Texture node init for instant
    /// display without a Task.
    func cachedImage(forUrl url: String, size: Int) -> UIImage? {
        memory.object(forKey: Self.cacheKey(url: url, size: size) as NSString)
    }

    func image(for source: MediaSource, width: Int, height: Int) -> UIImage? {
        memory.object(
            forKey: Self.cacheKey(url: source.url(), width: width, height: height) as NSString
        )
    }

    // MARK: - Async (memory → disk → network)

    func loadThumbnail(
        source: MediaSource,
        width: UInt64,
        height: UInt64
    ) async -> UIImage? {
        let key = Self.cacheKey(url: source.url(), width: Int(width), height: Int(height))
        return await load(key: key) { client in
            try await client.getMediaThumbnail(
                mediaSource: source, width: width, height: height
            )
        }
    }

    func loadThumbnail(mxcUrl: String, size: Int) async -> UIImage? {
        guard let source = try? MediaSource.fromUrl(url: mxcUrl) else {
            return nil
        }
        let px = UInt64(size)
        let key = Self.cacheKey(url: mxcUrl, size: size)
        return await load(key: key) { client in
            try await client.getMediaThumbnail(
                mediaSource: source, width: px, height: px
            )
        }
    }

    // MARK: - Core pipeline

    private func load(
        key: String,
        fetch: @escaping (Client) async throws -> Data
    ) async -> UIImage? {
        let nsKey = key as NSString

        // 1. Memory
        if let cached = memory.object(forKey: nsKey) {
            return cached
        }

        // 2. Deduplicate: if another cell already started a fetch
        //    for this key, wait for its result instead of doubling.
        inflightLock.lock()
        if let existing = inflight[key] {
            inflightLock.unlock()
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            // 3. Disk
            if let diskImage = await readDisk(key: key) {
                memory.setObject(diskImage, forKey: nsKey)
                return diskImage
            }

            // 4. Network (SDK fetch)
            guard let client = MatrixClientService.shared.client else {
                return nil
            }
            do {
                let data = try await fetch(client)
                guard let image = UIImage(data: data) else { return nil }
                memory.setObject(image, forKey: nsKey)
                writeDisk(key: key, data: data)
                return image
            } catch {
                return nil
            }
        }
        inflight[key] = task
        inflightLock.unlock()

        let result = await task.value

        inflightLock.lock()
        inflight.removeValue(forKey: key)
        inflightLock.unlock()

        return result
    }

    // MARK: - Disk I/O

    private func diskPath(for key: String) -> URL {
        // SHA256-like short hash from key for safe filenames.
        let safe = key.data(using: .utf8)!
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(64)
        return diskDir.appendingPathComponent(String(safe))
    }

    private func readDisk(key: String) async -> UIImage? {
        let path = diskPath(for: key)
        return await withCheckedContinuation { cont in
            ioQueue.async {
                guard let data = try? Data(contentsOf: path),
                      let image = UIImage(data: data) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: image)
            }
        }
    }

    private func writeDisk(key: String, data: Data) {
        let path = diskPath(for: key)
        ioQueue.async {
            try? data.write(to: path, options: .atomic)
        }
    }
}
