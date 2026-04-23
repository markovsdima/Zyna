//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Custom navigation controller. **Not** a `UINavigationController`
/// subclass — a plain `UIViewController` that owns its own stack and
/// the entire transition pipeline.
///
/// Owning the pipeline gives us:
/// - Full control over the slide animation — tuned to iOS 26's
///   Liquid Glass spring at a true 120 Hz on ProMotion, in lockstep
///   with the tab bar and our Metal glass chrome.
/// - Glass renderers that follow transitions cleanly: GlassService
///   gets direct capture hooks on every push/pop instead of waiting
///   on a watchdog, and the interactive driver bumps it per frame.
/// - An interactive back-swipe with scroll-conflict detection that
///   coordinates with `ContextSourceNode` in both directions, with
///   no per-screen wiring required.
/// - Freedom from UIKit coupling surprises — no `hidesBottomBarWhenPushed`
///   magic gated on `UINavigationController` parentage, no system
///   transition coordinator quietly inserting overlays during pop
///   (the iOS 26 Liquid Glass dim+blur was the immediate trigger,
///   but the broader value is not depending on what UIKit does).
///
/// Child controllers locate this object via
/// `UIViewController.zynaNavigationController` (parent-chain walk),
/// since UIKit's `navigationController` accessor only finds
/// `UINavigationController` instances.
public class ZynaNavigationController: UIViewController {

    // MARK: - Stack state

    /// All controllers currently on the stack, root first.
    public private(set) var stack: [UIViewController] = []

    /// Top of stack (visible controller), or nil when stack is empty.
    public var topViewController: UIViewController? { stack.last }

    // MARK: - Init

