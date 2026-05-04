//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Configurable glass navigation bar with island shapes.
///
/// Circle buttons are fixed 36x36 circles. Buttons before `.title`
/// in the items array are placed on the left, buttons after — on the right.
/// The `.title` is centered on the bar axis, fitted to its content width.
final class GlassTopBar: ASDisplayNode {

    // MARK: - Item

    enum Item {
        case circleButton(icon: UIImage, accessibilityLabel: String, action: () -> Void)
        case title(text: String, subtitle: String?)
        /// Splits items into left / right groups without a visual element.
        case flexibleSpace
    }

    // MARK: - Public

    var items: [Item] = [] {
        didSet { rebuildContent() }
    }

    var onTitleTapped: (() -> Void)?

    /// Updates the subtitle of the first `.title` item and recalculates glass width.
    var subtitle: String? {
        didSet {
            for entry in entries where entry.kind == .title {
                guard let tv = entry.titleView else { continue }
                tv.subtitle = subtitle
                fittedTitleW = tv.contentWidth + titleHPad * 2
                invalidateGlassGeometry()
                break
            }
        }
    }

    /// The view to capture as glass background (e.g. the table/scroll view).
    weak var sourceView: UIView? {
        didSet { anchor.sourceView = sourceView }
    }

    /// Background color the glass should sample where `sourceView` has no cells.
    var backdropClearColor: UIColor = .systemBackground {
        didSet { anchor.backdropClearColor = backdropClearColor }
    }

    /// Total height from top of screen (safeArea + bar).
    var coveredHeight: CGFloat {
        guard let parentView = view.superview else { return 0 }
        return parentView.safeAreaInsets.top + barHeight
    }

    // MARK: - Constants

    private let barHeight: CGFloat = 44
    private let sideInset: CGFloat = 6
    private let btnSize: CGFloat = 36
    private let btnPad: CGFloat = 8
    private let cornerR: CGFloat = 20
    private let titleHPad: CGFloat = 12
    private let gap: CGFloat = 6

    // MARK: - Glass (UIView, added in didLoad)

    private let anchor = GlassAnchor()

    // MARK: - Built content

    private struct Entry {
        enum Kind { case circle, title, flexibleSpace }
        let kind: Kind
        /// nil for `.flexibleSpace`.
        let node: ASDisplayNode?
        /// Non-nil for `.title` entries — direct access to the wrapped UIView.
        let titleView: GlassTopBarTitleView?
    }

    private var entries: [Entry] = []
    private var fittedTitleW: CGFloat = 0
    private var glassMaterial = GlassAdaptiveMaterial.light

    // MARK: - Init

    override init() {
        super.init()
    }

    // MARK: - didLoad

    override func didLoad() {
        super.didLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = false

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

        // Subnodes may already exist (items set before node loaded).
        view.sendSubviewToBack(anchor)
        applyGlassAdaptiveMaterial(anchor.adaptiveMaterial)
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
        layoutEntries(in: bounds)
    }

    private func layoutEntries(in rect: CGRect) {
        guard !entries.isEmpty else { return }

        let cy = rect.height / 2
        let dividerIdx = entries.firstIndex { $0.kind == .title || $0.kind == .flexibleSpace }

        // Left circles (before divider)
        var leftX = btnPad
        for (i, entry) in entries.enumerated() {
            guard entry.kind == .circle, let node = entry.node else { continue }
            guard dividerIdx == nil || i < dividerIdx! else { break }
            node.frame = CGRect(x: leftX, y: cy - btnSize / 2, width: btnSize, height: btnSize)
            leftX += btnSize + gap
        }

        // Right circles (after divider), placed right-to-left
        var rightX = rect.width - btnPad
        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            let entry = entries[i]
            guard entry.kind == .circle, let node = entry.node else { continue }
            guard let di = dividerIdx, i > di else { break }
            rightX -= btnSize
            node.frame = CGRect(x: rightX, y: cy - btnSize / 2, width: btnSize, height: btnSize)
            rightX -= gap
        }

