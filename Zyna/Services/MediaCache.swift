//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import ImageIO
import CryptoKit
import MatrixRustSDK

/// Two-tier image cache: NSCache (memory) → Caches/ (disk) → SDK fetch.
///
/// Generic thumbnail requests keep their server-provided image data.
/// Chat bubbles use a dedicated display-derivative path that normalizes
/// every image to the exact pixel recipe the bubble will render.
final class MediaCache {

    struct BubbleImage {
        let image: UIImage
        let sourcePixelSize: CGSize
    }

    private final class Entry: NSObject {
        let image: UIImage
        let sourcePixelSize: CGSize

        init(image: UIImage, sourcePixelSize: CGSize) {
            self.image = image
            self.sourcePixelSize = sourcePixelSize
        }
    }

    private struct StoredRecord: Codable {
        let imageData: Data
        let sourcePixelWidth: Int
        let sourcePixelHeight: Int
    }

    private struct PreparedImage {
        let entry: Entry
        let diskData: Data
    }

    private actor InflightStore {
        private var tasks: [String: Task<Entry?, Never>] = [:]

        func task(
            for key: String,
            orInsert makeTask: @Sendable () -> Task<Entry?, Never>
        ) -> Task<Entry?, Never> {
            if let existing = tasks[key] {
                return existing
            }
            let task = makeTask()
            tasks[key] = task
            return task
        }

        func remove(for key: String) {
            tasks.removeValue(forKey: key)
        }
    }

    static let shared = MediaCache()

    // MARK: - Memory

    private let memory = NSCache<NSString, Entry>()

    // MARK: - Disk

    private let diskDir: URL
    private let ioQueue = DispatchQueue(label: "com.zyna.mediacache.io", qos: .utility)

    // MARK: - Request deduplication

