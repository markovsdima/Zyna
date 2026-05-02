//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Custom tab bar host. **Not** a `UITabBarController` subclass —
/// a plain `UIViewController` that owns child controllers and a
/// `ZynaTabBar` chrome view at the bottom.
///
/// Owning the host gives us:
/// - Explicit, animated sync with `ZynaNavigationController`'s
///   push/pop. The bar slides in lockstep with the slide animation
///   instead of relying on UIKit's hardcoded magic, which only
///   fires for `UINavigationController` children anyway.
/// - A `ZynaTabBar` chrome we can style and animate freely:
///   custom items, badges, future hide-on-scroll, transition tints,
///   anything we'd need.
/// - Predictable safe-area math: children get
///   `additionalSafeAreaInsets.bottom` toggled between the bar
///   height and 0, so inner UIs respect the reservation without
///   knowing about us.
public class ZynaTabBarController: UIViewController {

    // MARK: - State

    public private(set) var controllers: [UIViewController] = []

    public var selectedIndex: Int {
        get { _selectedIndex }
        set { setSelectedIndex(newValue, animated: true, completion: nil) }
    }
    private var _selectedIndex: Int = 0

    public var selectedController: UIViewController? {
        guard _selectedIndex >= 0, _selectedIndex < controllers.count else { return nil }
        return controllers[_selectedIndex]
    }

    public private(set) var isTabBarHidden: Bool = false

    private let tabBar = ZynaTabBar(frame: .zero)

    // MARK: - Init

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(tabBar)

        tabBar.onItemTapped = { [weak self] index in
            self?.handleTabTapped(index)
        }

        // Materialize the initially selected controller's view.
        if let current = selectedController {
            attachControllerView(current)
        }
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        layoutTabBar()
        layoutSelectedControllerView()
    }

    public override var childForStatusBarStyle: UIViewController? { selectedController }
    public override var childForStatusBarHidden: UIViewController? { selectedController }
    public override var childForHomeIndicatorAutoHidden: UIViewController? { selectedController }
    public override var childForScreenEdgesDeferringSystemGestures: UIViewController? { selectedController }
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        selectedController?.supportedInterfaceOrientations ?? .allButUpsideDown
    }
    public override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        selectedController?.preferredInterfaceOrientationForPresentation ?? .portrait
    }

    // MARK: - Public API

    public func setControllers(
        _ newControllers: [UIViewController],
        items: [ZynaTabBarItem],
        selectedIndex: Int = 0
    ) {
        precondition(
            newControllers.count == items.count,
            "controllers and items must have the same count"
        )
        precondition(!newControllers.isEmpty, "tab bar requires at least one controller")
        let safeIndex = max(0, min(selectedIndex, newControllers.count - 1))

        // Detach existing children.
        for vc in controllers {
            vc.willMove(toParent: nil)
            vc.view.removeFromSuperview()
            vc.removeFromParent()
        }

        // Attach new children (parent linkage only — view added when selected).
        for vc in newControllers {
            addChild(vc)
            vc.didMove(toParent: self)
        }

        self.controllers = newControllers
        self._selectedIndex = safeIndex
        tabBar.setItems(items, selectedIndex: safeIndex)

        propagateAdditionalSafeArea()

        if isViewLoaded, let current = selectedController {
            attachControllerView(current)
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    /// Programmatic selection. Tap-driven selection routes through
    /// `handleTabTapped(_:)` so it can do the pop-to-root behavior.
    public func setSelectedIndex(_ newIndex: Int) {
        setSelectedIndex(newIndex, animated: true, completion: nil)
    }

    public func setSelectedIndex(
        _ newIndex: Int,
        animated: Bool,
        completion: (() -> Void)?
    ) {
        guard newIndex >= 0, newIndex < controllers.count else { return }
        let oldIndex = _selectedIndex
        guard oldIndex != newIndex else {
            completion?()
            return
        }

        _selectedIndex = newIndex

        if isViewLoaded {
            let incoming = controllers[newIndex]
            attachControllerView(incoming)

            let finishSelection = {
                if oldIndex >= 0, oldIndex < self.controllers.count {
                    self.controllers[oldIndex].view.removeFromSuperview()
                }
                completion?()
            }

            if animated {
                incoming.view.alpha = 0
                UIView.animate(withDuration: 0.1, delay: 0, options: .curveEaseOut) {
                    incoming.view.alpha = 1
                } completion: { _ in
                    finishSelection()
                }
            } else {
                incoming.view.alpha = 1
                finishSelection()
            }

            setNeedsStatusBarAppearanceUpdate()
        } else {
            completion?()
        }

        tabBar.setSelectedIndex(newIndex)
    }

    public func setTabBarHidden(_ hidden: Bool, animated: Bool) {
        guard isTabBarHidden != hidden else { return }
        isTabBarHidden = hidden
        propagateAdditionalSafeArea()

        guard isViewLoaded else { return }

        let targetFrame = tabBarRestingFrame()

        if animated {
            // Frame animation, not `layer.transform`:
            // `.systemChromeMaterial` blur uses a `CABackdropLayer`
            // that doesn't follow ancestor transform animations —
            // the blur stays put while the container moves.
            UIView.animate(
                withDuration: IOS26Spring.duration,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: [.curveEaseOut]
            ) {
                self.tabBar.frame = targetFrame
            }
        } else {
            tabBar.frame = targetFrame
        }
    }

    public func updateBadge(at index: Int, badge: String?) {
        tabBar.setBadge(badge, at: index)
    }

    // MARK: - Tap handling

    private func handleTabTapped(_ index: Int) {
        if index == _selectedIndex {
            // Double-tap → pop to root.
            if let nav = selectedController as? ZynaNavigationController {
                nav.popToRoot()
            }
            return
        }
        setSelectedIndex(index)
    }

    // MARK: - View hierarchy

    private func attachControllerView(_ vc: UIViewController) {
        let v = vc.view!
        v.frame = view.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(v, belowSubview: tabBar)
    }

    func reattachSelectedControllerViewIfNeeded() {
        guard let current = selectedController else { return }
        if current.view.superview !== view {
            attachControllerView(current)
        } else {
            layoutSelectedControllerView()
        }
    }

    // MARK: - Layout

    /// Resting frame for the current visibility state. Visible →
    /// above the home indicator; hidden → translated entirely below
    /// the screen edge.
    private func tabBarRestingFrame() -> CGRect {
        let safeBottom = view.safeAreaInsets.bottom
        let height = ZynaTabBar.barContentHeight + safeBottom
        let y = isTabBarHidden
            ? view.bounds.height
            : view.bounds.height - height
        return CGRect(x: 0, y: y, width: view.bounds.width, height: height)
    }

    private func layoutTabBar() {
        tabBar.frame = tabBarRestingFrame()
    }

    private func layoutSelectedControllerView() {
        selectedController?.view.frame = view.bounds
    }

    /// `additionalSafeAreaInsets.bottom` propagates through the view
    /// hierarchy, so a chat list table or glass input bar inside a
    /// child controller respects the tab bar reservation without
    /// knowing about us.
    private func propagateAdditionalSafeArea() {
        let bottom: CGFloat = isTabBarHidden ? 0 : ZynaTabBar.barContentHeight
        for vc in controllers where vc.additionalSafeAreaInsets.bottom != bottom {
            vc.additionalSafeAreaInsets.bottom = bottom
        }
    }
}
