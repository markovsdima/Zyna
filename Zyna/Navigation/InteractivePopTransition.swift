//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Drives an in-flight interactive pop transition. Owned by
/// `ZynaNavigationController` while the user is dragging.
///
/// Lifecycle: `init` installs the revealed view at the parallax
/// position with a dim overlay between it and the top; `update` is
/// called per gesture frame to set transforms synchronously;
/// `finish` or `cancel` springs to the appropriate end state and
/// invokes its completion so the host can finalize the stack.
final class InteractivePopTransition {

    let topVC: UIViewController
    let revealedVC: UIViewController
    let containerView: UIView

    private let dimView: UIView
    private let parallaxRatio: CGFloat
    private let dimAlpha: CGFloat
    private let springDuration: TimeInterval
    private let savedClipsToBounds: Bool
    private let savedCornerRadius: CGFloat

    private(set) var progress: CGFloat = 0

    init(
        topVC: UIViewController,
        revealedVC: UIViewController,
        in container: UIView,
        parallaxRatio: CGFloat,
        dimAlpha: CGFloat,
        springDuration: TimeInterval
    ) {
        self.topVC = topVC
        self.revealedVC = revealedVC
        self.containerView = container
        self.parallaxRatio = parallaxRatio
        self.dimAlpha = dimAlpha
        self.springDuration = springDuration

        let bounds = container.bounds
        let revealedView = revealedVC.view!
        revealedView.frame = bounds
        revealedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let dim = UIView(frame: bounds)
        dim.backgroundColor = .black
        dim.alpha = dimAlpha
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.dimView = dim

        // Save corner state so tearDown can restore it.
        self.savedClipsToBounds = topVC.view.clipsToBounds
        self.savedCornerRadius = topVC.view.layer.cornerRadius

        UIView.performWithoutAnimation {
            container.insertSubview(revealedView, belowSubview: topVC.view)
            container.insertSubview(dim, belowSubview: topVC.view)
            revealedView.transform = CGAffineTransform(
                translationX: -bounds.width * parallaxRatio, y: 0
            )
            topVC.view.layer.cornerRadius = IOS26Spring.screenCornerRadius
            topVC.view.layer.cornerCurve = .continuous
            topVC.view.clipsToBounds = true
        }
    }

    /// Apply `progress` (clamped to 0...1) to all participants
    /// synchronously. Called for every `.changed` gesture event.
    func update(progress newProgress: CGFloat) {
        let clamped = max(0, min(1, newProgress))
        self.progress = clamped

        let bounds = containerView.bounds
        let width = bounds.width
        let parallax = -width * parallaxRatio

        UIView.performWithoutAnimation {
            topVC.view.transform = CGAffineTransform(
                translationX: clamped * width, y: 0
            )
            revealedVC.view.transform = CGAffineTransform(
                translationX: parallax * (1 - clamped), y: 0
            )
            dimView.alpha = dimAlpha * (1 - clamped)
        }

        // No CAAnimation here, so the display link would idle out
        // and glass would freeze. Nudge it on every gesture frame.
        GlassService.shared.setNeedsCapture()
    }

    /// Spring to progress = 1 (pop completes). Caller's `completion`
    /// is responsible for removing the popped controller from the
    /// navigation stack.
    func finish(velocity: CGFloat, completion: @escaping () -> Void) {
        animate(toProgress: 1, velocity: velocity, completion: completion)
    }

    /// Spring back to progress = 0 (cancel). The navigation stack
    /// stays untouched; completion just tears down helper views.
    func cancel(velocity: CGFloat, completion: @escaping () -> Void) {
        animate(toProgress: 0, velocity: velocity, completion: completion)
    }

    /// Detach helper views and reset transforms. Caller invokes
    /// after the appropriate finish/cancel completion ran.
    func tearDown(removeTopFromHierarchy: Bool) {
        UIView.performWithoutAnimation {
            if removeTopFromHierarchy {
                topVC.view.removeFromSuperview()
            }
            topVC.view.transform = .identity
            topVC.view.layer.cornerRadius = savedCornerRadius
            topVC.view.layer.cornerCurve = .circular
            topVC.view.clipsToBounds = savedClipsToBounds
            revealedVC.view.transform = .identity
            dimView.removeFromSuperview()
        }
    }

    // MARK: - Private

    private func animate(
        toProgress targetProgress: CGFloat,
        velocity: CGFloat,
        completion: @escaping () -> Void
    ) {
        let bounds = containerView.bounds
        let width = bounds.width
        let parallax = -width * parallaxRatio

        let topTargetTx = targetProgress * width
        let revealedTargetTx = parallax * (1 - targetProgress)
        let dimTargetAlpha = dimAlpha * (1 - targetProgress)

        // UIView's spring velocity is "per unit distance to travel",
        // so divide pt/s by remaining distance. Guard against /0.
        let topRemaining = abs(topTargetTx - progress * width)
        let initialSpringVelocity = topRemaining > 0.5
            ? abs(velocity) / topRemaining
            : 0

        UIView.animate(
            withDuration: springDuration,
            delay: 0,
            usingSpringWithDamping: 1.0,
            initialSpringVelocity: initialSpringVelocity,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.topVC.view.transform = CGAffineTransform(translationX: topTargetTx, y: 0)
            self.revealedVC.view.transform = CGAffineTransform(translationX: revealedTargetTx, y: 0)
            self.dimView.alpha = dimTargetAlpha
        } completion: { _ in
            self.progress = targetProgress
            completion()
        }
    }
}
