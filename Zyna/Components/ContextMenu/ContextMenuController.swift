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

    // MARK: - Views

    private var overlayWindow: OverlayWindow?
    private let hostNode = ASDisplayNode()
    private let contentScroll = UIScrollView()
    private let dimmingView = UIView()
    private let actionsContainer = UIView()
    private let actionsStack = UIStackView()

    // MARK: - Drag-to-Select

    private var actionRows: [(control: HighlightControl, action: ContextMenuAction)] = []
    private weak var highlightedRow: HighlightControl?
    private let selectionFeedback = UISelectionFeedbackGenerator()

    // MARK: - Layout State

    private var targetContentFrame: CGRect = .zero
    private var targetActionsY: CGFloat = 0

    // MARK: - Constants

    private static let actionsWidth: CGFloat = 250
    private static let actionsCornerRadius: CGFloat = 14
    private static let actionRowHeight: CGFloat = 44
    private static let gap: CGFloat = 8
    private static let screenPadding: CGFloat = 16

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

        let container = window.rootViewController!.view!
        let bounds = sourceWindow.bounds
        let safeTop = sourceWindow.safeAreaInsets.top + Self.screenPadding
        let maxBottom = bounds.height - sourceWindow.safeAreaInsets.bottom - Self.screenPadding

        // 1. Dimming
        setupDimming(in: container)

        // 2. Actions (calculate size before layout)
        buildActions(in: container)
        let actionsHeight = actionsContainer.frame.height

        // 3. Calculate layout
        let availableHeight = maxBottom - safeTop
        let maxContentVisible = availableHeight - Self.gap - actionsHeight
        let contentHeight = sourceFrame.height
        let visibleContentHeight = min(contentHeight, maxContentVisible)

        var bubbleY = sourceFrame.origin.y
        var actionsY = bubbleY + visibleContentHeight + Self.gap

        if actionsY + actionsHeight > maxBottom {
            let excess = actionsY + actionsHeight - maxBottom
            bubbleY -= excess
            actionsY -= excess
        }

        if bubbleY < safeTop {
            bubbleY = safeTop
            actionsY = bubbleY + visibleContentHeight + Self.gap
        }

        targetContentFrame = CGRect(
            x: sourceFrame.origin.x,
            y: bubbleY,
            width: sourceFrame.width,
            height: visibleContentHeight
        )
        targetActionsY = actionsY

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

        // 5. Actions position
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

        // 6. Initial state
        dimmingView.alpha = 0
        actionsContainer.alpha = 0
        actionsContainer.transform = CGAffineTransform(translationX: 0, y: 8)
        selectionFeedback.prepare()

        // 7. Animate in
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
        }
    }

    // MARK: - Drag-to-Select

    func trackFinger(at screenPoint: CGPoint) {
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
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
            self.dimmingView.alpha = 0
            self.contentScroll.contentOffset = .zero
            self.contentScroll.frame = self.sourceFrame
            self.actionsContainer.alpha = 0
            self.actionsContainer.frame.origin.y = self.sourceFrame.maxY + Self.gap
        } completion: { _ in
            self.onDismissComplete?()
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil
            completion?()
        }
    }

    @objc private func backgroundTapped() {
        dismissMenu()
    }
}

// MARK: - Overlay Window (does not steal key status → input bar stays)

private final class OverlayWindow: UIWindow {

    override var canBecomeKey: Bool { false }

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
