//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Raw Matrix formatting kept next to a text-like message.
///
/// The parsed document is deliberately not stored here. `StoredMessage` can
/// be materialized on the main thread, while rich-text parsing belongs in a
/// background Texture node block or an indexing queue.
struct ChatTextMetadata: Equatable {
    static let matrixHTMLFormat = "org.matrix.custom.html"

    let format: String?
    let formattedBody: String?
}

struct RichTextStyle: OptionSet, Equatable, Hashable {
    let rawValue: UInt16

    static let bold = RichTextStyle(rawValue: 1 << 0)
    static let italic = RichTextStyle(rawValue: 1 << 1)
    static let underline = RichTextStyle(rawValue: 1 << 2)
    static let strikethrough = RichTextStyle(rawValue: 1 << 3)
    static let inlineCode = RichTextStyle(rawValue: 1 << 4)
    static let codeBlock = RichTextStyle(rawValue: 1 << 5)
}

struct RichTextRun: Equatable, Hashable {
    let location: Int
    let length: Int
    let style: RichTextStyle
    let headingLevel: Int?
    let quoteDepth: Int
    let listDepth: Int

    var range: NSRange {
        NSRange(location: location, length: length)
    }
}

struct RichTextLink: Equatable, Hashable {
    enum Origin: Equatable, Hashable {
        case explicit
        case detected
    }

    let location: Int
    let length: Int
    let destination: String
    let origin: Origin

    var range: NSRange {
        NSRange(location: location, length: length)
    }
}

struct RichTextDocument: Equatable, Hashable {
    let text: String
    let runs: [RichTextRun]
    let links: [RichTextLink]

    var hasLinks: Bool {
        !links.isEmpty
    }

    func prepending(_ prefix: String) -> RichTextDocument {
        guard !prefix.isEmpty else { return self }
        let offset = (prefix as NSString).length
        let prefixRun = RichTextRun(
            location: 0,
            length: offset,
            style: [],
            headingLevel: nil,
            quoteDepth: 0,
            listDepth: 0
        )
        return RichTextDocument(
            text: prefix + text,
            runs: [prefixRun] + runs.map {
                RichTextRun(
                    location: $0.location + offset,
                    length: $0.length,
                    style: $0.style,
                    headingLevel: $0.headingLevel,
                    quoteDepth: $0.quoteDepth,
                    listDepth: $0.listDepth
                )
            },
            links: links.map {
                RichTextLink(
                    location: $0.location + offset,
                    length: $0.length,
                    destination: $0.destination,
                    origin: $0.origin
                )
            }
        )
    }
}

enum MatrixRichTextParser {

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    static func parse(body: String, metadata: ChatTextMetadata?) -> RichTextDocument {
        let parsed: RichTextDocument
        if metadata?.format == ChatTextMetadata.matrixHTMLFormat,
           let html = metadata?.formattedBody,
           !html.isEmpty {
            var parser = MatrixHTMLParser()
            let htmlResult = parser.parse(html)

            // Structural HTML is also emitted for plain Zyna messages so
            // Matrix clients retain their line breaks. Prefer the plain body
            // unless the HTML adds actual rich-text semantics; this keeps a
            // local echo identical to the synced event, including whitespace.
            if htmlResult.hasRichTextSemantics {
                parsed = htmlResult.document.text.isEmpty && !body.isEmpty
                    ? plainDocument(body)
                    : htmlResult.document
            } else {
                parsed = plainDocument(
                    htmlResult.suppressedReplyFallback
                        ? removingPlainReplyFallback(from: body)
                        : body
                )
            }
        } else {
            parsed = plainDocument(body)
        }

        return addingDetectedLinks(to: parsed)
    }

    private static func plainDocument(_ text: String) -> RichTextDocument {
        let length = (text as NSString).length
        return RichTextDocument(
            text: text,
            runs: length == 0 ? [] : [
                RichTextRun(
                    location: 0,
                    length: length,
                    style: [],
                    headingLevel: nil,
                    quoteDepth: 0,
                    listDepth: 0
                )
            ],
            links: []
        )
    }

