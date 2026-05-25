//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import UIKit

final class ListContextMenuCellNode: ZynaCellNode {

    var onContextMenuActivated: ((CGPoint) -> Void)?
    var onQuickTap: (() -> Void)?
    var onDragChanged: ((CGPoint) -> Void)? {
        get { contextSourceNode.onDragChanged }
        set { contextSourceNode.onDragChanged = newValue }
    }
    var onDragEnded: ((CGPoint) -> Void)? {
        get { contextSourceNode.onDragEnded }
        set { contextSourceNode.onDragEnded = newValue }
    }
    var onInteractionLockChanged: ((Bool) -> Void)? {
        get { contextSourceNode.onInteractionLockChanged }
        set { contextSourceNode.onInteractionLockChanged = newValue }
    }

    private let contextSourceNode: ListContextSourceNode

    init(contentNode: ASDisplayNode) {
        self.contextSourceNode = ListContextSourceNode(contentNode: contentNode)
        super.init()
        automaticallyManagesSubnodes = true
        selectionStyle = .none
        backgroundColor = .clear

        contextSourceNode.activated = { [weak self] point in
            guard let self else { return }
            let pointInCell = self.contextSourceNode.view.convert(point, to: self.view)
            self.onContextMenuActivated?(pointInCell)
        }
        contextSourceNode.onQuickTap = { [weak self] _ in
            self?.onQuickTap?()
        }
        contextSourceNode.shouldBegin = { [weak self] _ in
            self?.onContextMenuActivated != nil
        }
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        ASWrapperLayoutSpec(layoutElement: contextSourceNode)
    }

    override func layout() {
        super.layout()
        contextSourceNode.frame = bounds
    }

    func extractContentForMenu(in coordinateSpace: UICoordinateSpace) -> (node: ASDisplayNode, frame: CGRect) {
        contextSourceNode.extractContentForMenu(in: coordinateSpace)
    }

    func restoreContentFromMenu() {
        contextSourceNode.restoreContentFromMenu()
    }

    func cancelContextMenuActivation(animated: Bool = true) {
        contextSourceNode.cancelInteraction(animated: animated)
    }

    func setContextAccessibilityActions(_ actions: [UIAccessibilityCustomAction]) {
        accessibilityActionsProvider = { actions }
        contextSourceNode.setContextAccessibilityActions(actions)
        refreshAccessibilityForwarding()
    }
}

private final class ListContextSourceNode: ASDisplayNode {

    var activated: ((CGPoint) -> Void)?
    var shouldBegin: ((CGPoint) -> Bool)?
    var onQuickTap: ((CGPoint) -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onInteractionLockChanged: ((Bool) -> Void)?

    private let contentNode: ASDisplayNode
    private var shrinkAnimator: UIViewPropertyAnimator?
    private var activationTimer: Timer?
    private var didActivate = false
    private var touchStartLocation: CGPoint = .zero
    private var latestLocation: CGPoint = .zero
    private var isInteractionLocked = false

    private enum Metrics {
        static let shrinkDelay: TimeInterval = 0.12
        static let shrinkDuration: TimeInterval = 0.25
        static let restoreDuration: TimeInterval = 0.2
        static let targetScale: CGFloat = 0.965
        static let horizontalSwipeCancelThreshold: CGFloat = 8
        static let movementCancelDistance: CGFloat = 10
        static let allowedExitInset: CGFloat = 28
    }

    init(contentNode: ASDisplayNode) {
        self.contentNode = contentNode
        super.init()
        addSubnode(contentNode)
    }

    override func didLoad() {
        super.didLoad()

        let gesture = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleGesture(_:))
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
        setNeedsLayout()
        CATransaction.commit()
        unlockInteractionIfNeeded()
        didActivate = false
    }

    func cancelInteraction(animated: Bool = true) {
        activationTimer?.invalidate()
        activationTimer = nil

        shrinkAnimator?.stopAnimation(true)
        shrinkAnimator = nil
        didActivate = false
        unlockInteractionIfNeeded()

        guard animated else {
            contentNode.view.transform = .identity
            return
        }

        UIView.animate(withDuration: Metrics.restoreDuration) {
            self.contentNode.view.transform = .identity
        }
    }

