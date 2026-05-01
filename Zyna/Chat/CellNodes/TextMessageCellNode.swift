//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class TextMessageCellNode: MessageCellNode {

    // MARK: - Subnodes

    private let flatContentNode: TextBubbleContentNode
    private let replyEventId: String?

    // MARK: - Constants

    private static let bubbleInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

    // MARK: - Init

    override init(message: ChatMessage, isGroupChat: Bool = false) {
        let usesAccentBubbleStyle = message.isOutgoing || message.zynaAttributes.color != nil
        let bubbleForegroundColor = usesAccentBubbleStyle
            ? AppColor.bubbleForegroundOutgoing
            : AppColor.bubbleForegroundIncoming
        let bubbleTimestampColor = usesAccentBubbleStyle
            ? AppColor.bubbleTimestampOutgoing
            : AppColor.bubbleTimestampIncoming

        let bodyText: String
        switch message.content {
        case .text(let body):
            bodyText = body
        case .notice(let body):
            bodyText = body
        case .emote(let body):
            bodyText = "* \(message.senderDisplayName ?? "") \(body)"
        case .image:
            bodyText = "📷 Photo"
        case .pendingOutgoingMediaBatch:
            bodyText = "📷 Photo"
        case .voice:
            bodyText = "🎤 Voice message"
        case .file(_, let filename, _, _, _):
            bodyText = "📎 \(filename)"
        case .callEvent(let type, _, let reason):
            bodyText = "📞 \(type.displayText(reason: reason))"
        case .systemEvent(let text, _):
            bodyText = text
        case .unsupported(let typeName):
            bodyText = "[\(typeName)]"
        case .redacted:
            bodyText = "Message deleted"
        }

        let bodyAttributedText = NSAttributedString(
            string: bodyText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: bubbleForegroundColor
            ]
        )

        let forwardedHeaderText: NSAttributedString?
        if let forwarderName = message.zynaAttributes.forwardedFrom {
            forwardedHeaderText = NSAttributedString(
                string: "↗ " + String(localized: "Forwarded from \(forwarderName)"),
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: bubbleTimestampColor
                ]
            )
        } else {
            forwardedHeaderText = nil
        }

        let replyHeaderData: TextBubbleContentNode.ReplyHeaderData?
        if let replyInfo = message.replyInfo {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            replyHeaderData = TextBubbleContentNode.ReplyHeaderData(
                senderText: NSAttributedString(
                    string: (replyInfo.senderDisplayName ?? replyInfo.senderId).isEmpty
                        ? "Unknown"
                        : (replyInfo.senderDisplayName ?? replyInfo.senderId),
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: usesAccentBubbleStyle
                            ? AppColor.replySenderOutgoing
                            : AppColor.replySenderIncoming,
                        .paragraphStyle: paragraph
                    ]
                ),
                bodyText: NSAttributedString(
                    string: replyInfo.body.isEmpty ? "Message" : replyInfo.body,
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 12),
                        .foregroundColor: usesAccentBubbleStyle
                            ? AppColor.replyBodyOutgoing
                            : AppColor.replyBodyIncoming,
                        .paragraphStyle: paragraph
                    ]
                ),
                barColor: usesAccentBubbleStyle ? AppColor.replyBarOutgoing : AppColor.replyBarIncoming
            )
        } else {
            replyHeaderData = nil
        }

        let timeAttributedText = NSAttributedString(
            string: MessageCellHelpers.timelineTimestampText(for: message),
            attributes: [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: bubbleTimestampColor
            ]
        )

        let statusIcon = message.isOutgoing
            ? MessageStatusIcon.from(sendStatus: message.effectiveSendStatus)
            : nil

        let maxContentWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
            - Self.bubbleInsets.left - Self.bubbleInsets.right

        self.flatContentNode = TextBubbleContentNode(
            bodyText: bodyAttributedText,
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeaderData,
            timeText: timeAttributedText,
            statusIcon: statusIcon,
            statusTintColor: bubbleTimestampColor,
            maxTextWidth: maxContentWidth
        )
        self.replyEventId = message.replyInfo?.eventId

        super.init(message: message, isGroupChat: isGroupChat)

        flatContentNode.style.maxWidth = ASDimension(unit: .points, value: maxContentWidth)

        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return ASInsetLayoutSpec(insets: Self.bubbleInsets, child: self.flatContentNode)
        }

        if let replyEventId {
            contextSourceNode.onQuickTap = { [weak self] point in
                guard let self, self.isNodeLoaded else { return }
                let localPoint = self.contextSourceNode.view.convert(point, to: self.flatContentNode.view)
                if let replyFrame = self.flatContentNode.replyHeaderFrame,
                   replyFrame.contains(localPoint) {
                    self.onReplyHeaderTapped?(replyEventId)
                }
            }
        }
    }

    override func didLoad() {
        super.didLoad()
        assignProbeName("textMessage.flatContent", to: flatContentNode)
    }

    override func updateSendStatus(_ status: String) {
        super.updateSendStatus(status)
        flatContentNode.statusIcon = statusIcon(forSendStatus: status)
    }
}
