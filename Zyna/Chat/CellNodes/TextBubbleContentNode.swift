//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import CoreText

/// Flattens the inner content of a text bubble into a single
/// async-drawn node. This keeps the common chat path shallow for
/// glass capture while preserving the existing text/reply/forward/time
/// layout semantics.
final class TextBubbleContentNode: ASDisplayNode {

    struct ReplyHeaderData {
        let senderText: NSAttributedString
        let bodyText: NSAttributedString
        let barColor: UIColor
    }

    fileprivate struct TextMetrics {
        let size: CGSize
        let trailingLineWidth: CGFloat
        let lineCount: Int
    }

    fileprivate struct LayoutMetrics {
        let size: CGSize
        let forwardedRect: CGRect?
        let replyRect: CGRect?
        let replyBarRect: CGRect?
        let replySenderRect: CGRect?
        let replyBodyRect: CGRect?
        let bodyRect: CGRect
        let timeRect: CGRect
        let statusRect: CGRect?
    }

    final class DrawParams: NSObject {
        let bodyText: NSAttributedString
        let forwardedHeaderText: NSAttributedString?
        let replyHeader: ReplyHeaderData?
        let timeText: NSAttributedString
        let statusIcon: MessageStatusIcon?
        let statusTintColor: UIColor
        let maxTextWidth: CGFloat

        init(
            bodyText: NSAttributedString,
            forwardedHeaderText: NSAttributedString?,
            replyHeader: ReplyHeaderData?,
            timeText: NSAttributedString,
            statusIcon: MessageStatusIcon?,
            statusTintColor: UIColor,
            maxTextWidth: CGFloat
        ) {
            self.bodyText = bodyText
            self.forwardedHeaderText = forwardedHeaderText
            self.replyHeader = replyHeader
            self.timeText = timeText
            self.statusIcon = statusIcon
            self.statusTintColor = statusTintColor
            self.maxTextWidth = maxTextWidth
        }
    }

    // MARK: - Constants

    private static let timeSpacing: CGFloat = 6
    private static let statusSpacing: CGFloat = 4
    private static let textBottomTimeSpacing: CGFloat = 2

    private static let replyBarWidth: CGFloat = 2
    private static let replyBarMinHeight: CGFloat = 16
    private static let replySpacing: CGFloat = 6
    private static let replyLineSpacing: CGFloat = 1
    private static let replyBottomInset: CGFloat = 4

    private static let statusSlotWidth: CGFloat = ceil(
        MessageStatusIconConfig.defaultSize
        + MessageStatusIconConfig.defaultSize * MessageStatusIconConfig.doubleCheckOffsetRatio
    )

    // MARK: - State

    private let bodyText: NSAttributedString
    private let forwardedHeaderText: NSAttributedString?
    private let replyHeader: ReplyHeaderData?
    private let timeText: NSAttributedString
    private let statusTintColor: UIColor
    private let maxTextWidth: CGFloat

    private(set) var replyHeaderFrame: CGRect?

    var statusIcon: MessageStatusIcon? {
        didSet {
            guard statusIcon != oldValue else { return }
            setNeedsDisplay()
            setNeedsLayout()
        }
    }

    // MARK: - Init

    init(
        bodyText: NSAttributedString,
        forwardedHeaderText: NSAttributedString?,
        replyHeader: ReplyHeaderData?,
        timeText: NSAttributedString,
        statusIcon: MessageStatusIcon?,
        statusTintColor: UIColor,
        maxTextWidth: CGFloat
    ) {
        self.bodyText = bodyText
        self.forwardedHeaderText = forwardedHeaderText
        self.replyHeader = replyHeader
        self.timeText = timeText
        self.statusIcon = statusIcon
        self.statusTintColor = statusTintColor
        self.maxTextWidth = maxTextWidth
        super.init()
        isOpaque = false
        style.flexShrink = 1
    }

