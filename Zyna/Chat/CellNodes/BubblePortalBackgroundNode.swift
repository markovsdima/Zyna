//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import ObjectiveC.runtime
import UIKit

/// Thin portal-backed background node. It owns the `_UIPortalView`
/// wrapper, clips it to the bubble shape, and delegates source-lifecycle
/// to a shared `PortalSourceView`.
final class BubblePortalBackgroundNode: ASDisplayNode {

    /// Capture marker shared with diagnostic layer naming.
    static let captureLayerName = "message.bubblePortalBackground"

    private final class WeakPortalSourceBox: NSObject {
        weak var sourceView: PortalSourceView?

        init(sourceView: PortalSourceView?) {
            self.sourceView = sourceView
        }
    }

    private enum CaptureAssociationKey {
        static var sourceView: UInt8 = 0
    }

    static func captureSourceView(for hostView: UIView) -> PortalSourceView? {
        (objc_getAssociatedObject(hostView, &CaptureAssociationKey.sourceView) as? WeakPortalSourceBox)?.sourceView
    }

    private static func setCaptureSourceView(_ sourceView: PortalSourceView?, on hostView: UIView) {
        objc_setAssociatedObject(
            hostView,
            &CaptureAssociationKey.sourceView,
            WeakPortalSourceBox(sourceView: sourceView),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    weak var sourceView: PortalSourceView? {
        didSet {
            guard sourceView !== oldValue else { return }
            scheduleSourceBindingUpdate(oldValue: oldValue)
        }
    }

    var radius: CGFloat = 0 {
        didSet {
            guard radius != oldValue else { return }
            if isNodeLoaded {
                setNeedsLayout()
            }
        }
    }

    var roundedCorners: UIRectCorner = .allCorners {
        didSet {
            guard roundedCorners != oldValue else { return }
            if isNodeLoaded {
                setNeedsLayout()
            }
        }
    }

    private var portal: PortalView?

    override init() {
        super.init()
        isOpaque = false
        isUserInteractionEnabled = false
    }

    override func didLoad() {
        super.didLoad()
        layer.name = Self.captureLayerName
        Self.setCaptureSourceView(sourceView, on: view)
        installPortalIfNeeded()
        bindPortalSource(oldValue: nil)
        updatePortalLayout()
    }

    override func layout() {
        super.layout()
        updatePortalLayout()
    }

    private func installPortalIfNeeded() {
        guard portal == nil, let portal = PortalView(matchesPosition: true) else {
            return
        }
        portal.view.backgroundColor = .clear
        portal.view.layer.name = "message.bubblePortalBackground.portalView"
        view.addSubview(portal.view)
        self.portal = portal
    }

    private func scheduleSourceBindingUpdate(oldValue: PortalSourceView?) {
        guard isNodeLoaded else { return }
        if Thread.isMainThread {
            bindPortalSource(oldValue: oldValue)
        } else {
            DispatchQueue.main.async { [weak self, weak oldValue] in
                self?.bindPortalSource(oldValue: oldValue)
            }
        }
    }

    private func bindPortalSource(oldValue: PortalSourceView?) {
        installPortalIfNeeded()
        guard let portal else { return }

        if let oldValue, oldValue !== sourceView {
            oldValue.removePortal(portal)
        }

        guard let sourceView else {
            portal.sourceView = nil
            Self.setCaptureSourceView(nil, on: view)
            view.isHidden = true
            return
        }

        view.isHidden = false
        Self.setCaptureSourceView(sourceView, on: view)
        sourceView.addPortal(portal)
    }

    private func updatePortalLayout() {
        portal?.view.frame = bounds

        let maskLayer = (view.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        maskLayer.frame = bounds
        maskLayer.name = "message.bubblePortalBackground.mask"
        maskLayer.path = currentPath().cgPath
        if view.layer.mask !== maskLayer {
            view.layer.mask = maskLayer
        }
    }

    private func currentPath() -> UIBezierPath {
        guard radius > 0 else {
            return UIBezierPath(rect: bounds)
        }
        return UIBezierPath(
            roundedRect: bounds,
            byRoundingCorners: roundedCorners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
    }
}

/// Shared manual capture path for layer trees that contain bubble portals.
/// Normal layer trees still use `CALayer.render`; only portal subtrees take
/// the slower source-remap path, and only during explicit snapshot/capture work.
enum BubblePortalCaptureRenderer {

    /// Cache only for this capture, so Texture layout/reparenting never needs
    /// invalidation. Search lazily to avoid walking every off-screen branch.
    private struct PortalLookup {
        private var results: [ObjectIdentifier: Bool] = [:]

        mutating func containsPortal(_ layer: CALayer) -> Bool {
            // Presentation snapshots of the same model share one entry.
            let id = ObjectIdentifier(layer.model())
            if let result = results[id] { return result }
            let result = isBubblePortalBackgroundLayer(layer)
                || (layer.sublayers?.contains { containsPortal($0) } ?? false)
            results[id] = result
            return result
        }
    }

    static func renderLayerForCapture(
        _ layer: CALayer,
        in ctx: CGContext,
        clipRectInLayer: CGRect,
        predictions: GlassCapturePredictions = .none
    ) {
        var portalLookup = PortalLookup()
        var sourceProjections: [GlassCapturePrediction] = []
        renderLayer(layer, in: ctx, clipRectInLayer: clipRectInLayer,
                    predictions: predictions, sourceProjections: &sourceProjections,
                    portalLookup: &portalLookup)
    }

    private static func renderLayer(
        _ layer: CALayer,
        in ctx: CGContext,
        clipRectInLayer: CGRect,
        predictions: GlassCapturePredictions,
        sourceProjections: inout [GlassCapturePrediction],
        portalLookup: inout PortalLookup
    ) {
        guard !clipRectInLayer.isEmpty else { return }

        let prediction = predictions.prediction(for: layer)
        var clip = clipRectInLayer
        if let prediction {
            ctx.saveGState()
            ctx.concatenate(prediction.transform)
            clip = clip.applying(prediction.inverse)
            sourceProjections.append(prediction)
        }
        defer {
            if prediction != nil {
                sourceProjections.removeLast()
                ctx.restoreGState()
            }
        }

        // Once the predicted root's geometry is applied, a portal-free
        // subtree can use CA's renderer, preserving its own contents/masks.
        // A returning viewport needs a manual clip even without portals:
        // CA's renderer would still crop it to the old presentation bounds.
        let leadsToPrediction = predictions.hasDescendant(in: layer)
        let changesViewport = prediction.map { $0.bounds != layer.bounds } ?? false
        if leadsToPrediction || changesViewport || portalLookup.containsPortal(layer) {
            renderLayerSubtreeWithBubblePortalFallback(
                layer,
                in: ctx,
                clipRectInLayer: clip,
                predictions: predictions,
                sourceProjections: &sourceProjections,
                portalLookup: &portalLookup
            )
            return
        }

        ctx.saveGState()
        ctx.clip(to: clip)
        layer.render(in: ctx)
        ctx.restoreGState()
    }

    private static func renderLayerSubtreeWithBubblePortalFallback(
        _ layer: CALayer,
        in ctx: CGContext,
        clipRectInLayer: CGRect,
        predictions: GlassCapturePredictions,
        sourceProjections: inout [GlassCapturePrediction],
        portalLookup: inout PortalLookup
    ) {
        guard !clipRectInLayer.isEmpty, !layer.isHidden, layer.opacity > 0 else { return }

        if renderBubblePortalBackgroundLayer(
            layer,
            in: ctx,
            clipRectInLayer: clipRectInLayer,
            sourceProjections: sourceProjections
        ) {
            return
        }

        guard let sublayers = layer.sublayers, !sublayers.isEmpty else {
            ctx.saveGState()
            ctx.clip(to: clipRectInLayer)
            layer.render(in: ctx)
            ctx.restoreGState()
            return
        }

        ctx.saveGState()
        ctx.clip(to: clipRectInLayer)
        if layer.masksToBounds {
            ctx.clip(to: predictions.prediction(for: layer)?.bounds ?? layer.bounds)
        }
        let visibleRect = ctx.boundingBoxOfClipPath
        for child in sublayers {
            guard !child.isHidden, child.opacity > 0 else { continue }
            let prediction = predictions.prediction(for: child)
            let childFrame: CGRect
            if let prediction {
                childFrame = child.convert(prediction.bounds.applying(prediction.transform), to: layer)
            } else {
                childFrame = child.frame
            }
            guard childFrame.intersects(visibleRect) else { continue }
            // An unclipped wrapper can have visible children outside its
            // bounds (e.g. swipe-to-reply). Carry the capture clip through
            // its transform instead of replacing it with child.bounds.
            let childClip = child.convert(visibleRect, from: layer)
            var boundsClip = childClip
            var childBounds = child.bounds
            if let prediction {
                boundsClip = childClip.applying(prediction.inverse)
                childBounds = prediction.bounds
            }
            if child.masksToBounds, !boundsClip.intersects(childBounds) { continue }

            withLayerGeometry(child, in: ctx) {
                renderLayer(child, in: ctx, clipRectInLayer: childClip,
                            predictions: predictions, sourceProjections: &sourceProjections,
                            portalLookup: &portalLookup)
            }
        }
        ctx.restoreGState()
    }

    static func withLayerGeometry(
        _ layer: CALayer,
        in ctx: CGContext,
        body: () -> Void
    ) {
        ctx.saveGState()
        ctx.translateBy(x: layer.position.x, y: layer.position.y)

        let transform = layer.transform
        if CATransform3DIsAffine(transform) {
            ctx.concatenate(CATransform3DGetAffineTransform(transform))
        }

        ctx.translateBy(
            x: -layer.bounds.minX - layer.bounds.width * layer.anchorPoint.x,
            y: -layer.bounds.minY - layer.bounds.height * layer.anchorPoint.y
        )
        body()
        ctx.restoreGState()
    }

    private static func isBubblePortalBackgroundLayer(_ layer: CALayer) -> Bool {
        layer.name == BubblePortalBackgroundNode.captureLayerName
    }

    private static func renderBubblePortalBackgroundLayer(
        _ layer: CALayer,
        in ctx: CGContext,
        clipRectInLayer: CGRect,
        sourceProjections: [GlassCapturePrediction]
    ) -> Bool {
        guard isBubblePortalBackgroundLayer(layer),
              let hostView = layer.model().delegate as? UIView,
              let sourceView = BubblePortalBackgroundNode.captureSourceView(for: hostView),
              !layer.isHidden,
              layer.opacity > 0 else {
            return false
        }

        ctx.saveGState()
        ctx.clip(to: clipRectInLayer)

        if let maskLayer = layer.mask as? CAShapeLayer,
           let maskPath = maskLayer.path {
            ctx.addPath(maskPath)
            ctx.clip()
        } else {
            ctx.clip(to: layer.bounds)
        }

        renderPortalSource(sourceView, in: ctx, mappedTo: layer, hostView: hostView,
                           sourceProjections: sourceProjections)

        ctx.restoreGState()
        return true
    }

    private static func renderPortalSource(
        _ sourceView: PortalSourceView,
        in ctx: CGContext,
        mappedTo hostLayer: CALayer,
        hostView: UIView,
        sourceProjections: [GlassCapturePrediction]
    ) {
        let sourceSubviews = sourceView.subviews.filter { !$0.isHidden && $0.alpha > 0 }
        if sourceSubviews.isEmpty {
            renderSourceView(sourceView, in: ctx, mappedTo: hostLayer, hostView: hostView,
                             sourceProjections: sourceProjections)
        } else {
            for sourceSubview in sourceSubviews {
                renderSourceView(sourceSubview, in: ctx, mappedTo: hostLayer, hostView: hostView,
                                 sourceProjections: sourceProjections)
            }
        }
    }

    private static func renderSourceView(
        _ sourceView: UIView,
        in ctx: CGContext,
        mappedTo hostLayer: CALayer,
        hostView: UIView,
        sourceProjections: [GlassCapturePrediction]
    ) {
        let usesPresentation = hostLayer !== hostView.layer
        let sourceLayer = usesPresentation
            ? (sourceView.layer.presentation() ?? sourceView.layer)
            : sourceView.layer
        guard !sourceLayer.bounds.isEmpty else { return }

        let convert: (CGPoint) -> CGPoint
        if !usesPresentation {
            // Model snapshots also run after reparenting into the menu window.
            convert = { sourceView.convert($0, to: hostView) }
        } else if let sourceWindow = sourceView.window,
                  sourceWindow === hostView.window,
                  sourceLayer !== sourceView.layer {
            // Match the actual layer being captured, including ancestor shrink
            // and scroll animations. Never mix model and presentation trees.
            convert = { sourceLayer.convert($0, to: hostLayer) }
        } else if let sourceWindow = sourceView.window,
                  let hostWindow = hostView.window,
                  let hostWindowLayer = hostWindow.layer.presentation() {
            // Bridge window coordinate spaces if the host was reparented, or
            // the source has not acquired a presentation layer yet.
            guard let sourceWindowLayer = sourceLayer === sourceView.layer
                ? sourceWindow.layer
                : sourceWindow.layer.presentation() else { return }
            convert = { point in
                let inSourceWindow = sourceLayer.convert(point, to: sourceWindowLayer)
                let inHostWindow = sourceWindow.convert(inSourceWindow, to: hostWindow)
                return hostLayer.convert(inHostWindow, from: hostWindowLayer)
            }
        } else {
            return
        }

        // A converted CGRect loses orientation; using only its origin also
        // drops scale. Map a basis to preserve the full affine geometry.
        func projectedPoint(_ point: CGPoint) -> CGPoint {
            var mapped = convert(point)
            // Predict the mask and content together, but keep the portal's
            // shared gradient fixed in window space (matchesPosition).
            // Undo ancestor motion before child motion. The traversal stack
            // contains only this portal's branch, independent of start order.
            for projection in sourceProjections {
                mapped = projection.sourcePoint(mapped, in: hostLayer)
            }
            return mapped
        }
        let origin = projectedPoint(.zero)
        let xAxis = projectedPoint(CGPoint(x: 1, y: 0))
        let yAxis = projectedPoint(CGPoint(x: 0, y: 1))
        let transform = CGAffineTransform(
            a: xAxis.x - origin.x, b: xAxis.y - origin.y,
            c: yAxis.x - origin.x, d: yAxis.y - origin.y,
            tx: origin.x, ty: origin.y
        )

        ctx.saveGState()
        ctx.concatenate(transform)
        sourceLayer.render(in: ctx)
        ctx.restoreGState()
    }
}
