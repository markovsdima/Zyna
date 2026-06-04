//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

struct BannerVisibilityContext: Equatable {
    var currentRoomId: String?

    static let empty = BannerVisibilityContext(currentRoomId: nil)
}

struct AppBannerItem {
    static let defaultDuration: TimeInterval = 5

    let id: String
    let title: String
    let subtitle: String?
    let icon: AppIcon
    let tintColor: UIColor
    let primaryActionTitle: String?
    let duration: TimeInterval?
    let suppressIn: ((BannerVisibilityContext) -> Bool)?
    let onPrimaryAction: () -> Void
    let onDismiss: (() -> Void)?

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: AppIcon,
        tintColor: UIColor,
        primaryActionTitle: String? = nil,
        duration: TimeInterval? = AppBannerItem.defaultDuration,
        suppressIn: ((BannerVisibilityContext) -> Bool)? = nil,
        onPrimaryAction: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tintColor = tintColor
        self.primaryActionTitle = primaryActionTitle
        self.duration = duration
        self.suppressIn = suppressIn
        self.onPrimaryAction = onPrimaryAction
        self.onDismiss = onDismiss
    }
}

final class AppBannerCenter {
    static let shared = AppBannerCenter()

    private weak var sourceWindow: UIWindow?
    private var overlayWindow: AppBannerOverlayWindow?
    private var currentItem: AppBannerItem?
    private var autoDismissWorkItem: DispatchWorkItem?
    private var visibilityContext: BannerVisibilityContext = .empty

    private init() {}

    func attach(to window: UIWindow) {
        guard sourceWindow !== window else { return }
        sourceWindow = window
        overlayWindow?.isHidden = true
        overlayWindow = nil
        currentItem = nil
        cancelAutoDismiss()
    }

    func updateVisibility(_ context: BannerVisibilityContext) {
        guard visibilityContext != context else { return }
        visibilityContext = context
        if let item = currentItem, item.suppressIn?(context) == true {
            dismissCurrent(animated: true, notify: false)
        }
    }

    func show(_ item: AppBannerItem) {
        dispatchPrecondition(condition: .onQueue(.main))
        if item.suppressIn?(visibilityContext) == true { return }
        guard let window = sourceWindow,
              let windowScene = window.windowScene else { return }

        let overlayWindow = overlayWindow ?? makeOverlayWindow(
            scene: windowScene,
            sourceWindow: window
        )
        overlayWindow.frame = window.bounds
        overlayWindow.windowLevel = window.windowLevel + 2
        self.overlayWindow = overlayWindow

        let isReplacing = overlayWindow.bannerContainer.hasVisibleBanner
        currentItem = item
        overlayWindow.isHidden = false
        overlayWindow.bannerContainer.show(item, animated: !isReplacing)
        scheduleAutoDismissIfNeeded(for: item)
    }

    func dismiss(id: String, animated: Bool = true) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard currentItem?.id == id else { return }
        dismissCurrent(animated: animated, notify: false)
    }

    func dismissAll(animated: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissCurrent(animated: animated, notify: false)
    }

    fileprivate func setAutoDismissPaused(_ paused: Bool) {
        if paused {
            cancelAutoDismiss()
        } else if let item = currentItem {
            scheduleAutoDismissIfNeeded(for: item)
        }
    }

    private func dismissCurrent(animated: Bool, notify: Bool) {
        cancelAutoDismiss()
        let dismissedItem = currentItem
        currentItem = nil
        overlayWindow?.bannerContainer.hide(animated: animated) { [weak self] in
            guard let self else { return }
            if self.currentItem == nil {
                self.overlayWindow?.isHidden = true
            }
        }
        if notify {
            dismissedItem?.onDismiss?()
        }
    }

    private func scheduleAutoDismissIfNeeded(for item: AppBannerItem) {
        cancelAutoDismiss()
        guard let duration = item.duration else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.currentItem?.id == item.id else { return }
            self.dismissCurrent(animated: true, notify: true)
        }
        autoDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func cancelAutoDismiss() {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
    }

    private func makeOverlayWindow(
        scene: UIWindowScene,
        sourceWindow: UIWindow
    ) -> AppBannerOverlayWindow {
        let window = AppBannerOverlayWindow(windowScene: scene)
        window.frame = sourceWindow.bounds
        window.windowLevel = sourceWindow.windowLevel + 2
        window.bannerContainer.onPrimaryAction = { [weak self] in
            guard let self, let item = self.currentItem else { return }
            self.dismissCurrent(animated: true, notify: false)
            item.onPrimaryAction()
        }
        window.bannerContainer.onSwipeDismiss = { [weak self] in
            self?.dismissCurrent(animated: true, notify: true)
        }
        window.bannerContainer.onInteractionStarted = { [weak self] in
            self?.setAutoDismissPaused(true)
        }
        window.bannerContainer.onInteractionEnded = { [weak self] in
            self?.setAutoDismissPaused(false)
        }
        return window
    }
}

