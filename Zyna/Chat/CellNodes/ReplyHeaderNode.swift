//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Compact reply header shown inside a message bubble.
/// Rendered as a single async-drawn node to keep the bubble subtree
/// shallow in the hot chat glass capture path.
final class ReplyHeaderNode: ASDisplayNode {

    // MARK: - Constants

    private static let barWidth: CGFloat = 2
    private static let horizontalSpacing: CGFloat = 6
    private static let lineSpacing: CGFloat = 1
    private static let bottomInset: CGFloat = 4
    private static let senderFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
    private static let bodyFont = UIFont.systemFont(ofSize: 12)

    // MARK: - Draw Parameters

    final class DrawParams: NSObject {
        let senderText: NSAttributedString
        let bodyText: NSAttributedString
        let barColor: UIColor

        init(senderText: NSAttributedString, bodyText: NSAttributedString, barColor: UIColor) {
            self.senderText = senderText
            self.bodyText = bodyText
            self.barColor = barColor
        }
    }

    // MARK: - State

    private let senderText: NSAttributedString
    private let bodyText: NSAttributedString
    private let barColor: UIColor
    private let maxTextWidth: CGFloat

    // MARK: - Init

    init(replyInfo: ReplyInfo, usesAccentStyle: Bool) {
        self.barColor = usesAccentStyle ? AppColor.replyBarOutgoing : AppColor.replyBarIncoming
        self.maxTextWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
            - Self.barWidth - Self.horizontalSpacing

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let senderString = replyInfo.senderDisplayName ?? replyInfo.senderId
        self.senderText = NSAttributedString(
            string: senderString.isEmpty ? "Unknown" : senderString,
            attributes: [
                .font: Self.senderFont,
                .foregroundColor: usesAccentStyle ? AppColor.replySenderOutgoing : AppColor.replySenderIncoming,
                .paragraphStyle: paragraph
            ]
        )

        let bodyString = replyInfo.body
        self.bodyText = NSAttributedString(
            string: bodyString.isEmpty ? "Message" : bodyString,
            attributes: [
                .font: Self.bodyFont,
                .foregroundColor: usesAccentStyle ? AppColor.replyBodyOutgoing : AppColor.replyBodyIncoming,
                .paragraphStyle: paragraph
            ]
        )

        super.init()
        isOpaque = false
        style.flexShrink = 1
        style.flexGrow = 1
    }

    // MARK: - Layout

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        let availableWidth: CGFloat
        if constrainedSize.width.isFinite, constrainedSize.width > 0 {
            availableWidth = min(constrainedSize.width, ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio)
        } else {
            availableWidth = ScreenConstants.width * MessageCellHelpers.maxBubbleWidthRatio
        }

        let textWidth = max(
            0,
            min(maxTextWidth, availableWidth - Self.barWidth - Self.horizontalSpacing)
        )

        let senderWidth = measuredSingleLineWidth(for: senderText, maxWidth: textWidth)
        let bodyWidth = measuredSingleLineWidth(for: bodyText, maxWidth: textWidth)
        let width = Self.barWidth + Self.horizontalSpacing + max(senderWidth, bodyWidth)
        let height = ceil(Self.senderFont.lineHeight)
            + Self.lineSpacing
            + ceil(Self.bodyFont.lineHeight)
            + Self.bottomInset

        return CGSize(width: ceil(width), height: height)
    }

    // MARK: - Drawing

    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        DrawParams(senderText: senderText, bodyText: bodyText, barColor: barColor)
    }

    override class func draw(_ bounds: CGRect, withParameters parameters: Any?,
                              isCancelled isCancelledBlock: () -> Bool, isRasterizing: Bool) {
        guard let params = parameters as? DrawParams,
              let ctx = UIGraphicsGetCurrentContext()
        else { return }

        if isCancelledBlock() { return }

        let contentHeight = max(0, bounds.height - Self.bottomInset)
        let textOriginX = Self.barWidth + Self.horizontalSpacing
        let textWidth = max(0, bounds.width - textOriginX)
        guard textWidth > 0 else { return }

        let barHeight = max(16, contentHeight)
        let barRect = CGRect(
            x: 0,
            y: floor((contentHeight - barHeight) / 2),
            width: Self.barWidth,
            height: barHeight
        )
        params.barColor.setFill()
        UIBezierPath(
            roundedRect: barRect,
            cornerRadius: Self.barWidth / 2
        ).fill()

        let senderHeight = ceil(Self.senderFont.lineHeight)
        let bodyHeight = ceil(Self.bodyFont.lineHeight)
        let senderRect = CGRect(x: textOriginX, y: 0, width: textWidth, height: senderHeight)
        let bodyRect = CGRect(
            x: textOriginX,
            y: senderHeight + Self.lineSpacing,
            width: textWidth,
            height: bodyHeight
        )

        if isCancelledBlock() { return }

        params.senderText.draw(
            with: senderRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )

        if isCancelledBlock() { return }

        params.bodyText.draw(
            with: bodyRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )

        _ = ctx
    }

    // MARK: - Helpers

    private func measuredSingleLineWidth(for text: NSAttributedString, maxWidth: CGFloat) -> CGFloat {
        let measured = text.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(min(maxWidth, measured.width))
    }
}