    public init(rootViewController: UIViewController? = nil) {
        super.init(nibName: nil, bundle: nil)
        if let rootViewController {
            seedRoot(rootViewController)
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Adds the root to the stack pre-`viewDidLoad`. Its view is
    /// materialized later in `viewDidLoad`.
    private func seedRoot(_ vc: UIViewController) {
        addChild(vc)
        stack.append(vc)
        vc.didMove(toParent: self)
    }

    // MARK: - Interactive pop state

    private var activeInteractivePop: InteractivePopTransition?
    private var fpsBoostToken: DisplayLinkToken?

    /// True while the user is dragging the back-swipe gesture or its
    /// finish/cancel animation is still running. Blocks programmatic
    /// `push`/`pop` to keep the stack in a coherent state.
    private var isInteractivePopActive = false

    /// True while a programmatic push/pop animation is in flight.
    /// `isUserInteractionEnabled = false` blocks taps but VoiceOver
    /// gestures (escape, magic tap) bypass it — so we need a separate
    /// flag to keep the VO escape from racing the animation.
    private var isAnimatingTransition = false

    private enum DeferredStackMutation {
        case push(UIViewController, animated: Bool)
        case pop(animated: Bool)
        case popToRoot(animated: Bool)
    }

    private var deferredStackMutations: [DeferredStackMutation] = []

    private var isTransitionInFlight: Bool {
        isInteractivePopActive || isAnimatingTransition
    }

    // MARK: - Lifecycle

    public override func loadView() {
        let v = ZynaNavBackingView()
        v.owner = self
        self.view = v
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

        // Materialize the seeded root if there was one.
        if let top = topViewController {
            attachView(of: top)
        }

        installInteractivePopGesture()
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        applyHidesBottomBarWhenPushed()
    }

    // Forward system-chrome decisions to the visible controller.
    public override var childForStatusBarStyle: UIViewController? { topViewController }
    public override var childForStatusBarHidden: UIViewController? { topViewController }
    public override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
    public override var childForScreenEdgesDeferringSystemGestures: UIViewController? { topViewController }
    public override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    // MARK: - Tab bar visibility (hidesBottomBarWhenPushed)

    /// Forwards `topViewController.hidesBottomBarWhenPushed` to the
    /// enclosing `ZynaTabBarController` so the bar slides in lockstep
    /// with our push/pop. Self-corrects on every layout pass.
    private func applyHidesBottomBarWhenPushed() {
        guard let zynaTabBar = self.zynaTabBarController else { return }
        let shouldHide = topViewController?.hidesBottomBarWhenPushed ?? false
        if zynaTabBar.isTabBarHidden != shouldHide {
            zynaTabBar.setTabBarHidden(shouldHide, animated: true)
        }
    }

    // MARK: - Interactive pop gesture

    /// Threshold for finishing the pop on gesture release. Below this
    /// progress fraction, releasing snaps back unless the velocity
    /// also clears `interactivePopVelocityThreshold`.
    private static let interactivePopProgressThreshold: CGFloat = 0.4

    /// Velocity (pt/s) above which a release always finishes the pop,
    /// even if the progress threshold isn't met. Lets a quick flick
    /// dismiss the chat without dragging halfway.
    private static let interactivePopVelocityThreshold: CGFloat = 1000

    private func installInteractivePopGesture() {
        let pan = InteractiveTransitionGestureRecognizer(
            target: self,
            action: #selector(handleInteractivePop(_:))
        )
        pan.allowedDirections = { [weak self] in
            // Right swipe = pop. Only valid when there's something to
            // pop and no other transition is already running.
            guard let self,
                  self.stack.count > 1,
                  !self.isInteractivePopActive
            else { return [] }
            return [.right]
        }
        view.addGestureRecognizer(pan)
    }

    @objc private func handleInteractivePop(_ gesture: UIPanGestureRecognizer) {
        let translationX = gesture.translation(in: view).x
        let velocityX = gesture.velocity(in: view).x
        let progress = max(0, min(1, translationX / max(view.bounds.width, 1)))

        switch gesture.state {
        case .began:
            beginInteractivePop()
        case .changed:
            activeInteractivePop?.update(progress: progress)
        case .ended:
            guard activeInteractivePop != nil else { return }
            let shouldFinish =
                progress > Self.interactivePopProgressThreshold ||
                velocityX > Self.interactivePopVelocityThreshold
            if shouldFinish {
                finishInteractivePop(velocity: velocityX)
            } else {
                cancelInteractivePop(velocity: velocityX)
            }
        case .cancelled, .failed:
            if activeInteractivePop != nil {
                cancelInteractivePop(velocity: 0)
            }
        default:
            break
        }
    }

    private func beginInteractivePop() {
        guard stack.count > 1, isViewLoaded else { return }
        let topVC = stack[stack.count - 1]
        let revealedVC = stack[stack.count - 2]

        isInteractivePopActive = true

        activeInteractivePop = InteractivePopTransition(
            topVC: topVC,
            revealedVC: revealedVC,
            in: view,
            parallaxRatio: Self.parallaxRatio,
            dimAlpha: CGFloat(Self.dimAlpha),
            springDuration: IOS26Spring.duration
        )

        // Keep ProMotion at 120 Hz while the finger is dragging.
        fpsBoostToken = DisplayLinkDriver.shared.subscribe(rate: .max) { _ in }

        GlassService.shared.setNeedsCapture()
    }

    private func finishInteractivePop(velocity: CGFloat) {
        guard let transition = activeInteractivePop else { return }
        let topVC = transition.topVC

        // Reveal the tab bar in lockstep with the spring if the
        // controller we're popping back to doesn't hide it.
        if let zynaTabBar = self.zynaTabBarController,
           zynaTabBar.isTabBarHidden,
           !transition.revealedVC.hidesBottomBarWhenPushed {
            zynaTabBar.setTabBarHidden(false, animated: true)
        }

        // Mutate stack synchronously so the post-pop state is visible
        // to anyone querying mid-animation.
        topVC.willMove(toParent: nil)
        stack.removeLast()

        let revealedVC = transition.revealedVC
        transition.finish(velocity: velocity) { [weak self, weak transition] in
            guard let self, let transition else { return }
            transition.tearDown(removeTopFromHierarchy: true)
            topVC.removeFromParent()
            self.activeInteractivePop = nil
            self.isInteractivePopActive = false
            self.fpsBoostToken?.invalidate()
            self.fpsBoostToken = nil
            self.setNeedsStatusBarAppearanceUpdate()
            self.flushDeferredStackMutationsIfPossible()
            UIAccessibility.post(
                notification: .screenChanged,
                argument: Self.accessibilityFocusTarget(for: revealedVC)
            )
        }
    }

    private func cancelInteractivePop(velocity: CGFloat) {
        guard let transition = activeInteractivePop else { return }
        transition.cancel(velocity: velocity) { [weak self, weak transition] in
            guard let self, let transition else { return }
            transition.tearDown(removeTopFromHierarchy: false)
            self.activeInteractivePop = nil
            self.isInteractivePopActive = false
            self.fpsBoostToken?.invalidate()
            self.fpsBoostToken = nil
            self.flushDeferredStackMutationsIfPossible()
        }
    }

    // MARK: - Stack mutations

    /// Push a new controller onto the stack.
    public func push(_ viewController: UIViewController, animated: Bool = true) {
        guard !stack.contains(where: { $0 === viewController }) else {
            assertionFailure(
                "ZynaNavigationController cannot push a controller that's already on the stack"
            )
            return
        }
        guard !isTransitionInFlight else {
            deferredStackMutations.append(.push(viewController, animated: animated))
            return
        }

        let previousTop = topViewController
        addChild(viewController)
        stack.append(viewController)

        if isViewLoaded, animated, let previousTop {
            // Direct kick so glass tracks the slide from frame 0
            // instead of waiting on the GlassService watchdog.
            GlassService.shared.captureFor(duration: IOS26Spring.duration + 0.1)
            performAnimatedPush(from: previousTop, to: viewController) {
                viewController.didMove(toParent: self)
            }
        } else {
            if isViewLoaded {
                attachView(of: viewController)
                if let previousTop {
                    detachView(of: previousTop)
                }
            }
            viewController.didMove(toParent: self)
            flushDeferredStackMutationsIfPossible()
        }
    }

    /// Pop the top controller. Returns the controller that was
    /// removed, or nil if the stack has only the root.
    @discardableResult
    public func pop(animated: Bool = true) -> UIViewController? {
        guard stack.count > 1 else { return nil }
        guard !isTransitionInFlight else {
            deferredStackMutations.append(.pop(animated: animated))
            return nil
        }

        let popped = stack.removeLast()
        let revealed = topViewController!  // safe: count was > 1

        popped.willMove(toParent: nil)

        if isViewLoaded, animated {
            GlassService.shared.captureFor(duration: IOS26Spring.duration + 0.1)
            performAnimatedPop(removing: popped, revealing: revealed) {
                popped.removeFromParent()
            }
        } else {
            if isViewLoaded {
                attachView(of: revealed)
                detachView(of: popped)
            }
            popped.removeFromParent()
            flushDeferredStackMutationsIfPossible()
        }

        return popped
    }

    /// Pop everything above the root. Returns the popped controllers
    /// in pop order (top first).
    @discardableResult
    public func popToRoot(animated: Bool = true) -> [UIViewController] {
        guard stack.count > 1 else { return [] }
        guard !isTransitionInFlight else {
            deferredStackMutations.append(.popToRoot(animated: animated))
            return []
        }

        let root = stack[0]
        let currentTop = topViewController!  // safe: count was > 1
        var popped: [UIViewController] = []

        while stack.count > 1 {
            let vc = stack.removeLast()
            vc.willMove(toParent: nil)
            popped.append(vc)
        }

        let finalize: () -> Void = {
            for vc in popped {
                vc.removeFromParent()
            }
        }

        if isViewLoaded, animated {
            // Animate the slide between currentTop → root. The middle
            // controllers were never in the hierarchy, so visually it
            // looks like a single pop from the actual top to the root.
            GlassService.shared.captureFor(duration: IOS26Spring.duration + 0.1)
            performAnimatedPop(removing: currentTop, revealing: root, completion: finalize)
        } else {
            if isViewLoaded {
                attachView(of: root)
                for vc in popped {
                    detachView(of: vc)
                }
            }
            finalize()
            flushDeferredStackMutationsIfPossible()
        }

        return popped
    }

    // MARK: - Animation

    /// Parallax ratio: how far the bottom controller drifts left
    /// while the top one slides in. UIKit's stock value is 30%.
    private static let parallaxRatio: CGFloat = 0.3

    /// Dim opacity applied to the bottom controller at the peak of
    /// the slide. UIKit/Telegram both use ~15%.
    private static let dimAlpha: Float = 0.15

    private static let transitionCornerRadius = IOS26Spring.screenCornerRadius

    /// Push: top slides in from the right, bottom parallaxes left,
    /// dim overlay fades to 15 %. Three animations grouped in one
    /// `CATransaction` so the completion fires once.
    private func performAnimatedPush(
        from oldTop: UIViewController,
        to newTop: UIViewController,
        completion: @escaping () -> Void
    ) {
        let containerBounds = view.bounds
        let width = containerBounds.width
        let parallax = -width * Self.parallaxRatio

        let newView = newTop.view!
        newView.frame = containerBounds
        newView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(newView)

        // Dim layer between bottom and top.
        let dim = UIView(frame: containerBounds)
        dim.backgroundColor = .black
        dim.layer.opacity = 0
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(dim, belowSubview: newView)

        let oldView = oldTop.view!

        // Round the sliding card to match the display corners.
        let savedClips = newView.clipsToBounds
        let savedRadius = newView.layer.cornerRadius
        newView.layer.cornerRadius = Self.transitionCornerRadius
        newView.layer.cornerCurve = .continuous
        newView.clipsToBounds = true

        view.isUserInteractionEnabled = false
        isAnimatingTransition = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        oldView.layer.transform = CATransform3DMakeTranslation(parallax, 0, 0)
        dim.layer.opacity = Self.dimAlpha
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            oldView.removeFromSuperview()
            dim.removeFromSuperview()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            oldView.layer.transform = CATransform3DIdentity
            CATransaction.commit()
            newView.layer.cornerRadius = savedRadius
            newView.layer.cornerCurve = .circular
            newView.clipsToBounds = savedClips
            self.view.isUserInteractionEnabled = true
            self.isAnimatingTransition = false
            completion()
            self.flushDeferredStackMutationsIfPossible()
            UIAccessibility.post(
                notification: .screenChanged,
                argument: Self.accessibilityFocusTarget(for: newTop)
            )
        }

        newView.layer.add(
            IOS26Spring.makeAnimation(
                keyPath: "transform.translation.x",
                from: width,
                to: 0
            ),
            forKey: "push.slideIn"
        )
        oldView.layer.add(
            IOS26Spring.makeAnimation(
                keyPath: "transform.translation.x",
                from: 0,
                to: parallax
            ),
            forKey: "push.parallax"
        )
        dim.layer.add(
            IOS26Spring.makeAnimation(
                keyPath: "opacity",
                from: 0,
                to: Self.dimAlpha
            ),
            forKey: "push.dim"
        )

        CATransaction.commit()
    }

    /// Pop: reverse of `performAnimatedPush`. Top slides out right,
    /// parallaxed bottom slides back to identity, dim fades to 0.
    private func performAnimatedPop(
        removing topVC: UIViewController,
        revealing revealedVC: UIViewController,
        completion: @escaping () -> Void
    ) {
        let containerBounds = view.bounds
        let width = containerBounds.width
        let parallax = -width * Self.parallaxRatio

        // Re-attach revealed view at parallax position, beneath top.
        let revealedView = revealedVC.view!
        revealedView.frame = containerBounds
        revealedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(revealedView, belowSubview: topVC.view)

        // Dim layer between revealed and top.
        let dim = UIView(frame: containerBounds)
        dim.backgroundColor = .black
        dim.layer.opacity = Self.dimAlpha
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(dim, belowSubview: topVC.view)

        let topView = topVC.view!

        let savedClips = topView.clipsToBounds
        let savedRadius = topView.layer.cornerRadius
        topView.layer.cornerRadius = Self.transitionCornerRadius
        topView.layer.cornerCurve = .continuous
        topView.clipsToBounds = true

        view.isUserInteractionEnabled = false
        isAnimatingTransition = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealedView.layer.transform = CATransform3DIdentity
        topView.layer.transform = CATransform3DMakeTranslation(width, 0, 0)
        dim.layer.opacity = 0
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            topView.removeFromSuperview()
            dim.removeFromSuperview()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            topView.layer.transform = CATransform3DIdentity
            CATransaction.commit()
            topView.layer.cornerRadius = savedRadius
            topView.layer.cornerCurve = .circular
            topView.clipsToBounds = savedClips
            self.view.isUserInteractionEnabled = true
            self.isAnimatingTransition = false
            completion()
            self.flushDeferredStackMutationsIfPossible()
            UIAccessibility.post(
                notification: .screenChanged,
                argument: Self.accessibilityFocusTarget(for: revealedVC)
            )
        }

        topView.layer.add(
            IOS26Spring.makeAnimation(
                keyPath: "transform.translation.x",
                from: 0,
                to: width
            ),
            forKey: "pop.slideOut"
        )
        revealedView.layer.add(
            IOS26Spring.makeAnimation(
                keyPath: "transform.translation.x",
                from: parallax,
                to: 0
            ),
            forKey: "pop.parallax"
        )
        dim.layer.add(
            IOS26Spring.makeAnimation(
                keyPath: "opacity",
                from: Self.dimAlpha,
                to: 0
            ),
            forKey: "pop.dim"
        )

        CATransaction.commit()
    }

