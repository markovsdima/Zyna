//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// One timing definition for the viewport, dimming mask, and UIKit chrome.
enum ContextMenuDismissalTiming {
    static let duration: TimeInterval = 0.25
    static let curve: GlassAnimationCurve = .easeOut
    static let captureTail: TimeInterval = 0.05
}

/// Returns the live menu viewport to the glass source before it moves.
/// Its Texture host keeps owning the content until the cell restores it.
final class ContextMenuDismissalTransition {
    private let containerView = UIView()
    private weak var dimmingView: UIView?
    private weak var scrollView: UIScrollView?
    private var viewportAnimation: GlassCaptureViewportAnimation?
    private let dimmingMask = CALayer()
    private let outsideViewport = CAShapeLayer()
    private let viewportMask = CALayer()
    private let contentMask = CAShapeLayer()
    private let maximumFramesPerSecond: Float

    init(contentView: UIView, contentPath: CGPath, scrollView: UIScrollView, dimmingView: UIView,
         overlayContainer: UIView, captureView: UIView) {
        self.dimmingView = dimmingView
        self.scrollView = scrollView
        maximumFramesPerSecond = Float(captureView.window?.screen.maximumFramesPerSecond ?? 60)

        // An action can close the menu during its entrance spring or while a
        // long message is decelerating. Move the visible state, not its target.
        Self.freezeGeometry(of: contentView)
        Self.freezeGeometry(of: scrollView)
        scrollView.isScrollEnabled = false

        UIView.performWithoutAnimation {
            installDimmingMask(contentView: contentView, scrollView: scrollView,
                               dimmingView: dimmingView, contentPath: contentPath)

            // Use a full-window container so capture culling never clips a
            // traveling bubble to its original cell. The affine mapping also
            // counteracts the inverted table and its nonzero content offset.
            // Let M map overlay to capture coordinates, c = bounds' midpoint,
            // and L = M's linear part, recovered from the basis below.
            // With transform = L and center = M(c), every point p maps to
            // L * (p - c) + M(c) = M(p), preserving its reparented position.
            // convert(rect:) alone loses axis direction in the flipped table.
            containerView.bounds = overlayContainer.bounds
            let origin = captureView.convert(CGPoint.zero, from: overlayContainer)
            let x = captureView.convert(CGPoint(x: 1, y: 0), from: overlayContainer)
            let y = captureView.convert(CGPoint(x: 0, y: 1), from: overlayContainer)
            containerView.transform = CGAffineTransform(
                a: x.x - origin.x, b: x.y - origin.y,
                c: y.x - origin.x, d: y.y - origin.y, tx: 0, ty: 0
            )
            containerView.center = captureView.convert(
                CGPoint(x: overlayContainer.bounds.midX, y: overlayContainer.bounds.midY),
                from: overlayContainer
            )
            containerView.isUserInteractionEnabled = false
            captureView.addSubview(containerView)
            containerView.addSubview(scrollView)
        }
    }

    /// Decelerate into the glass instead of crossing it at peak speed.
    /// Capture predicts this same viewport animation at the display target.
    func animate(to frame: CGRect) {
        if let scrollView {
            viewportAnimation = GlassCaptureViewportAnimation(
                view: scrollView, to: frame, duration: ContextMenuDismissalTiming.duration,
                curve: ContextMenuDismissalTiming.curve
            )
        }
        animate(outsideViewport, keyPath: "path", to: outsidePath(viewport: frame))
        animate(viewportMask, keyPath: "position",
                to: CGPoint(x: frame.midX, y: frame.midY))
        animate(viewportMask, keyPath: "bounds",
                to: CGRect(origin: .zero, size: frame.size))
        animate(contentMask, keyPath: "transform", to: CATransform3DIdentity)
    }

    /// Call after the cell has restored the node through addSubnode.
    func finish() {
        viewportAnimation?.stop()
        viewportAnimation = nil
        dimmingView?.layer.mask = nil
        containerView.removeFromSuperview()
    }

    private func installDimmingMask(contentView: UIView, scrollView: UIScrollView,
                                    dimmingView: UIView, contentPath: CGPath) {
        dimmingMask.frame = dimmingView.bounds
        dimmingMask.masksToBounds = true
        outsideViewport.fillColor = UIColor.white.cgColor
        outsideViewport.fillRule = .evenOdd
        outsideViewport.path = outsidePath(viewport: scrollView.frame)
        dimmingMask.addSublayer(outsideViewport)

        viewportMask.bounds = scrollView.bounds
        viewportMask.position = scrollView.layer.position
        viewportMask.masksToBounds = true
        dimmingMask.addSublayer(viewportMask)

        contentMask.bounds = contentView.bounds
        contentMask.position = contentView.layer.position
        contentMask.transform = contentView.layer.transform
        contentMask.fillColor = UIColor.white.cgColor
        contentMask.fillRule = .evenOdd
        // Cut the cell's vector outline out of an opaque surround. The
        // viewport clips it during scrolling, expansion, and bounce; no
        // text, gradient, or media pixels need to be rasterized for the mask.
        let margin = max(dimmingView.bounds.width, dimmingView.bounds.height) * 2
        let path = CGMutablePath()
        path.addRect(contentView.bounds.insetBy(dx: -margin, dy: -margin))
        path.addPath(contentPath)
        contentMask.path = path
        viewportMask.addSublayer(contentMask)
        dimmingView.layer.mask = dimmingMask
    }

    private func outsidePath(viewport: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(dimmingMask.bounds)
        path.addRect(viewport)
        return path
    }

    private func animate(_ layer: CALayer, keyPath: String, to value: Any) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = layer.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = ContextMenuDismissalTiming.duration
        animation.timingFunction = ContextMenuDismissalTiming.curve.timingFunction
        animation.fillMode = .backwards
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maximumFramesPerSecond), maximum: maximumFramesPerSecond,
            preferred: maximumFramesPerSecond
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        layer.add(animation, forKey: keyPath)
        CATransaction.commit()
    }

    private static func freezeGeometry(of view: UIView) {
        let visible = view.layer.presentation() ?? view.layer
        let bounds = visible.bounds
        let position = visible.position
        let transform = visible.transform
        UIView.performWithoutAnimation {
            // Stop UIScrollView's deceleration as well as CA animations.
            if let scrollView = view as? UIScrollView {
                scrollView.setContentOffset(bounds.origin, animated: false)
            }
            for key in view.layer.animationKeys() ?? [] {
                guard let property = view.layer.animation(forKey: key) as? CAPropertyAnimation,
                      let path = property.keyPath,
                      ["bounds", "position", "transform"].contains(where: {
                          path == $0 || path.hasPrefix($0 + ".")
                      }) else { continue }
                view.layer.removeAnimation(forKey: key)
            }
            view.bounds = bounds
            view.layer.position = position
            view.layer.transform = transform
        }
    }
}