    private static func removingPlainReplyFallback(from body: String) -> String {
        let normalized = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.hasPrefix("> <@") else {
            return body
        }

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let separator = lines.firstIndex(where: { $0.isEmpty }),
              lines[..<separator].allSatisfy({ $0.hasPrefix(">") }) else {
            return body
        }
        return lines.dropFirst(separator + 1).joined(separator: "\n")
    }

    private static func addingDetectedLinks(to document: RichTextDocument) -> RichTextDocument {
        guard !document.text.isEmpty,
              document.text.contains(".") || document.text.contains(":"),
              let detector = linkDetector else {
            return document
        }

        let fullRange = NSRange(location: 0, length: (document.text as NSString).length)
        var links = document.links
        detector.enumerateMatches(
            in: document.text,
            options: [],
            range: fullRange
        ) { result, _, _ in
            guard let result,
                  let url = result.url,
                  let destination = RichTextURLPolicy.destination(from: url.absoluteString),
                  !links.contains(where: { NSIntersectionRange($0.range, result.range).length > 0 })
            else {
                return
            }
            links.append(RichTextLink(
                location: result.range.location,
                length: result.range.length,
                destination: destination,
                origin: .detected
            ))
        }

        links.sort {
            if $0.location != $1.location { return $0.location < $1.location }
            return $0.length < $1.length
        }
        return RichTextDocument(text: document.text, runs: document.runs, links: links)
    }
}

enum RichTextURLPolicy {
    private static let allowedSchemes: Set<String> = ["http", "https"]

    static func destination(from rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme),
              components.host?.isEmpty == false,
              let url = components.url else {
            return nil
        }
        return url.absoluteString
    }
}

// MARK: - Matrix HTML subset

private struct MatrixHTMLParseResult {
    let document: RichTextDocument
    let hasRichTextSemantics: Bool
    let suppressedReplyFallback: Bool
}

private struct MatrixHTMLParser {

    private struct Context: Equatable {
        var style: RichTextStyle = []
        var headingLevel: Int?
        var quoteDepth = 0
        var listDepth = 0
        var linkDestination: String?

        var preservesWhitespace: Bool {
            style.contains(.codeBlock)
        }
    }

    private struct Element {
        let name: String
        let previousContext: Context
    }

    private struct ListState {
        let ordered: Bool
        var nextNumber: Int
    }

    private var text = NSMutableString()
    private var runs: [RichTextRun] = []
    private var links: [RichTextLink] = []
    private var context = Context()
    private var elements: [Element] = []
    private var lists: [ListState] = []
    private var suppressionDepth = 0
    private var hasRichTextSemantics = false
    private var suppressedReplyFallback = false

    mutating func parse(_ html: String) -> MatrixHTMLParseResult {
        var cursor = html.startIndex
        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                let nextTag = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                if suppressionDepth == 0 {
                    appendText(String(html[cursor..<nextTag]))
                }
                cursor = nextTag
                continue
            }

            if html[cursor...].hasPrefix("<!--") {
                if let commentEnd = html[cursor...].range(of: "-->")?.upperBound {
                    cursor = commentEnd
                } else {
                    break
                }
                continue
            }

            guard let end = tagEnd(in: html, after: cursor) else {
                if suppressionDepth == 0 {
                    appendText("<")
                }
                cursor = html.index(after: cursor)
                continue
            }

