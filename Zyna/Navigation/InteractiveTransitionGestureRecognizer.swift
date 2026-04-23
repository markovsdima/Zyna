//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import UIKit.UIGestureRecognizerSubclass

/// `UIPanGestureRecognizer` subclass driving interactive navigation
/// on `ZynaNavigationController`. Three responsibilities:
///
/// - **Direction gate.** A caller-supplied closure returns allowed
///   directions; the gesture fails if the dominant axis of the first
///   ~10 pt of movement doesn't match.
/// - **Scroll-conflict detection.** At touch begin, walks the
///   hit-test view chain looking for horizontally-scrollable
///   `UIScrollView`s or views flagged with
///   `disablesInteractiveTransitionGestureRecognizer`. If anything
///   wants the touch, the gesture fails immediately.
/// - **Late hijack.** `cancelsTouchesInView` starts `false` so child
///   gestures keep working until we resolve a valid direction; then
///   it flips to `true` and steals the touch from descendants.
public final class InteractiveTransitionGestureRecognizer: UIPanGestureRecognizer {

    public enum Direction: Hashable {
        case left
        case right
        case up
        case down
    }

    /// Called at touch begin to ask the host which directions are
    /// currently valid. Empty set ⇒ gesture cannot start. Evaluated
    /// fresh each touch so the host can gate dynamically.
    public var allowedDirections: () -> Set<Direction> = { [.right] }

    /// Movement (pt) before the recognizer commits to a direction.
    /// Smaller = more responsive, larger = more diagonal-tolerant.
    public var directionResolutionDistance: CGFloat = 10

    private var startLocation: CGPoint = .zero
    private var hasResolvedDirection = false

    public override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        self.delaysTouchesBegan = false
        self.cancelsTouchesInView = false
        self.maximumNumberOfTouches = 1
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first, let view = self.view else { return }

        startLocation = touch.location(in: view)
        hasResolvedDirection = false
        cancelsTouchesInView = false

        // Bail immediately if the touch landed inside something that
        // wants to claim horizontal panning.
        if hasBlockingScrollAncestor(at: startLocation, in: view) {
            self.state = .failed
            return
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard !hasResolvedDirection, let touch = touches.first, let view = self.view else {
            return
        }

        let current = touch.location(in: view)
        let dx = current.x - startLocation.x
        let dy = current.y - startLocation.y

        // Wait until the finger has moved enough that the dominant
        // axis is unambiguous.
        if abs(dx) < directionResolutionDistance, abs(dy) < directionResolutionDistance {
            return
        }

        hasResolvedDirection = true

        let allowed = allowedDirections()
        let primary: Direction
        if abs(dx) >= abs(dy) {
            primary = dx >= 0 ? .right : .left
        } else {
            primary = dy >= 0 ? .down : .up
        }

        if !allowed.contains(primary) {
            self.state = .failed
            return
        }

        // Direction is valid — claim the touch from any descendant
        // gesture or hit-test target so we can drive the transition.
        cancelsTouchesInView = true
    }

    public override func reset() {
        super.reset()
        hasResolvedDirection = false
        startLocation = .zero
        cancelsTouchesInView = false
    }

    // MARK: - Scroll conflict detection

    /// Walk the view chain from the hit-tested view at `point` up to
    /// (but not including) `rootView`. Return `true` if any view in
    /// that chain wants to claim horizontal pans.
    private func hasBlockingScrollAncestor(at point: CGPoint, in rootView: UIView) -> Bool {
        guard let hit = rootView.hitTest(point, with: nil) else { return false }

        var current: UIView? = hit
        while let v = current, v !== rootView {
            if v.disablesInteractiveTransitionGestureRecognizer {
                return true
            }
            if let scroll = v as? UIScrollView, isHorizontallyScrollable(scroll) {
                return true
            }
            current = v.superview
        }
        return false
    }

    /// True for any scroll view that can move horizontally — covers
    /// `UIScrollView`, `UICollectionView`, `ASCollectionNode.view`,
    /// and any other subclass.
    private func isHorizontallyScrollable(_ scroll: UIScrollView) -> Bool {
        if scroll.contentSize.width > scroll.bounds.width + 0.5 {
            return true
        }
        if scroll.alwaysBounceHorizontal && !scroll.alwaysBounceVertical {
            return true
        }
        return false
    }
}
