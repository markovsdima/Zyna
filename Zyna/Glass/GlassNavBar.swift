//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Glass navigation bar with 3 island shapes: back (circle), title (rounded rect), call (circle).
final class GlassNavBar: ASDisplayNode {

    // MARK: - Public

    var onBack: (() -> Void)?
    var onCall: (() -> Void)?
    var onTitleTapped: (() -> Void)?

    var name: String = "" {
        didSet { titleNode.name = name; setNeedsLayout() }
    }

    var presence: UserPresence? {
        didSet { titleNode.presence = presence; setNeedsLayout() }
    }

    var memberCount: Int? {
        didSet { titleNode.memberCount = memberCount; setNeedsLayout() }
    }

    var isTappable: Bool = false {
        didSet { titleNode.isTappable = isTappable }
    }

    /// The view to capture as glass background (e.g. the table/scroll view).
    weak var sourceView: UIView? {
        didSet { anchor.sourceView = sourceView }
    }

    /// Background color the glass should sample where `sourceView`
    /// has no cells. Defaults to the chat background; override only
    /// if hosting glass over a non-chat surface.
    var backdropClearColor: UIColor = AppColor.chatBackground {
        didSet { anchor.backdropClearColor = backdropClearColor }
    }

    /// Total height from top of screen (safeArea + bar).
    var coveredHeight: CGFloat {
        guard let supernode else { return 0 }
        return supernode.view.safeAreaInsets.top + barHeight
    }

    // MARK: - Subnodes

    let backButtonNode = AccessibleButtonNode()
    let callButtonNode = AccessibleButtonNode()
    let titleNode = PresenceTitleNode()

    // MARK: - Glass (UIView, added in didLoad)

    private let anchor = GlassAnchor()

    // MARK: - Constants

    private let barHeight: CGFloat = 44
    private let sideInset: CGFloat = 6
    private let btnSize: CGFloat = 36
    private let btnPad: CGFloat = 8
    private let cornerR: CGFloat = 20
    private let titleHPad: CGFloat = 12
    private var cachedTitleW: CGFloat = 0
    private var glassMaterial = GlassAdaptiveMaterial.light

    // MARK: - Init

    override init() {
        super.init()
        anchor.debugName = "nav"

        backButtonNode.setImage(
            AppIcon.chevronLeft.template(size: 17, weight: .semibold),
            for: .normal
        )
        backButtonNode.imageNode.tintColor = glassMaterial.glyphForeground
        backButtonNode.isAccessibilityElement = true
        backButtonNode.accessibilityLabel = "Back"
        backButtonNode.accessibilityTraits = .button
        backButtonNode.style.preferredSize = CGSize(width: btnSize, height: btnSize)

        callButtonNode.setImage(
            AppIcon.phone.template(size: 16, weight: .medium),
            for: .normal
        )
        callButtonNode.imageNode.tintColor = glassMaterial.glyphForeground
        callButtonNode.isAccessibilityElement = true
        callButtonNode.accessibilityLabel = "Call"
        callButtonNode.accessibilityTraits = .button
        callButtonNode.style.preferredSize = CGSize(width: btnSize, height: btnSize)
    }

    // MARK: - Accessibility