            let contentStart = html.index(after: cursor)
            handleTag(String(html[contentStart..<end]))
            cursor = html.index(after: end)
        }

        trimTrailingLayoutCharacters()
        return MatrixHTMLParseResult(
            document: RichTextDocument(text: text as String, runs: runs, links: links),
            hasRichTextSemantics: hasRichTextSemantics,
            suppressedReplyFallback: suppressedReplyFallback
        )
    }

    private func tagEnd(in html: String, after opening: String.Index) -> String.Index? {
        var index = html.index(after: opening)
        var quote: Character?
        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    private mutating func handleTag(_ rawTag: String) {
        let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("!") else {
            return
        }

        let isClosing = trimmed.hasPrefix("/")
        var body = isClosing ? String(trimmed.dropFirst()) : trimmed
        let explicitSelfClosing = body.hasSuffix("/")
        if explicitSelfClosing {
            body.removeLast()
        }

        let parsed = parseTagBody(body)
        let name = parsed.name
        guard !name.isEmpty else { return }
        let isVoid = Self.voidElements.contains(name)
        let isSelfClosing = explicitSelfClosing || isVoid

        if suppressionDepth > 0 {
            if isClosing {
                suppressionDepth -= 1
            } else if !isSelfClosing {
                suppressionDepth += 1
            }
            return
        }

        if name == "mx-reply" {
            if !isClosing {
                suppressedReplyFallback = true
                if !isSelfClosing {
                    suppressionDepth = 1
                }
            }
            return
        }

        if isClosing {
            closeElement(named: name)
        } else {
            openElement(named: name, attributes: parsed.attributes, isSelfClosing: isSelfClosing)
        }
    }

    private mutating func openElement(
        named name: String,
        attributes: [String: String],
        isSelfClosing: Bool
    ) {
        let previous = context

        switch name {
        case "strong", "b":
            context.style.insert(.bold)
            hasRichTextSemantics = true
        case "em", "i":
            context.style.insert(.italic)
            hasRichTextSemantics = true
        case "u":
            context.style.insert(.underline)
            hasRichTextSemantics = true
        case "del", "s", "strike":
            context.style.insert(.strikethrough)
            hasRichTextSemantics = true
        case "code":
            if !context.style.contains(.codeBlock) {
                context.style.insert(.inlineCode)
            }
            hasRichTextSemantics = true
        case "pre":
            ensureLineBreak()
            context.style.insert(.codeBlock)
            context.style.remove(.inlineCode)
            hasRichTextSemantics = true
        case "blockquote":
            ensureLineBreak()
            context.quoteDepth += 1
            hasRichTextSemantics = true
        case "h1", "h2", "h3", "h4", "h5", "h6":
            ensureLineBreak()
            context.headingLevel = Int(name.dropFirst())
            context.style.insert(.bold)
            hasRichTextSemantics = true
        case "p", "div":
            ensureLineBreak()
        case "br":
            append("\n")
        case "hr":
            ensureLineBreak()
            append("—")
            ensureLineBreak()
            hasRichTextSemantics = true
        case "a":
            if let href = attributes["href"],
               let destination = RichTextURLPolicy.destination(from: href) {
                context.linkDestination = destination
                hasRichTextSemantics = true
            }
        case "ul":
            ensureLineBreak()
            lists.append(ListState(ordered: false, nextNumber: 1))
            context.listDepth = lists.count
            hasRichTextSemantics = true
        case "ol":
            ensureLineBreak()
            let start = attributes["start"].flatMap(Int.init) ?? 1
            lists.append(ListState(ordered: true, nextNumber: max(1, start)))
            context.listDepth = lists.count
            hasRichTextSemantics = true
        case "li":
            ensureLineBreak()
            context.listDepth = max(context.listDepth, lists.count)
            if var list = lists.popLast() {
                let marker = list.ordered ? "\(list.nextNumber). " : "• "
                append(marker)
                if list.ordered && list.nextNumber < Int.max {
                    list.nextNumber += 1
                }
                lists.append(list)
            } else {
                append("• ")
            }
            hasRichTextSemantics = true
        case "img":
            if let alt = attributes["alt"], !alt.isEmpty {
                append(alt)
            }
        default:
            break
        }

        if !isSelfClosing {
            elements.append(Element(name: name, previousContext: previous))
        }
    }

    private mutating func closeElement(named name: String) {
        guard let index = elements.lastIndex(where: { $0.name == name }) else {
            return
        }

        switch name {
        case "p", "div", "pre", "blockquote",
             "h1", "h2", "h3", "h4", "h5", "h6", "li":
            ensureLineBreak()
        case "ul", "ol":
            ensureLineBreak()
            if !lists.isEmpty {
                lists.removeLast()
            }
        default:
            break
        }

        let previous = elements[index].previousContext
        elements.removeSubrange(index...)
        context = previous
        context.listDepth = lists.count
    }

    private mutating func appendText(_ rawText: String) {
        let decoded = decodeHTMLEntities(rawText)
        guard !decoded.isEmpty else { return }

        if context.preservesWhitespace {
            append(decoded.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n"))
            return
        }

        var pendingSpace = false
        var buffer = ""
        for scalar in decoded.unicodeScalars {
            let isCollapsibleWhitespace = scalar.value != 0x00A0
                && CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isCollapsibleWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace,
               text.length > 0 || !buffer.isEmpty,
               !(buffer.last == " " || buffer.last == "\n"
                 || (buffer.isEmpty && (text.hasSuffix(" ") || text.hasSuffix("\n")))) {
                buffer.append(" ")
            }
            pendingSpace = false
            buffer.unicodeScalars.append(scalar)
        }
        if pendingSpace,
           text.length > 0 || !buffer.isEmpty,
           !(buffer.last == " " || buffer.last == "\n"
             || (buffer.isEmpty && (text.hasSuffix(" ") || text.hasSuffix("\n")))) {
            buffer.append(" ")
        }
        append(buffer)
    }

    private mutating func append(_ value: String) {
        guard !value.isEmpty else { return }
        let start = text.length
        text.append(value)
        let length = text.length - start
        let run = RichTextRun(
            location: start,
            length: length,
            style: context.style,
            headingLevel: context.headingLevel,
            quoteDepth: context.quoteDepth,
            listDepth: context.listDepth
        )
        if let last = runs.last,
           last.location + last.length == start,
           last.style == run.style,
           last.headingLevel == run.headingLevel,
           last.quoteDepth == run.quoteDepth,
           last.listDepth == run.listDepth {
            runs[runs.count - 1] = RichTextRun(
                location: last.location,
                length: last.length + length,
                style: last.style,
                headingLevel: last.headingLevel,
                quoteDepth: last.quoteDepth,
                listDepth: last.listDepth
            )
        } else {
            runs.append(run)
        }

        if let destination = context.linkDestination {
            let link = RichTextLink(
                location: start,
                length: length,
                destination: destination,
                origin: .explicit
            )
            if let last = links.last,
               last.location + last.length == start,
               last.destination == destination,
               last.origin == .explicit {
                links[links.count - 1] = RichTextLink(
                    location: last.location,
                    length: last.length + length,
                    destination: destination,
                    origin: .explicit
                )
            } else {
                links.append(link)
            }
        }
    }

    private mutating func ensureLineBreak() {
        trimTrailingSpaces()
        guard text.length > 0,
              !text.hasSuffix("\n") else {
            return
        }
        append("\n")
    }

    private mutating func trimTrailingSpaces() {
        while text.length > 0,
              text.substring(with: NSRange(location: text.length - 1, length: 1)) == " " {
            truncate(to: text.length - 1)
        }
    }

    private mutating func trimTrailingLayoutCharacters() {
        while text.length > 0 {
            let last = text.substring(with: NSRange(location: text.length - 1, length: 1))
            guard last == " " || last == "\n" else { break }
            truncate(to: text.length - 1)
        }
    }

    private mutating func truncate(to newLength: Int) {
        guard newLength < text.length else { return }
        text.deleteCharacters(in: NSRange(location: newLength, length: text.length - newLength))
        runs = runs.compactMap { run in
            guard run.location < newLength else { return nil }
            return RichTextRun(
                location: run.location,
                length: min(run.length, newLength - run.location),
                style: run.style,
                headingLevel: run.headingLevel,
                quoteDepth: run.quoteDepth,
                listDepth: run.listDepth
            )
        }
        links = links.compactMap { link in
            guard link.location < newLength else { return nil }
            return RichTextLink(
                location: link.location,
                length: min(link.length, newLength - link.location),
                destination: link.destination,
                origin: link.origin
            )
        }
    }

    private func parseTagBody(_ body: String) -> (name: String, attributes: [String: String]) {
        var scanner = HTMLAttributeScanner(body)
        let name = scanner.readName().lowercased()
        return (name, scanner.readAttributes())
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        HTMLEntityDecoder.decode(value)
    }

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]
}