    /// Replace the entire stack. The last element becomes top.
    /// Controllers in the new stack that weren't previously present
    /// are `addChild`'d; controllers that drop out are removed.
    public func setStack(_ viewControllers: [UIViewController], animated: Bool = true) {
        precondition(!viewControllers.isEmpty, "ZynaNavigationController stack cannot be empty")

        let oldTop = topViewController
        let newTop = viewControllers.last!

        let oldSet = ObjectSetView(stack)
        let newSet = ObjectSetView(viewControllers)

        // Identify additions and removals by identity.
        let leaving = stack.filter { !newSet.contains($0) }
        let joining = viewControllers.filter { !oldSet.contains($0) }

        // Phase 1: signal departure.
        for vc in leaving {
            vc.willMove(toParent: nil)
        }

        // Phase 2: enter the stack.
        for vc in joining {
            addChild(vc)
        }

        // Phase 3: rewrite the stack.
        stack = viewControllers

        // Phase 4: swap visible view if the top changed.
        if isViewLoaded, oldTop !== newTop {
            attachView(of: newTop)
            if let oldTop {
                detachView(of: oldTop)
            }
        }

        // Phase 5: finalize relationships.
        for vc in joining {
            vc.didMove(toParent: self)
        }
        for vc in leaving {
            vc.removeFromParent()
        }
    }

