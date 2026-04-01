//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Glass navigation bar with 3 island shapes: back (circle), title (rounded rect), call (circle).
/// Lives in the main window; interactive content placed above glass renderer via GlassService.
final class GlassNavBar: UIView {

    // MARK: - Public

    var onBack: (() -> Void)?
    var onCall: (() -> Void)?
    var onTitleTapped: (() -> Void)?

    var name: String = "" {
        didSet { titleView.name = name; setNeedsLayout() }
    }

    var presence: UserPresence? {
        didSet { titleView.presence = presence; setNeedsLayout() }
    }

    var isTappable: Bool = false {
        didSet { titleView.isTappable = isTappable }
    }

    /// The view to capture as glass background (e.g. the table/scroll view).
    weak var sourceView: UIView? {
        didSet { anchor.sourceView = sourceView }
    }

    /// Total height from top of screen (safeArea + bar).
    var coveredHeight: CGFloat {
        guard let superview else { return 0 }
        return superview.safeAreaInsets.top + barHeight
    }

    // MARK: - Private

    private let anchor = GlassAnchor()
    private let contentView = UIView()

    private let backButton = UIButton(type: .system)
    private let callButton = UIButton(type: .system)
    private let titleView = PresenceTitleView()

    private let barHeight: CGFloat = 44
    private let sideInset: CGFloat = 6
    private let btnSize: CGFloat = 36
    private let btnPad: CGFloat = 8
    private let cornerR: CGFloat = 20
    private let titleHPad: CGFloat = 12
    private var cachedTitleW: CGFloat = 0

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        anchor.cornerRadius = cornerR
        anchor.shapeProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildShapes(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
                ?? GlassRenderer.ShapeParams()
        }
        addSubview(anchor)

        // Content (placed above glass renderer in main window)
        contentView.backgroundColor = .clear

        backButton.setImage(
            UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
            for: .normal
        )
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)

        callButton.setImage(
            UIImage(systemName: "phone.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)),
            for: .normal
        )
        callButton.addTarget(self, action: #selector(callTapped), for: .touchUpInside)

        titleView.onTapped = { [weak self] in self?.onTitleTapped?() }

        contentView.addSubview(backButton)
        contentView.addSubview(titleView)
        contentView.addSubview(callButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            GlassService.shared.attachContent(contentView, for: anchor)
        } else {
            contentView.removeFromSuperview()
        }
    }

    // MARK: - Layout

    func updateLayout(in parentView: UIView) {
        let safeTop = parentView.safeAreaInsets.top
        let fullWidth = parentView.bounds.width
        let barWidth = fullWidth - sideInset * 2

        frame = CGRect(x: sideInset, y: safeTop, width: barWidth, height: barHeight)
        anchor.frame = bounds
    }

    /// Called by GlassService when positioning content above renderer.
    /// Content frame is set to glassFrame by the service, so we layout relative to bounds.
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutContent(in: bounds)
    }

    private func layoutContent(in rect: CGRect) {
        let cy = rect.height / 2

        // Back button (left circle)
        backButton.frame = CGRect(
            x: btnPad,
            y: cy - btnSize / 2,
            width: btnSize,
            height: btnSize
        )

        // Call button (right circle)
        callButton.frame = CGRect(
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
        titleView.frame = CGRect(x: titleX, y: 0, width: titleW, height: rect.height)
    }

    private func fittedTitleWidth(maxWidth: CGFloat) -> CGFloat {
        let fitWidth = titleView.contentWidth
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

        // Title (rounded rect, center — use cached width from layoutContent)
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
}
