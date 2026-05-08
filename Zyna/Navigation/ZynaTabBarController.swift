//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Combine
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
/// - Predictable safe-area math: children get additional insets for
///   persistent root chrome, so inner UIs respect reservations without
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
    private let voicePlayerView = VoiceTopPlayerView(frame: .zero)
    private weak var voicePlaybackService: AudioPlayerService?
    private var voicePlaybackCancellables = Set<AnyCancellable>()
    private var isVoicePlayerVisible = false

    private enum VoicePlayerMetrics {
        static let height: CGFloat = 52
        static let topMargin: CGFloat = 6
        static let sideInset: CGFloat = 8
        static let maxWidth: CGFloat = 560
        static let bottomGap: CGFloat = 4

        static var reservedTopInset: CGFloat {
            topMargin + height + bottomGap
        }
    }

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
        installVoicePlayerView()
        if let service = voicePlaybackService {
            applyVoicePlaybackState(
                service.state,
                item: service.nowPlaying,
                snapshot: service.snapshot
            )
        }

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
        layoutVoicePlayerView()
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

    func setVoicePlaybackService(_ service: AudioPlayerService) {
        voicePlaybackService = service
        voicePlaybackCancellables.removeAll()

        service.$state
            .combineLatest(service.$nowPlaying, service.$snapshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, item, snapshot in
                self?.applyVoicePlaybackState(state, item: item, snapshot: snapshot)
            }
            .store(in: &voicePlaybackCancellables)
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
        view.bringSubviewToFront(voicePlayerView)
    }

    func reattachSelectedControllerViewIfNeeded() {
        guard let current = selectedController else { return }
        if current.view.superview !== view {
            attachControllerView(current)
        } else {
            layoutSelectedControllerView()
        }
    }

    private func installVoicePlayerView() {
        voicePlayerView.isHidden = !isVoicePlayerVisible
        voicePlayerView.alpha = isVoicePlayerVisible ? 1 : 0
        voicePlayerView.onPlayPause = { [weak self] in
            guard let service = self?.voicePlaybackService else { return }
            if service.state.isPlaying {
                service.pause()
            } else {
                service.resume()
            }
        }
        voicePlayerView.onClose = { [weak self] in
            self?.voicePlaybackService?.stop()
        }
        voicePlayerView.onSeek = { [weak self] progress in
            self?.voicePlaybackService?.seek(to: progress)
        }
        voicePlayerView.onSpeed = { [weak self] in
            self?.voicePlaybackService?.cyclePlaybackRate()
        }
        view.addSubview(voicePlayerView)
    }

    private func applyVoicePlaybackState(
        _ state: AudioPlayerService.State,
        item: AudioPlayerService.NowPlayingItem?,
        snapshot: AudioPlayerService.PlaybackSnapshot
    ) {
        voicePlayerView.configure(state: state, item: item, snapshot: snapshot)

        let shouldShow: Bool
        if case .idle = state {
            shouldShow = false
        } else {
            shouldShow = item != nil
        }

        setVoicePlayerVisible(shouldShow, animated: isViewLoaded)
    }

    private func setVoicePlayerVisible(_ visible: Bool, animated: Bool) {
        guard isVoicePlayerVisible != visible else { return }
        isVoicePlayerVisible = visible
        propagateAdditionalSafeArea()
        controllers.forEach {
            guard $0.isViewLoaded else { return }
            $0.view.setNeedsLayout()
        }
        recaptureGlassAfterVoicePlayerChromeChange(animated: animated)

        guard isViewLoaded else { return }

        let targetFrame = voicePlayerRestingFrame(visible: visible)

        if visible {
            voicePlayerView.isHidden = false
            voicePlayerView.frame = voicePlayerRestingFrame(visible: false)
            view.bringSubviewToFront(voicePlayerView)
        }

        let animations = {
            self.voicePlayerView.alpha = visible ? 1 : 0
            self.voicePlayerView.frame = targetFrame
        }

        if animated {
            UIView.animate(
                withDuration: IOS26Spring.duration,
                delay: 0,
                usingSpringWithDamping: 1,
                initialSpringVelocity: 0,
                options: [.curveEaseOut, .beginFromCurrentState],
                animations: animations,
                completion: { [weak self] _ in
                    guard let self, !self.isVoicePlayerVisible else { return }
                    self.voicePlayerView.isHidden = true
                }
            )
        } else {
            animations()
            voicePlayerView.isHidden = !visible
        }
    }

    private func recaptureGlassAfterVoicePlayerChromeChange(animated: Bool) {
        let duration = animated ? IOS26Spring.duration + 0.15 : 0.15
        GlassService.shared.captureFor(duration: duration)
        GlassService.shared.setNeedsCapture()

        DispatchQueue.main.async { [weak self] in
            self?.view.layoutIfNeeded()
            GlassService.shared.setNeedsCapture()
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

    private func voicePlayerRestingFrame(visible: Bool) -> CGRect {
        let width = min(view.bounds.width - VoicePlayerMetrics.sideInset * 2, VoicePlayerMetrics.maxWidth)
        let x = (view.bounds.width - width) / 2
        let visibleY = view.safeAreaInsets.top + VoicePlayerMetrics.topMargin
        let hiddenY = visibleY - VoicePlayerMetrics.height - VoicePlayerMetrics.topMargin - 4
        return CGRect(
            x: x,
            y: visible ? visibleY : hiddenY,
            width: width,
            height: VoicePlayerMetrics.height
        )
    }

    private func layoutVoicePlayerView() {
        voicePlayerView.frame = voicePlayerRestingFrame(visible: isVoicePlayerVisible)
        if !voicePlayerView.isHidden {
            view.bringSubviewToFront(voicePlayerView)
        }
    }

    private func layoutSelectedControllerView() {
        selectedController?.view.frame = view.bounds
    }

    /// `additionalSafeAreaInsets` propagates through the view hierarchy,
    /// so inner screens can respect persistent chrome reservations without
    /// knowing which root overlay owns them.
    private func propagateAdditionalSafeArea() {
        let bottom: CGFloat = isTabBarHidden ? 0 : ZynaTabBar.barContentHeight
        let top: CGFloat = isVoicePlayerVisible ? VoicePlayerMetrics.reservedTopInset : 0
        for vc in controllers where vc.additionalSafeAreaInsets.bottom != bottom || vc.additionalSafeAreaInsets.top != top {
            vc.additionalSafeAreaInsets.bottom = bottom
            vc.additionalSafeAreaInsets.top = top
        }
    }
}