        // Title: centered. Only `.title` has a node; `.flexibleSpace` is invisible.
        if let di = dividerIdx, entries[di].kind == .title, let titleNode = entries[di].node {
            let leftCount = entries[..<di].filter { $0.kind == .circle }.count
            let rightCount = entries[(di + 1)...].filter { $0.kind == .circle }.count
            let sideSlots = max(leftCount, rightCount)
            let maxW = rect.width - (btnPad + CGFloat(sideSlots) * (btnSize + gap)) * 2
            let w = min(fittedTitleW, maxW)
            let x = (rect.width - w) / 2
            titleNode.frame = CGRect(x: x, y: 0, width: w, height: rect.height)
        }
    }

    // MARK: - Content rebuilding

    private func rebuildContent() {
        // Tear down previous
        for entry in entries {
            entry.node?.removeFromSupernode()
        }
        entries.removeAll()

        for item in items {
            switch item {
            case .circleButton(let icon, let label, let action):
                let btn = AccessibleButtonNode()
                btn.setImage(icon.withRenderingMode(.alwaysTemplate), for: .normal)
                btn.imageNode.tintColor = glassMaterial.glyphForeground
                btn.isAccessibilityElement = true
                btn.accessibilityLabel = label
                btn.accessibilityTraits = .button
                btn.style.preferredSize = CGSize(width: btnSize, height: btnSize)
                let handler = action
                btn.addTarget(self, action: #selector(circleButtonTapped(_:)), forControlEvents: .touchUpInside)
                // Store the action in the node's user data
                objc_setAssociatedObject(btn, &GlassTopBar.actionKey, handler, .OBJC_ASSOCIATION_COPY_NONATOMIC)
                addSubnode(btn)
                entries.append(Entry(kind: .circle, node: btn, titleView: nil))

            case .title(let text, let subtitle):
                let tv = GlassTopBarTitleView()
                tv.text = text
                tv.subtitle = subtitle
                tv.applyGlassAdaptiveMaterial(glassMaterial)
                tv.onTapped = { [weak self] in self?.onTitleTapped?() }
                let titleNode = ASDisplayNode(viewBlock: { tv })
                addSubnode(titleNode)
                entries.append(Entry(kind: .title, node: titleNode, titleView: tv))
                fittedTitleW = tv.contentWidth + titleHPad * 2

            case .flexibleSpace:
                entries.append(Entry(kind: .flexibleSpace, node: nil, titleView: nil))
            }
        }

        applyGlassAdaptiveMaterial(glassMaterial)

        // Ensure glass renderer stays behind interactive content
        if isNodeLoaded {
            view.sendSubviewToBack(anchor)
        }

        invalidateGlassGeometry()
    }

    private func invalidateGlassGeometry() {
        setNeedsLayout()
        layoutIfNeeded()
        guard isNodeLoaded else { return }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        GlassService.shared.setNeedsCapture()
    }

    /// Accessibility targets (title + circle buttons) in items-array
    /// order. Screens can take this array and reorder to taste when
    /// overriding their own `accessibilityElements`.
    var accessibilityElementsInOrder: [UIView] {
        guard isNodeLoaded else { return [] }
        return entries.compactMap { entry in
            switch entry.kind {
            case .title: return entry.titleView
            case .circle: return entry.node?.view
            case .flexibleSpace: return nil
            }
        }
    }

    private static var actionKey: UInt8 = 0

    @objc private func circleButtonTapped(_ sender: ASButtonNode) {
        if let action = objc_getAssociatedObject(sender, &GlassTopBar.actionKey) as? () -> Void {
            action()
        }
    }

    // MARK: - Shape building

    private func buildShapes(glassFrame: CGRect, captureFrame: CGRect, scale: CGFloat) -> GlassRenderer.ShapeParams {
        var p = GlassRenderer.ShapeParams()
        let cw = captureFrame.width
        let ch = captureFrame.height
        guard cw > 0, ch > 0 else { return p }

        let barW = glassFrame.width
        let dividerIdx = entries.firstIndex { $0.kind == .title || $0.kind == .flexibleSpace }

        var circleIndex = 0

        func addCircleShape(x: CGFloat) {
            let cx = glassFrame.origin.x + x + btnSize / 2
            let cy = glassFrame.midY
            let shape = SIMD4<Float>(
                Float((cx - captureFrame.origin.x) / cw),
                Float((cy - captureFrame.origin.y) / ch),
                Float((btnSize / 2) / ch),
                0
            )
            switch circleIndex {
            case 0: p.shape1 = shape
            case 1: p.shape2 = shape
            case 2: p.shape3 = shape
            default: break
            }
            circleIndex += 1
        }

        // Left circles (before divider)
        var leftX = btnPad
        for (i, entry) in entries.enumerated() {
            guard entry.kind == .circle else { continue }
            guard dividerIdx == nil || i < dividerIdx! else { break }
            addCircleShape(x: leftX)
            leftX += btnSize + gap
        }

        // Right circles (after divider), placed right-to-left
        var rightX = barW - btnPad
        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            guard entries[i].kind == .circle else { continue }
            guard let di = dividerIdx, i > di else { break }
            rightX -= btnSize
            addCircleShape(x: rightX)
            rightX -= gap
        }

        if let di = dividerIdx, entries[di].kind == .title {
            let leftCount = entries[..<di].filter { $0.kind == .circle }.count
            let rightCount = entries[(di + 1)...].filter { $0.kind == .circle }.count
            let sideSlots = max(leftCount, rightCount)
            let maxW = barW - (btnPad + CGFloat(sideSlots) * (btnSize + gap)) * 2
            let w = min(fittedTitleW, maxW)
            let x = glassFrame.origin.x + (barW - w) / 2
            p.shape0 = SIMD4<Float>(
                Float((x - captureFrame.origin.x) / cw),
                Float((glassFrame.origin.y - captureFrame.origin.y) / ch),
                Float(w / cw),
                Float(glassFrame.height / ch)
            )
            p.shape0cornerR = Float(cornerR * scale) / Float(ch * scale)
        }

        // Shader gates shape1 on `shapeCount >= 2`, shape2 on `>= 3`, etc.
        // Always reserve shape0's slot so circles light up when title is absent.
        // Degenerate (zero) shape0 has no effect on the SDF union.
        p.shapeCount = Float(1 + circleIndex)
        return p
    }

    private func applyGlassAdaptiveMaterial(_ material: GlassAdaptiveMaterial) {
        glassMaterial = material
        let glyph = material.glyphForeground
        for entry in entries {
            switch entry.kind {
            case .circle:
                guard let button = entry.node as? ASButtonNode else { continue }
                button.imageNode.tintColor = glyph
            case .title:
                entry.titleView?.applyGlassAdaptiveMaterial(material)
            case .flexibleSpace:
                break
            }
        }
    }
}