    private let inflight = InflightStore()

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
        if width == height { return cacheKey(url: url, size: width) }
        return "\(url)|\(width)x\(height)"
    }

    private static func bubbleCacheKey(url: String, maxPixelWidth: Int, maxPixelHeight: Int) -> String {
        "\(url)|bubble-v2|\(maxPixelWidth)x\(maxPixelHeight)"
    }

    // MARK: - Synchronous (memory only, safe from any thread)

    /// Returns image from memory cache if available. Does not hit
    /// disk or network. Call from Texture node init for instant
    /// display without a Task.
    func cachedImage(forUrl url: String, size: Int) -> UIImage? {
        memory.object(forKey: Self.cacheKey(url: url, size: size) as NSString)?.image
    }

    func bubbleImage(for source: MediaSource, maxPixelWidth: Int, maxPixelHeight: Int) -> BubbleImage? {
        let key = Self.bubbleCacheKey(
            url: source.url(),
            maxPixelWidth: maxPixelWidth,
            maxPixelHeight: maxPixelHeight
        )
        guard let entry = memory.object(forKey: key as NSString) else {
            return nil
        }
        return BubbleImage(image: entry.image, sourcePixelSize: entry.sourcePixelSize)
    }

    // MARK: - Async (memory → disk → network)

    func loadThumbnail(
        source: MediaSource,
        width: UInt64,
        height: UInt64
    ) async -> UIImage? {
        let key = Self.cacheKey(url: source.url(), width: Int(width), height: Int(height))
        let entry = await load(key: key, fetch: { client in
            try await client.getMediaThumbnail(
                mediaSource: source, width: width, height: height
            )
        }, prepare: Self.prepareOriginalEntry(from:))
        return entry?.image
    }

    func loadThumbnail(mxcUrl: String, size: Int) async -> UIImage? {
        guard let source = try? MediaSource.fromUrl(url: mxcUrl) else {
            return nil
        }
        let px = UInt64(size)
        let key = Self.cacheKey(url: mxcUrl, size: size)
        let entry = await load(key: key, fetch: { client in
            try await client.getMediaThumbnail(
                mediaSource: source, width: px, height: px
            )
        }, prepare: Self.prepareOriginalEntry(from:))
        return entry?.image
    }

    func loadBubbleImage(
        source: MediaSource,
        maxPixelWidth: Int,
        maxPixelHeight: Int,
        knownAspectRatio: CGFloat?
    ) async -> BubbleImage? {
        let key = Self.bubbleCacheKey(
            url: source.url(),
            maxPixelWidth: maxPixelWidth,
            maxPixelHeight: maxPixelHeight
        )
        let fetchSize = Self.bubbleFetchPixelSize(
            maxPixelWidth: maxPixelWidth,
            maxPixelHeight: maxPixelHeight,
            knownAspectRatio: knownAspectRatio
        )
        let entry = await load(key: key, fetch: { client in
            try await client.getMediaThumbnail(
                mediaSource: source,
                width: UInt64(fetchSize.width),
                height: UInt64(fetchSize.height)
            )
        }, prepare: { data in
            Self.prepareBubbleEntry(
                from: data,
                maxPixelWidth: maxPixelWidth,
                maxPixelHeight: maxPixelHeight
            )
        })
        guard let entry else { return nil }
        return BubbleImage(image: entry.image, sourcePixelSize: entry.sourcePixelSize)
    }

    // MARK: - Core pipeline

    private func load(
        key: String,
        fetch: @escaping (Client) async throws -> Data,
        prepare: @escaping (Data) -> PreparedImage?
    ) async -> Entry? {
        let nsKey = key as NSString

        if let cached = memory.object(forKey: nsKey) {
            return cached
        }

        let task = await inflight.task(for: key) { [self, key] in
            Task<Entry?, Never> {
                let cacheKey = key as NSString
                if let diskEntry = await readDisk(key: key) {
                    memory.setObject(diskEntry, forKey: cacheKey)
                    return diskEntry
                }

                guard let client = MatrixClientService.shared.client else {
                    return nil
                }

                do {
                    let data = try await fetch(client)
                    guard let prepared = prepare(data) else { return nil }
                    memory.setObject(prepared.entry, forKey: cacheKey)
                    writeDisk(key: key, data: prepared.diskData)
                    return prepared.entry
                } catch {
                    return nil
                }
            }
        }

        let result = await task.value

        await inflight.remove(for: key)

        return result
    }

    // MARK: - Image preparation

    private static func prepareOriginalEntry(from data: Data) -> PreparedImage? {
        guard let image = UIImage(data: data) else { return nil }
        let sourcePixelSize = pixelSize(for: image)
        let diskData = encodeStoredRecord(imageData: data, sourcePixelSize: sourcePixelSize) ?? data
        return PreparedImage(
            entry: Entry(image: image, sourcePixelSize: sourcePixelSize),
            diskData: diskData
        )
    }

    private static func prepareBubbleEntry(
        from data: Data,
        maxPixelWidth: Int,
        maxPixelHeight: Int
    ) -> PreparedImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let sourcePixelSize = sourcePixelSize(from: imageSource)
            ?? pixelSize(for: UIImage(data: data))
        guard sourcePixelSize.width > 0,
              sourcePixelSize.height > 0 else {
            return nil
        }

        let targetPixelSize = bubbleTargetPixelSize(
            sourcePixelSize: sourcePixelSize,
            maxPixelWidth: maxPixelWidth,
            maxPixelHeight: maxPixelHeight
        )
        let fillPixelSize = aspectFillPixelSize(
            sourcePixelSize: sourcePixelSize,
            targetPixelSize: targetPixelSize
        )
        let maxThumbnailPixelSize = max(
            1,
            Int(ceil(max(fillPixelSize.width, fillPixelSize.height)))
        )

        let baseImage = downsampledImage(
            from: imageSource,
            maxPixelSize: maxThumbnailPixelSize
        ) ?? UIImage(data: data)
        guard let baseImage else { return nil }

        let renderedImage = renderBubbleImage(
            baseImage,
            targetPixelSize: targetPixelSize
        )
        guard let displayData = encodedDisplayData(for: renderedImage) else {
            return nil
        }

        let diskData = encodeStoredRecord(
            imageData: displayData,
            sourcePixelSize: sourcePixelSize
        ) ?? displayData

        return PreparedImage(
            entry: Entry(image: renderedImage, sourcePixelSize: sourcePixelSize),
            diskData: diskData
        )
    }

    static func bubbleFetchPixelSize(
        maxPixelWidth: Int,
        maxPixelHeight: Int,
        knownAspectRatio: CGFloat?
    ) -> (width: Int, height: Int) {
        guard let knownAspectRatio,
              knownAspectRatio > 0 else {
            let dim = max(maxPixelWidth, maxPixelHeight)
            return (width: dim, height: dim)
        }

        let sourceSize = CGSize(width: knownAspectRatio, height: 1)
        let targetSize = bubbleTargetPixelSize(
            sourcePixelSize: sourceSize,
            maxPixelWidth: maxPixelWidth,
            maxPixelHeight: maxPixelHeight
        )
        let fillSize = aspectFillPixelSize(
            sourcePixelSize: sourceSize,
            targetPixelSize: targetSize
        )
        return (
            width: max(1, Int(ceil(fillSize.width))),
            height: max(1, Int(ceil(fillSize.height)))
        )
    }

    private static func bubbleTargetPixelSize(
        sourcePixelSize: CGSize,
        maxPixelWidth: Int,
        maxPixelHeight: Int
    ) -> CGSize {
        let width = CGFloat(max(1, maxPixelWidth))
        let aspectRatio = sourcePixelSize.width / sourcePixelSize.height
        guard aspectRatio > 0 else {
            return CGSize(width: width, height: CGFloat(max(1, maxPixelHeight)))
        }

        let naturalHeight = width / aspectRatio
        let height = min(naturalHeight, CGFloat(max(1, maxPixelHeight)))
        return CGSize(width: width, height: max(1, round(height)))
    }

    private static func aspectFillPixelSize(
        sourcePixelSize: CGSize,
        targetPixelSize: CGSize
    ) -> CGSize {
        guard sourcePixelSize.width > 0,
              sourcePixelSize.height > 0,
              targetPixelSize.width > 0,
              targetPixelSize.height > 0 else {
            return targetPixelSize
        }

        let scale = max(
            targetPixelSize.width / sourcePixelSize.width,
            targetPixelSize.height / sourcePixelSize.height
        )
        return CGSize(
            width: ceil(sourcePixelSize.width * scale),
            height: ceil(sourcePixelSize.height * scale)
        )
    }

    private static func downsampledImage(
        from imageSource: CGImageSource,
        maxPixelSize: Int
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func renderBubbleImage(
        _ image: UIImage,
        targetPixelSize: CGSize
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha(image)
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: targetPixelSize, format: format)
        return renderer.image { _ in
            image.draw(in: aspectFillRect(imageSize: image.size, bounds: CGRect(origin: .zero, size: targetPixelSize)))
        }
    }

    private static func encodedDisplayData(for image: UIImage) -> Data? {
        if hasAlpha(image) {
            return image.pngData()
        }
        return image.jpegData(compressionQuality: 0.85)
    }

    private static func hasAlpha(_ image: UIImage) -> Bool {
        guard let alphaInfo = image.cgImage?.alphaInfo else {
            return false
        }
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }

    private static func aspectFillRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }

    private static func sourcePixelSize(from imageSource: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }

        let width = CGFloat(truncating: widthNumber)
        let height = CGFloat(truncating: heightNumber)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        switch orientation {
        case 5, 6, 7, 8:
            return CGSize(width: height, height: width)
        default:
            return CGSize(width: width, height: height)
        }
    }

    private static func pixelSize(for image: UIImage?) -> CGSize {
        guard let image else { return .zero }
        return CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
    }

    private static func encodeStoredRecord(imageData: Data, sourcePixelSize: CGSize) -> Data? {
        let record = StoredRecord(
            imageData: imageData,
            sourcePixelWidth: Int(round(sourcePixelSize.width)),
            sourcePixelHeight: Int(round(sourcePixelSize.height))
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(record)
    }

    private static func decodeStoredRecord(from data: Data) -> Entry? {
        let decoder = PropertyListDecoder()
        if let record = try? decoder.decode(StoredRecord.self, from: data),
           let image = UIImage(data: record.imageData) {
            return Entry(
                image: image,
                sourcePixelSize: CGSize(
                    width: record.sourcePixelWidth,
                    height: record.sourcePixelHeight
                )
            )
        }

        guard let image = UIImage(data: data) else {
            return nil
        }
        return Entry(image: image, sourcePixelSize: pixelSize(for: image))
    }

    // MARK: - Disk I/O

    private func diskPath(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(filename)
    }

    private func readDisk(key: String) async -> Entry? {
        let path = diskPath(for: key)
        return await withCheckedContinuation { cont in
            ioQueue.async {
                guard let data = try? Data(contentsOf: path) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: Self.decodeStoredRecord(from: data))
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
