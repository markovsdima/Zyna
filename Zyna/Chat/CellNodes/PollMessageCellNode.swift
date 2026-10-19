//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class PollMessageCellNode: MessageCellNode {
    enum Action { case vote([String]), edit, end, retry(String), dismissFailure(String) }
    var onPollAction: ((Action) -> Void)?
    var canVote = false
    var canEdit = false
    var canEnd = false

    private let questionNode = ASTextNode()
    private let summaryNode = ASTextNode()
    private let actionNode = ASTextNode()
    private var optionNodes: [PollOptionNode] = []
    private var poll: PollSnapshot
    private var draftSelection: Set<String>?
    private var footerAction: Action?
    private let replyEventId: String?
    private var creationStatus: String?

    override init(message: ChatMessage, isGroupChat: Bool = false) {
        guard case .poll(let poll) = message.content else { preconditionFailure("Expected a poll") }
        self.poll = poll
        self.replyEventId = message.replyInfo?.eventId
        self.creationStatus = message.isSyntheticOutgoingEnvelope ? message.effectiveSendStatus : nil
        super.init(message: message, isGroupChat: isGroupChat)

        questionNode.attributedText = NSAttributedString(string: poll.definition.question,
            attributes: [.font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: bubbleForegroundColor])
        questionNode.maximumNumberOfLines = 0
        questionNode.style.flexShrink = 1
        summaryNode.maximumNumberOfLines = 1
        summaryNode.style.height = ASDimension(unit: .points, value: 18)
        actionNode.maximumNumberOfLines = 1
        actionNode.style.height = ASDimension(unit: .points, value: 32)
        optionNodes = poll.definition.answers.map {
            PollOptionNode(answer: $0, foreground: bubbleForegroundColor, secondary: bubbleTimestampColor)
        }
        bubbleNode.layoutSpecBlock = { [weak self] _, size in
            guard let self else { return ASLayoutSpec() }
            let width = min(360, size.max.width)
            let spacer = ASLayoutSpec()
            spacer.style.flexGrow = 1
            let time = ASStackLayoutSpec(direction: .horizontal, spacing: 4, justifyContent: .end,
                alignItems: .center, children: [spacer, self.timeNode] + (self.statusIconNode.map { [$0] } ?? []))
            var children: [ASLayoutElement] = []
            if let reply = self.replyHeaderNode { children.append(reply) }
            children += [self.questionNode]
            children += self.optionNodes
            children += [self.summaryNode, self.actionNode, time]
            let stack = ASStackLayoutSpec(direction: .vertical, spacing: 10, justifyContent: .start,
                alignItems: .stretch, children: children)
            stack.style.width = ASDimension(unit: .points, value: max(1, width - 28))
            return ASInsetLayoutSpec(insets: UIEdgeInsets(top: 14, left: 14, bottom: 10, right: 14), child: stack)
        }
        // ContextSourceNode owns tap/hold arbitration. Routing quick taps by
        // geometry avoids competing controls cancelling long-press or reply.
        contextSourceNode.onQuickTap = { [weak self] point in self?.handleTap(point) }
        updateResults(animated: false)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let gutter: CGFloat = reservesAvatarGutter ? 40 : 0
        contextSourceNode.style.maxWidth = ASDimension(unit: .points,
            value: min(360, max(180, constrainedSize.max.width * 0.84 - gutter)))
        return super.layoutSpecThatFits(constrainedSize)
    }

    func updatePoll(_ value: PollSnapshot) {
        guard value.definition == poll.definition else { return }
        guard poll != value else { return }
        let hasNewLocalOperation = value.pending != nil && value.pending?.operationID != poll.pending?.operationID
        let draftWasConfirmed = draftSelection != nil && draftSelection == Set(value.selectedAnswerIDs)
            && value.selectedAnswerIDs != poll.selectedAnswerIDs
        if hasNewLocalOperation || draftWasConfirmed || !value.allowsVote {
            draftSelection = nil
        }
        poll = value
        updateResults(animated: isNodeLoaded && interfaceState.contains(.visible))
    }

    func updatePermissions(vote: Bool, edit: Bool, end: Bool) {
        guard canVote != vote || canEdit != edit || canEnd != end else { return }
        canVote = vote
        if !vote { draftSelection = nil }
        canEdit = edit
        canEnd = end
        updateResults(animated: false)
    }

    func updateCreationStatus(for message: ChatMessage) {
        let status = message.isSyntheticOutgoingEnvelope ? message.effectiveSendStatus : nil
        guard creationStatus != status else { return }
        creationStatus = status
        updateResults(animated: false)
    }

    private func updateResults(animated: Bool) {
        let selected = draftSelection ?? Set(poll.displayedSelection)
        for option in optionNodes {
            option.update(count: poll.voteCounts[option.answer.id] ?? 0, total: poll.totalVoters,
                selected: selected.contains(option.answer.id), showsResults: poll.showsResults, animated: animated)
        }
        let summary = poll.showsResults ? String(localized: "\(poll.totalVoters) voters")
            : String(localized: "Results after the poll ends")
        summaryNode.attributedText = NSAttributedString(string: summary,
            attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: bubbleTimestampColor])

        footerAction = nil
        let footer: String
        if let creationStatus {
            switch creationStatus {
            case "failed": footer = String(localized: "Couldn't send poll")
            case "sent": footer = String(localized: "Waiting for sync…")
            default: footer = String(localized: "Sending…")
            }
        } else if let draftSelection, draftSelection != Set(poll.displayedSelection), canVote, poll.allowsVote {
            footer = String(localized: "Vote")
            footerAction = .vote(poll.definition.answers.map(\.id).filter(selected.contains))
        } else if let pending = poll.pending, pending.failed {
            if pending.canRetry {
                footer = String(localized: "Couldn't send · Retry")
                footerAction = .retry(pending.operationID)
            } else {
                footer = String(localized: "Dismiss failed action")
                footerAction = .dismissFailure(pending.operationID)
            }
        } else if let pending = poll.pending {
            if pending.awaitingSync { footer = String(localized: "Waiting for sync…") }
            else {
                switch pending.kind {
                case .response: footer = String(localized: "Sending vote…")
                case .edit: footer = String(localized: "Updating poll…")
                case .end: footer = String(localized: "Ending poll…")
                case .start: footer = String(localized: "Sending…")
                }
            }
        } else if poll.hasEnded {
            footer = String(localized: "Poll ended")
        } else if poll.selectionLimit > 1, canVote {
            footer = String(localized: "Select up to \(poll.selectionLimit) answers")
        } else if canEdit {
            footer = String(localized: "Edit poll")
            footerAction = .edit
        } else if canEnd {
            footer = String(localized: "End poll")
            footerAction = .end
        } else {
            footer = selected.isEmpty ? String(localized: "Choose an answer") : String(localized: "You voted")
        }
        actionNode.attributedText = NSAttributedString(string: footer,
            attributes: [.font: UIFont.systemFont(ofSize: 14, weight: footerAction == nil ? .regular : .semibold),
                         .foregroundColor: footerAction == nil ? bubbleTimestampColor : bubbleForegroundColor])
        if isNodeLoaded { refreshAccessibilityForwarding() }
    }

    private func handleTap(_ point: CGPoint) {
        guard allowsInteractiveActions, isNodeLoaded else { return }
        if let replyHeaderNode, replyHeaderNode.bounds.contains(contextSourceNode.convert(point, to: replyHeaderNode)) {
            if let replyEventId { onReplyHeaderTapped?(replyEventId) }
            return
        }
        if actionNode.bounds.contains(contextSourceNode.convert(point, to: actionNode)), let action = footerAction {
            onPollAction?(action)
            return
        }
        guard let option = optionNodes.first(where: { $0.bounds.contains(contextSourceNode.convert(point, to: $0)) }) else { return }
        select(option.answer.id)
    }

    private func select(_ id: String) {
        guard canVote, allowsInteractiveActions, poll.allowsVote else { return }
        if poll.selectionLimit == 1 {
            guard poll.displayedSelection != [id] else { return }
            onPollAction?(.vote([id]))
        } else {
            var selection = draftSelection ?? Set(poll.displayedSelection)
            if selection.contains(id) { selection.remove(id) }
            else if selection.count < poll.selectionLimit { selection.insert(id) }
            else { return }
            draftSelection = selection == Set(poll.displayedSelection) ? nil : selection
            updateResults(animated: true)
        }
    }

    func pollAccessibilityActions() -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if canVote, poll.allowsVote {
            actions = optionNodes.map { option in
                let selected = (draftSelection ?? Set(poll.displayedSelection)).contains(option.answer.id)
                let title = (selected ? String(localized: "Selected") + ": " : "") + option.answer.text
                return UIAccessibilityCustomAction(name: title) { [weak self] _ in self?.select(option.answer.id); return true }
            }
        }
        if let action = footerAction {
            switch action {
            case .vote, .retry:
                actions.append(UIAccessibilityCustomAction(name: actionNode.attributedText?.string ?? "") { [weak self] _ in
                    self?.onPollAction?(action)
                    return true
                })
            case .edit, .end, .dismissFailure:
                break // Supplied by the chat's shared context actions.
            }
        }
        return actions
    }
}

