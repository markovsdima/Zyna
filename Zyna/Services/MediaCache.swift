//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import MatrixRustSDK

final class MediaCache {

    static let shared = MediaCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
    }

    // MARK: - Public

    func image(for source: MediaSource) -> UIImage? {
        cache.object(forKey: cacheKey(source))
    }

    func loadThumbnail(
        source: MediaSource,
        width: UInt64,
        height: UInt64
    ) async -> UIImage? {
        let key = cacheKey(source)

        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let client = MatrixClientService.shared.client else { return nil }

        do {
            let data = try await client.getMediaThumbnail(
                mediaSource: source,
                width: width,
                height: height
            )
            guard let image = UIImage(data: data) else { return nil }
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }

    func loadThumbnail(mxcUrl: String, size: Int) async -> UIImage? {
        let key = mxcUrl as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let source = try? MediaSource.fromUrl(url: mxcUrl) else { return nil }
        let px = UInt64(size)
        guard let image = await loadThumbnail(source: source, width: px, height: px) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Private

    private func cacheKey(_ source: MediaSource) -> NSString {
        source.url() as NSString
    }
}
