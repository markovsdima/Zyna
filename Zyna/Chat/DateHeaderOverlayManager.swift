//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

private enum DateHeaderOverlay {
    static let topMargin: CGFloat = 8
    static let horizontalMargin: CGFloat = 16
    static let maxWidth: CGFloat = 220
    static let pushSpacing: CGFloat = 4
    static let revealDuration: TimeInterval = 0.16
    static let settleHideDelay: TimeInterval = 0.24
    static let settleHideDuration: TimeInterval = 0.32
    static let preHidePulseLead: TimeInterval = 0.14
    static let backgroundPulseUpDuration: TimeInterval = 0.12
    static let backgroundPulseDownDuration: TimeInterval = 0.28
    static let anchorOverscan: CGFloat = 72

    static let baseBackgroundColor = AppColor.systemEventBackground
    static let highlightedBackgroundColor = UIColor.dynamic(
        light: UIColor(hex: 0xFFFFFF),
        dark: UIColor(hex: 0x242424)
    )
}

private final class DateHeaderOverlayView: UIView {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 10
        static let verticalPadding: CGFloat = 4
    }

    private let label = UILabel()
    private var modelId: String?
    private var backgroundPulseGeneration = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = DateHeaderOverlay.baseBackgroundColor
        layer.cornerRadius = 10
        layer.masksToBounds = true
        alpha = 0

        label.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(model: DateDividerModel) {
        guard model.id != modelId else { return }
        modelId = model.id
        label.text = model.title
    }

    func pulseBackground() {
        backgroundPulseGeneration += 1
        let generation = backgroundPulseGeneration
        layer.removeAnimation(forKey: "backgroundColor")

        UIView.animate(
            withDuration: DateHeaderOverlay.backgroundPulseUpDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            self.backgroundColor = DateHeaderOverlay.highlightedBackgroundColor
        } completion: { [weak self] _ in
            guard let self,
                  self.backgroundPulseGeneration == generation
            else { return }

            UIView.animate(
                withDuration: DateHeaderOverlay.backgroundPulseDownDuration,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
            ) {
                self.backgroundColor = DateHeaderOverlay.baseBackgroundColor
            }
        }
    }

    func prepareHighlightedBackground() {
        backgroundPulseGeneration += 1
        layer.removeAnimation(forKey: "backgroundColor")
        backgroundColor = DateHeaderOverlay.highlightedBackgroundColor
    }

    func settleBackground() {
        backgroundPulseGeneration += 1
        let generation = backgroundPulseGeneration
        layer.removeAnimation(forKey: "backgroundColor")

        UIView.animate(
            withDuration: DateHeaderOverlay.backgroundPulseDownDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            self.backgroundColor = DateHeaderOverlay.baseBackgroundColor
        } completion: { [weak self] _ in
            guard let self,
                  self.backgroundPulseGeneration == generation
            else { return }
            self.backgroundColor = DateHeaderOverlay.baseBackgroundColor
        }
    }

    func resetBackground() {
        backgroundPulseGeneration += 1
        layer.removeAnimation(forKey: "backgroundColor")
        backgroundColor = DateHeaderOverlay.baseBackgroundColor
    }

    func fittingSize(maxWidth: CGFloat) -> CGSize {
        let labelMaxWidth = max(0, maxWidth - Metrics.horizontalPadding * 2)
        let labelSize = label.sizeThatFits(
            CGSize(width: labelMaxWidth, height: .greatestFiniteMagnitude)
        )
        return CGSize(
            width: min(maxWidth, ceil(labelSize.width) + Metrics.horizontalPadding * 2),
            height: ceil(labelSize.height) + Metrics.verticalPadding * 2
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(
            dx: Metrics.horizontalPadding,
            dy: Metrics.verticalPadding
        )
    }
}

final class DateHeaderOverlayManager {
    private struct Anchor {
        let model: DateDividerModel
        let rect: CGRect
    }

    private enum HeaderRole {
        case sticky
        case inline
    }

    private struct DesiredHeader {
        let model: DateDividerModel
        let frame: CGRect
        let alpha: CGFloat
        let role: HeaderRole
    }

    let containerView = UIView()
    private var visibleViews: [String: DateHeaderOverlayView] = [:]
    private var reusableViews: [DateHeaderOverlayView] = []
    private var targetAlphaById: [String: CGFloat] = [:]
    private var roleById: [String: HeaderRole] = [:]
    private var delayedFadeOutById: [String: DispatchWorkItem] = [:]

    init() {
        containerView.clipsToBounds = true
        containerView.backgroundColor = .clear
        containerView.isUserInteractionEnabled = false
        containerView.alpha = 0
    }

