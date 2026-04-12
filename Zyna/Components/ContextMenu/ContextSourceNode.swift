//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ContextSourceNode: ASDisplayNode {

    var activated: ((CGPoint) -> Void)?
    var shouldBegin: ((CGPoint) -> Bool)?

    /// Called with the location (in self coordinates) when a quick tap ends before activation.
    var onQuickTap: ((CGPoint) -> Void)?

    /// Called with screen-space point while finger drags after activation.
    var onDragChanged: ((CGPoint) -> Void)?
    /// Called with screen-space point when finger lifts after activation.
    var onDragEnded: ((CGPoint) -> Void)?
    /// Called when interaction should be locked (true) or unlocked (false).
    var onInteractionLockChanged: ((Bool) -> Void)?

    private var shrinkAnimator: UIViewPropertyAnimator?
    private var activationTimer: Timer?
    let contentNode: ASDisplayNode
    private var didActivate = false
    private var touchStartLocation: CGPoint = .zero

    /// Horizontal pan distance (pt) past which we treat the touch as
    /// a back-swipe and bow out so the navigation pan can take over.
    private static let horizontalSwipeCancelThreshold: CGFloat = 8

    init(contentNode: ASDisplayNode) {
        self.contentNode = contentNode
        super.init()
        addSubnode(contentNode)
    }

    override func didLoad() {
        super.didLoad()
        let gesture = UILongPressGestureRecognizer(
            target: self, action: #selector(handleGesture)
        )
        gesture.minimumPressDuration = 0
        gesture.delegate = self
        view.addGestureRecognizer(gesture)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASWrapperLayoutSpec(layoutElement: contentNode)
    }

    override func layout() {
        super.layout()
        contentNode.frame = bounds
    }

    // MARK: - Reparenting

    func extractContentForMenu(in coordinateSpace: UICoordinateSpace) -> (node: ASDisplayNode, frame: CGRect) {
        let contentView = contentNode.view
        let savedTransform = contentView.transform
        contentView.transform = .identity
        let frame = contentView.convert(contentView.bounds, to: coordinateSpace)
        contentView.transform = savedTransform
        return (contentNode, frame)
    }

    func restoreContentFromMenu() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        addSubnode(contentNode)
        contentNode.view.transform = .identity
        contentNode.view.alpha = 1
        contentNode.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Gesture

    @objc private func handleGesture(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: view)

        switch gesture.state {
        case .began:
            if shouldBegin?(location) == false {
                gesture.isEnabled = false
                gesture.isEnabled = true
                return
            }
            touchStartLocation = location
            startShrink()

        case .changed:
            if didActivate {
                let screenPoint = gesture.location(in: nil)
                onDragChanged?(screenPoint)
            } else {
                // Bail out on a horizontal swipe so the navigation
                // back-swipe pan can take over (the two gestures
                // recognize simultaneously by design — see the
                // delegate below). Skipped after shrink begins,
                // because then the touch is ours.
                if shrinkAnimator == nil {
                    let dx = location.x - touchStartLocation.x
                    let dy = location.y - touchStartLocation.y
                    if abs(dx) > Self.horizontalSwipeCancelThreshold,
                       abs(dx) > abs(dy) {
                        cancelShrink()
                        gesture.isEnabled = false
                        gesture.isEnabled = true
                        return
                    }
                }

                let expandedBounds = view.bounds.insetBy(dx: -40, dy: -40)
                if !expandedBounds.contains(location) {
                    cancelShrink()
                    gesture.isEnabled = false
                    gesture.isEnabled = true
                }
            }

        case .ended, .cancelled, .failed:
            if didActivate {
                let screenPoint = gesture.location(in: nil)
                onDragEnded?(screenPoint)
            } else {
                let wasQuickTap = shrinkAnimator == nil && activationTimer != nil
                cancelShrink()
                if wasQuickTap && gesture.state == .ended {
                    onQuickTap?(location)
                }
            }
            didActivate = false

        default:
            break
        }
    }

    // MARK: - Animation

    private func startShrink() {
        shrinkAnimator?.stopAnimation(true)

        activationTimer = Timer.scheduledTimer(
            withTimeInterval: 0.12, repeats: false
        ) { [weak self] _ in
            self?.beginShrinkAnimation()
        }
    }

    private func beginShrinkAnimation() {
        onInteractionLockChanged?(true)
        GlassService.shared.captureFor(duration: 0.3)
        // The user held past the shrink threshold; the touch is
        // ours, kill any in-flight back-swipe pan.
        cancelEnclosingNavigationPopGesture()
        let targetScale: CGFloat = 0.92

        shrinkAnimator = UIViewPropertyAnimator(
            duration: 0.25,
            curve: .easeOut
        ) {
            self.contentNode.view.transform = CGAffineTransform(
                scaleX: targetScale, y: targetScale
            )
        }

        shrinkAnimator?.addCompletion { [weak self] position in
            guard position == .end else { return }
            self?.triggerActivation()
        }

        shrinkAnimator?.startAnimation()
    }

    private func triggerActivation() {
        didActivate = true
        shrinkAnimator = nil

        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        let location = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        activated?(location)
    }

    /// Walk the view chain and cancel the nearest interactive
    /// back-swipe pan via an `isEnabled` toggle.
    private func cancelEnclosingNavigationPopGesture() {
        var current: UIView? = self.view
        while let v = current {
            if let recognizers = v.gestureRecognizers {
                for r in recognizers where r is InteractiveTransitionGestureRecognizer {
                    r.isEnabled = false
                    r.isEnabled = true
                    return
                }
            }
            current = v.superview
        }
    }

    private func cancelShrink() {
        activationTimer?.invalidate()
        activationTimer = nil

        guard let animator = shrinkAnimator else { return }
        animator.stopAnimation(true)
        shrinkAnimator = nil
        onInteractionLockChanged?(false)

        GlassService.shared.captureFor(duration: 0.25)
        UIView.animate(withDuration: 0.2) {
            self.contentNode.view.transform = .identity
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ContextSourceNode: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        if shrinkAnimator != nil || didActivate { return false }
        return other is UIPanGestureRecognizer
    }
}
