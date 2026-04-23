//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Shared cache of circular, aspect-filled UIImages. Multiple call
/// sites using the same cache key get one UIImage instance — avoids
/// per-node precomposition for repeating chat avatars. Corners are
/// transparent, so the cell background shows through.
enum CircularImageCache {

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    /// Circular crop of `source`, cached by `cacheKey + diameter`.
    /// Pass a stable key (e.g. mxc URL) to share across render sites.
    static func roundedImage(source: UIImage, diameter: CGFloat, cacheKey: String) -> UIImage {
        let nsKey = "\(cacheKey):\(Int(diameter))" as NSString
        if let cached = cache.object(forKey: nsKey) { return cached }

        let size = CGSize(width: diameter, height: diameter)
        // Direct init instead of the more obvious .preferred() —
        // this path runs off-main while .preferred() reads main
        // screen state (main-thread-bound).
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rounded = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: rect).addClip()
            let drawRect = aspectFillRect(imageSize: source.size, bounds: rect)
            source.draw(in: drawRect)
        }
        cache.setObject(rounded, forKey: nsKey)
        return rounded
    }

    private static func aspectFillRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: w,
            height: h
        )
    }
}