    func hide(animated: Bool = false) {
        cancelDelayedFadeOuts()
        for id in visibleViews.keys {
            targetAlphaById[id] = 0
        }

        guard containerView.alpha > 0 || visibleViews.values.contains(where: { $0.alpha > 0 }) else {
            return
        }
        let updates = {
            self.containerView.alpha = 0
            for view in self.visibleViews.values {
                view.alpha = 0
                view.resetBackground()
            }
        }
        if animated {
            UIView.animate(
                withDuration: DateHeaderOverlay.settleHideDuration,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                animations: updates
            )
        } else {
            containerView.layer.removeAnimation(forKey: "opacity")
            for view in visibleViews.values {
                view.layer.removeAnimation(forKey: "opacity")
            }
            updates()
        }
    }

    func update(
        viewport: CGRect,
        rows: [ChatTimelineRow],
        visibleIndexPaths: [IndexPath],
        tableView: UITableView,
        hostView: UIView,
        isScrolling: Bool,
        animated: Bool
    ) {
        var anchors: [Anchor] = []
        var activeTimestamp: Date?
        var activeMinY = CGFloat.greatestFiniteMagnitude

        for indexPath in visibleIndexPaths {
            guard rows.indices.contains(indexPath.row) else { continue }

            let rowRect = tableView.convert(tableView.rectForRow(at: indexPath), to: hostView)
            switch rows[indexPath.row] {
            case .message(let message):
                let visibleRect = rowRect.intersection(viewport)
                guard !visibleRect.isNull, visibleRect.height > 0 else { continue }
                if visibleRect.minY < activeMinY {
                    activeMinY = visibleRect.minY
                    activeTimestamp = message.timestamp
                }
            case .dateDivider(let model):
                if rowRect.maxY > viewport.minY - DateHeaderOverlay.anchorOverscan
                    && rowRect.minY < viewport.maxY {
                    anchors.append(Anchor(
                        model: model,
                        rect: rowRect.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
                    ))
                }
            }
        }

        guard activeTimestamp != nil || !anchors.isEmpty else {
            hide(animated: animated)
            return
        }

        containerView.layer.removeAnimation(forKey: "opacity")
        containerView.frame = viewport
        containerView.alpha = 1

        let maxWidth = min(
            DateHeaderOverlay.maxWidth,
            max(0, viewport.width - DateHeaderOverlay.horizontalMargin * 2)
        )

        var desired: [String: DesiredHeader] = [:]
        var desiredOrder: [String] = []

        func headerSize(for model: DateDividerModel) -> CGSize {
            let view = viewForHeader(id: model.id)
            view.update(model: model)
            return view.fittingSize(maxWidth: maxWidth)
        }

        func naturalFrame(for model: DateDividerModel, anchorRect: CGRect) -> CGRect {
            let size = headerSize(for: model)
            return CGRect(
                x: (viewport.width - size.width) / 2,
                y: anchorRect.minY + (anchorRect.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }

        var anchorFramesById: [String: CGRect] = [:]
        for anchor in anchors {
            let frame = naturalFrame(for: anchor.model, anchorRect: anchor.rect)
            anchorFramesById[anchor.model.id] = frame
        }

        let activeModel = activeTimestamp.map { DateDividerModel.make(for: $0) }
        func handoffFrame(for id: String, frame: CGRect) -> CGRect {
            guard id != activeModel?.id,
                  frame.maxY > 0,
                  frame.minY < DateHeaderOverlay.topMargin
            else {
                return frame
            }

            var adjusted = frame
            adjusted.origin.y = DateHeaderOverlay.topMargin
            return adjusted
        }

        if let activeModel {
            let size = headerSize(for: activeModel)
            let naturalY = anchorFramesById[activeModel.id]?.minY
            let stickyY = DateHeaderOverlay.topMargin
            var y = max(naturalY ?? (-size.height - DateHeaderOverlay.pushSpacing), stickyY)
            let unclampedY = y

            for (id, frame) in anchorFramesById where id != activeModel.id {
                let collisionFrame = handoffFrame(for: id, frame: frame)
                guard collisionFrame.maxY > 0,
                      collisionFrame.minY <= y + size.height + DateHeaderOverlay.pushSpacing
                else { continue }
                y = min(y, collisionFrame.minY - size.height - DateHeaderOverlay.pushSpacing)
            }

            y = max(-size.height - DateHeaderOverlay.pushSpacing, y)
            let isNatural = naturalY.map { abs(unclampedY - $0) < 0.5 && abs(y - $0) < 0.5 } ?? false
            desired[activeModel.id] = DesiredHeader(
                model: activeModel,
                frame: CGRect(
                    x: (viewport.width - size.width) / 2,
                    y: y,
                    width: size.width,
                    height: size.height
                ),
                alpha: isNatural || isScrolling ? 1 : 0,
                role: isNatural ? .inline : .sticky
            )
            desiredOrder.append(activeModel.id)
        }

        for anchor in anchors {
            if anchor.model.id == activeModel?.id {
                continue
            }
            let frame = handoffFrame(
                for: anchor.model.id,
                frame: anchorFramesById[anchor.model.id] ?? naturalFrame(for: anchor.model, anchorRect: anchor.rect)
            )
            guard frame.maxY > 0, frame.minY < viewport.height else { continue }
            desired[anchor.model.id] = DesiredHeader(
                model: anchor.model,
                frame: frame,
                alpha: 1,
                role: frame.minY <= DateHeaderOverlay.topMargin + 0.5 ? .sticky : .inline
            )
            desiredOrder.append(anchor.model.id)
        }

        apply(desired: desired, order: desiredOrder, animated: animated)
    }

    private func viewForHeader(id: String) -> DateHeaderOverlayView {
        if let view = visibleViews[id] {
            return view
        }
        let view = reusableViews.popLast() ?? DateHeaderOverlayView()
        visibleViews[id] = view
        containerView.addSubview(view)
        return view
    }

    private func apply(
        desired: [String: DesiredHeader],
        order: [String],
        animated: Bool
    ) {
        let desiredIds = Set(desired.keys)
        for id in Array(visibleViews.keys) where !desiredIds.contains(id) {
            guard let view = visibleViews.removeValue(forKey: id) else { continue }
            cancelDelayedFadeOut(id: id)
            targetAlphaById.removeValue(forKey: id)
            roleById.removeValue(forKey: id)
            view.layer.removeAllAnimations()
            view.alpha = 0
            view.resetBackground()
            view.removeFromSuperview()
            reusableViews.append(view)
        }

        guard !desired.isEmpty else {
            hide(animated: animated)
            return
        }

        for (id, header) in desired {
            let view = viewForHeader(id: id)
            view.update(model: header.model)
            view.frame = header.frame
            applyAlpha(
                header.alpha,
                to: view,
                id: id,
                role: header.role,
                animated: animated
            )
        }

        for id in order {
            if let view = visibleViews[id] {
                containerView.bringSubviewToFront(view)
            }
        }
    }

    private func applyAlpha(
        _ alpha: CGFloat,
        to view: DateHeaderOverlayView,
        id: String,
        role: HeaderRole,
        animated: Bool
    ) {
        let targetAlpha: CGFloat = alpha > 0.01 ? 1 : 0
        let previousTargetAlpha = targetAlphaById[id] ?? view.alpha
        let previousRole = roleById[id]
        roleById[id] = role

        guard abs(previousTargetAlpha - targetAlpha) > 0.01 else {
            if role == .inline, previousRole != .inline {
                view.resetBackground()
            }
            return
        }

        targetAlphaById[id] = targetAlpha

        if targetAlpha > 0 {
            cancelDelayedFadeOut(id: id)
            guard role == .sticky else {
                view.layer.removeAnimation(forKey: "opacity")
                view.alpha = 1
                view.resetBackground()
                return
            }

            view.prepareHighlightedBackground()
            UIView.animate(
                withDuration: DateHeaderOverlay.revealDuration,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
            ) {
                view.alpha = targetAlpha
            } completion: { [weak self, weak view] _ in
                guard let self,
                      let view,
                      self.targetAlphaById[id] == 1,
                      self.visibleViews[id] === view
                else { return }
                view.settleBackground()
            }
        } else if animated && role == .sticky {
            scheduleDelayedFadeOut(for: view, id: id)
        } else {
            cancelDelayedFadeOut(id: id)
            view.layer.removeAnimation(forKey: "opacity")
            view.alpha = 0
            view.resetBackground()
        }
    }

    private func scheduleDelayedFadeOut(for view: DateHeaderOverlayView, id: String) {
        cancelDelayedFadeOut(id: id)

        let workItem = DispatchWorkItem { [weak self, weak view] in
            guard let self,
                  let view,
                  self.targetAlphaById[id] == 0,
                  self.visibleViews[id] === view
            else { return }

            view.pulseBackground()
            let fadeWorkItem = DispatchWorkItem { [weak self, weak view] in
                guard let self,
                      let view,
                      self.targetAlphaById[id] == 0,
                      self.visibleViews[id] === view
                else { return }

                UIView.animate(
                    withDuration: DateHeaderOverlay.settleHideDuration,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
                ) {
                    view.alpha = 0
                } completion: { [weak self, weak view] _ in
                    guard let self,
                          let view,
                          self.targetAlphaById[id] == 0,
                          self.visibleViews[id] === view
                    else { return }
                    view.resetBackground()
                }

                self.delayedFadeOutById[id] = nil
            }

            self.delayedFadeOutById[id] = fadeWorkItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + DateHeaderOverlay.preHidePulseLead,
                execute: fadeWorkItem
            )
        }

        delayedFadeOutById[id] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DateHeaderOverlay.settleHideDelay,
            execute: workItem
        )
    }

    private func cancelDelayedFadeOut(id: String) {
        delayedFadeOutById.removeValue(forKey: id)?.cancel()
    }

    private func cancelDelayedFadeOuts() {
        for workItem in delayedFadeOutById.values {
            workItem.cancel()
        }
        delayedFadeOutById.removeAll()
    }
}
