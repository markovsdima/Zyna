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

        anchor.cornerRadius = 18
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
    func updateLayout(in parentView: UIView) {
        let safeBottom = parentView.safeAreaInsets.bottom

        // Measure input node height
        let width = parentView.bounds.width
        let fittedSize = inputNode.layoutThatFits(ASSizeRange(
            min: CGSize(width: width, height: 0),
            max: CGSize(width: width, height: .greatestFiniteMagnitude)
        )).size

        let barHeight = fittedSize.height + safeBottom
        let barY = parentView.bounds.height - barHeight - keyboardHeight

        frame = CGRect(x: 0, y: barY, width: width, height: fittedSize.height)
        anchor.frame = bounds

        inputNode.frame = CGRect(x: 0, y: 0, width: width, height: fittedSize.height)
    }

    /// Returns how much space the input bar + keyboard covers at the bottom.
    var coveredHeight: CGFloat {
        guard let superview else { return 0 }
        let safeBottom = superview.safeAreaInsets.bottom
        return bounds.height + safeBottom + keyboardHeight
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
