// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit

/// One GPU-composited highlight, allocated only for the bubble being opened.
/// It does not redraw text, drive a display link, or change the bubble layout.
final class BubbleLinkActivity {
    private let layer = CAGradientLayer()
    private let mask = CAShapeLayer()
    private var observers: [NSObjectProtocol] = []
    private var isVisible = true
    private var isRemoved = false

    init(parent: CALayer, color: UIColor) {
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.colors = [color.withAlphaComponent(0.03).cgColor,
                        color.withAlphaComponent(0.23).cgColor,
                        color.withAlphaComponent(0.03).cgColor]
        // Keep a visible static state if the render server drops animations.
        layer.locations = [0, 0.5, 1]
        layer.mask = mask
        parent.addSublayer(layer)
        for name in [UIApplication.didBecomeActiveNotification, UIAccessibility.reduceMotionStatusDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.restoreAnimationIfNeeded()
            })
        }
        restoreAnimationIfNeeded()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func setVisible(_ value: Bool) {
        isVisible = value
        restoreAnimationIfNeeded()
    }

    private func restoreAnimationIfNeeded() {
        guard !isRemoved else { return }
        guard isVisible, !UIAccessibility.isReduceMotionEnabled else {
            layer.removeAnimation(forKey: "linkOpening")
            return
        }
        guard layer.animation(forKey: "linkOpening") == nil else { return }
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.8, -0.4, 0]
        animation.toValue = [1, 1.4, 1.8]
        animation.duration = 1.25
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "linkOpening")
    }

    func update(bounds: CGRect, path: CGPath) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        mask.frame = layer.bounds
        mask.path = path
        CATransaction.commit()
        restoreAnimationIfNeeded()
    }

    func remove() {
        isRemoved = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
    }
}
