//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Animates a clear, clipped viewport with timing shared by glass capture.
/// Position, scroll offset, and clip size advance to the same display time.
final class GlassCaptureViewportAnimation {
    private static let animationKey = "glass.contextViewport"
    private let animation: GlassCaptureAnimation

    /// The caller freezes visible geometry before reparenting the viewport.
    /// Read that model state; its previous presentation may belong to another
    /// window until CA commits the new hierarchy.
    init(view: UIView, to frame: CGRect, duration: TimeInterval,
         curve: GlassAnimationCurve = .easeOut) {
        let fromPosition = view.layer.position
        let toPosition = CGPoint(x: frame.minX + frame.width * view.layer.anchorPoint.x,
                                 y: frame.minY + frame.height * view.layer.anchorPoint.y)
        let fromBounds = view.bounds
        let toBounds = CGRect(origin: .zero, size: frame.size)

        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = fromPosition
        position.toValue = toPosition
        position.duration = duration
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = fromBounds
        bounds.toValue = toBounds
        bounds.duration = duration
        let animation = CAAnimationGroup()
        animation.animations = [position, bounds]
        self.animation = GlassCaptureAnimation(
            view: view, animation: animation, key: Self.animationKey,
            duration: duration, curve: curve,
            applyTarget: {
                view.bounds = toBounds
                view.layer.position = toPosition
            },
            sample: { presented, progress in
                func interpolate(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
                    from + (to - from) * progress
                }
                return GlassCapturePrediction(
                    layer: presented,
                    position: CGPoint(x: interpolate(fromPosition.x, toPosition.x),
                                      y: interpolate(fromPosition.y, toPosition.y)),
                    bounds: CGRect(x: interpolate(fromBounds.minX, toBounds.minX),
                                   y: interpolate(fromBounds.minY, toBounds.minY),
                                   width: interpolate(fromBounds.width, toBounds.width),
                                   height: interpolate(fromBounds.height, toBounds.height))
                )
            }
        )
    }

    func stop() {
        animation.stop()
    }

    func prediction(at targetTimestamp: CFTimeInterval) -> GlassCapturePrediction? {
        animation.prediction(at: targetTimestamp)
    }
}