    // MARK: - Layout

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        let width = resolvedWidth(from: constrainedSize.width)
        return Self.makeLayout(
            width: width,
            maxTextWidth: maxTextWidth,
            bodyText: bodyText,
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            timeText: timeText,
            statusIcon: statusIcon
        ).size
    }

    override func layout() {
        super.layout()
        let layout = Self.makeLayout(
            width: bounds.width,
            maxTextWidth: maxTextWidth,
            bodyText: bodyText,
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            timeText: timeText,
            statusIcon: statusIcon
        )
        replyHeaderFrame = layout.replyRect
    }

    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        DrawParams(
            bodyText: bodyText,
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            timeText: timeText,
            statusIcon: statusIcon,
            statusTintColor: statusTintColor,
            maxTextWidth: maxTextWidth
        )
    }

    override class func draw(_ bounds: CGRect, withParameters parameters: Any?,
                              isCancelled isCancelledBlock: () -> Bool, isRasterizing: Bool) {
        guard let params = parameters as? DrawParams else { return }

        let layout = makeLayout(
            width: bounds.width,
            maxTextWidth: params.maxTextWidth,
            bodyText: params.bodyText,
            forwardedHeaderText: params.forwardedHeaderText,
            replyHeader: params.replyHeader,
            timeText: params.timeText,
            statusIcon: params.statusIcon
        )

        if isCancelledBlock() { return }

        if let forwardedRect = layout.forwardedRect,
           let forwardedHeaderText = params.forwardedHeaderText {
            forwardedHeaderText.draw(
                with: forwardedRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                context: nil
            )
        }

        if isCancelledBlock() { return }

        if let replyRect = layout.replyRect,
           let replyHeader = params.replyHeader,
           let replyBarRect = layout.replyBarRect,
           let replySenderRect = layout.replySenderRect,
           let replyBodyRect = layout.replyBodyRect {
            replyHeader.barColor.setFill()
            UIBezierPath(
                roundedRect: replyBarRect,
                cornerRadius: Self.replyBarWidth / 2
            ).fill()

            replyHeader.senderText.draw(
                with: replySenderRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                context: nil
            )
            replyHeader.bodyText.draw(
                with: replyBodyRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                context: nil
            )

            _ = replyRect
        }

        if isCancelledBlock() { return }

        params.bodyText.draw(
            with: layout.bodyRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        if isCancelledBlock() { return }

        params.timeText.draw(
            with: layout.timeRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        if let statusRect = layout.statusRect {
            drawStatusIcon(
                params.statusIcon,
                tintColor: params.statusTintColor,
                in: statusRect,
                cancelled: isCancelledBlock
            )
        }
    }

    // MARK: - Helpers

    private func resolvedWidth(from constrainedWidth: CGFloat) -> CGFloat {
        guard constrainedWidth.isFinite, constrainedWidth > 0 else { return maxTextWidth }
        return min(maxTextWidth, constrainedWidth)
    }

    private static func makeLayout(
        width: CGFloat,
        maxTextWidth: CGFloat,
        bodyText: NSAttributedString,
        forwardedHeaderText: NSAttributedString?,
        replyHeader: ReplyHeaderData?,
        timeText: NSAttributedString,
        statusIcon: MessageStatusIcon?
    ) -> LayoutMetrics {
        let availableWidth = max(0, min(maxTextWidth, width))

        var y: CGFloat = 0
        var contentWidth: CGFloat = 0

        var forwardedRect: CGRect?
        if let forwardedHeaderText {
            let forwardedSize = singleLineSize(for: forwardedHeaderText, maxWidth: availableWidth)
            let rect = CGRect(origin: CGPoint(x: 0, y: y), size: forwardedSize)
            forwardedRect = rect.integral
            y = rect.maxY
            contentWidth = max(contentWidth, rect.width)
        }

        var replyRect: CGRect?
        var replyBarRect: CGRect?
        var replySenderRect: CGRect?
        var replyBodyRect: CGRect?
        if let replyHeader {
            let senderSize = singleLineSize(for: replyHeader.senderText, maxWidth: max(0, availableWidth - replyBarWidth - replySpacing))
            let bodySize = singleLineSize(for: replyHeader.bodyText, maxWidth: max(0, availableWidth - replyBarWidth - replySpacing))
            let textWidth = max(senderSize.width, bodySize.width)
            let rect = CGRect(
                x: 0,
                y: y,
                width: replyBarWidth + replySpacing + textWidth,
                height: ceil(senderSize.height) + replyLineSpacing + ceil(bodySize.height) + replyBottomInset
            )
            replyRect = rect.integral

            let contentHeight = rect.height - replyBottomInset
            let barHeight = max(replyBarMinHeight, contentHeight)
            replyBarRect = CGRect(
                x: rect.minX,
                y: rect.minY + floor((contentHeight - barHeight) / 2),
                width: replyBarWidth,
                height: barHeight
            ).integral

            let textX = rect.minX + replyBarWidth + replySpacing
            let senderRect = CGRect(x: textX, y: rect.minY, width: textWidth, height: ceil(senderSize.height))
            replySenderRect = senderRect.integral
            let bodyRect = CGRect(
                x: textX,
                y: senderRect.maxY + replyLineSpacing,
                width: textWidth,
                height: ceil(bodySize.height)
            )
            replyBodyRect = bodyRect.integral

            y = rect.maxY
            contentWidth = max(contentWidth, rect.width)
        }

        let timeTextSize = singleLineSize(for: timeText, maxWidth: .greatestFiniteMagnitude)
        let statusSlotWidth = statusIcon == nil ? 0 : self.statusSlotWidth + statusSpacing
        let timeRowHeight = max(timeTextSize.height, statusDrawHeight(for: statusIcon))
        let timeRowWidth = timeTextSize.width + statusSlotWidth

        let bodyMetrics = textMetrics(for: bodyText, maxWidth: availableWidth)
        let inlineMinWidth = bodyMetrics.trailingLineWidth + timeSpacing + timeRowWidth
        let fitsInline = inlineMinWidth <= availableWidth
        let minBodyWidth = fitsInline ? inlineMinWidth : timeRowWidth
        let bodyWidth = max(bodyMetrics.size.width, minBodyWidth)
        let bodyHeight = bodyMetrics.size.height + (fitsInline ? 0 : timeRowHeight + textBottomTimeSpacing)

        let bodyRect = CGRect(x: 0, y: y, width: bodyWidth, height: bodyMetrics.size.height).integral
        contentWidth = max(contentWidth, bodyWidth)

        let totalHeight = y + bodyHeight
        let timeOriginY = fitsInline
            ? y + bodyMetrics.size.height - timeRowHeight
            : y + bodyMetrics.size.height + textBottomTimeSpacing
        let timeRect = CGRect(
            x: contentWidth - timeRowWidth,
            y: timeOriginY + floor((timeRowHeight - timeTextSize.height) / 2),
            width: timeTextSize.width,
            height: timeTextSize.height
        ).integral

        let statusRect: CGRect?
        if statusIcon == nil {
            statusRect = nil
        } else {
            statusRect = CGRect(
                x: timeRect.maxX + statusSpacing,
                y: timeOriginY,
                width: self.statusSlotWidth,
                height: timeRowHeight
            ).integral
        }

        return LayoutMetrics(
            size: CGSize(width: ceil(contentWidth), height: ceil(totalHeight)),
            forwardedRect: forwardedRect,
            replyRect: replyRect,
            replyBarRect: replyBarRect,
            replySenderRect: replySenderRect,
            replyBodyRect: replyBodyRect,
            bodyRect: bodyRect,
            timeRect: timeRect,
            statusRect: statusRect
        )
    }

    private static func drawStatusIcon(
        _ icon: MessageStatusIcon?,
        tintColor: UIColor,
        in rect: CGRect,
        cancelled: () -> Bool
    ) {
        guard let icon else { return }
        if cancelled() { return }

        let slotWidth = statusSlotWidth
        let slotX = rect.minX
        let slotY = rect.minY + floor((rect.height - MessageStatusIconConfig.defaultSize) / 2)

        switch icon {
        case .pending:
            let frame = MessageStatusIconImages.clockFrame.withTintColor(tintColor, renderingMode: .alwaysOriginal)
            let hand = MessageStatusIconImages.clockHand.withTintColor(tintColor, renderingMode: .alwaysOriginal)
            let iconRect = CGRect(
                x: slotX + slotWidth - MessageStatusIconConfig.defaultSize,
                y: slotY,
                width: MessageStatusIconConfig.defaultSize,
                height: MessageStatusIconConfig.defaultSize
            )
            frame.draw(in: iconRect)
            if cancelled() { return }
            hand.draw(in: iconRect)
        case .sent:
            let image = MessageStatusIconImages.check.withTintColor(tintColor, renderingMode: .alwaysOriginal)
            let iconRect = CGRect(
                x: slotX + slotWidth - image.size.width,
                y: rect.minY + floor((rect.height - image.size.height) / 2),
                width: image.size.width,
                height: image.size.height
            )
            image.draw(in: iconRect)
        case .read:
            let image = MessageStatusIconImages.check.withTintColor(tintColor, renderingMode: .alwaysOriginal)
            let offset = MessageStatusIconConfig.defaultSize * MessageStatusIconConfig.doubleCheckOffsetRatio
            let firstRect = CGRect(
                x: slotX,
                y: rect.minY + floor((rect.height - image.size.height) / 2),
                width: image.size.width,
                height: image.size.height
            )
            image.draw(in: firstRect)
            if cancelled() { return }
            let secondRect = firstRect.offsetBy(dx: offset, dy: 0)
            image.draw(in: secondRect)
        case .failed:
            let image = MessageStatusIconImages.failedBadge
            let iconRect = CGRect(
                x: slotX + slotWidth - image.size.width,
                y: rect.minY + floor((rect.height - image.size.height) / 2),
                width: image.size.width,
                height: image.size.height
            )
            image.draw(in: iconRect)
        }
    }

    private static func statusDrawHeight(for icon: MessageStatusIcon?) -> CGFloat {
        switch icon {
        case .failed:
            return MessageStatusIconImages.failedBadge.size.height
        case .none:
            return 0
        default:
            return MessageStatusIconConfig.defaultSize
        }
    }

    private static func singleLineSize(for attributedText: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let boundedWidth = maxWidth.isFinite ? maxWidth : CGFloat.greatestFiniteMagnitude
        let size = attributedText.boundingRect(
            with: CGSize(width: boundedWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        return CGSize(width: ceil(min(boundedWidth, size.width)), height: ceil(size.height))
    }

    private static func textMetrics(for attributedText: NSAttributedString, maxWidth: CGFloat) -> TextMetrics {
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
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            path,
            nil
        )

        let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        let drawingSize = attributedText.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size

        var trailingWidth: CGFloat = 0
        if let lastLine = lines.last {
            trailingWidth = CGFloat(CTLineGetTypographicBounds(lastLine, nil, nil, nil))
        }

        return TextMetrics(
            size: CGSize(
                width: ceil(max(suggestedSize.width, drawingSize.width)),
                height: ceil(max(suggestedSize.height, drawingSize.height))
            ),
            trailingLineWidth: ceil(trailingWidth),
            lineCount: lines.count
        )
    }

}
