//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class TextMessageCellNode: MessageCellNode {

    var onLinkTapped: ((URL) -> Void)?

    private struct AccessibleLink {
        let url: URL
        let label: String
    }

    // MARK: - Subnodes

    private let flatContentNode: TextBubbleContentNode
    private let replyEventId: String?
    private let accessibleLinks: [AccessibleLink]

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

        let bodyDocument: RichTextDocument
        switch message.content {
        case .text(let body):
            bodyDocument = MatrixRichTextParser.parse(
                body: body,
                metadata: message.textMetadata
            )
        case .notice(let body):
            bodyDocument = MatrixRichTextParser.parse(
                body: body,
                metadata: message.textMetadata
            )
        case .emote(let body):
            bodyDocument = MatrixRichTextParser.parse(
                body: body,
                metadata: message.textMetadata
            ).prepending("* \(message.senderDisplayName ?? "") ")
        case .image:
            bodyDocument = MatrixRichTextParser.parse(body: "📷 Photo", metadata: nil)
        case .video(_, _, _, _, _, let filename, _, _, _, _):
            bodyDocument = MatrixRichTextParser.parse(body: "🎬 \(filename)", metadata: nil)
        case .pendingOutgoingMediaBatch:
            bodyDocument = MatrixRichTextParser.parse(body: "📷 Photo", metadata: nil)
        case .voice:
            bodyDocument = MatrixRichTextParser.parse(
                body: "🎤 \(String(localized: "Voice message"))",
                metadata: nil
            )
        case .file(_, let filename, _, _, _):
            bodyDocument = MatrixRichTextParser.parse(body: "📎 \(filename)", metadata: nil)
        case .callEvent(let type, _, let reason):
            bodyDocument = MatrixRichTextParser.parse(
                body: "📞 \(type.displayText(reason: reason))",
                metadata: nil
            )
        case .matrixRTCCall(let details):
            bodyDocument = MatrixRichTextParser.parse(
                body: "📞 \(details.timelineText(isDirect: !isGroupChat, currentUserId: nil))",
                metadata: nil
            )
        case .systemEvent(let text, _):
            bodyDocument = MatrixRichTextParser.parse(body: text, metadata: nil)
        case .unsupported(let typeName):
            bodyDocument = MatrixRichTextParser.parse(body: "[\(typeName)]", metadata: nil)
        case .redacted:
            bodyDocument = MatrixRichTextParser.parse(body: "Message deleted", metadata: nil)
        }

        let bodyAttributedText = RichTextRenderer.attributedString(
            from: bodyDocument,
            foregroundColor: bubbleForegroundColor,
            linkColor: usesAccentBubbleStyle
                ? bubbleForegroundColor
                : AppColor.accent
        )
        self.accessibleLinks = Self.makeAccessibleLinks(from: bodyDocument)

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
            quoteBarColor: usesAccentBubbleStyle
                ? AppColor.replyBarOutgoing
                : AppColor.replyBarIncoming,
            maxTextWidth: maxContentWidth
        )
        self.replyEventId = message.replyInfo?.eventId

        super.init(message: message, isGroupChat: isGroupChat)

        flatContentNode.style.maxWidth = ASDimension(unit: .points, value: maxContentWidth)

        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return ASInsetLayoutSpec(insets: Self.bubbleInsets, child: self.flatContentNode)
        }

        if replyEventId != nil || bodyDocument.hasLinks {
            contextSourceNode.onQuickTap = { [weak self] point in
                guard let self, self.isNodeLoaded else { return }
                let localPoint = self.contextSourceNode.convert(point, to: self.flatContentNode)
                if let url = self.flatContentNode.linkURL(at: localPoint) {
                    self.onLinkTapped?(url)
                    return
                }
                if let replyFrame = self.flatContentNode.replyHeaderFrame,
                   replyFrame.contains(localPoint),
                   let replyEventId {
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

    func linkAccessibilityActions() -> [UIAccessibilityCustomAction] {
        accessibleLinks.map { link in
            UIAccessibilityCustomAction(
                name: String(localized: "Open link") + ": " + link.label
            ) { [weak self] _ in
                guard let self,
                      self.onLinkTapped != nil else {
                    return false
                }
                self.onLinkTapped?(link.url)
                return true
            }
        }
    }

    private static func makeAccessibleLinks(
        from document: RichTextDocument
    ) -> [AccessibleLink] {
        let text = document.text as NSString
        var destinations = Set<String>()
        return document.links.compactMap { link in
            guard link.range.location >= 0,
                  NSMaxRange(link.range) <= text.length,
                  let url = URL(string: link.destination),
                  destinations.insert(link.destination).inserted else {
                return nil
            }
            let visibleText = text.substring(with: link.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AccessibleLink(
                url: url,
                label: visibleText.isEmpty
                    ? (url.host ?? link.destination)
                    : visibleText
            )
        }
    }
}