    // MARK: - View hierarchy management

    private func attachView(of vc: UIViewController) {
        let v = vc.view!
        v.frame = view.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(v)
        setNeedsStatusBarAppearanceUpdate()
    }

    private func detachView(of vc: UIViewController) {
        vc.view.removeFromSuperview()
    }

    private func flushDeferredStackMutationsIfPossible() {
        guard !isTransitionInFlight,
              !deferredStackMutations.isEmpty else { return }

        let mutation = deferredStackMutations.removeFirst()
        switch mutation {
        case .push(let viewController, let animated):
            push(viewController, animated: animated)
        case .pop(let animated):
            _ = pop(animated: animated)
        case .popToRoot(let animated):
            _ = popToRoot(animated: animated)
        }
    }

    /// VoiceOver Z-scrub dismiss. Called via `ZynaNavBackingView`
    /// (UIView override) since UIKit dispatches escape on views,
    /// not view controllers.
    func performEscapeAction() -> Bool {
        guard stack.count > 1,
              !isInteractivePopActive,
              !isAnimatingTransition
        else { return false }
        pop()
        return true
    }

    /// Target for `.screenChanged` after push/pop. VCs conforming to
    /// `AccessibilityFocusProviding` pick the specific element; others
    /// fall back to the VC's whole view (VO descends into its subtree).
    private static func accessibilityFocusTarget(for vc: UIViewController?) -> Any? {
        guard let vc else { return nil }
        if let provider = vc as? AccessibilityFocusProviding,
           let focus = provider.initialAccessibilityFocus {
            return focus
        }
        return vc.view
    }
}

/// Backing view whose only job is to forward the VO two-finger Z-scrub
/// escape gesture to the owning nav controller.
private final class ZynaNavBackingView: UIView {
    weak var owner: ZynaNavigationController?

    override func accessibilityPerformEscape() -> Bool {
        owner?.performEscapeAction() ?? false
    }
}

/// Identity-based set lookup over an array of reference types.
/// Lets `setStack` diff old vs. new without making controllers
/// conform to `Hashable`.
private struct ObjectSetView {
    private let identifiers: Set<ObjectIdentifier>

    init(_ array: [AnyObject]) {
        self.identifiers = Set(array.map(ObjectIdentifier.init))
    }

    func contains(_ object: AnyObject) -> Bool {
        identifiers.contains(ObjectIdentifier(object))
    }
}