private struct HTMLAttributeScanner {
    private let source: String
    private var index: String.Index

    init(_ source: String) {
        self.source = source
        self.index = source.startIndex
    }

    mutating func readName() -> String {
        skipWhitespace()
        let start = index
        while index < source.endIndex,
              !source[index].isWhitespace,
              source[index] != "/" {
            index = source.index(after: index)
        }
        return String(source[start..<index])
    }

    mutating func readAttributes() -> [String: String] {
        var result: [String: String] = [:]
        while index < source.endIndex {
            skipWhitespace()
            guard index < source.endIndex,
                  source[index] != "/" else {
                break
            }

            let keyStart = index
            while index < source.endIndex,
                  !source[index].isWhitespace,
                  source[index] != "=",
                  source[index] != "/" {
                index = source.index(after: index)
            }
            let key = String(source[keyStart..<index]).lowercased()
            skipWhitespace()

            guard index < source.endIndex,
                  source[index] == "=" else {
                if !key.isEmpty {
                    result[key] = ""
                }
                continue
            }
            index = source.index(after: index)
            skipWhitespace()

            let value: String
            if index < source.endIndex,
               source[index] == "\"" || source[index] == "'" {
                let quote = source[index]
                index = source.index(after: index)
                let valueStart = index
                while index < source.endIndex, source[index] != quote {
                    index = source.index(after: index)
                }
                value = String(source[valueStart..<index])
                if index < source.endIndex {
                    index = source.index(after: index)
                }
            } else {
                let valueStart = index
                while index < source.endIndex,
                      !source[index].isWhitespace,
                      source[index] != "/" {
                    index = source.index(after: index)
                }
                value = String(source[valueStart..<index])
            }
            if !key.isEmpty {
                result[key] = HTMLEntityDecoder.decode(value)
            }
        }
        return result
    }