// MARK: - Overlay window

private final class AppBannerOverlayWindow: UIWindow {
    let bannerContainer = AppBannerContainerView()

    override var canBecomeKey: Bool { false }

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        backgroundColor = .clear

        let rootVC = UIViewController()
        rootVC.view.backgroundColor = .clear
        rootVC.view = bannerContainer
        rootViewController = rootVC
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        guard let hitView,
              hitView !== self,
              hitView !== bannerContainer else {
            return nil
        }
        return hitView
    }
}

// MARK: - Container

private final class AppBannerContainerView: UIView {
    var onPrimaryAction: (() -> Void)?
    var onSwipeDismiss: (() -> Void)?
    var onInteractionStarted: (() -> Void)?
    var onInteractionEnded: (() -> Void)?

    var hasVisibleBanner: Bool {
        !bannerView.isHidden && bannerView.alpha > 0.01
    }

    private let bannerView = AppBannerView()
    private var panStartFrame: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        bannerView.isHidden = true
        bannerView.alpha = 0
        bannerView.onPrimaryAction = { [weak self] in
            self?.onPrimaryAction?()
        }
        bannerView.onTouchDown = { [weak self] in
            self?.onInteractionStarted?()
        }
        bannerView.onTouchUp = { [weak self] in
            self?.onInteractionEnded?()
        }
        addSubview(bannerView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        bannerView.addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !isPanningOrHidden {
            bannerView.frame = targetBannerFrame()
        }
        bannerView.layoutIfNeeded()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !bannerView.isHidden,
              bannerView.alpha > 0.01,
              bannerView.frame.contains(point) else {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    func show(_ item: AppBannerItem, animated: Bool) {
        bannerView.configure(item)
        let targetFrame = targetBannerFrame()

        if bannerView.isHidden {
            bannerView.frame = targetFrame.offsetBy(dx: 0, dy: -24)
            bannerView.alpha = 0
            bannerView.isHidden = false
        }

        let animations = {
            self.bannerView.frame = targetFrame
            self.bannerView.alpha = 1
        }

        if animated {
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
                animations: animations
            )
        } else {
            animations()
        }
    }

    func hide(animated: Bool, completion: @escaping () -> Void) {
        guard !bannerView.isHidden else {
            completion()
            return
        }

        let animations = {
            self.bannerView.frame = self.targetBannerFrame().offsetBy(dx: 0, dy: -24)
            self.bannerView.alpha = 0
        }
        let finish: (Bool) -> Void = { _ in
            self.bannerView.isHidden = true
            completion()
        }

        if animated {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn],
                animations: animations,
                completion: finish
            )
        } else {
            animations()
            finish(true)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            panStartFrame = bannerView.frame
            onInteractionStarted?()
        case .changed:
            var dy = translation.y
            if dy > 0 { dy = dy / 3 }
            bannerView.frame = panStartFrame.offsetBy(dx: 0, dy: dy)
        case .ended:
            let velocity = gesture.velocity(in: self).y
            if translation.y < -28 || velocity < -600 {
                onSwipeDismiss?()
            } else {
                UIView.animate(
                    withDuration: 0.18,
                    delay: 0,
                    options: [.curveEaseOut],
                    animations: { self.bannerView.frame = self.targetBannerFrame() }
                )
                onInteractionEnded?()
            }
        case .cancelled, .failed:
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.curveEaseOut],
                animations: { self.bannerView.frame = self.targetBannerFrame() }
            )
            onInteractionEnded?()
        default:
            break
        }
    }

    private var isPanningOrHidden: Bool {
        if bannerView.isHidden { return true }
        for gesture in bannerView.gestureRecognizers ?? [] {
            if gesture.state == .began || gesture.state == .changed { return true }
        }
        return false
    }

    private func targetBannerFrame() -> CGRect {
        let horizontalInset: CGFloat = 12
        let width = min(bounds.width - horizontalInset * 2, 430)
        let x = (bounds.width - width) / 2
        return CGRect(
            x: x,
            y: safeAreaInsets.top + 8,
            width: width,
            height: AppBannerView.height
        )
    }
}

