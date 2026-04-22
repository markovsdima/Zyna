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
