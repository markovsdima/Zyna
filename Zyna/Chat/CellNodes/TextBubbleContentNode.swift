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

    fileprivate struct LayoutMetrics {
        let size: CGSize
        let forwardedRect: CGRect?
        let replyRect: CGRect?
        let replyBarRect: CGRect?
        let replySenderRect: CGRect?
        let replyBodyRect: CGRect?
        let bodyRect: CGRect
        let bodyLayout: BodyTextLayout
        let timeRect: CGRect
        let statusRect: CGRect?
    }

    private struct StatusGeometry: Equatable {
        let hasSlot: Bool
        let drawHeight: CGFloat
    }

    fileprivate struct LinkHitRegion {
        let rect: CGRect
        let url: URL
    }

    private struct PreparedLayout {
        let statusGeometry: StatusGeometry
        let metrics: LayoutMetrics
    }

    private struct LayoutGeometry {
        let size: CGSize
        let replyRect: CGRect?
        let bodyRect: CGRect
        let quoteBarRects: [CGRect]
        let linkHitRegions: [LinkHitRegion]

        init(_ metrics: LayoutMetrics) {
            size = metrics.size
            replyRect = metrics.replyRect
            bodyRect = metrics.bodyRect
            quoteBarRects = metrics.bodyLayout.quoteBarRects
            linkHitRegions = metrics.bodyLayout.linkHitRegions
        }
    }

    private struct PreparedGeometry {
        let measuredWidth: CGFloat
        let statusGeometry: StatusGeometry
        let geometry: LayoutGeometry
    }

    private final class PreparedLayoutBox: NSObject {
        let value: PreparedLayout

        init(_ value: PreparedLayout) {
            self.value = value
        }
    }

    private final class PreparedLayoutCacheKey: NSObject {}

    private struct LayoutState {
        var statusIcon: MessageStatusIcon?
        var preparedGeometries: [PreparedGeometry] = []
        var generation: UInt = 0
    }

    private struct AppliedLayout: Equatable {
        let size: CGSize
        let statusGeometry: StatusGeometry
    }

    fileprivate final class BodyTextLayout {
        private struct Decoration {
            let rect: CGRect
            let color: UIColor
        }

        let size: CGSize
        let trailingLineWidth: CGFloat
        let lineCount: Int
        let quoteBarRects: [CGRect]
        let linkHitRegions: [LinkHitRegion]

        private let frame: ReusableTextFrame?
        private let pathHeight: CGFloat
        private let codeBackgrounds: [Decoration]
        private let strikethroughs: [Decoration]

        init(attributedText: NSAttributedString, width: CGFloat) {
            guard attributedText.length > 0, width > 0 else {
                size = .zero
                trailingLineWidth = 0
                lineCount = 0
                quoteBarRects = []
                linkHitRegions = []
                frame = nil
                pathHeight = 1
                codeBackgrounds = []
                strikethroughs = []
                return
            }

            let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
            let constrainedWidth = max(1, width)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: attributedText.length),
                nil,
                CGSize(width: constrainedWidth, height: .greatestFiniteMagnitude),
                nil
            )
            let measuredSize = CGSize(
                width: ceil(min(constrainedWidth, suggested.width)),
                height: ceil(suggested.height)
            )
            let frameHeight = max(1, measuredSize.height + 2)
            let path = CGMutablePath()
            path.addRect(CGRect(
                x: 0,
                y: 0,
                width: constrainedWidth,
                height: frameHeight
            ))
            let textFrame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: 0, length: attributedText.length),
                path,
                nil
            )
            let frameLines = (CTFrameGetLines(textFrame) as? [CTLine]) ?? []
            var lineOrigins = Array(repeating: CGPoint.zero, count: frameLines.count)
            if !frameLines.isEmpty {
                CTFrameGetLineOrigins(
                    textFrame,
                    CFRange(location: 0, length: 0),
                    &lineOrigins
                )
            }

            size = measuredSize
            if let lastLine = frameLines.last,
               let lastOrigin = lineOrigins.last {
                trailingLineWidth = ceil(
                    lastOrigin.x
                        + CGFloat(CTLineGetTypographicBounds(lastLine, nil, nil, nil))
                )
            } else {
                trailingLineWidth = 0
            }
            lineCount = frameLines.count
            frame = ReusableTextFrame(
                frame: textFrame,
                attributedText: attributedText,
                size: CGSize(width: constrainedWidth, height: frameHeight)
            )
            let decorations = Self.makeDecorations(
                attributedText: attributedText,
                lines: frameLines,
                origins: lineOrigins,
                pathHeight: frameHeight
            )
            pathHeight = frameHeight
            codeBackgrounds = decorations.backgrounds
            strikethroughs = decorations.strikethroughs
            quoteBarRects = Self.makeQuoteBarRects(
                attributedText: attributedText,
                lines: frameLines,
                origins: lineOrigins,
                height: frameHeight
            )
            linkHitRegions = Self.makeLinkHitRegions(
                attributedText: attributedText,
                lines: frameLines,
                origins: lineOrigins,
                height: frameHeight
            )
        }

        func draw(
            in rect: CGRect,
            quoteBarColor: UIColor,
            context: CGContext
        ) {
            for decoration in codeBackgrounds {
                context.setFillColor(decoration.color.cgColor)
                context.fill(decoration.rect.offsetBy(dx: rect.minX, dy: rect.minY))
            }

            if !quoteBarRects.isEmpty {
                context.beginPath()
                for quoteRect in quoteBarRects {
                    let translated = quoteRect.offsetBy(dx: rect.minX, dy: rect.minY)
                    context.addPath(CGPath(
                        roundedRect: translated,
                        cornerWidth: translated.width / 2,
                        cornerHeight: translated.width / 2,
                        transform: nil
                    ))
                }
                context.setFillColor(quoteBarColor.cgColor)
                context.fillPath()
            }

            guard let frame else { return }
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: rect.minX, y: rect.minY + pathHeight)
            context.scaleBy(x: 1, y: -1)
            frame.withExclusiveFrame { CTFrameDraw($0, context) }
            context.restoreGState()

            for decoration in strikethroughs {
                context.setFillColor(decoration.color.cgColor)
                context.fill(decoration.rect.offsetBy(dx: rect.minX, dy: rect.minY))
            }
        }

        private static func makeDecorations(
            attributedText: NSAttributedString,
            lines: [CTLine],
            origins: [CGPoint],
            pathHeight: CGFloat
        ) -> (backgrounds: [Decoration], strikethroughs: [Decoration]) {
            var containsDecoration = false
            attributedText.enumerateAttributes(
                in: NSRange(location: 0, length: attributedText.length),
                options: []
            ) { attributes, _, stop in
                if attributes[.zynaCodeBackground] != nil
                    || attributes[.zynaStrikethrough] != nil {
                    containsDecoration = true
                    stop.pointee = true
                }
            }
            guard containsDecoration else { return ([], []) }

            var backgrounds: [Decoration] = []
            var strikethroughs: [Decoration] = []

            for (line, origin) in zip(lines, origins) {
                let baselineY = pathHeight - origin.y
                let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
                for run in runs {
                    let range = CTRunGetStringRange(run)
                    guard range.location != kCFNotFound,
                          range.location >= 0,
                          range.location < attributedText.length,
                          range.length > 0 else {
                        continue
                    }

                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    let width = CGFloat(CTRunGetTypographicBounds(
                        run,
                        CFRange(location: 0, length: 0),
                        &ascent,
                        &descent,
                        nil
                    ))
                    guard width > 0 else { continue }

                    var position = CGPoint.zero
                    CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                    let x = origin.x + position.x
                    let stringIndex = range.location

                    if let color = attributedText.attribute(
                        .zynaCodeBackground,
                        at: stringIndex,
                        effectiveRange: nil
                    ) as? UIColor {
                        backgrounds.append(Decoration(
                            rect: CGRect(
                                x: floor(x),
                                y: floor(baselineY - ascent),
                                width: ceil(width),
                                height: ceil(ascent + descent)
                            ),
                            color: color
                        ))
                    }

                    if attributedText.attribute(
                        .zynaStrikethrough,
                        at: stringIndex,
                        effectiveRange: nil
                    ) != nil {
                        let color = attributedText.attribute(
                            .foregroundColor,
                            at: stringIndex,
                            effectiveRange: nil
                        ) as? UIColor ?? .label
                        let font = attributedText.attribute(
                            .font,
                            at: stringIndex,
                            effectiveRange: nil
                        ) as? UIFont ?? UIFont.systemFont(ofSize: 16)
                        strikethroughs.append(Decoration(
                            rect: CGRect(
                                x: x,
                                y: floor(baselineY - font.xHeight / 2),
                                width: ceil(width),
                                height: max(1, ceil(font.pointSize / 16))
                            ),
                            color: color
                        ))
                    }
                }
            }
            return (backgrounds, strikethroughs)
        }

        private static func makeLinkHitRegions(
            attributedText: NSAttributedString,
            lines: [CTLine],
            origins: [CGPoint],
            height: CGFloat
        ) -> [LinkHitRegion] {
            var links: [(range: NSRange, url: URL)] = []
            attributedText.enumerateAttribute(
                .zynaLinkDestination,
                in: NSRange(location: 0, length: attributedText.length),
                options: []
            ) { value, range, _ in
                guard let destination = value as? String,
                      let url = URL(string: destination) else {
                    return
                }
                links.append((range, url))
            }
            guard !links.isEmpty else { return [] }

            var result: [LinkHitRegion] = []
            for (line, origin) in zip(lines, origins) {
                let cfRange = CTLineGetStringRange(line)
                guard cfRange.location != kCFNotFound,
                      cfRange.length > 0 else {
                    continue
                }
                let lineRange = NSRange(
                    location: cfRange.location,
                    length: cfRange.length
                )
                let verticalRect = lineRect(line: line, origin: origin, height: height)

                for link in links {
                    let intersection = NSIntersectionRange(lineRange, link.range)
                    guard intersection.length > 0 else { continue }

                    var secondaryStart: CGFloat = 0
                    var secondaryEnd: CGFloat = 0
                    let primaryStart = CTLineGetOffsetForStringIndex(
                        line,
                        intersection.location,
                        &secondaryStart
                    )
                    let primaryEnd = CTLineGetOffsetForStringIndex(
                        line,
                        NSMaxRange(intersection),
                        &secondaryEnd
                    )
                    let minOffset = min(
                        min(primaryStart, secondaryStart),
                        min(primaryEnd, secondaryEnd)
                    )
                    let maxOffset = max(
                        max(primaryStart, secondaryStart),
                        max(primaryEnd, secondaryEnd)
                    )
                    result.append(LinkHitRegion(
                        rect: CGRect(
                            x: origin.x + minOffset,
                            y: verticalRect.minY,
                            width: max(1, maxOffset - minOffset),
                            height: verticalRect.height
                        ),
                        url: link.url
                    ))
                }
            }
            return result
        }

        private static func makeQuoteBarRects(
            attributedText: NSAttributedString,
            lines: [CTLine],
            origins: [CGPoint],
            height: CGFloat
        ) -> [CGRect] {
            let barWidth: CGFloat = 2
            let quoteIndent: CGFloat = 12
            var result: [CGRect] = []
            var containsQuote = false
            attributedText.enumerateAttribute(
                .zynaQuoteDepth,
                in: NSRange(location: 0, length: attributedText.length),
                options: []
            ) { value, _, stop in
                if (value as? Int ?? 0) > 0 {
                    containsQuote = true
                    stop.pointee = true
                }
            }
            guard containsQuote else { return [] }

            for (line, origin) in zip(lines, origins) {
                let lineRange = CTLineGetStringRange(line)
                guard lineRange.location != kCFNotFound,
                      lineRange.length > 0 else {
                    continue
                }
                let range = NSIntersectionRange(
                    NSRange(location: lineRange.location, length: lineRange.length),
                    NSRange(location: 0, length: attributedText.length)
                )
                guard range.length > 0 else { continue }

                var quoteDepth = 0
                attributedText.enumerateAttribute(
                    .zynaQuoteDepth,
                    in: range,
                    options: []
                ) { value, _, _ in
                    quoteDepth = max(quoteDepth, value as? Int ?? 0)
                }
                guard quoteDepth > 0 else { continue }

                let lineRect = Self.lineRect(line: line, origin: origin, height: height)
                let verticalRect = CGRect(
                    x: 0,
                    y: floor(lineRect.minY),
                    width: barWidth,
                    height: ceil(lineRect.height)
                )
                for depth in 0..<quoteDepth {
                    let candidate = verticalRect.offsetBy(
                        dx: CGFloat(depth) * quoteIndent,
                        dy: 0
                    )
                    if let index = result.lastIndex(where: {
                        abs($0.minX - candidate.minX) < 0.5
                            && candidate.minY <= $0.maxY + 3
                    }) {
                        result[index] = result[index].union(candidate)
                    } else {
                        result.append(candidate)
                    }
                }
            }
            return result
        }

        private static func lineRect(
            line: CTLine,
            origin: CGPoint,
            height: CGFloat
        ) -> CGRect {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            ))
            return CGRect(
                x: origin.x,
                y: height - origin.y - ascent,
                width: width,
                height: ascent + descent + leading
            )
        }
    }

    fileprivate final class DrawParams: NSObject {
        let bodyText: NSAttributedString
        let forwardedHeaderText: NSAttributedString?
        let replyHeader: ReplyHeaderData?
        let timeText: NSAttributedString
        let statusIcon: MessageStatusIcon?
        let statusTintColor: UIColor
        let quoteBarColor: UIColor
        let maxTextWidth: CGFloat
        let preparedLayout: LayoutMetrics?

        init(
            bodyText: NSAttributedString,
            forwardedHeaderText: NSAttributedString?,
            replyHeader: ReplyHeaderData?,
            timeText: NSAttributedString,
            statusIcon: MessageStatusIcon?,
            statusTintColor: UIColor,
            quoteBarColor: UIColor,
            maxTextWidth: CGFloat,
            preparedLayout: LayoutMetrics?
        ) {
            self.bodyText = bodyText
            self.forwardedHeaderText = forwardedHeaderText
            self.replyHeader = replyHeader
            self.timeText = timeText
            self.statusIcon = statusIcon
            self.statusTintColor = statusTintColor
            self.quoteBarColor = quoteBarColor
            self.maxTextWidth = maxTextWidth
            self.preparedLayout = preparedLayout
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
    // Texture measures the full table data set. Keep CoreText frames in a
    // shared bounded cache instead of retaining one in every message node.
    private static let preparedLayoutCache: NSCache<PreparedLayoutCacheKey, PreparedLayoutBox> = {
        let cache = NSCache<PreparedLayoutCacheKey, PreparedLayoutBox>()
        cache.countLimit = 128
        return cache
    }()

    // MARK: - State

    private let bodyText: NSAttributedString
    private let forwardedHeaderText: NSAttributedString?
    private let replyHeader: ReplyHeaderData?
    private let timeText: NSAttributedString
    private let statusTintColor: UIColor
    private let quoteBarColor: UIColor
    private let maxTextWidth: CGFloat
    private let layoutState: Atomic<LayoutState>
    private let preparedLayoutCacheKey = PreparedLayoutCacheKey()
    private var appliedLayout: AppliedLayout?
    private var linkHitRegions: [LinkHitRegion] = []

    private(set) var replyHeaderFrame: CGRect?
    private(set) var bodyFrame: CGRect = .zero
    private(set) var quoteBarFrames: [CGRect] = []

    var statusIcon: MessageStatusIcon? {
        get { layoutState.withValue { $0.statusIcon } }
        set {
            let update = layoutState.withValue {
                state -> (old: MessageStatusIcon?, invalidated: Bool) in
                let oldValue = state.statusIcon
                guard oldValue != newValue else { return (oldValue, false) }
                state.statusIcon = newValue
                let invalidated = Self.statusGeometry(for: oldValue)
                    != Self.statusGeometry(for: newValue)
                if invalidated {
                    state.generation &+= 1
                    state.preparedGeometries.removeAll(keepingCapacity: false)
                }
                return (oldValue, invalidated)
            }
            guard update.old != newValue else { return }

            setNeedsDisplay()
            if update.invalidated {
                Self.preparedLayoutCache.removeObject(forKey: preparedLayoutCacheKey)
                setNeedsLayout()
            }
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
        quoteBarColor: UIColor,
        maxTextWidth: CGFloat
    ) {
        self.bodyText = bodyText
        self.forwardedHeaderText = forwardedHeaderText
        self.replyHeader = replyHeader
        self.timeText = timeText
        self.statusTintColor = statusTintColor
        self.quoteBarColor = quoteBarColor
        self.maxTextWidth = maxTextWidth
        self.layoutState = Atomic(LayoutState(statusIcon: statusIcon))
        super.init()
        isOpaque = false
        isLayerBacked = true
        style.flexShrink = 1
    }

    deinit {
        Self.preparedLayoutCache.removeObject(forKey: preparedLayoutCacheKey)
    }

    // MARK: - Layout

    override func calculateSizeThatFits(_ constrainedSize: CGSize) -> CGSize {
        let width = resolvedWidth(from: constrainedSize.width)
        let snapshot = layoutState.withValue { state in
            let geometry = Self.statusGeometry(for: state.statusIcon)
            let cachedSize = state.preparedGeometries.last(where: {
                $0.measuredWidth == width && $0.statusGeometry == geometry
            })?.geometry.size
            return (
                statusIcon: state.statusIcon,
                geometry: geometry,
                generation: state.generation,
                cachedSize: cachedSize
            )
        }
        if let cachedSize = snapshot.cachedSize {
            return cachedSize
        }

        let statusIcon = snapshot.statusIcon
        let layout = Self.makeLayout(
            width: width,
            maxTextWidth: maxTextWidth,
            bodyText: bodyText,
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            timeText: timeText,
            statusIcon: statusIcon
        )
        let prepared = PreparedLayout(
            statusGeometry: snapshot.geometry,
            metrics: layout
        )
        let accepted = layoutState.withValue { state -> Bool in
            guard state.generation == snapshot.generation,
                  Self.statusGeometry(for: state.statusIcon) == snapshot.geometry else {
                return false
            }
            state.preparedGeometries.removeAll {
                $0.measuredWidth == width && $0.statusGeometry == snapshot.geometry
            }
            state.preparedGeometries.append(PreparedGeometry(
                measuredWidth: width,
                statusGeometry: snapshot.geometry,
                geometry: LayoutGeometry(layout)
            ))
            if state.preparedGeometries.count > 2 {
                state.preparedGeometries.removeFirst(state.preparedGeometries.count - 2)
            }
            return true
        }
        if accepted {
            Self.preparedLayoutCache.setObject(
                PreparedLayoutBox(prepared),
                forKey: preparedLayoutCacheKey
            )
        }
        return layout.size
    }

    override func layout() {
        super.layout()
        let statusIcon = self.statusIcon
        let geometry = Self.statusGeometry(for: statusIcon)
        let applied = AppliedLayout(size: bounds.size, statusGeometry: geometry)
        guard appliedLayout != applied else { return }

        let preparedGeometry = layoutState.withValue { state in
            state.preparedGeometries.reversed().first(where: {
                $0.statusGeometry == geometry && $0.geometry.size == bounds.size
            })
        }
        let resolvedGeometry: LayoutGeometry
        if let preparedGeometry {
            resolvedGeometry = preparedGeometry.geometry
        } else {
            let fallback = Self.makeLayout(
                width: bounds.width,
                maxTextWidth: maxTextWidth,
                bodyText: bodyText,
                forwardedHeaderText: forwardedHeaderText,
                replyHeader: replyHeader,
                timeText: timeText,
                statusIcon: statusIcon
            )
            resolvedGeometry = LayoutGeometry(fallback)
            Self.preparedLayoutCache.setObject(
                PreparedLayoutBox(PreparedLayout(
                    statusGeometry: geometry,
                    metrics: fallback
                )),
                forKey: preparedLayoutCacheKey
            )
        }
        replyHeaderFrame = resolvedGeometry.replyRect
        bodyFrame = resolvedGeometry.bodyRect
        quoteBarFrames = resolvedGeometry.quoteBarRects.map {
            $0.offsetBy(dx: resolvedGeometry.bodyRect.minX, dy: resolvedGeometry.bodyRect.minY)
        }
        linkHitRegions = resolvedGeometry.linkHitRegions
        appliedLayout = applied
    }

    func linkURL(at point: CGPoint) -> URL? {
        guard bodyFrame.contains(point),
              bodyText.length > 0 else {
            return nil
        }

        let localPoint = CGPoint(
            x: point.x - bodyFrame.minX,
            y: point.y - bodyFrame.minY
        )
        return linkHitRegions.first(where: {
            $0.rect.insetBy(dx: -1, dy: -2).contains(localPoint)
        })?.url
    }

    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        let statusIcon = self.statusIcon
        let geometry = Self.statusGeometry(for: statusIcon)
        let cached = Self.preparedLayoutCache.object(forKey: preparedLayoutCacheKey)?.value
        let preparedLayout = cached.flatMap {
            $0.statusGeometry == geometry && $0.metrics.size == bounds.size
                ? $0.metrics
                : nil
        }
        return DrawParams(
            bodyText: bodyText,
            forwardedHeaderText: forwardedHeaderText,
            replyHeader: replyHeader,
            timeText: timeText,
            statusIcon: statusIcon,
            statusTintColor: statusTintColor,
            quoteBarColor: quoteBarColor,
            maxTextWidth: maxTextWidth,
            preparedLayout: preparedLayout
        )
    }

    override class func draw(_ bounds: CGRect, withParameters parameters: Any?,
                              isCancelled isCancelledBlock: () -> Bool, isRasterizing: Bool) {
        guard let params = parameters as? DrawParams else { return }

        let layout = params.preparedLayout ?? makeLayout(
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

        if let context = UIGraphicsGetCurrentContext() {
            layout.bodyLayout.draw(
                in: layout.bodyRect,
                quoteBarColor: params.quoteBarColor,
                context: context
            )
        }

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

    private static func statusGeometry(for icon: MessageStatusIcon?) -> StatusGeometry {
        StatusGeometry(
            hasSlot: icon != nil,
            drawHeight: statusDrawHeight(for: icon)
        )
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

        let bodyLayout = BodyTextLayout(
            attributedText: bodyText,
            width: availableWidth
        )
        let inlineMinWidth = bodyLayout.trailingLineWidth + timeSpacing + timeRowWidth
        let fitsInline = bodyLayout.lineCount > 0 && inlineMinWidth <= availableWidth
        let bodyWidth = max(
            bodyLayout.size.width,
            fitsInline ? inlineMinWidth : timeRowWidth
        )
        let bodyHeight = bodyLayout.size.height
            + (fitsInline ? 0 : timeRowHeight + textBottomTimeSpacing)

        let bodyRect = CGRect(
            x: 0,
            y: y,
            width: bodyWidth,
            height: bodyLayout.size.height
        ).integral
        contentWidth = max(contentWidth, bodyWidth)

        let totalHeight = y + bodyHeight
        let timeOriginY = fitsInline
            ? y + bodyLayout.size.height - timeRowHeight
            : y + bodyLayout.size.height + textBottomTimeSpacing
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
            bodyLayout: bodyLayout,
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

}

/// Reuses a frame without sharing it between overlapping display jobs.
/// Contended draws build a private frame instead of waiting for drawing
/// to finish. Geometry and hit testing never acquire this lock.
final class ReusableTextFrame {
    private let frame: CTFrame
    private let attributedText: NSAttributedString
    private let size: CGSize
    private let lock = NSLock()

    init(frame: CTFrame, attributedText: NSAttributedString, size: CGSize) {
        self.frame = frame
        self.attributedText = attributedText.copy() as! NSAttributedString
        self.size = size
    }

    func withExclusiveFrame<Result>(
        _ body: (CTFrame) throws -> Result
    ) rethrows -> Result {
        if lock.try() {
            defer { lock.unlock() }
            return try body(frame)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let privateFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            path,
            nil
        )
        return try body(privateFrame)
    }
}