    /// Override to enforce reading order: back → title → call.
    /// Without this, Texture iterates subviews and may interleave with
    /// anchor/renderer or sort by frame in unexpected ways.
    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if backButtonNode.isNodeLoaded { elements.append(backButtonNode.view) }
            if titleNode.isNodeLoaded { elements.append(titleNode.view) }
            if callButtonNode.isNodeLoaded { elements.append(callButtonNode.view) }
            return elements
        }
        set { }
    }

    // MARK: - didLoad

    override func didLoad() {
        super.didLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = false

        // Glass UIView parts — below subnode views
        anchor.cornerRadius = cornerR
        anchor.shapeProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildShapes(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
                ?? GlassRenderer.ShapeParams()
        }
        anchor.onAdaptiveMaterialChanged = { [weak self] material in
            self?.applyGlassAdaptiveMaterial(material)
        }
        view.addSubview(anchor)
        anchor.accessibilityElementsHidden = true

        // Subnodes on top of renderer
        addSubnode(backButtonNode)
        addSubnode(titleNode)
        addSubnode(callButtonNode)
        applyGlassAdaptiveMaterial(anchor.adaptiveMaterial)

        view.sendSubviewToBack(anchor)

        backButtonNode.addTarget(self, action: #selector(backTapped), forControlEvents: .touchUpInside)
        callButtonNode.addTarget(self, action: #selector(callTapped), forControlEvents: .touchUpInside)
        titleNode.onTapped = { [weak self] in self?.onTitleTapped?() }
    }

    // MARK: - Layout

    func updateLayout(in parentView: UIView) {
        let safeTop = parentView.safeAreaInsets.top
        let fullWidth = parentView.bounds.width
        let barWidth = fullWidth - sideInset * 2

        frame = CGRect(x: sideInset, y: safeTop, width: barWidth, height: barHeight)
        anchor.frame = bounds
        anchor.renderHostContainerView = parentView
    }

    override func layout() {
        super.layout()
        let rect = bounds
        let cy = rect.height / 2

        // Back button (left circle)
        backButtonNode.frame = CGRect(
            x: btnPad,
            y: cy - btnSize / 2,
            width: btnSize,
            height: btnSize
        )

        // Call button (right circle)
        callButtonNode.frame = CGRect(
            x: rect.width - btnPad - btnSize,
            y: cy - btnSize / 2,
            width: btnSize,
            height: btnSize
        )

        // Title (center, fitted to content)
        let maxTitleW = rect.width - (btnPad + btnSize + btnPad) * 2
        cachedTitleW = fittedTitleWidth(maxWidth: maxTitleW)
        let titleW = cachedTitleW
        let titleX = (rect.width - titleW) / 2
        titleNode.frame = CGRect(x: titleX, y: 0, width: titleW, height: rect.height)
    }

    private func fittedTitleWidth(maxWidth: CGFloat) -> CGFloat {
        let fitWidth = titleNode.contentWidth
        guard fitWidth > 0 else { return maxWidth }
        return min(fitWidth + titleHPad * 2, maxWidth)
    }

    // MARK: - Actions

    @objc private func backTapped() { onBack?() }
    @objc private func callTapped() { onCall?() }

    // MARK: - Multi-shape

    private func buildShapes(glassFrame: CGRect, captureFrame: CGRect, scale: CGFloat) -> GlassRenderer.ShapeParams {
        var p = GlassRenderer.ShapeParams()
        let cw = captureFrame.width
        let ch = captureFrame.height
        guard cw > 0, ch > 0 else { return p }

        let cy = glassFrame.midY

        // Back button (circle, left)
        let backCX = glassFrame.origin.x + btnPad + btnSize / 2
        let backCY = cy
        let backR = btnSize / 2

        // Call button (circle, right)
        let callCX = glassFrame.maxX - btnPad - btnSize / 2
        let callCY = cy
        let callR = btnSize / 2

        // Title (rounded rect, center — use cached width from layout)
        let maxTitleW = glassFrame.width - (btnPad + btnSize + btnPad) * 2
        let titleW = cachedTitleW > 0 ? cachedTitleW : fittedTitleWidth(maxWidth: maxTitleW)
        let titleX = glassFrame.origin.x + (glassFrame.width - titleW) / 2
        let titleY = glassFrame.origin.y
        let titleH = glassFrame.height

        // Shape 0: title (rounded rect)
        p.shape0 = SIMD4<Float>(
            Float((titleX - captureFrame.origin.x) / cw),
            Float((titleY - captureFrame.origin.y) / ch),
            Float(titleW / cw),
            Float(titleH / ch)
        )
        p.shape0cornerR = Float(cornerR * scale) / Float(ch * scale)

        // Shape 1: back button (circle)
        p.shape1 = SIMD4<Float>(
            Float((backCX - captureFrame.origin.x) / cw),
            Float((backCY - captureFrame.origin.y) / ch),
            Float(backR / ch),
            0
        )

        // Shape 2: call button (circle)
        p.shape2 = SIMD4<Float>(
            Float((callCX - captureFrame.origin.x) / cw),
            Float((callCY - captureFrame.origin.y) / ch),
            Float(callR / ch),
            0
        )

        p.shapeCount = 3
        return p
    }

    private func applyGlassAdaptiveMaterial(_ material: GlassAdaptiveMaterial) {
        glassMaterial = material
        let glyph = material.glyphForeground
        backButtonNode.imageNode.tintColor = glyph
        callButtonNode.imageNode.tintColor = glyph
        titleNode.applyGlassAdaptiveMaterial(material)
    }
}
