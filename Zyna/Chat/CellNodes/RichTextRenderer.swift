//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

extension NSAttributedString.Key {
    static let zynaLinkDestination = NSAttributedString.Key("com.zyna.richText.linkDestination")
    static let zynaQuoteDepth = NSAttributedString.Key("com.zyna.richText.quoteDepth")
    static let zynaCodeBackground = NSAttributedString.Key("com.zyna.richText.codeBackground")
    static let zynaStrikethrough = NSAttributedString.Key("com.zyna.richText.strikethrough")
}

enum RichTextRenderer {

    private enum FontFamily: Int {
        case system
        case monospaced
    }

    private final class FontCacheKey: NSObject {
        let family: FontFamily
        let pointSize: CGFloat
        let traits: UIFontDescriptor.SymbolicTraits

        init(
            family: FontFamily,
            pointSize: CGFloat,
            traits: UIFontDescriptor.SymbolicTraits
        ) {
            self.family = family
            self.pointSize = pointSize
            self.traits = traits
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(family.rawValue)
            hasher.combine(pointSize)
            hasher.combine(traits.rawValue)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? FontCacheKey else { return false }
            return family == other.family
                && pointSize == other.pointSize
                && traits == other.traits
        }
    }

    private static let fontCache: NSCache<FontCacheKey, UIFont> = {
        let cache = NSCache<FontCacheKey, UIFont>()
        cache.countLimit = 24
        return cache
    }()

    static func attributedString(
        from document: RichTextDocument,
        foregroundColor: UIColor,
        linkColor: UIColor,
        baseFontSize: CGFloat = 16
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: document.text,
            attributes: [
                .font: UIFont.systemFont(ofSize: baseFontSize),
                .foregroundColor: foregroundColor
            ]
        )
        let fullLength = result.length

        for run in document.runs {
            guard !run.style.isEmpty
                    || run.headingLevel != nil
                    || run.quoteDepth > 0
                    || run.listDepth > 0 else {
                continue
            }
            let range = clipped(run.range, to: fullLength)
            guard range.length > 0 else { continue }
            result.addAttributes(
                attributes(
                    for: run,
                    foregroundColor: foregroundColor,
                    baseFontSize: baseFontSize
                ),
                range: range
            )
        }

        for link in document.links {
            let range = clipped(link.range, to: fullLength)
            guard range.length > 0 else { continue }
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: linkColor,
                .underlineColor: linkColor,
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .zynaLinkDestination: link.destination
            ]
            if let url = URL(string: link.destination) {
                attributes[.link] = url
            }
            result.addAttributes(attributes, range: range)
        }

        return result
    }

    private static func attributes(
        for run: RichTextRun,
        foregroundColor: UIColor,
        baseFontSize: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        let fontSize = headingFontSize(level: run.headingLevel, base: baseFontSize)

        if run.style.contains(.codeBlock) || run.style.contains(.inlineCode) {
            attributes[.font] = cachedFont(
                family: .monospaced,
                pointSize: run.style.contains(.codeBlock)
                    ? max(14, fontSize - 1)
                    : fontSize,
                traits: []
            )
            attributes[.zynaCodeBackground] = foregroundColor.withAlphaComponent(0.10)
        } else {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.style.contains(.bold) || run.headingLevel != nil {
                traits.insert(.traitBold)
            }
            if run.style.contains(.italic) {
                traits.insert(.traitItalic)
            }
            if !traits.isEmpty || fontSize != baseFontSize {
                attributes[.font] = cachedFont(
                    family: .system,
                    pointSize: fontSize,
                    traits: traits
                )
            }
        }

        if run.style.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if run.style.contains(.strikethrough) {
            attributes[.zynaStrikethrough] = true
        }

        if run.quoteDepth > 0 || run.listDepth > 0 || run.style.contains(.codeBlock) {
            let paragraph = NSMutableParagraphStyle()
            let quoteInset = CGFloat(run.quoteDepth) * 12
            let listInset = CGFloat(run.listDepth) * 14
            let inset = quoteInset + listInset
            paragraph.firstLineHeadIndent = inset
            paragraph.headIndent = inset
            paragraph.paragraphSpacing = run.style.contains(.codeBlock) ? 3 : 1
            attributes[.paragraphStyle] = paragraph
        }
        if run.quoteDepth > 0 {
            attributes[.zynaQuoteDepth] = run.quoteDepth
        }

        return attributes
    }

    private static func cachedFont(
        family: FontFamily,
        pointSize: CGFloat,
        traits: UIFontDescriptor.SymbolicTraits
    ) -> UIFont {
        let key = FontCacheKey(
            family: family,
            pointSize: pointSize,
            traits: traits
        )
        if let cached = fontCache.object(forKey: key) {
            return cached
        }

        let font: UIFont
        switch family {
        case .system:
            let base = UIFont.systemFont(ofSize: pointSize)
            let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
                ?? base.fontDescriptor
            font = UIFont(descriptor: descriptor, size: pointSize)
        case .monospaced:
            font = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        }
        fontCache.setObject(font, forKey: key)
        return font
    }

    private static func headingFontSize(level: Int?, base: CGFloat) -> CGFloat {
        switch level {
        case 1: return base + 6
        case 2: return base + 4
        case 3: return base + 2
        case 4: return base + 1
        default: return base
        }
    }

    private static func clipped(_ range: NSRange, to length: Int) -> NSRange {
        guard range.location >= 0,
              range.location < length else {
            return NSRange(location: 0, length: 0)
        }
        return NSRange(
            location: range.location,
            length: min(range.length, length - range.location)
        )
    }
}