private final class PollOptionNode: ASDisplayNode {
    let answer: PollDefinition.Answer
    private let textNode = ASTextNode()
    private let selectionNode = ASTextNode()
    private let resultNode = ASTextNode()
    private let progressNode: PollProgressNode
    private let foreground: UIColor

    init(answer: PollDefinition.Answer, foreground: UIColor, secondary: UIColor) {
        self.answer = answer
        self.foreground = foreground
        self.progressNode = PollProgressNode(color: foreground)
        super.init()
        automaticallyManagesSubnodes = true
        textNode.attributedText = NSAttributedString(string: answer.text,
            attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: foreground])
        textNode.maximumNumberOfLines = 0
        textNode.style.flexShrink = 1
        textNode.style.flexGrow = 1
        selectionNode.style.preferredSize = CGSize(width: 24, height: 22)
        resultNode.style.preferredSize = CGSize(width: 44, height: 20)
        resultNode.maximumNumberOfLines = 1
        progressNode.style.height = ASDimension(unit: .points, value: 4)
        style.minHeight = ASDimension(unit: .points, value: 44)
    }

    func update(count: Int, total: Int, selected: Bool, showsResults: Bool, animated: Bool) {
        selectionNode.attributedText = NSAttributedString(string: selected ? "●" : "○",
            attributes: [.font: UIFont.systemFont(ofSize: 21), .foregroundColor: foreground])
        let fraction = total > 0 ? min(1, Double(count) / Double(total)) : 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        resultNode.attributedText = NSAttributedString(string: showsResults ? "\(Int((fraction * 100).rounded()))%" : "",
            attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                         .foregroundColor: foreground, .paragraphStyle: paragraph])
        progressNode.update(progress: showsResults ? fraction : (selected ? 1 : 0), animated: animated)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let row = ASStackLayoutSpec(direction: .horizontal, spacing: 8, justifyContent: .start,
            alignItems: .start, children: [selectionNode, textNode, resultNode])
        let bar = ASInsetLayoutSpec(insets: UIEdgeInsets(top: 0, left: 32, bottom: 4, right: 0), child: progressNode)
        return ASStackLayoutSpec(direction: .vertical, spacing: 6, justifyContent: .start,
            alignItems: .stretch, children: [row, bar])
    }
}

