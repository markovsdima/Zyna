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

    final class DrawParams: NSObject {
        let forwardedHeaderText: NSAttributedString?
        let replyHeader: ReplyHeaderData?
        let durationText: NSAttributedString
        let timeText: NSAttributedString
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
    }

    private let forwardedHeaderText: NSAttributedString?
    private let replyHeader: ReplyHeaderData?
    private let timeText: NSAttributedString
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

    init(
        forwardedHeaderText: NSAttributedString?,
        replyHeader: ReplyHeaderData?,
        durationText: NSAttributedString,
        timeText: NSAttributedString,
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
            samples: params.waveformSamples,
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
    }

    private static func makeLayout(
        width: CGFloat,
        maxContentWidth: CGFloat,
        forwardedHeaderText: NSAttributedString?,
        replyHeader: ReplyHeaderData?,
        durationText: NSAttributedString,
        timeText: NSAttributedString,
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

        let waveformWidth = CGFloat(waveformSamples.count) * (waveformBarWidth + waveformBarSpacing) - waveformBarSpacing
        let durationSize = singleLineSize(for: durationText, maxWidth: availableWidth)
        let rowWidth = playButtonSize.width + contentSpacing + waveformWidth + contentSpacing + durationSize.width
        let rowHeight = max(playButtonSize.height, durationSize.height, waveformHeight)
        let timeSize = singleLineSize(for: timeText, maxWidth: availableWidth)
        let contentWidth = max(rowWidth, timeSize.width)

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
            x: waveformRect.maxX + contentSpacing,
            y: y + floor((rowHeight - durationSize.height) / 2),
            width: durationSize.width,
            height: durationSize.height
        ).integral
        let timeRect = CGRect(
            x: contentWidth - timeSize.width,
            y: y + rowHeight + stackSpacing,
            width: timeSize.width,
            height: timeSize.height
        ).integral

        usedWidth = max(usedWidth, contentWidth)

        return LayoutMetrics(
            size: CGSize(width: ceil(usedWidth), height: ceil(timeRect.maxY)),
            forwardedRect: forwardedRect,
            replyRect: replyRect,
            replyBarRect: replyBarRect,
            replySenderRect: replySenderRect,
            replyBodyRect: replyBodyRect,
            playButtonRect: playButtonRect,
            playImageRect: playImageRect,
            waveformRect: waveformRect,
            durationRect: durationRect,
            timeRect: timeRect
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
