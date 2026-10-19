//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// A short scale animation whose capture can use the next display time.
/// Capture uses Core Animation's resolved start time and easing curve.
final class GlassCaptureScaleAnimation {
    private static let animationKey = "glass.contextScale"
    private weak var view: UIView?
    private let animation: GlassCaptureAnimation

    init(view: UIView, toScale: CGFloat, duration: CFTimeInterval,
         curve: GlassAnimationCurve, fromTransform: CATransform3D? = nil,
         completion: ((Bool) -> Void)? = nil) {
        self.view = view
        let fromTransform = fromTransform ?? (view.layer.presentation() ?? view.layer).transform
        let fromScale = CGFloat(fromTransform.m11)
        let fromTranslation = CGPoint(x: fromTransform.m41, y: fromTransform.m42)

        // Take over from the visible transform, including an unfinished
        // reply-swipe return. Retire previous transform animations so they
        // cannot reappear underneath ours. Do not rely on UIKit's keys.
        for key in view.layer.animationKeys() ?? [] {
            guard let property = view.layer.animation(forKey: key) as? CAPropertyAnimation,
                  let keyPath = property.keyPath,
                  keyPath == "transform" || keyPath.hasPrefix("transform.") else { continue }
            view.layer.removeAnimation(forKey: key)
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = fromTransform
        animation.toValue = CATransform3DMakeScale(toScale, toScale, 1)
        self.animation = GlassCaptureAnimation(
            view: view, animation: animation, key: Self.animationKey,
            duration: duration, curve: curve,
            applyTarget: {
                view.transform = CGAffineTransform(scaleX: toScale, y: toScale)
            },
            sample: { presented, progress in
                guard presented.transform.m11 > 0 else { return nil }
                let scale = fromScale + (toScale - fromScale) * progress
                let translation = CGPoint(
                    x: fromTranslation.x * (1 - progress),
                    y: fromTranslation.y * (1 - progress)
                )
                return GlassCapturePrediction(layer: presented, scale: scale, translation: translation)
            },
            completion: completion
        )
    }

    /// Pass the same frozen geometry to an immediate successor, even if
    /// interaction callbacks mutate the layer before that animation is added.
    @discardableResult
    func cancel() -> CATransform3D? {
        var frozenTransform: CATransform3D?
        if animation.isRunning, let view {
            let transform = (view.layer.presentation() ?? view.layer).transform
            frozenTransform = transform
            UIView.performWithoutAnimation {
                view.layer.transform = transform
            }
        }
        // Retire the session even if CA already removed its animation but
        // has not delivered the stop callback. A late success must not
        // activate the menu after cancellation; never freeze a successor.
        animation.stop()
        return frozenTransform
    }

    func prediction(at targetTimestamp: CFTimeInterval) -> GlassCapturePrediction? {
        animation.prediction(at: targetTimestamp)
    }
}