    @objc private func handleGesture(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: view)
        latestLocation = location

        switch gesture.state {
        case .began:
            touchStartLocation = location
            startShrink()

        case .changed:
            if didActivate {
                onDragChanged?(gesture.location(in: nil))
            } else if shouldCancelBeforeActivation(at: location) {
                gesture.isEnabled = false
                gesture.isEnabled = true
                cancelInteraction()
            }

        case .ended, .cancelled, .failed:
            if didActivate {
                onDragEnded?(gesture.location(in: nil))
            } else {
                let wasQuickTap = shrinkAnimator == nil && activationTimer != nil
                let moved = hypot(
                    location.x - touchStartLocation.x,
                    location.y - touchStartLocation.y
                )
                cancelInteraction()
                if wasQuickTap && gesture.state == .ended && moved < 8 {
                    onQuickTap?(location)
                }
            }
            didActivate = false

        default:
            break
        }
    }

    private func shouldCancelBeforeActivation(at location: CGPoint) -> Bool {
        if shrinkAnimator == nil {
            let dx = location.x - touchStartLocation.x
            let dy = location.y - touchStartLocation.y
            if abs(dx) > Metrics.horizontalSwipeCancelThreshold,
               abs(dx) > abs(dy) {
                return true
            }
            if hypot(dx, dy) > Metrics.movementCancelDistance,
               abs(dy) > abs(dx) {
                return true
            }
        }

        let expandedBounds = view.bounds.insetBy(
            dx: -Metrics.allowedExitInset,
            dy: -Metrics.allowedExitInset
        )
        return !expandedBounds.contains(location)
    }

    private func startShrink() {
        shrinkAnimator?.stopAnimation(true)

        activationTimer = Timer.scheduledTimer(
            withTimeInterval: Metrics.shrinkDelay,
            repeats: false
        ) { [weak self] _ in
            self?.beginShrinkAnimation()
        }
    }

    private func beginShrinkAnimation() {
        lockInteractionIfNeeded()
        cancelEnclosingNavigationPopGesture()

        shrinkAnimator = UIViewPropertyAnimator(
            duration: Metrics.shrinkDuration,
            curve: .easeOut
        ) {
            self.contentNode.view.transform = CGAffineTransform(
                scaleX: Metrics.targetScale,
                y: Metrics.targetScale
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
        activationTimer?.invalidate()
        activationTimer = nil

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        activated?(latestLocation)
    }

    private func cancelEnclosingNavigationPopGesture() {
        var current: UIView? = view
        while let candidate = current {
            if let recognizers = candidate.gestureRecognizers {
                for recognizer in recognizers where recognizer is InteractiveTransitionGestureRecognizer {
                    recognizer.isEnabled = false
                    recognizer.isEnabled = true
                    return
                }
            }
            current = candidate.superview
        }
    }

    private func lockInteractionIfNeeded() {
        guard !isInteractionLocked else { return }
        isInteractionLocked = true
        onInteractionLockChanged?(true)
    }

    private func unlockInteractionIfNeeded() {
        guard isInteractionLocked else { return }
        isInteractionLocked = false
        onInteractionLockChanged?(false)
    }

    func setContextAccessibilityActions(_ actions: [UIAccessibilityCustomAction]) {
        accessibilityCustomActions = actions
        if let contentCellNode = contentNode as? ZynaCellNode {
            contentCellNode.accessibilityActionsProvider = { actions }
            contentCellNode.refreshAccessibilityForwarding()
        }
        contentNode.accessibilityCustomActions = actions
    }
}

extension ListContextSourceNode: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if UIAccessibility.isVoiceOverRunning { return false }
        let location = gestureRecognizer.location(in: view)
        return shouldBegin?(location) ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        if shrinkAnimator != nil || didActivate { return false }
        return other is UIPanGestureRecognizer
    }
}
