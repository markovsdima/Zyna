//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Shared CA lifecycle and timing for motions sampled by glass capture.
/// Motion-specific code supplies target state and geometry at eased progress.
/// Main-thread only; sampling is driven by capture, with no additional timer.
final class GlassCaptureAnimation: NSObject, CAAnimationDelegate {
    private final class WeakAnimation {
        weak var value: GlassCaptureAnimation?
        init(_ value: GlassCaptureAnimation) { self.value = value }
    }

    private static var active: [WeakAnimation] = []
    private weak var layer: CALayer?
    private weak var originalParent: CALayer?
    private let key: String
    private let duration: CFTimeInterval
    private let curve: GlassAnimationCurve
    private let sample: (CALayer, CGFloat) -> GlassCapturePrediction?
    private var completion: ((Bool) -> Void)?
    private var isActive = true

    /// Capture motion endpoints by value in sample; keep view ownership weak.
    init(view: UIView, animation: CAAnimation, key: String,
         duration: CFTimeInterval, curve: GlassAnimationCurve,
         applyTarget: () -> Void,
         sample: @escaping (CALayer, CGFloat) -> GlassCapturePrediction?,
         completion: ((Bool) -> Void)? = nil) {
        layer = view.layer
        originalParent = view.layer.superlayer
        self.key = key
        self.duration = duration
        self.curve = curve
        self.sample = sample
        self.completion = completion
        super.init()

        animation.duration = duration
        animation.timingFunction = curve.timingFunction
        // Let CA resolve the start at commit. Preserve source geometry if
        // its first presentation sample precedes that resolved start.
        animation.fillMode = .backwards
        let maxFPS = Float(view.window?.screen.maximumFramesPerSecond ?? 60)
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maxFPS), maximum: maxFPS, preferred: maxFPS
        )
        animation.delegate = self
        UIView.performWithoutAnimation(applyTarget)
        Self.active.removeAll { $0.value == nil }
        Self.active.append(WeakAnimation(self))
        view.layer.add(animation, forKey: key)
    }

    /// A retained handle must not mutate a successor using the same key.
    var isRunning: Bool { isActive && ownedAnimation != nil }

    private var ownedAnimation: CAAnimation? {
        // CA copies animations on add. Delegate identity identifies this
        // session across copies; the key alone may already name a successor.
        guard let animation = layer?.animation(forKey: key),
              animation.delegate === self else { return nil }
        return animation
    }

    /// Removes this animation, leaving the model state chosen by the caller.
    /// Scale cancellation freezes it first; viewport completion keeps its end.
    func stop() {
        finish(false, removeAnimation: true)
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        finish(flag)
    }

    private func finish(_ finished: Bool, removeAnimation: Bool = false) {
        guard isActive else { return }
        isActive = false
        Self.active.removeAll { $0.value == nil || $0.value === self }
        let callback = completion
        completion = nil
        // Retire before calling user code: completion may immediately start
        // another animation on this layer, including under the same key.
        if removeAnimation, ownedAnimation != nil {
            layer?.removeAnimation(forKey: key)
        }
        callback?(finished)
    }

    static func predictions(at targetTimestamp: CFTimeInterval) -> [GlassCapturePrediction] {
        active.compactMap { $0.value?.prediction(at: targetTimestamp) }
    }

    func prediction(at targetTimestamp: CFTimeInterval) -> GlassCapturePrediction? {
        guard isActive, let layer, layer.superlayer === originalParent,
              let animation = ownedAnimation, animation.beginTime > 0,
              let presented = layer.presentation() else { return nil }
        // Before CA resolves beginTime, capture presentation without
        // prediction; never force a transaction commit from capture.
        let elapsed = layer.convertTime(targetTimestamp, from: nil) - animation.beginTime
        return sample(presented, curve.value(at: elapsed / duration))
    }
}
