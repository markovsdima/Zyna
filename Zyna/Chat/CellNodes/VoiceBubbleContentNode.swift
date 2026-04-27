//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class VoiceBubbleContentNode: ASDisplayNode {

    struct ReplyHeaderData {
        let senderText: NSAttributedString
        let bodyText: NSAttributedString
        let barColor: UIColor
    }

    // MARK: - Constants

    private static let replyBarWidth: CGFloat = 2
    private static let replyBarMinHeight: CGFloat = 16
    private static let replySpacing: CGFloat = 6
    private static let replyLineSpacing: CGFloat = 1
    private static let replyBottomInset: CGFloat = 4

    private static let playButtonSize = CGSize(width: 32, height: 32)
    private static let waveformBarWidth: CGFloat = 3
    private static let waveformBarSpacing: CGFloat = 2
    private static let waveformCornerRadius: CGFloat = 1.5
    private static let waveformHeight: CGFloat = 20
    private static let contentSpacing: CGFloat = 8
    private static let stackSpacing: CGFloat = 2
    private static let statusSpacing: CGFloat = 4
    private static let statusSlotWidth: CGFloat = ceil(
        MessageStatusIconConfig.defaultSize
        + MessageStatusIconConfig.defaultSize * MessageStatusIconConfig.doubleCheckOffsetRatio
    )

    final class DrawParams: NSObject {
        let forwardedHeaderText: NSAttributedString?
        let replyHeader: ReplyHeaderData?
        let durationText: NSAttributedString
        let timeText: NSAttributedString
        let statusIcon: MessageStatusIcon?
        let statusTintColor: UIColor
        let waveformSamples: [UInt16]
        let waveformProgress: Float
        let waveformFilledColor: UIColor
        let waveformUnfilledColor: UIColor
        let playImage: UIImage
        let maxContentWidth: CGFloat

        init(
            forwardedHeaderText: NSAttributedString?,
            replyHeader: ReplyHeaderData?,
            durationText: NSAttributedString,
            timeText: NSAttributedString,
            statusIcon: MessageStatusIcon?,
            statusTintColor: UIColor,
            waveformSamples: [UInt16],
            waveformProgress: Float,
            waveformFilledColor: UIColor,
            waveformUnfilledColor: UIColor,
            playImage: UIImage,
            maxContentWidth: CGFloat
        ) {
            self.forwardedHeaderText = forwardedHeaderText
            self.replyHeader = replyHeader
            self.durationText = durationText
            self.timeText = timeText
            self.statusIcon = statusIcon
            self.statusTintColor = statusTintColor
            self.waveformSamples = waveformSamples
            self.waveformProgress = waveformProgress
            self.waveformFilledColor = waveformFilledColor
            self.waveformUnfilledColor = waveformUnfilledColor
            self.playImage = playImage
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
        let playButtonRect: CGRect
        let playImageRect: CGRect
        let waveformRect: CGRect
        let durationRect: CGRect
        let timeRect: CGRect
        let statusRect: CGRect?
    }

    private let forwardedHeaderText: NSAttributedString?
    private let replyHeader: ReplyHeaderData?
    private let timeText: NSAttributedString
    private let statusTintColor: UIColor
    private let waveformSamples: [UInt16]
    private let waveformFilledColor: UIColor
    private let waveformUnfilledColor: UIColor
    private let playImageWhenPaused: UIImage
    private let playImageWhenPlaying: UIImage
    private let maxContentWidth: CGFloat

    private(set) var replyHeaderFrame: CGRect?
    private(set) var playButtonFrame: CGRect = .zero

    var durationText: NSAttributedString {
        didSet { setNeedsDisplay(); setNeedsLayout() }
    }

    var waveformProgress: Float = 0 {
        didSet {
            guard waveformProgress != oldValue else { return }
            setNeedsDisplay()
        }
    }

    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            setNeedsDisplay()
        }
    }

    var statusIcon: MessageStatusIcon? {
        didSet {
            guard statusIcon != oldValue else { return }
            setNeedsDisplay()
            setNeedsLayout()
        }
    }

    init(
        forwardedHeaderText: NSAttributedString?,
        replyHeader: ReplyHeaderData?,
        durationText: NSAttributedString,
        timeText: NSAttributedString,
        statusIcon: MessageStatusIcon?,
        statusTintColor: UIColor,
        waveformSamples: [UInt16],
        waveformFilledColor: UIColor,
        waveformUnfilledColor: UIColor,
        playImageWhenPaused: UIImage,
        playImageWhenPlaying: UIImage,
        maxContentWidth: CGFloat
    ) {
        self.forwardedHeaderText = forwardedHeaderText
        self.replyHeader = replyHeader
        self.durationText = durationText
        self.timeText = timeText
        self.statusIcon = statusIcon
        self.statusTintColor = statusTintColor
        self.waveformSamples = waveformSamples
        self.waveformFilledColor = waveformFilledColor
        self.waveformUnfilledColor = waveformUnfilledColor
        self.playImageWhenPaused = playImageWhenPaused
        self.playImageWhenPlaying = playImageWhenPlaying
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
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            durationText: durationText,
            timeText: timeText,
            statusIcon: statusIcon,
            waveformSamples: waveformSamples
        ).size
    }

    override func layout() {
        super.layout()
        let layout = Self.makeLayout(
            width: bounds.width,
            maxContentWidth: maxContentWidth,
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            durationText: durationText,
            timeText: timeText,
            statusIcon: statusIcon,
            waveformSamples: waveformSamples
        )
        replyHeaderFrame = layout.replyRect
        playButtonFrame = layout.playButtonRect
    }

    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        DrawParams(
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            durationText: durationText,
            timeText: timeText,
            statusIcon: statusIcon,
            statusTintColor: statusTintColor,
            waveformSamples: waveformSamples,
            waveformProgress: waveformProgress,
            waveformFilledColor: waveformFilledColor,
            waveformUnfilledColor: waveformUnfilledColor,
            playImage: isPlaying ? playImageWhenPlaying : playImageWhenPaused,
            maxContentWidth: maxContentWidth
        )
    }

    override class func draw(_ bounds: CGRect, withParameters parameters: Any?,
                              isCancelled isCancelledBlock: () -> Bool, isRasterizing: Bool) {
        guard let params = parameters as? DrawParams else { return }

        let layout = makeLayout(
            width: bounds.width,
            maxContentWidth: params.maxContentWidth,
            forwardedHeaderText: params.forwardedHeaderText,
            replyHeader: params.replyHeader,
            durationText: params.durationText,
            timeText: params.timeText,
            statusIcon: params.statusIcon,
            waveformSamples: params.waveformSamples
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

        params.playImage.draw(in: layout.playImageRect)
        drawWaveform(
            samples: fittedWaveformSamples(
                from: params.waveformSamples,
                maxWidth: layout.waveformRect.width
            ),
            progress: params.waveformProgress,
            filledColor: params.waveformFilledColor,
            unfilledColor: params.waveformUnfilledColor,
            rect: layout.waveformRect,
            cancelled: isCancelledBlock
        )

        if isCancelledBlock() { return }

        params.durationText.draw(
            with: layout.durationRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )
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

    private static func makeLayout(
        width: CGFloat,
        maxContentWidth: CGFloat,
        forwardedHeaderText: NSAttributedString?,
        replyHeader: ReplyHeaderData?,
        durationText: NSAttributedString,
        timeText: NSAttributedString,
        statusIcon: MessageStatusIcon?,
        waveformSamples: [UInt16]
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
            y = replyRect!.maxY
            usedWidth = max(usedWidth, replyRect!.width)
        }

        let durationSize = singleLineSize(for: durationText, maxWidth: availableWidth)
        let timeSize = singleLineSize(for: timeText, maxWidth: availableWidth)
        let statusWidth = statusIcon == nil ? 0 : statusSlotWidth + statusSpacing
        let timeRowHeight = max(timeSize.height, statusDrawHeight(for: statusIcon))
        let timeRowWidth = timeSize.width + statusWidth
        let maxWaveformWidth = max(
            0,
            availableWidth - playButtonSize.width - contentSpacing - durationSize.width - contentSpacing
        )
        let displayedWaveformSamples = fittedWaveformSamples(
            from: waveformSamples,
            maxWidth: maxWaveformWidth
        )
        let waveformWidth = widthForWaveform(sampleCount: displayedWaveformSamples.count)
        let waveformToDurationSpacing = waveformWidth > 0 ? contentSpacing : 0
        let rowWidth = playButtonSize.width + contentSpacing + waveformWidth + waveformToDurationSpacing + durationSize.width
        let rowHeight = max(playButtonSize.height, durationSize.height, waveformHeight)
        let contentWidth = max(rowWidth, timeRowWidth)

        let playButtonRect = CGRect(x: 0, y: y, width: playButtonSize.width, height: playButtonSize.height).integral
        let playImageRect = CGRect(
            x: playButtonRect.minX + floor((playButtonSize.width - 16) / 2),
            y: playButtonRect.minY + floor((playButtonSize.height - 16) / 2),
            width: 16,
            height: 16
        ).integral
        let waveformRect = CGRect(
            x: playButtonRect.maxX + contentSpacing,
            y: y + floor((rowHeight - waveformHeight) / 2),
            width: waveformWidth,
            height: waveformHeight
        ).integral
        let durationRect = CGRect(
            x: waveformWidth > 0
                ? waveformRect.maxX + waveformToDurationSpacing
                : playButtonRect.maxX + contentSpacing,
            y: y + floor((rowHeight - durationSize.height) / 2),
            width: durationSize.width,
            height: durationSize.height
        ).integral
        let timeRect = CGRect(
            x: contentWidth - timeRowWidth,
            y: y + rowHeight + stackSpacing + floor((timeRowHeight - timeSize.height) / 2),
            width: timeSize.width,
            height: timeSize.height
        ).integral
        let statusRect = statusIcon == nil ? nil : CGRect(
            x: timeRect.maxX + statusSpacing,
            y: y + rowHeight + stackSpacing,
            width: statusSlotWidth,
            height: timeRowHeight
        ).integral

        usedWidth = max(usedWidth, contentWidth)

        return LayoutMetrics(
            size: CGSize(width: ceil(usedWidth), height: ceil(max(timeRect.maxY, statusRect?.maxY ?? 0))),
            forwardedRect: forwardedRect,
            replyRect: replyRect,
            replyBarRect: replyBarRect,
            replySenderRect: replySenderRect,
            replyBodyRect: replyBodyRect,
            playButtonRect: playButtonRect,
            playImageRect: playImageRect,
            waveformRect: waveformRect,
            durationRect: durationRect,
            timeRect: timeRect,
            statusRect: statusRect
        )
    }

    private static func fittedWaveformSamples(from samples: [UInt16], maxWidth: CGFloat) -> [UInt16] {
        let maxSampleCount = Int(
            floor((maxWidth + waveformBarSpacing) / (waveformBarWidth + waveformBarSpacing))
        )
        let clampedCount = max(0, min(samples.count, maxSampleCount))

        guard clampedCount > 0 else { return [] }
        guard clampedCount < samples.count else { return samples }

        return resampleWaveform(samples, to: clampedCount)
    }

    private static func widthForWaveform(sampleCount: Int) -> CGFloat {
        guard sampleCount > 0 else { return 0 }
        return CGFloat(sampleCount) * (waveformBarWidth + waveformBarSpacing) - waveformBarSpacing
    }

    private static func drawStatusIcon(
        _ icon: MessageStatusIcon?,
        tintColor: UIColor,
        in rect: CGRect,
        cancelled: () -> Bool
    ) {
        guard let icon else { return }
        if cancelled() { return }

        let slotX = rect.minX
        let slotY = rect.minY + floor((rect.height - MessageStatusIconConfig.defaultSize) / 2)

        switch icon {
        case .pending:
            let frame = MessageStatusIconImages.clockFrame.withTintColor(tintColor, renderingMode: .alwaysOriginal)
            let hand = MessageStatusIconImages.clockHand.withTintColor(tintColor, renderingMode: .alwaysOriginal)
            let iconRect = CGRect(
                x: slotX + statusSlotWidth - MessageStatusIconConfig.defaultSize,
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
                x: slotX + statusSlotWidth - image.size.width,
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
            image.draw(in: firstRect.offsetBy(dx: offset, dy: 0))
        case .failed:
            let image = MessageStatusIconImages.failedBadge
            let iconRect = CGRect(
                x: slotX + statusSlotWidth - image.size.width,
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

    private static func singleLineSize(for text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let size = text.boundingRect(
            with: CGSize(width: maxWidth.isFinite ? maxWidth : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        return CGSize(width: ceil(min(maxWidth, size.width)), height: ceil(size.height))
    }

    private static func resampleWaveform(_ waveform: [UInt16], to count: Int) -> [UInt16] {
        guard !waveform.isEmpty else {
            return [UInt16](repeating: 100, count: count)
        }
        guard waveform.count != count else { return waveform }

        var result = [UInt16]()
        result.reserveCapacity(count)
        for i in 0..<count {
            let position = Float(i) / Float(count) * Float(waveform.count)
            let index = Int(position)
            let fraction = position - Float(index)
            let value: Float
            if index + 1 < waveform.count {
                value = Float(waveform[index]) * (1 - fraction) + Float(waveform[index + 1]) * fraction
            } else {
                value = Float(waveform[min(index, waveform.count - 1)])
            }
            result.append(UInt16(min(value, 1024)))
        }
        return result
    }

    private static func drawWaveform(
        samples: [UInt16],
        progress: Float,
        filledColor: UIColor,
        unfilledColor: UIColor,
        rect: CGRect,
        cancelled: () -> Bool
    ) {
        let filledCount = Int(progress * Float(samples.count))
        for i in 0..<samples.count {
            if cancelled() { return }
            let height = max(3, CGFloat(samples[i]) / 1024.0 * rect.height)
            let x = rect.minX + CGFloat(i) * (waveformBarWidth + waveformBarSpacing)
            let y = rect.minY + (rect.height - height) / 2
            let barRect = CGRect(x: x, y: y, width: waveformBarWidth, height: height)
            let color = i < filledCount ? filledColor : unfilledColor
            color.setFill()
            UIBezierPath(roundedRect: barRect, cornerRadius: waveformCornerRadius).fill()
        }
    }
}
