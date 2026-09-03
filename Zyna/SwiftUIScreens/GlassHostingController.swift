//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI
import UIKit

private enum GlassHostingMetrics {
    static let contentGap: CGFloat = 8
    static let scrollViewLookupRetryInterval: CFTimeInterval = 0.5
}

/// Reserves room for the bar island without touching the safe area.
private struct GlassHostedContent<Content: View>: View {

    let topInset: CGFloat
    let content: Content

    var body: some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: topInset)
        }
    }
}

/// Push-ready shell that gives a SwiftUI screen the chrome Texture
/// screens get: glass top bar, embedded voice player, VoiceOver order,
/// glass re-capture on scroll.
///
/// The bar's height reaches the content as a `safeAreaInset`, never
/// through `additionalSafeAreaInsets`: the bar places itself at
/// `safeAreaInsets.top` and the voice player discounts only its own
/// contribution, so inflating the safe area pushes the chrome down too.
final class GlassHostingController<Content: View>: UIViewController {

    /// Replacing `items` drops the default back button — rebuild it.
    let glassTopBar: GlassTopBar

    /// Fires when the navigation stack drops this screen (pop, pop-to-root,
    /// stack replacement). Modal presentations on top do not trigger it.
    var onRemovedFromParent: (@MainActor () -> Void)?

    private let hostingController: UIHostingController<GlassHostedContent<Content>>
    private let screenBackgroundColor: UIColor
    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?
    private weak var cachedScrollView: UIScrollView?
    private var lastScrollViewLookup: CFTimeInterval = 0
    private var isRegisteredAsCaptureSource = false

    /// - Parameter screenBackgroundColor: feeds both the root view and the
    ///   glass clear color, which must never diverge.
    init(
        title: String,
        rootView: Content,
        audioPlayer: AudioPlayerService? = nil,
        screenBackgroundColor: UIColor = .appBG,
        onBack: (() -> Void)? = nil
    ) {
        let bar = GlassTopBar()
        self.glassTopBar = bar
        self.hostingController = UIHostingController(
            rootView: GlassHostedContent(
                topInset: bar.barHeight + GlassHostingMetrics.contentGap,
                content: rootView
            )
        )
        self.screenBackgroundColor = screenBackgroundColor
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
        self.voicePlayerHost = audioPlayer.map {
            EmbeddedVoiceTopPlayerHost(viewController: self, audioPlayer: $0)
        }
        buildBarItems(title: title, onBack: onBack)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = GlassHostingRootView()
        root.backgroundColor = screenBackgroundColor
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHostingController()
        setupGlassTopBar()
        setupVoicePlayerHost()
        wireAccessibilityOrder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hostingController.view.frame = view.bounds
        voicePlayerHost?.layout()
        glassTopBar.updateLayout(in: view)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        voicePlayerHost?.refresh()
        registerCaptureSource()
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Recapture once the push transition has settled.
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        unregisterCaptureSource()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            onRemovedFromParent?()
        }
    }

    deinit {
        if isRegisteredAsCaptureSource {
            GlassService.shared.removeCaptureSource(self)
        }
    }

    // MARK: - Setup

    private func setupHostingController() {
        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = screenBackgroundColor
        glassTopBar.sourceView = hostingController.view
        view.addSubview(glassTopBar.view)
    }

    private func buildBarItems(title: String, onBack: (() -> Void)?) {
        var items: [GlassTopBar.Item] = []
        if let onBack {
            let backIcon = AppIcon.chevronBackward.template(size: 17, weight: .semibold)
            items.append(.circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: onBack
            ))
        }
        items.append(.title(text: title, subtitle: nil))
        glassTopBar.items = items
    }

    private func setupVoicePlayerHost() {
        voicePlayerHost?.onVisibilityChanged = { [weak self] in
            self?.view.setNeedsLayout()
            GlassService.shared.setNeedsCapture()
        }
        voicePlayerHost?.install()
    }

    private func wireAccessibilityOrder() {
        guard let root = view as? GlassHostingRootView else { return }
        root.glassTopBar = glassTopBar
        root.contentView = hostingController.view
        root.voicePlayerView = voicePlayerHost?.accessibilityView
    }

    // MARK: - Glass capture

    private func registerCaptureSource() {
        guard !isRegisteredAsCaptureSource else { return }
        isRegisteredAsCaptureSource = true
        GlassService.shared.addCaptureSource(self)
    }

    private func unregisterCaptureSource() {
        guard isRegisteredAsCaptureSource else { return }
        isRegisteredAsCaptureSource = false
        GlassService.shared.removeCaptureSource(self)
    }

    /// SwiftUI owns the scroll view's delegate, so glass polls its state
    /// every frame instead. Failed lookups are throttled to keep that
    /// polling cheap; a miss can't be cached for good, since SwiftUI may
    /// build the scroll view lazily.
    private var hostedScrollView: UIScrollView? {
        if let cachedScrollView, cachedScrollView.window != nil {
            return cachedScrollView
        }
        let now = CACurrentMediaTime()
        guard now - lastScrollViewLookup > GlassHostingMetrics.scrollViewLookupRetryInterval else {
            return nil
        }
        lastScrollViewLookup = now
        cachedScrollView = Self.findScrollView(in: hostingController.view)
        return cachedScrollView
    }

    /// Breadth-first: the screen's main scroll view is the shallowest one.
    private static func findScrollView(in root: UIView) -> UIScrollView? {
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            if let scrollView = candidate as? UIScrollView {
                return scrollView
            }
            queue.append(contentsOf: candidate.subviews)
        }
        return nil
    }
}

// MARK: - GlassCaptureSource

extension GlassHostingController: GlassCaptureSource {

    /// Excludes `isTracking`: a finger resting on a list it never dragged
    /// would hold the capture loop open for nothing.
    var needsGlassCapture: Bool {
        guard let scrollView = hostedScrollView else { return false }
        return scrollView.isDragging || scrollView.isDecelerating
    }

    var captureSourceFrame: CGRect? {
        guard let window = view.window else { return nil }
        return view.convert(view.bounds, to: window)
    }
}

// MARK: - Accessibility

extension GlassHostingController: AccessibilityFocusProviding {
    /// First bar element after push — the back button when there is one.
    var initialAccessibilityFocus: UIView? {
        AccessibilityElementOrder.firstVisibleView(in: glassTopBar)
    }
}

/// Voice player when visible, then the bar items, then the content.
private final class GlassHostingRootView: UIView {

    weak var glassTopBar: GlassTopBar?
    weak var contentView: UIView?
    weak var voicePlayerView: UIView?

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let voicePlayerView,
               voicePlayerView.superview === self,
               !voicePlayerView.isHidden,
               voicePlayerView.alpha > 0.01 {
                elements.append(voicePlayerView)
            }
            if let glassTopBar, glassTopBar.view.superview === self {
                elements.append(contentsOf: glassTopBar.accessibilityElementsInOrder)
            }
            if let contentView, contentView.superview === self {
                elements.append(contentView)
            }
            return elements
        }
        set { }
    }
}