// MARK: - Title view

private final class GlassTopBarTitleView: UIView {

    var text: String = "" {
        didSet {
            titleLabel.text = text
            updateAccessibilityLabel()
            setNeedsLayout()
        }
    }

    var subtitle: String? {
        didSet {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = subtitle == nil
            updateAccessibilityLabel()
            setNeedsLayout()
        }
    }

    var onTapped: (() -> Void)?

    var contentWidth: CGFloat {
        let titleW = titleLabel.intrinsicContentSize.width
        let subW = subtitleLabel.isHidden ? 0 : subtitleLabel.intrinsicContentSize.width
        return ceil(max(titleW, subW))
    }

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var glassMaterial = GlassAdaptiveMaterial.light

    override init(frame: CGRect) {
        super.init(frame: frame)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = glassMaterial.primaryForeground
        titleLabel.textAlignment = .center

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = glassMaterial.secondaryForeground
        subtitleLabel.textAlignment = .center
        subtitleLabel.isHidden = true

        addSubview(titleLabel)
        addSubview(subtitleLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        if subtitleLabel.isHidden {
            titleLabel.frame = b
        } else {
            let titleH = ceil(titleLabel.font.lineHeight)
            let subH = ceil(subtitleLabel.font.lineHeight)
            let totalH = titleH + 1 + subH
            let topY = (b.height - totalH) / 2
            titleLabel.frame = CGRect(x: 0, y: topY, width: b.width, height: titleH)
            subtitleLabel.frame = CGRect(x: 0, y: topY + titleH + 1, width: b.width, height: subH)
        }
    }

    @objc private func handleTap() { onTapped?() }

    private func updateAccessibilityLabel() {
        var label = text
        if let subtitle, !subtitle.isEmpty {
            label += ", \(subtitle)"
        }
        accessibilityLabel = label
    }

    func applyGlassAdaptiveMaterial(_ material: GlassAdaptiveMaterial) {
        glassMaterial = material
        titleLabel.textColor = material.primaryForeground
        subtitleLabel.textColor = material.secondaryForeground
    }
}
