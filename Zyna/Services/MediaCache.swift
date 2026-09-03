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
        private var tasks: [String: (token: UInt64, task: Task<Entry?, Never>)] = [:]
        private var nextToken: UInt64 = 0

        /// Any waiter may remove the finished task with `removeIfCurrent`;
        /// the token guarantees a newer task that reused the key is left
        /// alone (plain removal by key could evict it and start a third load).
        func task(
            for key: String,
            orInsert makeTask: @Sendable () -> Task<Entry?, Never>
        ) -> (task: Task<Entry?, Never>, token: UInt64) {
            if let existing = tasks[key] {
                return (existing.task, existing.token)
            }
            nextToken += 1
            let task = makeTask()
            tasks[key] = (nextToken, task)
            return (task, nextToken)
        }

        func removeIfCurrent(_ key: String, token: UInt64) {
            guard tasks[key]?.token == token else { return }
            tasks.removeValue(forKey: key)
        }
    }

    static let shared = MediaCache()

    // MARK: - Memory

    private let memory = NSCache<NSString, Entry>()

    // MARK: - Disk

    /// Both guarded by `generationLock`; requests capture them as a
    /// `CacheContext` on entry (see "Account isolation").
    private var activeUserId: String?
    private var diskDir: URL
    private let ioQueue = DispatchQueue(label: "com.zyna.mediacache.io", qos: .utility)

    // MARK: - Request deduplication

    private let inflight = InflightStore()

    // MARK: - Init

    private init() {
        memory.countLimit = 300

        activeUserId = UserDefaults.standard.string(forKey: "com.zyna.matrix.lastUserId")
        diskDir = LocalDataProtection.thumbnailsDirectory(for: activeUserId)
        _ = try? LocalDataProtection.createProtectedDirectory(
            at: diskDir,
            protection: .sensitive,
            excludeFromBackup: true
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

    private static func previewBubbleCacheKey(
        previewIdentity: String,
        maxPixelWidth: Int,
        maxPixelHeight: Int
    ) -> String {
        "preview|\(previewIdentity)|bubble-v2|\(maxPixelWidth)x\(maxPixelHeight)"
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

    func previewBubbleImage(
        previewIdentity: String,
        maxPixelWidth: Int,
        maxPixelHeight: Int
    ) -> BubbleImage? {
        let key = Self.previewBubbleCacheKey(
            previewIdentity: previewIdentity,
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

    func loadPreviewBubbleImage(
        previewIdentity: String,
        imageData: Data,
        maxPixelWidth: Int,
        maxPixelHeight: Int
    ) async -> BubbleImage? {
        let key = Self.previewBubbleCacheKey(
            previewIdentity: previewIdentity,
            maxPixelWidth: maxPixelWidth,
            maxPixelHeight: maxPixelHeight
        )
        let entry = await loadPreparedLocal(
            key: key,
            data: imageData,
            prepare: { data in
                Self.prepareBubbleEntry(
                    from: data,
                    maxPixelWidth: maxPixelWidth,
                    maxPixelHeight: maxPixelHeight
                )
            }
        )
        guard let entry else { return nil }
        return BubbleImage(image: entry.image, sourcePixelSize: entry.sourcePixelSize)
    }

    // MARK: - Core pipeline

    private func load(
        key baseKey: String,
        fetch: @escaping (Client) async throws -> Data,
        prepare: @escaping (Data) -> PreparedImage?
    ) async -> Entry? {
        if let cached = memory.object(forKey: baseKey as NSString) {
            return cached
        }

        // Captured on entry, not inside the task: a task that first runs
        // after an account switch must still belong to the account that
        // asked. The in-flight key carries the generation, so a request of
        // the new account never joins this producer.
        let context = currentContext()
        let key = context.scoped(baseKey)

        let (task, token) = await inflight.task(for: key) { [self, baseKey, context] in
            Task<Entry?, Never> {
                if let diskEntry = await readDisk(key: baseKey, context: context) {
                    return publish(diskEntry, into: memory, key: baseKey, context: context) ? diskEntry : nil
                }

                guard let client = MatrixClientService.shared.client else {
                    return nil
                }

                do {
                    let data = try await fetch(client)
                    guard let prepared = prepare(data) else { return nil }
                    guard publish(prepared.entry, into: memory, key: baseKey, context: context) else {
                        return nil
                    }
                    writeDisk(key: baseKey, data: prepared.diskData, context: context)
                    return prepared.entry
                } catch {
                    return nil
                }
            }
        }

        let result = await task.value

        await inflight.removeIfCurrent(key, token: token)

        return result
    }

    private func loadPreparedLocal(
        key baseKey: String,
        data: Data,
        prepare: @escaping (Data) -> PreparedImage?
    ) async -> Entry? {
        let nsKey = baseKey as NSString

        if let cached = memory.object(forKey: nsKey) {
            return cached
        }

        let context = currentContext()
        let key = context.scoped(baseKey)

        let (task, token) = await inflight.task(for: key) { [self, data, baseKey, context] in
            Task<Entry?, Never> {
                if let cached = memory.object(forKey: baseKey as NSString) {
                    return cached
                }

                guard let prepared = prepare(data) else {
                    return nil
                }

                return publish(prepared.entry, into: memory, key: baseKey, context: context) ? prepared.entry : nil
            }
        }

        let result = await task.value

        await inflight.removeIfCurrent(key, token: token)

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

    private static func diskPath(for key: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(filename)
    }

    /// Account switch. Generation bump, memory clear and directory swap
    /// happen under one lock so no producer can publish in between; the
    /// directory itself is prepared on the I/O queue afterwards.
    func activate(userId: String?) {
        let directory = LocalDataProtection.thumbnailsDirectory(for: userId)
        generationLock.lock()
        cacheGeneration += 1
        memory.removeAllObjects()
        attachmentMemory.removeAllObjects()
        let changed = activeUserId != userId
        activeUserId = userId
        diskDir = directory
        generationLock.unlock()

        guard changed else { return }
        ioQueue.sync {
            _ = try? LocalDataProtection.createProtectedDirectory(
                at: directory,
                protection: .sensitive,
                excludeFromBackup: true
            )
        }
    }

    func clearAll(userId: String? = nil) {
        generationLock.lock()
        cacheGeneration += 1
        memory.removeAllObjects()
        attachmentMemory.removeAllObjects()
        let directory = LocalDataProtection.thumbnailsDirectory(for: userId ?? activeUserId)
        generationLock.unlock()

        ioQueue.sync {
            try? FileManager.default.removeItem(at: directory)
            _ = try? LocalDataProtection.createProtectedDirectory(
                at: directory,
                protection: .sensitive,
                excludeFromBackup: true
            )
        }
    }

    private func readDisk(key: String, context: CacheContext) async -> Entry? {
        let path = Self.diskPath(for: key, in: context.diskDir)
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

    /// Writes into the directory captured with the request, and only if the
    /// generation is still current when the I/O queue gets to it. `clearAll`
    /// bumps before it removes the directory on the same queue, so a write
    /// queued earlier either lands in the old directory (then removed) or
    /// is skipped.
    private func writeDisk(key: String, data: Data, context: CacheContext) {
        let path = Self.diskPath(for: key, in: context.diskDir)
        ioQueue.async { [self] in
            guard context.generation == currentCacheGeneration else { return }
            try? LocalDataProtection.writeProtectedData(
                data,
                to: path,
                protection: .sensitive
            )
        }
    }

    // MARK: - Account isolation

    /// What a request captures on entry. Publishing later checks the
    /// generation and targets this directory, never the current one, so a
    /// download that outlives a logout cannot land in the next account's
    /// caches. Both fields change together under `generationLock`.
    struct CacheContext {
        let generation: Int
        let diskDir: URL

        /// In-flight and demand keys carry the generation, so a consumer of
        /// the new account never joins a producer of the old one.
        func scoped(_ key: String) -> String {
            "g\(generation)|\(key)"
        }
    }

    private let generationLock = NSLock()
    private var cacheGeneration = 0

    private func currentContext() -> CacheContext {
        generationLock.lock()
        defer { generationLock.unlock() }
        return CacheContext(generation: cacheGeneration, diskDir: diskDir)
    }

    private var currentCacheGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return cacheGeneration
    }

    /// Memory publish, atomic with `activate`/`clearAll`: those clear and
    /// bump under the same lock, so a stale producer can neither slip in
    /// between the check and the insert nor publish after the clear.
    @discardableResult
    private func publish(
        _ entry: Entry,
        into cache: NSCache<NSString, Entry>,
        key: String,
        cost: Int? = nil,
        context: CacheContext
    ) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard context.generation == cacheGeneration else { return false }
        if let cost {
            cache.setObject(entry, forKey: key as NSString, cost: cost)
        } else {
            cache.setObject(entry, forKey: key as NSString)
        }
        return true
    }

    #if DEBUG
    /// Seams for `AttachmentsAutoDiagnostics`: run something right before a
    /// producer publishes, bump the generation, or evict memory tiers.
    var debugBeforePublishHook: (@Sendable () -> Void)?

    func debugBumpCacheGeneration() {
        generationLock.lock()
        cacheGeneration += 1
        generationLock.unlock()
    }

    func debugEvictMemory() {
        generationLock.lock()
        memory.removeAllObjects()
        attachmentMemory.removeAllObjects()
        generationLock.unlock()
    }
    #endif

    // MARK: - Attachments (room media grid)

    enum AttachmentFetchError: Error {
        case noClient
        /// Every consumer went away before the download started.
        case noDemand
    }

    private struct AttachmentLoadOutcome {
        let entry: Entry
        let stats: AttachmentFetchStats
    }

    private enum AttachmentLoadResult {
        case loaded(AttachmentLoadOutcome)
        case skippedNoDemand
        case failed
    }

    private struct FetchedBytes {
        let data: Data
        let queueMs: Double
        let fetchMs: Double
    }

    private actor AttachmentInflightStore {
        private var tasks: [String: (token: UInt64, task: Task<AttachmentLoadResult, Never>)] = [:]
        private var nextToken: UInt64 = 0

        /// `isOwner` marks the caller that started the task (for stats). Any
        /// waiter removes the finished task via `removeIfCurrent`, which is
        /// what lets a `.skippedNoDemand` retry start a fresh task instead
        /// of re-joining the finished one.
        func task(
            for key: String,
            orInsert makeTask: @Sendable () -> Task<AttachmentLoadResult, Never>
        ) -> (task: Task<AttachmentLoadResult, Never>, token: UInt64, isOwner: Bool) {
            if let existing = tasks[key] {
                return (existing.task, existing.token, false)
            }
            nextToken += 1
            let task = makeTask()
            tasks[key] = (nextToken, task)
            return (task, nextToken, true)
        }

        func removeIfCurrent(_ key: String, token: UInt64) {
            guard tasks[key]?.token == token else { return }
            tasks.removeValue(forKey: key)
        }
    }

    /// De-duplicates SDK fetches by `(generation, mxc, sdk key)` so two tile
    /// sizes, or a tile and the viewer, share one SDK call.
    private actor InflightDataStore {
        private var tasks: [String: (token: UInt64, task: Task<FetchedBytes, Error>)] = [:]
        private var nextToken: UInt64 = 0

        func task(
            for key: String,
            orInsert makeTask: @Sendable () -> Task<FetchedBytes, Error>
        ) -> (task: Task<FetchedBytes, Error>, token: UInt64, isOwner: Bool) {
            if let existing = tasks[key] {
                return (existing.task, existing.token, false)
            }
            nextToken += 1
            let task = makeTask()
            tasks[key] = (nextToken, task)
            return (task, nextToken, true)
        }

        func removeIfCurrent(_ key: String, token: UInt64) {
            guard tasks[key]?.token == token else { return }
            tasks.removeValue(forKey: key)
        }
    }

    /// Who still wants the bytes of a request. Consumers hold a ticket while
    /// they wait; a producer that reaches the gate with no tickets left skips
    /// the download instead of queueing stale work behind which visible
    /// tiles would starve.
    private actor AttachmentDemand {
        private var tickets: [String: Set<UUID>] = [:]

        func enter(_ key: String) -> UUID {
            let ticket = UUID()
            tickets[key, default: []].insert(ticket)
            return ticket
        }

        func leave(_ key: String, ticket: UUID) {
            guard var set = tickets[key] else { return }
            set.remove(ticket)
            if set.isEmpty {
                tickets.removeValue(forKey: key)
            } else {
                tickets[key] = set
            }
        }

        func hasDemand(_ key: String) -> Bool {
            !(tickets[key]?.isEmpty ?? true)
        }
    }

    /// Square tile derivatives. Separate from `memory` because that cache is
    /// count-limited and a grid holds far more entries than a chat does.
    private let attachmentMemory: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private let attachmentInflight = AttachmentInflightStore()
    private let attachmentBytes = InflightDataStore()
    private let attachmentDemand = AttachmentDemand()
    /// Bound concurrent SDK media calls per lane, held only around the call
    /// itself. Measured after relogin: two originals (4–7 MB) holding a shared
    /// 4-permit gate queued 22 thumbnail files for 6.5 s on average.
    private let attachmentThumbnailGate = AsyncSemaphore(permits: 3)
    private let attachmentOriginalGate = AsyncSemaphore(permits: 1)
    /// The viewer: a fast swipe through ten photos must not leave ten
    /// originals downloading at once (an SDK call cannot be cancelled once
    /// started). Two permits keep the current and the next one moving; the
    /// viewer also debounces before it starts a load.
    private let attachmentInteractiveGate = AsyncSemaphore(permits: 2)

    private func attachmentGate(for lane: AttachmentFetchLane) -> AsyncSemaphore {
        switch lane {
        case .thumbnail: return attachmentThumbnailGate
        case .original: return attachmentOriginalGate
        case .interactive: return attachmentInteractiveGate
        }
    }

    private static func attachmentKey(mxc: String, tilePixelSize: Int) -> String {
        "\(mxc)|att-v1|sq\(tilePixelSize)"
    }

    private static func attachmentCost(of entry: Entry) -> Int {
        let size = pixelSize(for: entry.image)
        return max(1, Int(size.width * size.height * 4))
    }

    /// Memory only; safe to call from a SwiftUI `init`.
    func cachedAttachmentThumbnail(mxc: String, tilePixelSize: Int) -> UIImage? {
        attachmentMemory.object(
            forKey: Self.attachmentKey(mxc: mxc, tilePixelSize: tilePixelSize) as NSString
        )?.image
    }

    /// Memory → disk → SDK. Bytes are fetched at most once per `(mxc, sdk key)`
    /// regardless of how many tile sizes ask for them. The caller's task
    /// cancellation withdraws its demand; the shared producer keeps running
    /// only while someone else still wants the result.
    func loadAttachmentThumbnail(
        _ request: AttachmentFetchRequest,
        tilePixelSize: Int,
        lane: AttachmentFetchLane = .thumbnail
    ) async -> AttachmentThumbnail? {
        let key = Self.attachmentKey(mxc: request.mxc, tilePixelSize: tilePixelSize)

        if let cached = attachmentMemory.object(forKey: key as NSString) {
            return AttachmentThumbnail(
                image: cached.image,
                sourcePixelSize: cached.sourcePixelSize,
                stats: AttachmentFetchStats(
                    tier: .memory, bytes: 0, queueMs: 0, fetchMs: 0, prepareMs: 0, request: request.label
                )
            )
        }

        let context = currentContext()
        let inflightKey = context.scoped(key)
        let demand = attachmentDemand
        let demandKey = context.scoped(request.bytesKey)
        let ticket = await demand.enter(demandKey)
        defer {
            Task { await demand.leave(demandKey, ticket: ticket) }
        }

        return await withTaskCancellationHandler {
            var attempt = 0
            while true {
                attempt += 1
                let (task, token, isOwner) = await attachmentInflight.task(for: inflightKey) { [self, key, request, tilePixelSize, lane, context] in
                    Task<AttachmentLoadResult, Never> {
                        await produceAttachmentThumbnail(
                            request, key: key, tilePixelSize: tilePixelSize, lane: lane, context: context
                        )
                    }
                }
                let result = await task.value
                // Removed by whoever finishes waiting, so a retry below can
                // never re-join this finished task.
                await attachmentInflight.removeIfCurrent(inflightKey, token: token)

                switch result {
                case .loaded(let outcome):
                    return AttachmentThumbnail(
                        image: outcome.entry.image,
                        sourcePixelSize: outcome.entry.sourcePixelSize,
                        stats: isOwner ? outcome.stats : outcome.stats.coalesced
                    )
                case .skippedNoDemand:
                    // Joined a producer that had already decided nobody was
                    // waiting. The finished task is gone from the store, so
                    // one more attempt starts a fresh producer.
                    if attempt < 2, !Task.isCancelled {
                        continue
                    }
                    return nil
                case .failed:
                    return nil
                }
            }
        } onCancel: {
            Task { await demand.leave(demandKey, ticket: ticket) }
        }
    }

    /// Full decrypted bytes of a source through the same de-duplication and
    /// demand accounting the grid uses, so a tile still downloading an
    /// original and the viewer opening on top of it share one SDK call.
    func loadFullContent(source: MediaSource) async throws -> Data {
        let request = AttachmentFetchRequest.fullContent(source: source)
        let context = currentContext()
        let demand = attachmentDemand
        let demandKey = context.scoped(request.bytesKey)
        let ticket = await demand.enter(demandKey)
        defer {
            Task { await demand.leave(demandKey, ticket: ticket) }
        }

        return try await withTaskCancellationHandler {
            var attempt = 0
            while true {
                attempt += 1
                do {
                    return try await fetchAttachmentBytes(request, lane: .interactive, context: context).bytes.data
                } catch AttachmentFetchError.noDemand where attempt < 2 && !Task.isCancelled {
                    continue
                }
            }
        } onCancel: {
            Task { await demand.leave(demandKey, ticket: ticket) }
        }
    }

    private func produceAttachmentThumbnail(
        _ request: AttachmentFetchRequest,
        key: String,
        tilePixelSize: Int,
        lane: AttachmentFetchLane,
        context: CacheContext
    ) async -> AttachmentLoadResult {
        if let diskEntry = await readDisk(key: key, context: context) {
            #if DEBUG
            debugBeforePublishHook?()
            #endif
            guard publish(
                diskEntry, into: attachmentMemory, key: key,
                cost: Self.attachmentCost(of: diskEntry), context: context
            ) else {
                return .failed
            }
            return .loaded(AttachmentLoadOutcome(
                entry: diskEntry,
                stats: AttachmentFetchStats(
                    tier: .disk, bytes: 0, queueMs: 0, fetchMs: 0, prepareMs: 0, request: request.label
                )
            ))
        }

        do {
            let fetched = try await fetchAttachmentBytes(request, lane: lane, context: context)

            let prepareStart = CACurrentMediaTime()
            guard let prepared = Self.prepareAttachmentEntry(
                from: fetched.bytes.data, tilePixelSize: tilePixelSize
            ) else {
                return .failed
            }
            let prepareMs = (CACurrentMediaTime() - prepareStart) * 1000

            // Account changed while this was downloading: drop the result
            // rather than publish it into the new account's caches.
            #if DEBUG
            debugBeforePublishHook?()
            #endif
            guard publish(
                prepared.entry, into: attachmentMemory, key: key,
                cost: Self.attachmentCost(of: prepared.entry), context: context
            ) else {
                return .failed
            }
            writeDisk(key: key, data: prepared.diskData, context: context)
            return .loaded(AttachmentLoadOutcome(
                entry: prepared.entry,
                stats: AttachmentFetchStats(
                    tier: fetched.isOwner ? .sdk : .coalesced,
                    bytes: fetched.isOwner ? fetched.bytes.data.count : 0,
                    queueMs: fetched.bytes.queueMs,
                    fetchMs: fetched.bytes.fetchMs,
                    prepareMs: prepareMs,
                    request: request.label
                )
            ))
        } catch AttachmentFetchError.noDemand {
            return .skippedNoDemand
        } catch {
            return .failed
        }
    }

    /// `isOwner` tells whether this call triggered the SDK fetch or joined
    /// one already in flight. Only the owner's bytes count as traffic.
    private func fetchAttachmentBytes(
        _ request: AttachmentFetchRequest,
        lane: AttachmentFetchLane,
        context: CacheContext
    ) async throws -> (bytes: FetchedBytes, isOwner: Bool) {
        let key = context.scoped(request.bytesKey)
        let gate = attachmentGate(for: lane)
        let (task, token, isOwner) = await attachmentBytes.task(for: key) { [self, key, request, gate] in
            Task<FetchedBytes, Error> {
                let meterEpoch = AttachmentFetchMeter.shared.currentEpoch()
                guard await attachmentDemand.hasDemand(key) else {
                    AttachmentFetchMeter.shared.skippedForLackOfDemand(epoch: meterEpoch)
                    throw AttachmentFetchError.noDemand
                }
                guard let client = MatrixClientService.shared.client else {
                    throw AttachmentFetchError.noClient
                }

                let queueStart = CACurrentMediaTime()
                await gate.acquire()
                let queueMs = (CACurrentMediaTime() - queueStart) * 1000
                let result: Result<FetchedBytes, Error>
                if await attachmentDemand.hasDemand(key) {
                    // Counted here, at the producer, so the number of SDK
                    // calls does not depend on which consumer survives.
                    let meter = AttachmentFetchMeter.shared
                    let label = request.label
                    let start = CACurrentMediaTime()
                    let epoch = meter.begin(label)
                    do {
                        let data: Data
                        switch request {
                        case .serverThumbnail(let source, let width, let height):
                            data = try await client.getMediaThumbnail(
                                mediaSource: source, width: width, height: height
                            )
                        case .fullContent(let source):
                            data = try await client.getMediaContent(mediaSource: source)
                        }
                        let fetchMs = (CACurrentMediaTime() - start) * 1000
                        meter.end(label, epoch: epoch, bytes: data.count, ms: fetchMs)
                        result = .success(FetchedBytes(data: data, queueMs: queueMs, fetchMs: fetchMs))
                    } catch {
                        meter.end(label, epoch: epoch, bytes: nil, ms: (CACurrentMediaTime() - start) * 1000)
                        result = .failure(error)
                    }
                } else {
                    AttachmentFetchMeter.shared.skippedForLackOfDemand(epoch: meterEpoch)
                    result = .failure(AttachmentFetchError.noDemand)
                }
                await gate.release()
                return try result.get()
            }
        }

        let outcome: Result<FetchedBytes, Error>
        do {
            outcome = .success(try await task.value)
        } catch {
            outcome = .failure(error)
        }
        await attachmentBytes.removeIfCurrent(key, token: token)
        return (try outcome.get(), isOwner)
    }

    /// Aspect-fill square at exactly `tilePixelSize`, decoded through ImageIO
    /// so a full-size original never becomes a full-size bitmap.
    private static func prepareAttachmentEntry(from data: Data, tilePixelSize: Int) -> PreparedImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let sourcePixelSize = sourcePixelSize(from: imageSource)
            ?? pixelSize(for: UIImage(data: data))
        guard sourcePixelSize.width > 0,
              sourcePixelSize.height > 0 else {
            return nil
        }

        let side = CGFloat(max(1, tilePixelSize))
        let targetPixelSize = CGSize(width: side, height: side)
        let fillPixelSize = aspectFillPixelSize(
            sourcePixelSize: sourcePixelSize,
            targetPixelSize: targetPixelSize
        )
        let maxThumbnailPixelSize = max(
            1,
            Int(ceil(max(fillPixelSize.width, fillPixelSize.height)))
        )

        guard let baseImage = downsampledImage(
            from: imageSource,
            maxPixelSize: maxThumbnailPixelSize
        ) ?? UIImage(data: data) else {
            return nil
        }

        let renderedImage = renderBubbleImage(baseImage, targetPixelSize: targetPixelSize)
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
}
