//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import UIKit

final class ListContextMenuController {

    var onDismissComplete: (() -> Void)?

    private let contentNode: ASDisplayNode
    private let sourceFrame: CGRect
    private let anchorPoint: CGPoint
    private let actions: [ContextMenuAction]

    private var overlayWindow: ListContextMenuOverlayWindow?
    private let hostNode = ASDisplayNode()
    private let liftContainer = UIView()
    private let dimmingView = UIView()
    private let actionsContainer = UIView()
    private let actionsStack = UIStackView()
    private var actionRows: [(control: ListContextActionControl, action: ContextMenuAction)] = []
    private weak var highlightedRow: ListContextActionControl?
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private var targetSourceFrame: CGRect = .zero
    private var isDismissing = false

    private static let screenPadding: CGFloat = 12
    private static let menuWidth: CGFloat = 260
    private static let actionRowHeight: CGFloat = 46
    private static let cornerRadius: CGFloat = 14
    private static let gap: CGFloat = 8

    init(
        contentNode: ASDisplayNode,
        sourceFrame: CGRect,
        anchorPoint: CGPoint,
        actions: [ContextMenuAction]
    ) {
        self.contentNode = contentNode
        self.sourceFrame = sourceFrame
        self.anchorPoint = anchorPoint
        self.actions = actions
    }

