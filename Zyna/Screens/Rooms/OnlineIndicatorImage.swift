//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Pre-rendered green online-status dot with a cell-background border,
/// cached per trait style. Every online cell shares the same UIImage,
/// so there's no per-node CALayer cornerRadius + border offscreen pass.
enum OnlineIndicatorImage {

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 4
        return c
    }()

    static func render(
        diameter: CGFloat,
        borderWidth: CGFloat,
        userInterfaceStyle: UIUserInterfaceStyle
    ) -> UIImage {
        let key = "\(Int(diameter)):\(Int(borderWidth)):\(userInterfaceStyle.rawValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let borderColor = UIColor.systemBackground.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: userInterfaceStyle)
        )
        let size = CGSize(width: diameter, height: diameter)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { _ in
            let inset = borderWidth / 2
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            UIColor.systemGreen.setFill()
            UIBezierPath(ovalIn: rect).fill()
            borderColor.setStroke()
            let border = UIBezierPath(ovalIn: rect)
            border.lineWidth = borderWidth
            border.stroke()
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
