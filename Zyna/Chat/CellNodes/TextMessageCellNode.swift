//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import CoreText

final class TextMessageCellNode: MessageCellNode {

    // MARK: - Subnodes

    private let textNode = ASTextNode()

    // MARK: - Constants

    private static let bubbleInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
    private static let timeSpacing: CGFloat = 6

    // MARK: - Init

    override init(message: ChatMessage, isGroupChat: Bool = false) {
        super.init(message: message, isGroupChat: isGroupChat)

        // Message text
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
        case .voice:
            bodyText = "🎤 Voice message"
        case .file(_, let filename, _, _):
            bodyText = "📎 \(filename)"
        case .unsupported(let typeName):
            bodyText = "[\(typeName)]"
        case .redacted:
            bodyText = "Message deleted"
        }

        textNode.attributedText = NSAttributedString(
            string: bodyText,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: isOutgoing ? UIColor.white : UIColor.label
            ]
        )

        let maxContentWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
            - Self.bubbleInsets.left - Self.bubbleInsets.right
        textNode.style.maxWidth = ASDimension(unit: .points, value: maxContentWidth)

        // Bubble layout
        bubbleNode.layoutSpecBlock = { [weak self] _, _ in
            guard let self,
                  let attributedText = self.textNode.attributedText,
                  let timeText = self.timeNode.attributedText
            else { return ASLayoutSpec() }

            let metrics = Self.textMetrics(for: attributedText, maxWidth: maxContentWidth)
            let timeTextSize = Self.singleLineSize(for: timeText)
            let statusIconWidth: CGFloat = self.statusIconNode.map {
                $0.iconSize + 4  // 4pt gap between time and icon
            } ?? 0
            let timeSize = CGSize(
                width: timeTextSize.width + statusIconWidth,
                height: timeTextSize.height
            )

            let fitsInline = metrics.trailingLineWidth + Self.timeSpacing + timeSize.width
                <= maxContentWidth

            // Build text element — add height placeholder when time goes below
            let textElement: ASLayoutElement
            if fitsInline {
                textElement = self.textNode
            } else {
                let timePlaceholder = ASLayoutSpec()
                timePlaceholder.style.preferredSize = CGSize(
                    width: timeSize.width, height: timeSize.height + 2
                )
                let placeholderRow = ASStackLayoutSpec.horizontal()
                placeholderRow.justifyContent = .end
                placeholderRow.children = [timePlaceholder]

                textElement = ASStackLayoutSpec(
                    direction: .vertical,
                    spacing: 0,
                    justifyContent: .start,
                    alignItems: .stretch,
                    children: [self.textNode, placeholderRow]
                )
            }

            // Add reply header if present
            let mainContent: ASLayoutElement
            if let replyHeader = self.replyHeaderNode {
                mainContent = ASStackLayoutSpec(
                    direction: .vertical,
                    spacing: 0,
                    justifyContent: .start,
                    alignItems: .stretch,
                    children: [replyHeader, textElement]
                )
            } else {
                mainContent = textElement
            }

            // Ensure minimum width so time doesn't overflow
            let minWidth = fitsInline
                ? metrics.trailingLineWidth + Self.timeSpacing + timeSize.width
                : timeSize.width
            mainContent.style.minWidth = ASDimension(unit: .points, value: minWidth)

            // Time + optional status icon glued together as a row.
            let timeGroup: ASLayoutElement
            if let iconNode = self.statusIconNode {
                timeGroup = ASStackLayoutSpec(
                    direction: .horizontal,
                    spacing: 4,
                    justifyContent: .end,
                    alignItems: .center,
                    children: [self.timeNode, iconNode]
                )
            } else {
                timeGroup = self.timeNode
            }

            // Overlay time at bottom-right of entire content
            let timeCorner = ASRelativeLayoutSpec(
                horizontalPosition: .end,
                verticalPosition: .end,
                sizingOption: [],
                child: timeGroup
            )
            let result = ASOverlayLayoutSpec(child: mainContent, overlay: timeCorner)

            return ASInsetLayoutSpec(insets: Self.bubbleInsets, child: result)
        }
    }

    // MARK: - CoreText Measurement

    private struct TextMetrics {
        let size: CGSize
        let trailingLineWidth: CGFloat
    }

    private static func textMetrics(
        for attributedText: NSAttributedString,
        maxWidth: CGFloat
    ) -> TextMetrics {
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)

        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            nil
        )

        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: maxWidth, height: 100_000))
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: attributedText.length), path, nil
        )

        var trailingWidth: CGFloat = 0
        if let lines = CTFrameGetLines(frame) as? [CTLine], let lastLine = lines.last {
            trailingWidth = CGFloat(CTLineGetTypographicBounds(lastLine, nil, nil, nil))
        }

        return TextMetrics(
            size: CGSize(width: ceil(suggestedSize.width), height: ceil(suggestedSize.height)),
            trailingLineWidth: ceil(trailingWidth)
        )
    }

    private static func singleLineSize(for attributedText: NSAttributedString) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            nil
        )
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}