    func show(in sourceWindow: UIWindow) {
        guard !actions.isEmpty,
              let scene = sourceWindow.windowScene else {
            return
        }

        let window = ListContextMenuOverlayWindow(windowScene: scene)
        window.windowLevel = sourceWindow.windowLevel + 1
        window.frame = sourceWindow.bounds
        window.backgroundColor = .clear
        window.rootViewController = UIViewController()
        window.isHidden = false
        overlayWindow = window

        guard let container = window.rootViewController?.view else { return }
        container.backgroundColor = .clear
        setupDimming(in: container)
        setupLiftedContent(in: container)
        setupActions(in: container)
        layout(in: window)
        animateIn()
    }

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
        handleAction(match.action)
    }

    func dismiss(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard !isDismissing else { return }
        isDismissing = true

        let finish = { [weak self] in
            guard let self else { return }
            self.onDismissComplete?()
            completion?()
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil
        }

        guard animated else {
            finish()
            return
        }

        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.curveEaseInOut]
        ) {
            self.dimmingView.alpha = 0
            self.actionsContainer.alpha = 0
            self.actionsContainer.transform = CGAffineTransform(translationX: 0, y: 6)
            self.liftContainer.frame = self.sourceFrame
            self.contentNode.view.transform = .identity
        } completion: { _ in
            finish()
        }
    }

    private func setupDimming(in container: UIView) {
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        dimmingView.alpha = 0
        dimmingView.frame = container.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(dimmingView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        dimmingView.addGestureRecognizer(tap)
    }

    private func setupLiftedContent(in container: UIView) {
        liftContainer.frame = sourceFrame
        liftContainer.backgroundColor = .clear
        container.addSubview(liftContainer)

        hostNode.frame = CGRect(origin: .zero, size: sourceFrame.size)
        liftContainer.addSubview(hostNode.view)
        hostNode.addSubnode(contentNode)
        contentNode.frame = CGRect(origin: .zero, size: sourceFrame.size)
    }

    private func setupActions(in container: UIView) {
        actionsContainer.backgroundColor = .secondarySystemBackground
        actionsContainer.layer.cornerRadius = Self.cornerRadius
        actionsContainer.clipsToBounds = true
        actionsContainer.layer.shadowColor = UIColor.black.cgColor
        actionsContainer.layer.shadowOpacity = 0.14
        actionsContainer.layer.shadowRadius = 12
        actionsContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
        actionsContainer.alpha = 0

        actionsStack.axis = .vertical
        actionsStack.alignment = .fill
        actionsStack.distribution = .fill
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        actionsContainer.addSubview(actionsStack)
        NSLayoutConstraint.activate([
            actionsStack.leadingAnchor.constraint(equalTo: actionsContainer.leadingAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: actionsContainer.trailingAnchor),
            actionsStack.topAnchor.constraint(equalTo: actionsContainer.topAnchor),
            actionsStack.bottomAnchor.constraint(equalTo: actionsContainer.bottomAnchor)
        ])

        for (index, action) in actions.enumerated() {
            if index > 0 {
                actionsStack.addArrangedSubview(makeSeparator())
            }
            let row = makeActionRow(action)
            actionsStack.addArrangedSubview(row)
            actionRows.append((control: row, action: action))
        }

        container.addSubview(actionsContainer)
    }

    private func layout(in window: UIWindow) {
        let bounds = window.bounds
        let safeTop = window.safeAreaInsets.top + Self.screenPadding
        let safeBottom = bounds.height - window.safeAreaInsets.bottom - Self.screenPadding
        let separatorHeight = CGFloat(max(0, actions.count - 1)) / UIScreen.main.scale
        let menuHeight = CGFloat(actions.count) * Self.actionRowHeight + separatorHeight
        let menuWidth = min(Self.menuWidth, bounds.width - Self.screenPadding * 2)

        targetSourceFrame = sourceFrame

        let preferredX = anchorPoint.x - menuWidth / 2
        let menuX = min(
            max(Self.screenPadding, preferredX),
            bounds.width - Self.screenPadding - menuWidth
        )

        let belowY = sourceFrame.maxY + Self.gap
        let aboveY = sourceFrame.minY - Self.gap - menuHeight
        let menuY: CGFloat
        if belowY + menuHeight <= safeBottom {
            menuY = belowY
        } else if aboveY >= safeTop {
            menuY = aboveY
        } else {
            menuY = min(max(safeTop, belowY), safeBottom - menuHeight)
            let overlap = targetSourceFrame.maxY + Self.gap - menuY
            if overlap > 0 {
                targetSourceFrame.origin.y -= overlap
            }
        }

        actionsContainer.frame = CGRect(x: menuX, y: menuY, width: menuWidth, height: menuHeight)
    }

    private func animateIn() {
        actionsContainer.transform = CGAffineTransform(translationX: 0, y: 8)
        selectionFeedback.prepare()

        UIView.animate(
            withDuration: 0.32,
            delay: 0,
            usingSpringWithDamping: 0.82,
            initialSpringVelocity: 0,
            options: []
        ) {
            self.dimmingView.alpha = 1
            self.liftContainer.frame = self.targetSourceFrame
            self.contentNode.view.transform = .identity
            self.actionsContainer.alpha = 1
            self.actionsContainer.transform = .identity
        }
    }

    private func makeActionRow(_ action: ContextMenuAction) -> ListContextActionControl {
        let row = ListContextActionControl()
        row.heightAnchor.constraint(equalToConstant: Self.actionRowHeight).isActive = true
        row.translatesAutoresizingMaskIntoConstraints = false
        row.accessibilityLabel = action.title
        row.accessibilityTraits = .button

        let color: UIColor = action.isDestructive ? .systemRed : .label

        let iconView = UIImageView(image: action.image)
        iconView.tintColor = color
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let label = UILabel()
        label.text = action.title
        label.font = .systemFont(ofSize: 16, weight: .regular)
        label.textColor = color
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail

        let stack = UIStackView(arrangedSubviews: [iconView, label])
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
            self?.handleAction(action)
        }, for: .touchUpInside)

        return row
    }

    private func makeSeparator() -> UIView {
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return separator
    }

    private func hitTestRow(at screenPoint: CGPoint) -> ListContextActionControl? {
        let pointInStack = actionsStack.convert(screenPoint, from: nil)
        return actionRows.first { $0.control.frame.contains(pointInStack) }?.control
    }

    private func handleAction(_ action: ContextMenuAction) {
        switch action.behavior {
        case .dismissBeforeHandling:
            dismiss { action.handler() }
        case .handleInMenu:
            action.handler()
        }
    }

    @objc private func backgroundTapped() {
        dismiss()
    }
}

private final class ListContextActionControl: UIControl {
    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? .systemGray4 : .clear
        }
    }
}

private final class ListContextMenuOverlayWindow: UIWindow {
    override var canBecomeKey: Bool { false }
}
