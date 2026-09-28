//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Geometry for one capture frame; never changes a live/presentation layer.
struct GlassCapturePrediction {
    let layer: CALayer
    let bounds: CGRect
    let transform: CGAffineTransform
    let inverse: CGAffineTransform

    init(layer: CALayer, scale: CGFloat, translation: CGPoint? = nil) {
        let ratio = scale / CGFloat(layer.transform.m11)
        let translation = translation ?? CGPoint(x: layer.transform.m41, y: layer.transform.m42)
        let anchor = CGPoint(
            x: layer.bounds.minX + layer.bounds.width * layer.anchorPoint.x,
            y: layer.bounds.minY + layer.bounds.height * layer.anchorPoint.y
        )
        let transform = CGAffineTransform(
            a: ratio, b: 0, c: 0, d: ratio,
            tx: anchor.x * (1 - ratio) + (translation.x - layer.transform.m41) / layer.transform.m11,
            ty: anchor.y * (1 - ratio) + (translation.y - layer.transform.m42) / layer.transform.m22
        )
        self.init(layer: layer, bounds: layer.bounds, transform: transform)
    }

    /// A viewport changes both its location and the portion of its
    /// children that is visible. Its bounds must advance with its origin.
    init(layer: CALayer, position: CGPoint, bounds: CGRect) {
        // With L = the layer's linear transform, b = bounds.origin,
        // s = bounds.size, a = anchorPoint, and ' = predicted state:
        // X = L^-1 * (position' - position) + (b - b') + (s - s') * a.
        // Size * anchor is componentwise. Capture already applies the
        // current geometry; this local translation advances it to the target.
        // Transform the delta as a vector: f(delta) - f(0) cancels the
        // affine inverse's translation, leaving only L^-1 * delta.
        let inverseTransform = layer.affineTransform().inverted()
        let delta = CGPoint(x: position.x - layer.position.x,
                            y: position.y - layer.position.y)
        let localDelta = delta.applying(inverseTransform)
        let localOrigin = CGPoint.zero.applying(inverseTransform)
        let transform = CGAffineTransform(
            translationX: localDelta.x - localOrigin.x + layer.bounds.minX - bounds.minX
                + (layer.bounds.width - bounds.width) * layer.anchorPoint.x,
            y: localDelta.y - localOrigin.y + layer.bounds.minY - bounds.minY
                + (layer.bounds.height - bounds.height) * layer.anchorPoint.y
        )
        self.init(layer: layer, bounds: bounds, transform: transform)
    }

    private init(layer: CALayer, bounds: CGRect, transform: CGAffineTransform) {
        self.layer = layer
        self.bounds = bounds
        self.transform = transform
        inverse = transform.inverted()
    }

    func matches(_ candidate: CALayer) -> Bool {
        candidate.model() === layer.model()
    }

    func sourcePoint(_ point: CGPoint, in host: CALayer) -> CGPoint {
        let inRoot = layer.convert(point, from: host).applying(inverse)
        return host.convert(inRoot, from: layer)
    }
}

/// One index per capture tick, shared by every glass region. Empty captures
/// do no model-layer lookup; active captures use O(1) tests during traversal.
struct GlassCapturePredictions {
    static let none = GlassCapturePredictions([])

    private var byLayer: [ObjectIdentifier: GlassCapturePrediction] = [:]
    private var ancestorIDs: Set<ObjectIdentifier> = []

    init(_ predictions: [GlassCapturePrediction]) {
        for prediction in predictions {
            let id = ObjectIdentifier(prediction.layer.model())
            // A motion describes a layer's complete future geometry. Scale
            // and viewport motions currently own distinct layers.
            assert(byLayer[id] == nil, "Multiple capture motions own the same layer")
            byLayer[id] = prediction
            var current = prediction.layer.superlayer
            while let ancestor = current {
                guard ancestorIDs.insert(ObjectIdentifier(ancestor.model())).inserted else { break }
                current = ancestor.superlayer
            }
        }
    }

    func prediction(for layer: CALayer) -> GlassCapturePrediction? {
        guard !byLayer.isEmpty else { return nil }
        return byLayer[ObjectIdentifier(layer.model())]
    }

    /// Strict descendants: a predicted root may itself contain another motion.
    func hasDescendant(in layer: CALayer) -> Bool {
        guard !ancestorIDs.isEmpty else { return false }
        return ancestorIDs.contains(ObjectIdentifier(layer.model()))
    }
}
