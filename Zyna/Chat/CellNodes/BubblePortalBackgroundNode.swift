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
        layer.name = "message.bubblePortalBackground"
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

    static func renderLayerForCapture(
        _ layer: CALayer,
        in ctx: CGContext,
        clipRectInLayer: CGRect
    ) {
        guard !clipRectInLayer.isEmpty else { return }

        if subtreeContainsBubblePortalBackground(layer) {
            renderLayerSubtreeWithBubblePortalFallback(
                layer,
                in: ctx,
                clipRectInLayer: clipRectInLayer
            )
            return
        }

        ctx.saveGState()
        ctx.clip(to: clipRectInLayer)
        layer.render(in: ctx)
        ctx.restoreGState()
    }

    private static func renderLayerSubtreeWithBubblePortalFallback(
        _ layer: CALayer,
        in ctx: CGContext,
        clipRectInLayer: CGRect
    ) {
        guard !clipRectInLayer.isEmpty, !layer.isHidden, layer.opacity > 0 else { return }

        if renderBubblePortalBackgroundLayer(
            layer,
            in: ctx,
            clipRectInLayer: clipRectInLayer
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
        for child in sublayers {
            guard !child.isHidden, child.opacity > 0 else { continue }
            let childFrame = child.frame
            guard childFrame.intersects(clipRectInLayer) else { continue }

            withLayerGeometry(child, in: ctx) {
                renderLayerForCapture(child, in: ctx, clipRectInLayer: child.bounds)
            }
        }
        ctx.restoreGState()
    }

    private static func withLayerGeometry(
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
            x: -layer.bounds.width * layer.anchorPoint.x,
            y: -layer.bounds.height * layer.anchorPoint.y
        )
        body()
        ctx.restoreGState()
    }

    private static func subtreeContainsBubblePortalBackground(_ layer: CALayer) -> Bool {
        if isBubblePortalBackgroundLayer(layer) {
            return true
        }
        return layer.sublayers?.contains(where: subtreeContainsBubblePortalBackground) ?? false
    }

    private static func isBubblePortalBackgroundLayer(_ layer: CALayer) -> Bool {
        if layer.name == "message.bubblePortalBackground" {
            return true
        }
        guard let hostView = layer.delegate as? UIView else { return false }
        return BubblePortalBackgroundNode.captureSourceView(for: hostView) != nil
    }

    private static func renderBubblePortalBackgroundLayer(
        _ layer: CALayer,
        in ctx: CGContext,
        clipRectInLayer: CGRect
    ) -> Bool {
        guard let hostView = layer.delegate as? UIView,
              let sourceView = BubblePortalBackgroundNode.captureSourceView(for: hostView),
              !hostView.isHidden,
              hostView.alpha > 0 else {
            return false
        }

        ctx.saveGState()
        ctx.clip(to: clipRectInLayer)

        if let maskLayer = hostView.layer.mask as? CAShapeLayer,
           let maskPath = maskLayer.path {
            ctx.addPath(maskPath)
            ctx.clip()
        } else {
            ctx.clip(to: hostView.bounds)
        }

        renderPortalSource(sourceView, in: ctx, mappedTo: hostView)

        ctx.restoreGState()
        return true
    }

    private static func renderPortalSource(
        _ sourceView: PortalSourceView,
        in ctx: CGContext,
        mappedTo hostView: UIView
    ) {
        let sourceSubviews = sourceView.subviews.filter { !$0.isHidden && $0.alpha > 0 }
        if sourceSubviews.isEmpty {
            renderSourceView(sourceView, in: ctx, mappedTo: hostView)
        } else {
            for sourceSubview in sourceSubviews {
                renderSourceView(sourceSubview, in: ctx, mappedTo: hostView)
            }
        }
    }

    private static func renderSourceView(
        _ sourceView: UIView,
        in ctx: CGContext,
        mappedTo hostView: UIView
    ) {
        let sourceFrame = sourceView.convert(sourceView.bounds, to: hostView)
        guard !sourceFrame.isEmpty else { return }

        ctx.saveGState()
        ctx.translateBy(x: sourceFrame.minX, y: sourceFrame.minY)
        sourceView.layer.render(in: ctx)
        ctx.restoreGState()
    }
}
