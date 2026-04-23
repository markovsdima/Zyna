//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class FileBubbleContentNode: ASDisplayNode {

    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case downloaded
    }

    // MARK: - Constants

    private static let iconSize = CGSize(width: 44, height: 44)
    private static let iconCornerRadius: CGFloat = 10
    private static let rowSpacing: CGFloat = 10
    private static let columnSpacing: CGFloat = 2
    private static let replyBarWidth: CGFloat = 2
    private static let replyBarMinHeight: CGFloat = 16
    private static let replySpacing: CGFloat = 6
    private static let replyLineSpacing: CGFloat = 1
    private static let replyBottomInset: CGFloat = 4
    private static let headerBottomSpacing: CGFloat = 4
    private static let statusSpacing: CGFloat = 3
    private static let statusSlotWidth: CGFloat = ceil(
        MessageStatusIconConfig.defaultSize
        + MessageStatusIconConfig.defaultSize * MessageStatusIconConfig.doubleCheckOffsetRatio
    )

    struct ReplyHeaderData {
        let senderText: NSAttributedString
        let bodyText: NSAttributedString
        let barColor: UIColor
    }

    final class DrawParams: NSObject {
        let extText: NSAttributedString
        let filenameText: NSAttributedString
        let sizeText: NSAttributedString
        let timeText: NSAttributedString
        let forwardedHeaderText: NSAttributedString?
        let replyHeader: ReplyHeaderData?
        let extColor: UIColor
        let iconBackgroundColor: UIColor
        let statusIcon: MessageStatusIcon?
        let statusTintColor: UIColor
        let downloadState: DownloadState
        let maxContentWidth: CGFloat

        init(
            extText: NSAttributedString,
            filenameText: NSAttributedString,
            sizeText: NSAttributedString,
            timeText: NSAttributedString,
            forwardedHeaderText: NSAttributedString?,
            replyHeader: ReplyHeaderData?,
            extColor: UIColor,
            iconBackgroundColor: UIColor,
            statusIcon: MessageStatusIcon?,
            statusTintColor: UIColor,
            downloadState: DownloadState,
            maxContentWidth: CGFloat
        ) {
            self.extText = extText
            self.filenameText = filenameText
            self.sizeText = sizeText
            self.timeText = timeText
            self.forwardedHeaderText = forwardedHeaderText
            self.replyHeader = replyHeader
            self.extColor = extColor
            self.iconBackgroundColor = iconBackgroundColor
            self.statusIcon = statusIcon
            self.statusTintColor = statusTintColor
            self.downloadState = downloadState
            self.maxContentWidth = maxContentWidth
        }
    }

    fileprivate struct LayoutMetrics {
        let size: CGSize
        let forwardedRect: CGRect?
        let replyRect: CGRect?
        let replyBarRect: CGRect?
        let replySenderRect: CGRect?
        let replyBodyRect: CGRect?
        let iconRect: CGRect
        let extRect: CGRect
        let filenameRect: CGRect
        let sizeRect: CGRect
        let timeRect: CGRect
        let statusRect: CGRect?
    }

    private let extText: NSAttributedString
    private let filenameText: NSAttributedString
    private let sizeText: NSAttributedString
    private let timeText: NSAttributedString
    private let forwardedHeaderText: NSAttributedString?
    private let replyHeader: ReplyHeaderData?
    private let extColor: UIColor
    private let iconBackgroundColor: UIColor
    private let statusTintColor: UIColor
    private let maxContentWidth: CGFloat

    private(set) var replyHeaderFrame: CGRect?

    var statusIcon: MessageStatusIcon? {
        didSet {
            guard statusIcon != oldValue else { return }
            setNeedsDisplay()
            setNeedsLayout()
        }
    }

    var downloadState: DownloadState = .idle {
        didSet {
            guard downloadState != oldValue else { return }
            setNeedsDisplay()
        }
    }

    init(
        extText: NSAttributedString,
        filenameText: NSAttributedString,
        sizeText: NSAttributedString,
        timeText: NSAttributedString,
        forwardedHeaderText: NSAttributedString?,
        replyHeader: ReplyHeaderData?,
        extColor: UIColor,
        iconBackgroundColor: UIColor,
        statusIcon: MessageStatusIcon?,
        statusTintColor: UIColor,
        maxContentWidth: CGFloat
    ) {
        self.extText = extText
        self.filenameText = filenameText
        self.sizeText = sizeText
        self.timeText = timeText
        self.forwardedHeaderText = forwardedHeaderText
        self.replyHeader = replyHeader
        self.extColor = extColor
        self.iconBackgroundColor = iconBackgroundColor
        self.statusIcon = statusIcon
        self.statusTintColor = statusTintColor
        self.maxContentWidth = maxContentWidth
        super.init()
        isOpaque = false
        style.flexShrink = 1
    }

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        let width = constrainedSize.width.isFinite && constrainedSize.width > 0
            ? min(maxContentWidth, constrainedSize.width)
            : maxContentWidth
        return Self.makeLayout(
            width: width,
            maxContentWidth: maxContentWidth,
            extText: extText,
            filenameText: filenameText,
            sizeText: sizeText,
            timeText: timeText,
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            statusIcon: statusIcon
        ).size
    }

    override func layout() {
        super.layout()
        let layout = Self.makeLayout(
            width: bounds.width,
            maxContentWidth: maxContentWidth,
            extText: extText,
            filenameText: filenameText,
            sizeText: sizeText,
            timeText: timeText,
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            statusIcon: statusIcon
        )
        replyHeaderFrame = layout.replyRect
    }

    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        DrawParams(
            extText: extText,
            filenameText: filenameText,
            sizeText: sizeText,
            timeText: timeText,
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            extColor: extColor,
            iconBackgroundColor: iconBackgroundColor,
            statusIcon: statusIcon,
            statusTintColor: statusTintColor,
            downloadState: downloadState,
            maxContentWidth: maxContentWidth
        )
    }

    override class func draw(_ bounds: CGRect, withParameters parameters: Any?,
                              isCancelled isCancelledBlock: () -> Bool, isRasterizing: Bool) {
        guard let params = parameters as? DrawParams else { return }

        let layout = makeLayout(
            width: bounds.width,
            maxContentWidth: params.maxContentWidth,
            extText: params.extText,
            filenameText: params.filenameText,
            sizeText: params.sizeText,
            timeText: params.timeText,
            forwardedHeaderText: params.forwardedHeaderText,
            replyHeader: params.replyHeader,
            statusIcon: params.statusIcon
        )

        if let forwardedRect = layout.forwardedRect,
           let forwardedHeaderText = params.forwardedHeaderText {
            forwardedHeaderText.draw(
                with: forwardedRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                context: nil
            )
        }

        if isCancelledBlock() { return }

        if let replyHeader = params.replyHeader,
           let replyBarRect = layout.replyBarRect,
           let replySenderRect = layout.replySenderRect,
           let replyBodyRect = layout.replyBodyRect {
            replyHeader.barColor.setFill()
            UIBezierPath(roundedRect: replyBarRect, cornerRadius: Self.replyBarWidth / 2).fill()
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
        }

        if isCancelledBlock() { return }

        params.iconBackgroundColor.setFill()
        UIBezierPath(
            roundedRect: layout.iconRect,
            cornerRadius: Self.iconCornerRadius
        ).fill()

        params.extText.draw(
            with: layout.extRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )

        if case .downloading(let progress) = params.downloadState {
            drawProgress(progress: progress, color: params.extColor, rect: layout.iconRect)
        }

        if isCancelledBlock() { return }

        params.filenameText.draw(
            with: layout.filenameRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )
        params.sizeText.draw(
            with: layout.sizeRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )
        params.timeText.draw(
            with: layout.timeRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        if let statusRect = layout.statusRect {
            drawStatusIcon(params.statusIcon, tintColor: params.statusTintColor, in: statusRect)
        }
    }

    private static func makeLayout(
        width: CGFloat,
        maxContentWidth: CGFloat,
        extText: NSAttributedString,
        filenameText: NSAttributedString,
        sizeText: NSAttributedString,
        timeText: NSAttributedString,
        forwardedHeaderText: NSAttributedString?,
        replyHeader: ReplyHeaderData?,
        statusIcon: MessageStatusIcon?
    ) -> LayoutMetrics {
        let availableWidth = max(0, min(width, maxContentWidth))
        var y: CGFloat = 0
        var usedWidth: CGFloat = 0

        var forwardedRect: CGRect?
        if let forwardedHeaderText {
            let size = singleLineSize(for: forwardedHeaderText, maxWidth: availableWidth)
            forwardedRect = CGRect(origin: CGPoint(x: 0, y: y), size: size).integral
            y = forwardedRect!.maxY
            usedWidth = max(usedWidth, forwardedRect!.width)
        }

        var replyRect: CGRect?
        var replyBarRect: CGRect?
        var replySenderRect: CGRect?
        var replyBodyRect: CGRect?
        if let replyHeader {
            let textWidth = max(0, availableWidth - replyBarWidth - replySpacing)
            let senderSize = singleLineSize(for: replyHeader.senderText, maxWidth: textWidth)
            let bodySize = singleLineSize(for: replyHeader.bodyText, maxWidth: textWidth)
            replyRect = CGRect(
                x: 0,
                y: y,
                width: replyBarWidth + replySpacing + max(senderSize.width, bodySize.width),
                height: senderSize.height + replyLineSpacing + bodySize.height + replyBottomInset
            ).integral
            let contentHeight = replyRect!.height - replyBottomInset
            let barHeight = max(replyBarMinHeight, contentHeight)
            replyBarRect = CGRect(
                x: replyRect!.minX,
                y: replyRect!.minY + floor((contentHeight - barHeight) / 2),
                width: replyBarWidth,
                height: barHeight
            ).integral
            let textX = replyRect!.minX + replyBarWidth + replySpacing
            replySenderRect = CGRect(x: textX, y: replyRect!.minY, width: replyRect!.width - textX, height: senderSize.height).integral
            replyBodyRect = CGRect(x: textX, y: replySenderRect!.maxY + replyLineSpacing, width: replyRect!.width - textX, height: bodySize.height).integral
            y = replyRect!.maxY + headerBottomSpacing
            usedWidth = max(usedWidth, replyRect!.width)
        }

        let rightWidth = max(
            0,
            availableWidth - iconSize.width - rowSpacing
        )
        let filenameSize = singleLineSize(for: filenameText, maxWidth: rightWidth)
        let sizeSize = singleLineSize(for: sizeText, maxWidth: rightWidth)
        let timeSize = singleLineSize(for: timeText, maxWidth: rightWidth)
        let statusWidth = statusIcon == nil ? 0 : statusSlotWidth + statusSpacing
        let bottomRowWidth = sizeSize.width + 4 + timeSize.width + statusWidth
        let rightColumnWidth = min(rightWidth, max(filenameSize.width, bottomRowWidth))
        let rowHeight = max(iconSize.height, filenameSize.height + columnSpacing + sizeSize.height)
        let iconRect = CGRect(x: 0, y: y + floor((rowHeight - iconSize.height) / 2), width: iconSize.width, height: iconSize.height).integral
        let extSize = singleLineSize(for: extText, maxWidth: iconSize.width - 8)
        let extRect = CGRect(
            x: iconRect.minX + floor((iconSize.width - extSize.width) / 2),
            y: iconRect.minY + floor((iconSize.height - extSize.height) / 2),
            width: extSize.width,
            height: extSize.height
        ).integral
        let rightX = iconRect.maxX + rowSpacing
        let filenameRect = CGRect(x: rightX, y: y + floor((rowHeight - (filenameSize.height + columnSpacing + sizeSize.height)) / 2), width: rightColumnWidth, height: filenameSize.height).integral
        let timeGroupWidth = timeSize.width + statusWidth
        let bottomRowY = filenameRect.maxY + columnSpacing
        let sizeRect = CGRect(x: rightX, y: bottomRowY, width: sizeSize.width, height: sizeSize.height).integral
        let timeRect = CGRect(x: rightX + rightColumnWidth - timeGroupWidth, y: bottomRowY, width: timeSize.width, height: timeSize.height).integral
        let statusRect = statusIcon == nil ? nil : CGRect(
            x: timeRect.maxX + statusSpacing,
            y: bottomRowY + floor((timeSize.height - MessageStatusIconConfig.defaultSize) / 2),
            width: statusSlotWidth,
            height: max(timeSize.height, MessageStatusIconConfig.defaultSize)
        ).integral

        usedWidth = max(usedWidth, iconSize.width + rowSpacing + rightColumnWidth)

        return LayoutMetrics(
            size: CGSize(width: ceil(usedWidth), height: ceil(y + rowHeight)),
            forwardedRect: forwardedRect,
            replyRect: replyRect,
            replyBarRect: replyBarRect,
            replySenderRect: replySenderRect,
            replyBodyRect: replyBodyRect,
            iconRect: iconRect,
            extRect: extRect,
            filenameRect: filenameRect,
            sizeRect: sizeRect,
            timeRect: timeRect,
            statusRect: statusRect
        )
    }

    private static func singleLineSize(for text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let size = text.boundingRect(
            with: CGSize(width: maxWidth.isFinite ? maxWidth : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        return CGSize(width: ceil(min(maxWidth, size.width)), height: ceil(size.height))
    }

    private static func drawStatusIcon(_ icon: MessageStatusIcon?, tintColor: UIColor, in rect: CGRect) {
        guard let icon else { return }
        switch icon {
        case .pending:
            let frame = MessageStatusIconImages.clockFrame.withTintColor(tintColor, renderingMode: .alwaysOriginal)
            let hand = MessageStatusIconImages.clockHand.withTintColor(tintColor, renderingMode: .alwaysOriginal)
            let iconRect = CGRect(
                x: rect.minX + statusSlotWidth - MessageStatusIconConfig.defaultSize,
                y: rect.minY,
                width: MessageStatusIconConfig.defaultSize,
                height: MessageStatusIconConfig.defaultSize
            )
            frame.draw(in: iconRect)
            hand.draw(in: iconRect)
        case .sent:
            let image = MessageStatusIconImages.check.withTintColor(tintColor, renderingMode: .alwaysOriginal)
            let iconRect = CGRect(
                x: rect.minX + statusSlotWidth - image.size.width,
                y: rect.minY + floor((rect.height - image.size.height) / 2),
                width: image.size.width,
                height: image.size.height
            )
            image.draw(in: iconRect)
        case .read:
            let image = MessageStatusIconImages.check.withTintColor(tintColor, renderingMode: .alwaysOriginal)
            let offset = MessageStatusIconConfig.defaultSize * MessageStatusIconConfig.doubleCheckOffsetRatio
            let firstRect = CGRect(
                x: rect.minX,
                y: rect.minY + floor((rect.height - image.size.height) / 2),
                width: image.size.width,
                height: image.size.height
            )
            image.draw(in: firstRect)
            image.draw(in: firstRect.offsetBy(dx: offset, dy: 0))
        case .failed:
            let image = MessageStatusIconImages.failedBadge
            let iconRect = CGRect(
                x: rect.minX + statusSlotWidth - image.size.width,
                y: rect.minY + floor((rect.height - image.size.height) / 2),
                width: image.size.width,
                height: image.size.height
            )
            image.draw(in: iconRect)
        }
    }

    private static func drawProgress(progress: Double, color: UIColor, rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - 3
        let startAngle = -CGFloat.pi / 2
        let endAngle = startAngle + CGFloat(max(0, min(progress, 1))) * 2 * CGFloat.pi

        let trackPath = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 2 * .pi,
            clockwise: true
        )
        UIColor.black.withAlphaComponent(0.08).setStroke()
        trackPath.lineWidth = 2.5
        trackPath.stroke()

        let progressPath = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        color.setStroke()
        progressPath.lineWidth = 2.5
        progressPath.lineCapStyle = .round
        progressPath.stroke()
    }
}
