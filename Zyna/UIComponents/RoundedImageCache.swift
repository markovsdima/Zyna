//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Shared cache of rounded, aspect-filled UIImages. Used for non-circular
/// room avatars so Texture nodes can display precomposited images without
/// doing corner rounding work per cell.
enum RoundedImageCache {

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        return c
    }()

    static func roundedImage(
        source: UIImage,
        size: CGSize,
        cornerRadius: CGFloat,
        cacheKey: String
    ) -> UIImage {
        let nsKey = "\(cacheKey):\(Int(size.width))x\(Int(size.height)):\(Int(cornerRadius))" as NSString
        if let cached = cache.object(forKey: nsKey) { return cached }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = ScreenConstants.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rounded = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()
            let drawRect = aspectFillRect(imageSize: source.size, bounds: rect)
            source.draw(in: drawRect)
        }
        cache.setObject(rounded, forKey: nsKey)
        return rounded
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
}
