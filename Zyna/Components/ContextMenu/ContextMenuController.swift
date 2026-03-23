//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ContextMenuController: NSObject {

    // MARK: - Init Data

    private let contentNode: ASDisplayNode
    private let sourceFrame: CGRect
    private let actions: [ContextMenuAction]

    var onDismissComplete: (() -> Void)?
    var onReactionSelected: ((String) -> Void)?

    // MARK: - Views

    private var overlayWindow: OverlayWindow?
    private let hostNode = ASDisplayNode()
    private let contentScroll = UIScrollView()
    private let dimmingView = UIView()
    private let actionsContainer = UIView()
    private let actionsStack = UIStackView()
    private let reactionsBar = UIView()

    // MARK: - Emoji Grid (expanded picker)

    private let emojiGridContainer = UIView()
    private let emojiGridNode = InlineEmojiGridNode()
    private var isEmojiGridVisible = false

    // MARK: - Drag-to-Select

    private var actionRows: [(control: HighlightControl, action: ContextMenuAction)] = []
    private weak var highlightedRow: HighlightControl?
    private let selectionFeedback = UISelectionFeedbackGenerator()

    // MARK: - Layout State

    private var targetContentFrame: CGRect = .zero
    private var targetActionsY: CGFloat = 0
    private var targetReactionsY: CGFloat = 0
    private var reactionsAboveBubble = true

    // MARK: - Constants

    private static let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🔥"]
    private static let actionsWidth: CGFloat = 250
    private static let actionsCornerRadius: CGFloat = 14
    private static let actionRowHeight: CGFloat = 44
    private static let gap: CGFloat = 8
    private static let screenPadding: CGFloat = MessageCellHelpers.cellInsets.right
    private static let reactionsBarHeight: CGFloat = 44
    private static let emojiButtonSize: CGFloat = 36
    private static let emojiGridHeight: CGFloat = 300
    private static let emojiGridWidth: CGFloat = 266

    // MARK: - Init

    init(contentNode: ASDisplayNode, sourceFrame: CGRect, actions: [ContextMenuAction]) {
        self.contentNode = contentNode
        self.sourceFrame = sourceFrame
        self.actions = actions
    }

    // MARK: - Presentation

    func show(in sourceWindow: UIWindow) {
        guard let scene = sourceWindow.windowScene else { return }

        let window = OverlayWindow(windowScene: scene)
        window.windowLevel = sourceWindow.windowLevel + 1
        window.frame = sourceWindow.bounds
        window.isHidden = false
        self.overlayWindow = window

        let container = window.rootViewController!.view! // swiftlint:disable:this force_unwrapping
        let bounds = sourceWindow.bounds
        let safeTop = sourceWindow.safeAreaInsets.top + Self.screenPadding
        let maxBottom = bounds.height - sourceWindow.safeAreaInsets.bottom - Self.screenPadding

        // 1. Dimming
        setupDimming(in: container)

        // 2. Reactions bar + Actions (calculate sizes before layout)
        buildReactionsBar(in: container)
        buildActions(in: container)
        buildEmojiGrid(in: container)
        let actionsHeight = actionsContainer.frame.height
        let reactionsH = Self.reactionsBarHeight

        // 3. Calculate layout — reactions above bubble, actions below
        let availableHeight = maxBottom - safeTop
        let maxContentVisible = availableHeight - reactionsH - Self.gap - Self.gap - actionsHeight
        let contentHeight = sourceFrame.height
        let visibleContentHeight = min(contentHeight, maxContentVisible)

        // Try placing reactions above bubble
        var reactionsY = sourceFrame.origin.y - Self.gap - reactionsH
        var bubbleY = sourceFrame.origin.y
        var actionsY = bubbleY + visibleContentHeight + Self.gap
        reactionsAboveBubble = true

        // If reactions don't fit above, place them below actions
        if reactionsY < safeTop {
            reactionsAboveBubble = false
            bubbleY = safeTop
            actionsY = bubbleY + visibleContentHeight + Self.gap
            reactionsY = bubbleY - Self.gap - reactionsH
        }

        if actionsY + actionsHeight > maxBottom {
            let excess = actionsY + actionsHeight - maxBottom
            bubbleY -= excess
            actionsY -= excess
            if reactionsAboveBubble {
                reactionsY = bubbleY - Self.gap - reactionsH
            }
        }

        if bubbleY < safeTop + (reactionsAboveBubble ? reactionsH + Self.gap : 0) {
            bubbleY = safeTop + (reactionsAboveBubble ? reactionsH + Self.gap : 0)
            actionsY = bubbleY + visibleContentHeight + Self.gap
            if reactionsAboveBubble {
                reactionsY = bubbleY - Self.gap - reactionsH
            }
        }

        // If reactions below, place after actions
        if !reactionsAboveBubble {
            reactionsY = safeTop
            bubbleY = reactionsY + reactionsH + Self.gap
            actionsY = bubbleY + visibleContentHeight + Self.gap
        }

        targetContentFrame = CGRect(
            x: sourceFrame.origin.x,
            y: bubbleY,
            width: sourceFrame.width,
            height: visibleContentHeight
        )
        targetActionsY = actionsY
        targetReactionsY = reactionsY

        // 4. Content scroll view
        contentScroll.clipsToBounds = true
        contentScroll.showsVerticalScrollIndicator = false
        contentScroll.isScrollEnabled = contentHeight > maxContentVisible
        contentScroll.bounces = true
        contentScroll.frame = sourceFrame
        contentScroll.contentSize = sourceFrame.size
        container.addSubview(contentScroll)

        hostNode.frame = CGRect(origin: .zero, size: sourceFrame.size)
        contentScroll.addSubview(hostNode.view)
        hostNode.addSubnode(contentNode)
        contentNode.frame = CGRect(origin: .zero, size: sourceFrame.size)

        // 5. Actions & reactions position
        actionsContainer.frame.origin.y = sourceFrame.maxY + Self.gap
        let isRightAligned = sourceFrame.midX > bounds.width / 2
        let actionsX: CGFloat
        if isRightAligned {
            actionsX = sourceFrame.maxX - actionsContainer.frame.width
        } else {
            actionsX = sourceFrame.minX
        }
        actionsContainer.frame.origin.x = min(
            max(Self.screenPadding, actionsX),
            bounds.width - Self.screenPadding - actionsContainer.frame.width
        )

        // Reactions bar X — align with bubble
        let reactionsBarWidth = reactionsBar.frame.width
        let reactionsX: CGFloat
        if isRightAligned {
            reactionsX = sourceFrame.maxX - reactionsBarWidth
        } else {
            reactionsX = sourceFrame.minX
        }
        reactionsBar.frame.origin.x = min(
            max(Self.screenPadding, reactionsX),
            bounds.width - Self.screenPadding - reactionsBarWidth
        )
        reactionsBar.frame.origin.y = sourceFrame.origin.y - Self.gap - reactionsH

        // 6. Initial state
        dimmingView.alpha = 0
        actionsContainer.alpha = 0
        actionsContainer.transform = CGAffineTransform(translationX: 0, y: 8)
        reactionsBar.alpha = 0
        reactionsBar.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        selectionFeedback.prepare()

        // 7. Animate in
        GlassService.shared.captureFor(duration: 0.5)
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.75,
            initialSpringVelocity: 0,
            options: []
        ) {
            self.dimmingView.alpha = 1
            self.contentNode.view.transform = .identity
            self.contentScroll.frame = self.targetContentFrame
            self.actionsContainer.frame.origin.y = self.targetActionsY
            self.actionsContainer.alpha = 1
            self.actionsContainer.transform = .identity
            self.reactionsBar.frame.origin.y = self.targetReactionsY
            self.reactionsBar.alpha = 1
            self.reactionsBar.transform = .identity
        }
    }

    // MARK: - Drag-to-Select

    func trackFinger(at screenPoint: CGPoint) {
        guard !isEmojiGridVisible else { return }
        let row = hitTestRow(at: screenPoint)

        guard row !== highlightedRow else { return }

        highlightedRow?.backgroundColor = .clear
        row?.backgroundColor = .systemGray4
        highlightedRow = row

        if row != nil {
            selectionFeedback.selectionChanged()
            selectionFeedback.prepare()
        }
    }

    func releaseFinger(at screenPoint: CGPoint) {
        guard !isEmojiGridVisible else { return }
        guard let row = highlightedRow else { return }
        row.backgroundColor = .clear
        highlightedRow = nil

        guard let match = actionRows.first(where: { $0.control === row }) else { return }
        dismissMenu { match.action.handler() }
    }

    private func hitTestRow(at screenPoint: CGPoint) -> HighlightControl? {
        let pointInStack = actionsStack.convert(screenPoint, from: nil)
        return actionRows.first { $0.control.frame.contains(pointInStack) }?.control
    }

    // MARK: - Setup

    private func setupDimming(in container: UIView) {
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        dimmingView.frame = container.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(dimmingView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        dimmingView.addGestureRecognizer(tap)
    }

    private func buildReactionsBar(in container: UIView) {
        reactionsBar.backgroundColor = .secondarySystemBackground
        reactionsBar.layer.cornerRadius = Self.reactionsBarHeight / 2
        reactionsBar.layer.shadowColor = UIColor.black.cgColor
        reactionsBar.layer.shadowOpacity = 0.12
        reactionsBar.layer.shadowRadius = 8
        reactionsBar.layer.shadowOffset = CGSize(width: 0, height: 2)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        stack.distribution = .fillEqually

        for emoji in Self.quickEmojis {
            let button = UIButton(type: .system)
            button.setTitle(emoji, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 24)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: Self.emojiButtonSize).isActive = true
            button.heightAnchor.constraint(equalToConstant: Self.emojiButtonSize).isActive = true
            button.addAction(UIAction { [weak self] _ in
                self?.dismissMenu {
                    self?.onReactionSelected?(emoji)
                }
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        // "+" button for full picker
        let addButton = UIButton(type: .system)
        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.tintColor = .secondaryLabel
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(equalToConstant: Self.emojiButtonSize).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: Self.emojiButtonSize).isActive = true
        addButton.addAction(UIAction { [weak self] _ in
            self?.showEmojiGrid()
        }, for: .touchUpInside)
        stack.addArrangedSubview(addButton)

        stack.translatesAutoresizingMaskIntoConstraints = false
        reactionsBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: reactionsBar.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: reactionsBar.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: reactionsBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: reactionsBar.bottomAnchor)
        ])

        let emojiCount = CGFloat(Self.quickEmojis.count + 1)
        let barWidth = emojiCount * Self.emojiButtonSize + CGFloat(Self.quickEmojis.count) * 2 + 12
        reactionsBar.frame = CGRect(x: 0, y: 0, width: barWidth, height: Self.reactionsBarHeight)

        container.addSubview(reactionsBar)
    }

    // MARK: - Emoji Grid (inline expanded picker)

    private func buildEmojiGrid(in container: UIView) {
        emojiGridContainer.backgroundColor = .secondarySystemBackground
        emojiGridContainer.layer.cornerRadius = Self.actionsCornerRadius
        emojiGridContainer.clipsToBounds = true
        emojiGridContainer.alpha = 0
        emojiGridContainer.isHidden = true

        emojiGridNode.onEmojiSelected = { [weak self] emoji in
            self?.dismissMenu {
                self?.onReactionSelected?(emoji)
            }
        }

        emojiGridNode.onSearchActivated = { [weak self] in
            guard let self, let window = self.overlayWindow as? OverlayWindow else { return }
            window.allowKeyStatus = true
            window.makeKey()
        }

        emojiGridContainer.addSubview(emojiGridNode.view)
        emojiGridNode.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emojiGridNode.view.topAnchor.constraint(equalTo: emojiGridContainer.topAnchor),
            emojiGridNode.view.leadingAnchor.constraint(equalTo: emojiGridContainer.leadingAnchor),
            emojiGridNode.view.trailingAnchor.constraint(equalTo: emojiGridContainer.trailingAnchor),
            emojiGridNode.view.bottomAnchor.constraint(equalTo: emojiGridContainer.bottomAnchor)
        ])

        emojiGridContainer.frame = CGRect(x: 0, y: 0, width: Self.emojiGridWidth, height: Self.emojiGridHeight)
        container.addSubview(emojiGridContainer)
    }

    private func showEmojiGrid() {
        guard !isEmojiGridVisible else { return }
        isEmojiGridVisible = true

        // Don't make overlay key — input bar must stay in place.
        // Search field will request key status on demand via onSearchActivated.

        // Position emoji grid where reactionsBar is, but expanded
        let barFrame = reactionsBar.frame
        let gridWidth = Self.emojiGridWidth
        let gridHeight = Self.emojiGridHeight

        // Align emoji grid edge with bubble edge
        let bounds = overlayWindow?.bounds ?? UIScreen.main.bounds
        let isRightAligned = sourceFrame.midX > bounds.width / 2
        var gridX: CGFloat
        if isRightAligned {
            gridX = sourceFrame.maxX - gridWidth
        } else {
            gridX = sourceFrame.minX
        }
        var gridY = barFrame.origin.y

        // Clamp X to screen
        gridX = min(max(Self.screenPadding, gridX), bounds.width - Self.screenPadding - gridWidth)

        // Calculate combined layout: grid + gap + bubble must fit on screen
        let currentBubbleY = contentScroll.frame.origin.y
        let bubbleHeight = contentScroll.frame.height
        let maxBottom = bounds.height - (overlayWindow?.safeAreaInsets.bottom ?? 0) - Self.screenPadding
        let totalNeeded = gridHeight + Self.gap + bubbleHeight
        let bottomOfBubble = gridY + totalNeeded

        // If everything doesn't fit, shift grid up so bubble stays on screen
        if bottomOfBubble > maxBottom {
            gridY = maxBottom - totalNeeded
            // Don't go above safe area
            let safeTop = (overlayWindow?.safeAreaInsets.top ?? 0) + Self.screenPadding
            gridY = max(gridY, safeTop)
        }

        let targetFrame = CGRect(x: gridX, y: gridY, width: gridWidth, height: gridHeight)
        let newBubbleY = targetFrame.maxY + Self.gap

        // Start from reactions bar frame
        emojiGridContainer.frame = barFrame
        emojiGridContainer.isHidden = false
        emojiGridContainer.alpha = 0

        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0,
            options: []
        ) {
            self.reactionsBar.alpha = 0
            self.actionsContainer.alpha = 0
            self.actionsContainer.transform = CGAffineTransform(translationX: 0, y: 8)
            self.emojiGridContainer.frame = targetFrame
            self.emojiGridContainer.alpha = 1

            // Shift bubble below grid
            if newBubbleY != currentBubbleY {
                self.contentScroll.frame.origin.y = newBubbleY
            }
        }
    }

    private func hideEmojiGrid(completion: (() -> Void)? = nil) {
        guard isEmojiGridVisible else {
            completion?()
            return
        }

        // Dismiss keyboard and revoke key status
        emojiGridContainer.endEditing(true)
        (overlayWindow as? OverlayWindow)?.allowKeyStatus = false

        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn) {
            self.emojiGridContainer.alpha = 0
            self.emojiGridContainer.frame = self.reactionsBar.frame
            // Restore bubble to original position
            self.contentScroll.frame.origin.y = self.targetContentFrame.origin.y
        } completion: { _ in
            self.emojiGridContainer.isHidden = true
            self.isEmojiGridVisible = false
            completion?()
        }
    }

    private func buildActions(in container: UIView) {
        actionsContainer.backgroundColor = .secondarySystemBackground
        actionsContainer.layer.cornerRadius = Self.actionsCornerRadius
        actionsContainer.clipsToBounds = true
        actionsContainer.layer.shadowColor = UIColor.black.cgColor
        actionsContainer.layer.shadowOpacity = 0.15
        actionsContainer.layer.shadowRadius = 12
        actionsContainer.layer.shadowOffset = CGSize(width: 0, height: 4)

        actionsStack.axis = .vertical
        actionsStack.alignment = .fill
        actionsStack.distribution = .fill
        actionsContainer.addSubview(actionsStack)

        for (index, action) in actions.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.backgroundColor = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
                actionsStack.addArrangedSubview(separator)
            }
            let row = makeActionRow(action)
            actionsStack.addArrangedSubview(row)
            actionRows.append((control: row, action: action))
        }

        container.addSubview(actionsContainer)

        let fittingHeight = actionsStack.systemLayoutSizeFitting(
            CGSize(width: Self.actionsWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        actionsStack.frame = CGRect(x: 0, y: 0, width: Self.actionsWidth, height: fittingHeight)
        actionsContainer.frame.size = actionsStack.frame.size
    }

    // MARK: - Action Row

    private func makeActionRow(_ action: ContextMenuAction) -> HighlightControl {
        let row = HighlightControl()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: Self.actionRowHeight).isActive = true

        let color: UIColor = action.isDestructive ? .systemRed : .label

        let icon = UIImageView(image: action.image)
        icon.tintColor = color
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let label = UILabel()
        label.text = action.title
        label.font = .systemFont(ofSize: 16)
        label.textColor = color

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        row.addAction(UIAction { [weak self] _ in
            self?.dismissMenu { action.handler() }
        }, for: .touchUpInside)

        return row
    }

    // MARK: - Dismiss

    private func dismissMenu(completion: (() -> Void)? = nil) {
        if isEmojiGridVisible {
            isEmojiGridVisible = false
        }

        GlassService.shared.captureFor(duration: 0.3)
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
            self.dimmingView.alpha = 0
            self.contentScroll.contentOffset = .zero
            self.contentScroll.frame = self.sourceFrame
            self.actionsContainer.alpha = 0
            self.actionsContainer.frame.origin.y = self.sourceFrame.maxY + Self.gap
            self.reactionsBar.alpha = 0
            self.reactionsBar.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            self.emojiGridContainer.alpha = 0
        } completion: { _ in
            self.onDismissComplete?()
            completion?()
            DispatchQueue.main.async {
                self.overlayWindow?.isHidden = true
                self.overlayWindow = nil
            }
        }
    }

    @objc private func backgroundTapped() {
        dismissMenu()
    }
}

// MARK: - Overlay Window (does not steal key status → input bar stays)

private final class OverlayWindow: UIWindow {

    var allowKeyStatus = false

    override var canBecomeKey: Bool { allowKeyStatus }

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        backgroundColor = .clear
        let rootVC = UIViewController()
        rootVC.view.backgroundColor = .clear
        rootViewController = rootVC
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Highlight Control

private final class HighlightControl: UIControl {
    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? .systemGray4 : .clear
        }
    }
}

