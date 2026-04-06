//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Shared `UIImage` bank for message status indicators. Each image
/// is rendered once with Core Graphics at app startup and shared by
/// every message cell's `ASImageNode`. Images are authored in black and always
/// returned with `.alwaysTemplate` rendering mode so callers can
/// tint them per-bubble via `tintColor` on an `ASImageNode`.
///
/// Why a shared bank (vs per-cell `draw(_:)`): Texture creates a
/// new ASCellNode per index path; a custom `draw()` fires on each.
/// A pool of shared UIImages costs ~1 KB total and lets every
/// cell use a no-op `ASImageNode` with zero rendering overhead.
enum MessageStatusIconImages {

    // MARK: - Public

    static let clockFrame: UIImage = generateClockFrame()
    static let clockHand: UIImage = generateClockHand()
    static let check: UIImage = generateCheck()
    static let failedBadge: UIImage = generateFailedBadge()

    // MARK: - Geometry (canonical size: 11pt)

    /// All images are rendered at this canonical size. Callers scale
    /// via the ASImageNode preferredSize — UIKit handles bilinear
    /// interpolation for small downsizes.
    static let canonicalSize: CGFloat = 11

    // MARK: - Generators

    /// Outline circle + short vertical hand pointing up (minute hand).
    /// Black template. Caller tints via `tintColor`.
    private static func generateClockFrame() -> UIImage {
        let size = canonicalSize
        let stroke: CGFloat = 1.0
        return generate(size: CGSize(width: size, height: size)) { ctx, bounds in
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.setLineWidth(stroke)
            ctx.strokeEllipse(in: CGRect(
                x: stroke / 2, y: stroke / 2,
                width: bounds.width - stroke, height: bounds.height - stroke
            ))
            // 12-o'clock hand: vertical stroke from ~3pt to centre.
            ctx.fill(CGRect(
                x: (bounds.width - stroke) / 2,
                y: stroke * 3,
                width: stroke,
                height: bounds.height / 2 - stroke * 3
            ))
        }
    }

    /// Short horizontal bar through the centre — second hand.
    /// Rotated by CABasicAnimation; the pivot point is the image centre.
    private static func generateClockHand() -> UIImage {
        let size = canonicalSize
        let stroke: CGFloat = 1.0
        return generate(size: CGSize(width: size, height: size)) { ctx, bounds in
            ctx.setFillColor(UIColor.black.cgColor)
            ctx.fill(CGRect(
                x: (bounds.width - stroke) / 2,
                y: (bounds.height - stroke) / 2,
                width: bounds.width / 2 - stroke,
                height: stroke
            ))
        }
    }

    /// Full V-shape checkmark. The "delivered" state is built by
    /// layering two of these with a horizontal offset — no separate
    /// "partial" image needed. Stroke width is a fraction of size
    /// so downscaling stays crisp.
    private static func generateCheck() -> UIImage {
        let size = canonicalSize
        let stroke: CGFloat = size * MessageStatusIconConfig.strokeWidthRatio
        return generate(size: CGSize(width: size, height: size)) { ctx, bounds in
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(stroke)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            // Canonical V: short leg ~1/3 of long leg.
            let w = bounds.width
            let h = bounds.height
            let start = CGPoint(x: w * 0.10, y: h * 0.55)
            let apex  = CGPoint(x: w * 0.38, y: h * 0.80)
            let end   = CGPoint(x: w * 0.92, y: h * 0.22)
            ctx.move(to: start)
            ctx.addLine(to: apex)
            ctx.addLine(to: end)
            ctx.strokePath()
        }
    }

    /// Red filled circle with a thin white border ring and a white
    /// "!" glyph. Authored in full colour (NOT a template), so it
    /// reads against any bubble colour without tinting.
    private static func generateFailedBadge() -> UIImage {
        let size = canonicalSize + 2  // Slightly larger than checks
        return generateColour(size: CGSize(width: size, height: size)) { ctx, bounds in
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            let ringWidth: CGFloat = 1.0
            let outerR = min(bounds.width, bounds.height) / 2
            let fillR = outerR - ringWidth

            // White border ring
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(
                x: centre.x - outerR, y: centre.y - outerR,
                width: outerR * 2, height: outerR * 2
            ))

            // Red fill
            ctx.setFillColor(UIColor.systemRed.cgColor)
            ctx.fillEllipse(in: CGRect(
                x: centre.x - fillR, y: centre.y - fillR,
                width: fillR * 2, height: fillR * 2
            ))

            // Exclamation mark
            ctx.setFillColor(UIColor.white.cgColor)
            let barW: CGFloat = 1.3
            let barH = fillR * 0.72
            let barTop = centre.y - barH / 2 - fillR * 0.08
            ctx.fill(CGRect(
                x: centre.x - barW / 2,
                y: barTop,
                width: barW,
                height: barH
            ))
            let dotSize: CGFloat = barW
            ctx.fillEllipse(in: CGRect(
                x: centre.x - dotSize / 2,
                y: barTop + barH + fillR * 0.18,
                width: dotSize,
                height: dotSize
            ))
        }
    }

    // MARK: - Helpers

    /// Template image (black-only, tintable).
    private static func generate(
        size: CGSize,
        draw: (CGContext, CGRect) -> Void
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            ctx.cgContext.clear(CGRect(origin: .zero, size: size))
            draw(ctx.cgContext, CGRect(origin: .zero, size: size))
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// Full-colour image (NOT tintable).
    private static func generateColour(
        size: CGSize,
        draw: (CGContext, CGRect) -> Void
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            ctx.cgContext.clear(CGRect(origin: .zero, size: size))
            draw(ctx.cgContext, CGRect(origin: .zero, size: size))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
