//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Configurable glass navigation bar with island shapes.
///
/// Circle buttons are fixed 36x36 circles. Buttons before `.title`
/// in the items array are placed on the left, buttons after — on the right.
/// The `.title` is centered on the bar axis, fitted to its content width.
final class GlassTopBar: UIView {

    // MARK: - Item

    enum Item {
        case circleButton(icon: UIImage, action: () -> Void)
        case title(text: String, subtitle: String?)
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
                guard let tv = entry.view as? GlassTopBarTitleView else { continue }
                tv.subtitle = subtitle
                fittedTitleW = tv.contentWidth + titleHPad * 2
                setNeedsLayout()
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
        guard let superview else { return 0 }
        return superview.safeAreaInsets.top + barHeight
    }

    // MARK: - Constants

    private let barHeight: CGFloat = 44
    private let sideInset: CGFloat = 6
    private let btnSize: CGFloat = 36
    private let btnPad: CGFloat = 8
    private let cornerR: CGFloat = 20
    private let titleHPad: CGFloat = 12
    private let gap: CGFloat = 6

    // MARK: - Glass

    private let anchor = GlassAnchor()
    private let contentView = UIView()

    // MARK: - Built content

    /// Ordered entries matching `items`. Rebuilt on every `items` set.
    private struct Entry {
        enum Kind { case circle, title }
        let kind: Kind
        let view: UIView
    }

    private var entries: [Entry] = []
    /// Cached fitted title width (content + padding). Set in rebuildContent, stable from frame 0.
    private var fittedTitleW: CGFloat = 0

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false

        anchor.cornerRadius = cornerR
        anchor.shapeProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildShapes(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
                ?? GlassRenderer.ShapeParams()
        }
        addSubview(anchor)
        addSubview(anchor.renderer)

        contentView.backgroundColor = .clear
        addSubview(contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Hit testing

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let contentPoint = contentView.convert(point, from: self)
        if let hit = contentView.hitTest(contentPoint, with: event) {
            return hit
        }
        return nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let contentPoint = contentView.convert(point, from: self)
        return contentView.point(inside: contentPoint, with: event)
    }

    // MARK: - Layout

    func updateLayout(in parentView: UIView) {
        let safeTop = parentView.safeAreaInsets.top
        let fullWidth = parentView.bounds.width
        let barWidth = fullWidth - sideInset * 2

        frame = CGRect(x: sideInset, y: safeTop, width: barWidth, height: barHeight)
        anchor.frame = bounds
        contentView.frame = bounds
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutEntries(in: bounds)
    }

    private func layoutEntries(in rect: CGRect) {
        guard !entries.isEmpty else { return }

        let cy = rect.height / 2
        let titleIdx = entries.firstIndex { $0.kind == .title }

        // Left circles (before title)
        var leftX = btnPad
        for (i, entry) in entries.enumerated() {
            guard entry.kind == .circle else { continue }
            guard titleIdx == nil || i < titleIdx! else { break }
            entry.view.frame = CGRect(x: leftX, y: cy - btnSize / 2, width: btnSize, height: btnSize)
            leftX += btnSize + gap
        }

        // Right circles (after title), placed right-to-left
        var rightX = rect.width - btnPad
        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            let entry = entries[i]
            guard entry.kind == .circle else { continue }
            guard let ti = titleIdx, i > ti else { break }
            rightX -= btnSize
            entry.view.frame = CGRect(x: rightX, y: cy - btnSize / 2, width: btnSize, height: btnSize)
            rightX -= gap
        }

        // Title: centered
        if let ti = titleIdx {
            let leftCount = entries[..<ti].filter { $0.kind == .circle }.count
            let rightCount = entries[(ti + 1)...].filter { $0.kind == .circle }.count
            let sideSlots = max(leftCount, rightCount)
            let maxW = rect.width - (btnPad + CGFloat(sideSlots) * (btnSize + gap)) * 2
            let w = min(fittedTitleW, maxW)
            let x = (rect.width - w) / 2
            entries[ti].view.frame = CGRect(x: x, y: 0, width: w, height: rect.height)
        }
    }

    // MARK: - Content rebuilding

    private func rebuildContent() {
        // Tear down previous
        for entry in entries {
            entry.view.removeFromSuperview()
        }
        entries.removeAll()

        for item in items {
            switch item {
            case .circleButton(let icon, let action):
                let btn = GlassCircleButton(icon: icon, action: action)
                contentView.addSubview(btn)
                entries.append(Entry(kind: .circle, view: btn))

            case .title(let text, let subtitle):
                let titleView = GlassTopBarTitleView()
                titleView.text = text
                titleView.subtitle = subtitle
                titleView.onTapped = { [weak self] in self?.onTitleTapped?() }
                contentView.addSubview(titleView)
                entries.append(Entry(kind: .title, view: titleView))
                fittedTitleW = titleView.contentWidth + titleHPad * 2

            }
        }

        setNeedsLayout()
    }

    // MARK: - Shape building

    private func buildShapes(glassFrame: CGRect, captureFrame: CGRect, scale: CGFloat) -> GlassRenderer.ShapeParams {
        var p = GlassRenderer.ShapeParams()
        let cw = captureFrame.width
        let ch = captureFrame.height
        guard cw > 0, ch > 0 else { return p }

        // Compute geometry from constants — no dependency on UIView frames
        let barW = glassFrame.width
        let titleIdx = entries.firstIndex { $0.kind == .title }

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

        // Left circles (before title)
        var leftX = btnPad
        for (i, entry) in entries.enumerated() {
            guard entry.kind == .circle else { continue }
            guard titleIdx == nil || i < titleIdx! else { break }
            addCircleShape(x: leftX)
            leftX += btnSize + gap
        }

        // Right circles (after title), placed right-to-left
        var rightX = barW - btnPad
        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            guard entries[i].kind == .circle else { continue }
            guard let ti = titleIdx, i > ti else { break }
            rightX -= btnSize
            addCircleShape(x: rightX)
            rightX -= gap
        }

        // Title: centered
        var hasRect = false
        if let ti = titleIdx {
            let leftCount = entries[..<ti].filter { $0.kind == .circle }.count
            let rightCount = entries[(ti + 1)...].filter { $0.kind == .circle }.count
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
            hasRect = true
        }

        p.shapeCount = Float((hasRect ? 1 : 0) + circleIndex)
        return p
    }
}

// MARK: - Circle button

private final class GlassCircleButton: UIButton {

    private var action: (() -> Void)?

    init(icon: UIImage, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        setImage(icon, for: .normal)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { action?() }
}

// MARK: - Title view

private final class GlassTopBarTitleView: UIView {

    var text: String = "" {
        didSet { titleLabel.text = text }
    }

    var subtitle: String? {
        didSet {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = subtitle == nil
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

    override init(frame: CGRect) {
        super.init(frame: frame)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.isHidden = true

        addSubview(titleLabel)
        addSubview(subtitleLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
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
}

