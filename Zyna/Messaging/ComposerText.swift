//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

extension NSAttributedString.Key {
    /// Authoring intent survives TextKit replacing fonts for fallback glyphs.
    static let zynaComposerStyle = NSAttributedString.Key("ZynaComposerStyle")
}

/// A transportable snapshot of the editor, independent of its fonts and theme.
/// HTML contains only supported message formatting, never UIKit's HTML export.
struct ComposerText: Codable, Equatable, Sendable {
    let body: String
    var formattedBody: String? = nil

    var metadata: ChatTextMetadata? {
        formattedBody.map { ChatTextMetadata(format: ChatTextMetadata.matrixHTMLFormat, formattedBody: $0) }
    }

    init(body: String, formattedBody: String? = nil) {
        self.body = body
        self.formattedBody = formattedBody
    }

    init(body: String, metadata: ChatTextMetadata?) {
        self.init(body: body, formattedBody: metadata?.matrixHTML)
    }

    init(attributedText: NSAttributedString, trimming: Bool = false) {
        let attributedText = Self.normalizingNewlines(attributedText)
        let source: NSAttributedString
        if trimming {
            let string = attributedText.string as NSString
            let start = string.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
            let end = string.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
            source = start.location == NSNotFound ? NSAttributedString(string: "")
                : attributedText.attributedSubstring(from: NSRange(
                    location: start.location, length: NSMaxRange(end) - start.location
                ))
        } else {
            source = attributedText
        }
        body = source.string
        let units = Array(body.utf16)
        var htmlUnits = units
        for i in units.indices {
            // Keep a one-to-one UTF-16 mapping. HTML has no inline tab stops;
            // encode tabs as non-collapsing gaps and restore them from body.
            if units[i] == 9 {
                htmlUnits[i] = 0x00a0
            } else if units[i] == 0x2028 || units[i] == 0x2029 {
                htmlUnits[i] = 10
            } else if units[i] == 32 {
                // Preserve indentation/repeated spaces while keeping ordinary
                // word separators breakable in other Matrix clients.
                if i == 0 || [9, 10, 32, 0x2028, 0x2029].contains(units[i - 1])
                    || i == units.count - 1 || [10, 0x2028, 0x2029].contains(units[i + 1]) {
                    htmlUnits[i] = 0x00a0
                }
            }
        }
        let htmlText = String(decoding: htmlUnits, as: UTF16.self) as NSString
        var spans: [(range: NSRange, style: RichTextStyle, destination: String?)] = []
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            let style = Self.style(in: attributes)
            let destination = Self.link(in: attributes)
            // Fonts, colors and TextKit's private attributes can split a single
            // semantic span. Coalesce it before comparing edits or sending HTML.
            if let last = spans.last, last.style == style, last.destination == destination {
                spans[spans.count - 1].range.length += range.length
            } else {
                spans.append((range, style, destination))
            }
        }
        var html = ""
        var hasFormatting = false
        for span in spans {
            var text = Self.escape(htmlText.substring(with: span.range))
                .replacingOccurrences(of: "\n", with: "<br>")
                .replacingOccurrences(of: "\u{00a0}", with: "&#160;")
            for (flag, tag): (RichTextStyle, String) in [
                (.bold, "strong"), (.italic, "em"), (.underline, "u"),
                (.strikethrough, "del"), (.inlineCode, "code")
            ] where span.style.contains(flag) {
                text = "<\(tag)>\(text)</\(tag)>"
                hasFormatting = true
            }
            if let destination = span.destination {
                text = "<a href=\"\(Self.escape(destination))\">\(text)</a>"
                hasFormatting = true
            }
            html += text
        }
        formattedBody = hasFormatting ? html : nil
    }

    func attributedText(color: UIColor) -> NSAttributedString {
        let document = MatrixRichTextParser.parse(body: body, metadata: metadata)
        let result = NSMutableAttributedString(string: document.text, attributes: Self.attributes(style: [], color: color))
        for run in document.runs where NSMaxRange(run.range) <= result.length {
            result.addAttributes(Self.attributes(style: run.style, color: color), range: run.range)
        }
        for link in document.links where link.origin == .explicit && NSMaxRange(link.range) <= result.length {
            result.addAttribute(.link, value: link.destination, range: link.range)
        }
        return result
    }

    static func style(in attributes: [NSAttributedString.Key: Any]) -> RichTextStyle {
        if let semantic = attributes[.zynaComposerStyle] as? NSNumber {
            return RichTextStyle(rawValue: semantic.uint16Value)
        }
        // Foreign attributed text has no composer metadata. Infer its supported
        // appearance once at import; our own text always carries semantic style.
        var result: RichTextStyle = []
        if let font = attributes[.font] as? UIFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.traitBold) { result.insert(.bold) }
            if traits.contains(.traitItalic) { result.insert(.italic) }
            if traits.contains(.traitMonoSpace) { result.insert(.inlineCode) }
        }
        if (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0 { result.insert(.underline) }
        if (attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0 { result.insert(.strikethrough) }
        return result
    }

    static func attributes(style: RichTextStyle, color: UIColor) -> [NSAttributedString.Key: Any] {
        // The flat composer imports preformatted blocks as inline monospace;
        // block structure is not an editable style yet.
        var style = style
        if style.contains(.codeBlock) {
            style.remove(.codeBlock)
            style.insert(.inlineCode)
        }
        let base = style.contains(.inlineCode)
            ? UIFont.monospacedSystemFont(ofSize: 16, weight: .regular) : UIFont.systemFont(ofSize: 16)
        var traits = base.fontDescriptor.symbolicTraits
        if style.contains(.bold) { traits.insert(.traitBold) }
        if style.contains(.italic) { traits.insert(.traitItalic) }
        let font = base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: 16) } ?? base
        return [
            .zynaComposerStyle: NSNumber(value: style.rawValue),
            .font: font, .foregroundColor: color,
            .underlineStyle: style.contains(.underline) ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: style.contains(.strikethrough) ? NSUnderlineStyle.single.rawValue : 0
        ]
    }

    static func sanitizedPastedText(_ text: NSAttributedString, color: UIColor) -> NSAttributedString {
        let source = normalizingNewlines(text)
        let string = source.string as NSString
        let result = NSMutableAttributedString(string: "")
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            // Attachments have their own composer flow. Preserve text directly,
            // without HTML whitespace rules or automatic link detection.
            guard attributes[.attachment] == nil else { return }
            var supported = Self.attributes(style: style(in: attributes), color: color)
            supported[.link] = link(in: attributes)
            result.append(NSAttributedString(
                string: string.substring(with: range), attributes: supported
            ))
        }
        return result
    }

    private static func link(in attributes: [NSAttributedString.Key: Any]) -> String? {
        let raw = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
        return raw.flatMap(RichTextURLPolicy.destination)
    }

    private static func escape(_ text: String) -> String {
        ZynaHTMLCodec.escapeForHTMLAttribute(text)
    }

    private static func normalizingNewlines(_ text: NSAttributedString) -> NSAttributedString {
        // CRLF is one Swift Character; inspect UTF-16 to catch both forms.
        guard text.string.utf16.contains(13) else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        result.mutableString.replaceOccurrences(of: "\r\n", with: "\n", options: [], range: NSRange(location: 0, length: result.length))
        result.mutableString.replaceOccurrences(of: "\r", with: "\n", options: [], range: NSRange(location: 0, length: result.length))
        return result
    }
}