    private mutating func skipWhitespace() {
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
    }
}

private enum HTMLEntityDecoder {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©",
        "reg": "®", "trade": "™", "laquo": "«", "raquo": "»",
        "middot": "·", "bull": "•"
    ]

    static func decode(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        var cursor = value.startIndex

        while cursor < value.endIndex {
            guard value[cursor] == "&",
                  let semicolon = value[cursor...].firstIndex(of: ";"),
                  value.distance(from: cursor, to: semicolon) <= 16 else {
                result.append(value[cursor])
                cursor = value.index(after: cursor)
                continue
            }

            let nameStart = value.index(after: cursor)
            let entity = String(value[nameStart..<semicolon])
            if let decoded = decodeEntity(entity) {
                result.append(decoded)
                cursor = value.index(after: semicolon)
            } else {
                result.append("&")
                cursor = value.index(after: cursor)
            }
        }
        return result
    }

    private static func decodeEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return scalarString(String(entity.dropFirst(2)), radix: 16)
        }
        if entity.hasPrefix("#") {
            return scalarString(String(entity.dropFirst()), radix: 10)
        }
        return named[entity.lowercased()]
    }

    private static func scalarString(_ value: String, radix: Int) -> String? {
        guard let number = UInt32(value, radix: radix),
              let scalar = UnicodeScalar(number),
              !CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }
        return String(scalar)
    }
}
