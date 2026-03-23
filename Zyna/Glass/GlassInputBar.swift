//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import AsyncDisplayKit

/// Glass input bar with 3 shapes: attach (circle), text field (rounded rect), mic (circle).
/// Lives in the main window, content rendered in overlay via GlassService.
/// Tracks keyboard position and triggers glass capture on changes.
final class GlassInputBar: UIView {

    // MARK: - Public

    let inputNode = ChatInputNode()

    // MARK: - Private

    private let anchor = GlassAnchor()
    private let contentView = UIView()
    private var keyboardHeight: CGFloat = 0

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false

        anchor.cornerRadius = 24
        anchor.extendsCaptureToScreenBottom = true
        anchor.shapeProvider = { [weak self] glassFrame, captureFrame, scale in
            self?.buildShapes(glassFrame: glassFrame, captureFrame: captureFrame, scale: scale)
                ?? GlassRenderer.ShapeParams()
        }
        addSubview(anchor)

        contentView.backgroundColor = .clear
        contentView.addSubview(inputNode.view)

        // Remove default background — glass is our background
        inputNode.backgroundColor = .clear
        inputNode.view.backgroundColor = .clear

        observeKeyboard()
        observeInputSize()
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

    /// Call from ChatViewController.viewDidLayoutSubviews()
    private let barInsetClosed: CGFloat = 6
    private let barInsetOpen: CGFloat = 0

    func updateLayout(in parentView: UIView) {
        let safeBottom = parentView.safeAreaInsets.bottom

        let insetH = keyboardHeight > 0 ? barInsetOpen : barInsetClosed
        let fullWidth = parentView.bounds.width
        let barWidth = fullWidth - insetH * 2

        // Measure input node height
        let fittedSize = inputNode.layoutThatFits(ASSizeRange(
            min: CGSize(width: barWidth, height: 0),
            max: CGSize(width: barWidth, height: .greatestFiniteMagnitude)
        )).size

        let barY: CGFloat
        if keyboardHeight > 0 {
            barY = parentView.bounds.height - fittedSize.height - keyboardHeight - safeBottom - 4
        } else {
            barY = parentView.bounds.height - fittedSize.height - safeBottom * 0.5
        }

        frame = CGRect(x: insetH, y: barY, width: barWidth, height: fittedSize.height)
        anchor.frame = bounds

        inputNode.frame = CGRect(x: 0, y: 0, width: barWidth, height: fittedSize.height)
    }

    /// Returns how much space the input bar + keyboard covers at the bottom.
    var coveredHeight: CGFloat {
        guard let superview else { return 0 }
        let safeBottom = superview.safeAreaInsets.bottom
        if keyboardHeight > 0 {
            return bounds.height + keyboardHeight + safeBottom + 4
        } else {
            return bounds.height + safeBottom * 0.5
        }
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt,
              let superview else { return }

        let screenH = UIScreen.main.bounds.height
        let newKeyboardH = max(0, screenH - endFrame.origin.y)

        // Subtract safe area — we handle it ourselves
        let safeBottom = superview.safeAreaInsets.bottom
        keyboardHeight = max(0, newKeyboardH - safeBottom)

        GlassService.shared.captureFor(duration: duration + 0.1)

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: curve << 16),
            animations: {
                self.updateLayout(in: superview)
                // Notify ChatViewController to update table insets
                self.superview?.setNeedsLayout()
                self.superview?.layoutIfNeeded()
            }
        )
    }

    // MARK: - Multi-shape

    private func buildShapes(glassFrame: CGRect, captureFrame: CGRect, scale: CGFloat) -> GlassRenderer.ShapeParams {
        var p = GlassRenderer.ShapeParams()
        let cw = captureFrame.width
        let ch = captureFrame.height
        guard cw > 0, ch > 0 else { return p }

        // Layout constants from ChatInputNode.normalLayout
        let hPad: CGFloat = 14   // horizontal padding
        let vPad: CGFloat = 6    // vertical padding
        let btnSize: CGFloat = 48
        let spacing: CGFloat = 8 // between button and text field
        let cornerR: CGFloat = 24

        let contentY = glassFrame.origin.y + vPad
        let contentH = glassFrame.height - vPad * 2

        // Attach button (circle, bottom-aligned)
        let attachCX = glassFrame.origin.x + hPad + btnSize / 2
        let attachCY = contentY + contentH - btnSize / 2
        let attachR = btnSize / 2

        // Mic/Send button (circle, bottom-aligned)
        let micCX = glassFrame.maxX - hPad - btnSize / 2
        let micCY = attachCY
        let micR = btnSize / 2

        // Text field (rounded rect, between buttons)
        let textX = glassFrame.origin.x + hPad + btnSize + spacing
        let textW = glassFrame.width - hPad * 2 - btnSize * 2 - spacing * 2
        let textY = contentY
        let textH = contentH

        // Shape 0: text field (rounded rect)
        p.shape0 = SIMD4<Float>(
            Float((textX - captureFrame.origin.x) / cw),
            Float((textY - captureFrame.origin.y) / ch),
            Float(textW / cw),
            Float(textH / ch)
        )
        p.shape0cornerR = Float(cornerR * scale) / Float(ch * scale)

        // Shape 1: attach (circle) — center + radius normalized by capture height
        p.shape1 = SIMD4<Float>(
            Float((attachCX - captureFrame.origin.x) / cw),
            Float((attachCY - captureFrame.origin.y) / ch),
            Float(attachR / ch),
            0
        )

        // Shape 2: mic (circle)
        p.shape2 = SIMD4<Float>(
            Float((micCX - captureFrame.origin.x) / cw),
            Float((micCY - captureFrame.origin.y) / ch),
            Float(micR / ch),
            0
        )

        p.shapeCount = 3
        return p
    }

    // MARK: - Input size changes

    private func observeInputSize() {
        inputNode.onSizeChanged = { [weak self] in
            guard let self, let superview = self.superview else { return }
            GlassService.shared.setNeedsCapture()
            self.updateLayout(in: superview)
            superview.setNeedsLayout()
        }
    }
}
