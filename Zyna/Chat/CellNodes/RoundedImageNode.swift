//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Precomposited image node with per-corner rounding.
/// All drawing happens on a background thread via Texture's
/// `drawParameters` / `draw()` pipeline — no CALayer masks,
/// no main-thread compositing.
final class RoundedImageNode: ASDisplayNode {

    // MARK: - Draw Parameters

    final class DrawParams: NSObject {
        let image: UIImage?
        let radius: CGFloat
        let roundedCorners: UIRectCorner
        let contentMode: UIView.ContentMode

        init(image: UIImage?, radius: CGFloat, roundedCorners: UIRectCorner, contentMode: UIView.ContentMode) {
            self.image = image
            self.radius = radius
            self.roundedCorners = roundedCorners
            self.contentMode = contentMode
        }
    }

    // MARK: - Public State

    var image: UIImage? {
        didSet {
            if image !== oldValue { setNeedsDisplay() }
        }
    }

    var radius: CGFloat = 0 {
        didSet {
            if radius != oldValue { setNeedsDisplay() }
        }
    }

    /// Which corners to round. Default: all four.
    var roundedCorners: UIRectCorner = .allCorners {
        didSet {
            if roundedCorners != oldValue { setNeedsDisplay() }
        }
    }

    var imageContentMode: UIView.ContentMode = .scaleAspectFill

    func snapshotImage(from sourceImage: UIImage) -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let rendered = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            if radius > 0 {
                let path = UIBezierPath(
                    roundedRect: bounds,
                    byRoundingCorners: roundedCorners,
                    cornerRadii: CGSize(width: radius, height: radius)
                )
                path.addClip()
            }

            let drawRect: CGRect
            switch imageContentMode {
            case .scaleAspectFit:
                drawRect = Self.aspectFitRect(imageSize: sourceImage.size, bounds: bounds)
            case .scaleAspectFill:
                drawRect = Self.aspectFillRect(imageSize: sourceImage.size, bounds: bounds)
            default:
                drawRect = bounds
            }

            sourceImage.draw(in: drawRect)
        }

        return rendered.cgImage != nil ? rendered : nil
    }

    // MARK: - Init

    override init() {
        super.init()
        isOpaque = false
    }

    // MARK: - Drawing

    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        DrawParams(
            image: image,
            radius: radius,
            roundedCorners: roundedCorners,
            contentMode: imageContentMode
        )
    }

    override class func draw(_ bounds: CGRect, withParameters parameters: Any?,
                              isCancelled isCancelledBlock: () -> Bool, isRasterizing: Bool) {
        guard let params = parameters as? DrawParams,
              let image = params.image,
              let ctx = UIGraphicsGetCurrentContext()
        else { return }

        if isCancelledBlock() { return }

        // Clip to rounded rect
        if params.radius > 0 {
            let path = UIBezierPath(
                roundedRect: bounds,
                byRoundingCorners: params.roundedCorners,
                cornerRadii: CGSize(width: params.radius, height: params.radius)
            )
            ctx.addPath(path.cgPath)
            ctx.clip()
        }

        // Calculate draw rect for aspect-fill
        let drawRect: CGRect
        switch params.contentMode {
        case .scaleAspectFill:
            drawRect = aspectFillRect(imageSize: image.size, bounds: bounds)
        case .scaleAspectFit:
            drawRect = aspectFitRect(imageSize: image.size, bounds: bounds)
        default:
            drawRect = bounds
        }

        if isCancelledBlock() { return }

        image.draw(in: drawRect)
    }

    // MARK: - Geometry

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

    private static func aspectFitRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
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
