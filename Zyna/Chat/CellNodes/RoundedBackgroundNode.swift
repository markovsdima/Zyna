//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Precomposited rounded-rect background with per-corner control.
/// Fills a `UIBezierPath(roundedRect:byRoundingCorners:cornerRadii:)`
/// on a background thread via Texture's `draw()` pipeline — no CALayer
/// masks, no `clipsToBounds`, no main-thread compositing.
final class RoundedBackgroundNode: ASDisplayNode {

    // MARK: - Draw Parameters

    final class DrawParams: NSObject {
        let fillColor: UIColor
        let radius: CGFloat
        let roundedCorners: UIRectCorner

        init(fillColor: UIColor, radius: CGFloat, roundedCorners: UIRectCorner) {
            self.fillColor = fillColor
            self.radius = radius
            self.roundedCorners = roundedCorners
        }
    }

    // MARK: - Public State

    var fillColor: UIColor = .clear {
        didSet {
            if fillColor != oldValue { setNeedsDisplay() }
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

    // MARK: - Init

    override init() {
        super.init()
        isOpaque = false
    }

    // MARK: - Drawing

    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        DrawParams(fillColor: fillColor, radius: radius, roundedCorners: roundedCorners)
    }

    override class func draw(_ bounds: CGRect, withParameters parameters: Any?,
                              isCancelled isCancelledBlock: () -> Bool, isRasterizing: Bool) {
        guard let params = parameters as? DrawParams else { return }
        if isCancelledBlock() { return }

        let path: UIBezierPath
        if params.radius > 0 {
            path = UIBezierPath(
                roundedRect: bounds,
                byRoundingCorners: params.roundedCorners,
                cornerRadii: CGSize(width: params.radius, height: params.radius)
            )
        } else {
            path = UIBezierPath(rect: bounds)
        }

        params.fillColor.setFill()
        path.fill()
    }

    // MARK: - Path (for overlays like highlight)

    /// Main-thread helper for overlay layers (e.g. highlight) that need
    /// the bubble's shape. The async `draw()` path does NOT use this —
    /// it builds its own path from the `DrawParams` snapshot off-main.
    func currentPath() -> UIBezierPath {
        guard radius > 0 else { return UIBezierPath(rect: bounds) }
        return UIBezierPath(
            roundedRect: bounds,
            byRoundingCorners: roundedCorners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
    }
}