/// The fill animates only its layer transform. Votes never change its layout.
private final class PollProgressNode: ASDisplayNode {
    private let fill = ASDisplayNode()
    private var progress: Double = 0

    init(color: UIColor) {
        super.init()
        isLayerBacked = true
        backgroundColor = color.withAlphaComponent(0.15)
        cornerRadius = 2
        clipsToBounds = true
        fill.isLayerBacked = true
        fill.backgroundColor = color.withAlphaComponent(0.65)
        addSubnode(fill)
    }

    override func didLoad() {
        super.didLoad()
        fill.layer.anchorPoint = CGPoint(x: 0, y: 0.5)
    }

    override func layout() {
        super.layout()
        fill.layer.bounds = CGRect(origin: .zero, size: bounds.size)
        fill.layer.position = CGPoint(x: 0, y: bounds.midY)
        fill.layer.transform = CATransform3DMakeScale(progress, 1, 1)
    }

    func update(progress: Double, animated: Bool) {
        let previous = self.progress
        self.progress = progress
        guard isNodeLoaded else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.layer.transform = CATransform3DMakeScale(progress, 1, 1)
        CATransaction.commit()
        if animated, previous != progress {
            let animation = CABasicAnimation(keyPath: "transform.scale.x")
            animation.fromValue = previous
            animation.toValue = progress
            animation.duration = 0.18
            fill.layer.add(animation, forKey: "pollProgress")
        }
    }
}