// MARK: - View

private final class AppBannerView: UIControl {
    static let height: CGFloat = 72

    var onPrimaryAction: (() -> Void)?
    var onTouchDown: (() -> Void)?
    var onTouchUp: (() -> Void)?

    private let iconBackgroundView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let actionButton = UIButton(type: .system)

    private var hasPrimaryActionButton = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.98)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 20
        layer.shadowOffset = CGSize(width: 0, height: 8)
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        addTarget(self, action: #selector(primaryActionTapped), for: .touchUpInside)
        addTarget(self, action: #selector(touchDownHandler), for: .touchDown)
        addTarget(
            self,
            action: #selector(touchUpHandler),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )

        iconBackgroundView.clipsToBounds = true
        iconBackgroundView.isUserInteractionEnabled = false

        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false

        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isUserInteractionEnabled = false

        actionButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        actionButton.addTarget(self, action: #selector(primaryActionTapped), for: .touchUpInside)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(iconBackgroundView)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(actionButton)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: layer.cornerRadius
        ).cgPath

        let iconSize: CGFloat = 40
        let iconFrame = CGRect(
            x: 14,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        iconBackgroundView.frame = iconFrame
        iconBackgroundView.layer.cornerRadius = iconSize / 2
        iconView.frame = iconFrame

        let rightInset: CGFloat = 14
        let textLeft = iconFrame.maxX + 12
        let textRight: CGFloat
        if hasPrimaryActionButton {
            let size = actionButton.sizeThatFits(
                CGSize(width: bounds.width * 0.34, height: bounds.height)
            )
            let actionWidth = min(max(size.width + 12, 64), max(64, bounds.width * 0.32))
            let actionRight = bounds.width - rightInset
            actionButton.frame = CGRect(
                x: actionRight - actionWidth,
                y: (bounds.height - 34) / 2,
                width: actionWidth,
                height: 34
            )
            actionButton.isHidden = false
            textRight = actionButton.frame.minX - 12
        } else {
            actionButton.frame = .zero
            actionButton.isHidden = true
            textRight = bounds.width - rightInset
        }

        let textWidth = max(0, textRight - textLeft)
        titleLabel.frame = CGRect(x: textLeft, y: 16, width: textWidth, height: 20)
        subtitleLabel.frame = CGRect(x: textLeft, y: 36, width: textWidth, height: 18)
    }

    func configure(_ item: AppBannerItem) {
        iconBackgroundView.backgroundColor = item.tintColor.withAlphaComponent(0.16)
        iconView.image = item.icon.template(size: 18, weight: .semibold)
        iconView.tintColor = item.tintColor
        titleLabel.text = item.title
        subtitleLabel.text = item.subtitle

        if let actionTitle = item.primaryActionTitle, !actionTitle.isEmpty {
            hasPrimaryActionButton = true
            var configuration = UIButton.Configuration.filled()
            configuration.title = actionTitle
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = item.tintColor
            configuration.cornerStyle = .capsule
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 7,
                leading: 13,
                bottom: 7,
                trailing: 13
            )
            actionButton.configuration = configuration
        } else {
            hasPrimaryActionButton = false
        }

        accessibilityLabel = [item.title, item.subtitle]
            .compactMap { $0 }
            .joined(separator: ", ")
        accessibilityHint = item.primaryActionTitle
        setNeedsLayout()
    }

    @objc private func primaryActionTapped() {
        onPrimaryAction?()
    }

    @objc private func touchDownHandler() {
        onTouchDown?()
    }

    @objc private func touchUpHandler() {
        onTouchUp?()
    }
}
