//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// A short scale animation whose capture can use the next display time.
/// Capture uses Core Animation's resolved start time and easing curve.
final class GlassCaptureScaleAnimation: NSObject, CAAnimationDelegate {
    enum Curve {
        case easeOut
        case easeInOut

        var timingFunction: CAMediaTimingFunction {
            CAMediaTimingFunction(name: self == .easeOut ? .easeOut : .easeInEaseOut)
        }

        func value(at progress: Double) -> CGFloat {
            guard progress > 0 else { return 0 }
            guard progress < 1 else { return 1 }
            let x1 = self == .easeOut ? 0.0 : 0.42
            let x2 = 0.58
            var low = 0.0
            var high = 1.0
            for _ in 0..<18 {
                let t = (low + high) * 0.5
                let s = 1 - t
                let x = 3 * s * s * t * x1 + 3 * s * t * t * x2 + t * t * t
                if x < progress { low = t } else { high = t }
            }
            let t = (low + high) * 0.5
            return CGFloat(3 * (1 - t) * t * t + t * t * t)
        }
    }

    /// Geometry for one capture frame; never changes a live/presentation layer.
    struct Prediction {
        let layer: CALayer
        let transform: CGAffineTransform
        let inverse: CGAffineTransform
        private let ancestorIDs: Set<ObjectIdentifier>

        init(layer: CALayer, scale: CGFloat, translation: CGPoint? = nil) {
            self.layer = layer
            let ratio = scale / CGFloat(layer.transform.m11)
            let translation = translation ?? CGPoint(x: layer.transform.m41, y: layer.transform.m42)
            let anchor = CGPoint(
                x: layer.bounds.minX + layer.bounds.width * layer.anchorPoint.x,
                y: layer.bounds.minY + layer.bounds.height * layer.anchorPoint.y
            )
            transform = CGAffineTransform(
                a: ratio, b: 0, c: 0, d: ratio,
                tx: anchor.x * (1 - ratio) + (translation.x - layer.transform.m41) / layer.transform.m11,
                ty: anchor.y * (1 - ratio) + (translation.y - layer.transform.m42) / layer.transform.m22
            )
            inverse = transform.inverted()
            var ids: Set<ObjectIdentifier> = []
            var current: CALayer? = layer
            while let ancestor = current {
                ids.insert(ObjectIdentifier(ancestor.model()))
                current = ancestor.superlayer
            }
            ancestorIDs = ids
        }

        func contains(_ ancestor: CALayer) -> Bool {
            ancestorIDs.contains(ObjectIdentifier(ancestor.model()))
        }

        func matches(_ candidate: CALayer) -> Bool {
            candidate.model() === layer.model()
        }

        func sourcePoint(_ point: CGPoint, in host: CALayer) -> CGPoint {
            let inRoot = layer.convert(point, from: host).applying(inverse)
            return host.convert(inRoot, from: layer)
        }
    }

    private final class WeakAnimation {
        weak var value: GlassCaptureScaleAnimation?
        init(_ value: GlassCaptureScaleAnimation) { self.value = value }
    }

    private static var active: [WeakAnimation] = []
    private static let animationKey = "glass.contextScale"
    private weak var view: UIView?
    private weak var originalParent: CALayer?
    private let fromScale: CGFloat
    private let fromTranslation: CGPoint
    private let toScale: CGFloat
    private let duration: CFTimeInterval
    private let curve: Curve
    private var completion: ((Bool) -> Void)?
    private var isActive = true

    init(view: UIView, toScale: CGFloat, duration: CFTimeInterval,
         curve: Curve, fromTransform: CATransform3D? = nil,
         completion: ((Bool) -> Void)? = nil) {
        self.view = view
        originalParent = view.layer.superlayer
        let fromTransform = fromTransform ?? (view.layer.presentation() ?? view.layer).transform
        fromScale = CGFloat(fromTransform.m11)
        fromTranslation = CGPoint(x: fromTransform.m41, y: fromTransform.m42)
        self.toScale = toScale
        self.duration = duration
        self.curve = curve
        self.completion = completion
        super.init()

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
        animation.duration = duration
        animation.timingFunction = curve.timingFunction
        // CA can resolve its start just ahead of the current sample time.
        // Keep the source geometry during that gap instead of exposing the
        // model's final transform for one capture frame.
        animation.fillMode = .backwards
        let maxFPS = Float(view.window?.screen.maximumFramesPerSecond ?? 60)
        animation.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maxFPS), maximum: maxFPS, preferred: maxFPS
        )
        animation.delegate = self
        UIView.performWithoutAnimation {
            view.transform = CGAffineTransform(scaleX: toScale, y: toScale)
        }
        view.layer.add(animation, forKey: Self.animationKey)
        Self.active.removeAll { $0.value == nil }
        Self.active.append(WeakAnimation(self))
    }

    /// Pass the same frozen geometry to an immediate successor, even if
    /// interaction callbacks mutate the layer before that animation is added.
    @discardableResult
    func cancel() -> CATransform3D? {
        guard isActive else { return nil }
        var frozenTransform: CATransform3D?
        if let view {
            let transform = (view.layer.presentation() ?? view.layer).transform
            frozenTransform = transform
            UIView.performWithoutAnimation {
                view.layer.transform = transform
            }
        }
        finish(false)
        view?.layer.removeAnimation(forKey: Self.animationKey)
        return frozenTransform
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        finish(flag)
    }

    private func finish(_ finished: Bool) {
        guard isActive else { return }
        isActive = false
        Self.active.removeAll { $0.value == nil || $0.value === self }
        let callback = completion
        completion = nil
        callback?(finished)
    }

    static func predictions(at targetTimestamp: CFTimeInterval) -> [Prediction] {
        active.compactMap { $0.value?.prediction(at: targetTimestamp) }
    }

    func prediction(at targetTimestamp: CFTimeInterval) -> Prediction? {
        guard isActive, let view,
              view.layer.superlayer === originalParent,
              let animation = view.layer.animation(forKey: Self.animationKey),
              animation.beginTime > 0,
              let presented = view.layer.presentation(),
              presented.transform.m11 > 0 else { return nil }
        // Leave beginTime at its default so a delayed commit cannot consume
        // the start of the animation. Until CA resolves it, capture the
        // presentation state without prediction; never force a commit here.
        let elapsed = view.layer.convertTime(targetTimestamp, from: nil) - animation.beginTime
        let progress = curve.value(at: elapsed / duration)
        let scale = fromScale + (toScale - fromScale) * progress
        let translation = CGPoint(
            x: fromTranslation.x * (1 - progress),
            y: fromTranslation.y * (1 - progress)
        )
        return Prediction(layer: presented, scale: scale, translation: translation)
    }
}
