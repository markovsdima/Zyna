//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Content that wants VoiceOver focus moved to a specific view
/// when the popup appears. Defaults to `nil` — no explicit focus.
protocol AccessibilityFocusProviding {
    var initialAccessibilityFocus: UIView? { get }
}

/// Popup card right-aligned below an anchor frame. Tap backdrop to dismiss.
final class AnchoredPopupNode: ASDisplayNode {

    var onDismiss: (() -> Void)?

    private let backdropNode = ASDisplayNode()
    /// Outer wrapper carries the shadow and must not clip — clipping
    /// would also clip the shadow itself. `cardContainer` (clipped)
    /// holds the rounded card body.
    private let cardShadow = ASDisplayNode()
    private let cardContainer = ASDisplayNode()
    private let content: ASDisplayNode
    private let preferredContentWidth: CGFloat
    private let preferredContentHeight: CGFloat
    private let cardCornerRadius: CGFloat
    private let gap: CGFloat = 6
    private var anchorFrame: CGRect?

    init(
        content: ASDisplayNode,
        preferredWidth: CGFloat,
        preferredHeight: CGFloat,
        cardCornerRadius: CGFloat = 14
    ) {
        self.content = content
        self.preferredContentWidth = preferredWidth
        self.preferredContentHeight = preferredHeight
        self.cardCornerRadius = cardCornerRadius
        super.init()
        automaticallyManagesSubnodes = true
        clipsToBounds = false

        backdropNode.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        cardShadow.backgroundColor = .clear
        cardShadow.clipsToBounds = false
        cardShadow.automaticallyManagesSubnodes = true
        cardShadow.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return ASWrapperLayoutSpec(layoutElement: self.cardContainer)
        }

        cardContainer.backgroundColor = .systemBackground
        cardContainer.cornerRadius = cardCornerRadius
        cardContainer.clipsToBounds = true
        cardContainer.automaticallyManagesSubnodes = true
        cardContainer.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return ASWrapperLayoutSpec(layoutElement: self.content)
        }
    }

    override func didLoad() {
        super.didLoad()
        cardShadow.layer.shadowColor = UIColor.black.cgColor
        cardShadow.layer.shadowOpacity = 0.18
        cardShadow.layer.shadowRadius = 14
        cardShadow.layer.shadowOffset = CGSize(width: 0, height: 6)

        // Trap VoiceOver inside the popup — swipes don't leak to the
        // underlying screen, and the user can't get lost outside.
        view.accessibilityViewIsModal = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(backdropTapped))
        backdropNode.view.addGestureRecognizer(tap)
    }

    // MARK: - Anchor

    /// Anchor frame in parent's coord space. Card aligns right-below.
    func setAnchor(_ frame: CGRect) {
        anchorFrame = frame
        setNeedsLayout()
    }

    // MARK: - Presentation

    /// Scales up from top-right corner — pivot near anchor's chevron.
    func animateIn() {
        guard isNodeLoaded else { return }
        // First show needs the layout pass to materialize cardShadow's
        // bounds; without it the anchorPoint shift has nothing to read
        // and the scale pivots from (0, 0) instead of the chevron.
        view.layoutIfNeeded()

        backdropNode.alpha = 0
        cardShadow.alpha = 0

        shiftCardAnchorPointTopRight()
        cardShadow.layer.transform = CATransform3DMakeScale(0.6, 0.6, 1)

        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0.2,
            options: [.curveEaseOut]
        ) {
            self.backdropNode.alpha = 1
            self.cardShadow.alpha = 1
            self.cardShadow.layer.transform = CATransform3DIdentity
        }

        // Hand VO focus off to the content — don't wait for animation,
        // the announcement is what matters.
        if let focus = (content as? AccessibilityFocusProviding)?.initialAccessibilityFocus {
            UIAccessibility.post(notification: .screenChanged, argument: focus)
        }
    }

    func dismiss(completion: (() -> Void)? = nil) {
        guard isNodeLoaded else { completion?(); return }
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseIn]) {
            self.backdropNode.alpha = 0
            self.cardShadow.alpha = 0
            self.cardShadow.layer.transform = CATransform3DMakeScale(0.6, 0.6, 1)
        } completion: { _ in
            self.view.removeFromSuperview()
            self.removeFromSupernode()
            completion?()
        }
    }

    @objc private func backdropTapped() {
        onDismiss?()
        dismiss()
    }

    /// VoiceOver two-finger Z-scrub dismiss. Otherwise VO users are
    /// trapped inside the modal until they pick an option.
    override func accessibilityPerformEscape() -> Bool {
        onDismiss?()
        dismiss()
        return true
    }

    /// Shifts the card's anchorPoint to top-right without moving its frame.
    private func shiftCardAnchorPointTopRight() {
        let layer = cardShadow.layer
        let bounds = layer.bounds
        let newAnchor = CGPoint(x: 1, y: 0)
        let oldAnchor = layer.anchorPoint
        let deltaX = (newAnchor.x - oldAnchor.x) * bounds.width
        let deltaY = (newAnchor.y - oldAnchor.y) * bounds.height
        layer.anchorPoint = newAnchor
        layer.position = CGPoint(x: layer.position.x + deltaX, y: layer.position.y + deltaY)
    }

    // MARK: - Layout

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        backdropNode.style.preferredSize = constrainedSize.max
        backdropNode.style.layoutPosition = .zero

        cardShadow.style.preferredSize = CGSize(
            width: preferredContentWidth,
            height: preferredContentHeight
        )

        if let anchor = anchorFrame {
            let x = max(16, anchor.maxX - preferredContentWidth)
            let y = anchor.maxY + gap
            cardShadow.style.layoutPosition = CGPoint(x: x, y: y)
        } else {
            cardShadow.style.layoutPosition = CGPoint(
                x: (constrainedSize.max.width - preferredContentWidth) / 2,
                y: (constrainedSize.max.height - preferredContentHeight) / 2
            )
        }

        return ASAbsoluteLayoutSpec(sizing: .default, children: [backdropNode, cardShadow])
    }

    override func layout() {
        super.layout()
        // Match shadow path to card's rounded shape — without it, the
        // shadow renders against cardShadow's rectangular bounds.
        cardShadow.layer.shadowPath = UIBezierPath(
            roundedRect: cardShadow.bounds,
            cornerRadius: cardCornerRadius
        ).cgPath
    }
}
