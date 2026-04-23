//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//
// Side-by-side comparison: Apple Liquid Glass vs custom glass.
// Place above the chat content to compare refraction on the same background.
//

import UIKit

/// Visual comparison of Apple's Liquid Glass vs our custom glass shader.
/// Shows matching shapes: rounded rect + 2 circles, Apple on top, ours below.
///
/// Usage:
///     let comparison = GlassComparisonView()
///     comparison.sourceView = tableNode.view
///     view.addSubview(comparison)
///     comparison.updateLayout(in: view)
///
final class GlassComparisonView: UIView {

    /// The view to capture as glass background (same as input bar uses).
    weak var sourceView: UIView? {
        didSet { anchor.sourceView = sourceView }
    }

    // MARK: - Layout constants (match GlassInputBar)

    private let barHeight: CGFloat = 56
    private let hPad: CGFloat = 14
    private let vPad: CGFloat = 4
    private let btnSize: CGFloat = 48
    private let spacing: CGFloat = 8
    private let gap: CGFloat = 16   // gap between Apple and custom bars
    private var contentH: CGFloat { barHeight - vPad * 2 }
    private var cornerR: CGFloat { contentH / 2 }  // perfect capsule

    // MARK: - Apple glass (top)

    private var appleRect: UIView?
    private var appleCircleL: UIView?
    private var appleCircleR: UIView?

    // MARK: - Custom glass (bottom)

    private let anchor = GlassAnchor()
    private let contentView = UIView()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        setupAppleGlass()
        setupCustomGlass()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Apple Glass

    private func setupAppleGlass() {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .clear)

            // Rounded rect
            let rect = UIVisualEffectView(effect: glass)
            rect.layer.cornerRadius = cornerR
            rect.layer.cornerCurve = .continuous
            rect.clipsToBounds = true
            addSubview(rect)
            appleRect = rect

            // Left circle
            let circL = UIVisualEffectView(effect: glass)
            circL.clipsToBounds = true
            addSubview(circL)
            appleCircleL = circL

            // Right circle
            let circR = UIVisualEffectView(effect: glass)
            circR.clipsToBounds = true
            addSubview(circR)
            appleCircleR = circR
        }

        let label = UILabel()
        label.text = "Apple"
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.5)
        label.tag = 100
        addSubview(label)
    }

    // MARK: - Custom Glass

    private func setupCustomGlass() {
        anchor.cornerRadius = cornerR
        anchor.shapeProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildShapes(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
                ?? GlassRenderer.ShapeParams()
        }
        addSubview(anchor)

        contentView.backgroundColor = .clear
        addSubview(contentView)

        let label = UILabel()
        label.text = "Custom"
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.5)
        label.tag = 101
        contentView.addSubview(label)
    }

    // MARK: - Lifecycle

    // MARK: - Layout

    func updateLayout(in parentView: UIView) {
        let fullWidth = parentView.bounds.width
        let barWidth = fullWidth - 12

        // Two bars stacked: Apple on top, Custom below
        let totalHeight = barHeight * 2 + gap
        let topY = parentView.bounds.midY - totalHeight / 2

        frame = CGRect(x: 6, y: topY, width: barWidth, height: totalHeight)
        anchor.frame = CGRect(x: 0, y: barHeight + gap, width: barWidth, height: barHeight)
        anchor.renderHostContainerView = parentView

        layoutAppleShapes(y: 0, width: barWidth)
        layoutLabel(tag: 100, y: -14)
        layoutLabel(tag: 101, y: barHeight + gap - 14)
    }

    private func layoutAppleShapes(y: CGFloat, width: CGFloat) {
        let contentY = y + vPad

        // Left circle
        let circleY = contentY + contentH - btnSize
        appleCircleL?.frame = CGRect(x: hPad, y: circleY, width: btnSize, height: btnSize)
        appleCircleL?.layer.cornerRadius = btnSize / 2

        // Right circle
        appleCircleR?.frame = CGRect(x: width - hPad - btnSize, y: circleY, width: btnSize, height: btnSize)
        appleCircleR?.layer.cornerRadius = btnSize / 2

        // Rounded rect between circles
        let rectX = hPad + btnSize + spacing
        let rectW = width - hPad * 2 - btnSize * 2 - spacing * 2
        appleRect?.frame = CGRect(x: rectX, y: contentY, width: rectW, height: contentH)
        appleRect?.layer.cornerRadius = cornerR
    }

    private func layoutLabel(tag: Int, y: CGFloat) {
        guard let label = viewWithTag(tag) as? UILabel ?? contentView.viewWithTag(tag) as? UILabel else { return }
        label.sizeToFit()
        label.frame.origin = CGPoint(x: 8, y: y)
    }

    // MARK: - Shape builder (same as GlassInputBar)

    private func buildShapes(glassFrame: CGRect, captureFrame: CGRect, scale: CGFloat) -> GlassRenderer.ShapeParams {
        var p = GlassRenderer.ShapeParams()
        let cw = captureFrame.width
        let ch = captureFrame.height
        guard cw > 0, ch > 0 else { return p }

        let contentY = glassFrame.origin.y + vPad
        let contentH = glassFrame.height - vPad * 2

        let attachCX = glassFrame.origin.x + hPad + btnSize / 2
        let attachCY = contentY + contentH - btnSize / 2
        let attachR = btnSize / 2

        let micCX = glassFrame.maxX - hPad - btnSize / 2
        let micCY = attachCY
        let micR = btnSize / 2

        let textX = glassFrame.origin.x + hPad + btnSize + spacing
        let textW = glassFrame.width - hPad * 2 - btnSize * 2 - spacing * 2
        let textY = contentY
        let textH = contentH

        p.shape0 = SIMD4<Float>(
            Float((textX - captureFrame.origin.x) / cw),
            Float((textY - captureFrame.origin.y) / ch),
            Float(textW / cw),
            Float(textH / ch)
        )
        p.shape0cornerR = Float(cornerR * scale) / Float(ch * scale)

        p.shape1 = SIMD4<Float>(
            Float((attachCX - captureFrame.origin.x) / cw),
            Float((attachCY - captureFrame.origin.y) / ch),
            Float(attachR / ch),
            0
        )

        p.shape2 = SIMD4<Float>(
            Float((micCX - captureFrame.origin.x) / cw),
            Float((micCY - captureFrame.origin.y) / ch),
            Float(micR / ch),
            0
        )

        p.shapeCount = 3
        return p
    }
}
