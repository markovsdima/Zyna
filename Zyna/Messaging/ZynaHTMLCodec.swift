//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit

/// Encodes and decodes `ZynaMessageAttributes` as an HTML `<span>` carrier
/// inside Matrix `formatted_body`. All Zyna-specific data rides in a
/// single hidden element:
///
/// ```html
/// Hello<span data-zyna='{"v":1,"color":"#FF0000",...}'></span>
/// ```
///
/// Why one span with a JSON blob (rather than many `data-zyna-*` atomic
/// attributes): unified parsing, trivial round-trip, easy versioning,
/// stable against HTML sanitisers in foreign clients.
///
/// Foreign Matrix clients (Element, SchildiChat, …) render only the
/// text before the span — the empty span with an unknown `data-zyna`
/// attribute is ignored visually. The raw event content is preserved
/// through federation intact, so Zyna can always recover the data.
enum ZynaHTMLCodec {

    /// Current schema version. Bump only on breaking changes to the
    /// JSON shape (rename of a field, changed semantics). Additive
    /// changes (new optional field) do not need a bump — older readers
    /// ignore unknown keys naturally.
    static let currentVersion = 1

    /// The HTML attribute name used on the carrier `<span>`.
    static let dataAttributeName = "data-zyna"

    // MARK: - Encode

    /// Appends a hidden carrier `<span>` with Zyna attributes to the
    /// existing HTML body. Returns `userHTML` unchanged if attributes
    /// are empty.
    static func encode(
        userHTML: String,
        attributes: ZynaMessageAttributes
    ) -> String {
        guard !attributes.isEmpty else { return userHTML }
        guard let json = buildJSON(from: attributes) else { return userHTML }
        let escaped = escapeForHTMLAttribute(json)
        return userHTML + "<span \(dataAttributeName)=\"\(escaped)\"></span>"
    }

    // MARK: - Decode

    /// Extracts Zyna attributes from the raw HTML of a received event's
    /// `formatted_body`. Returns an empty struct if no carrier found
    /// or the payload is malformed.
    static func decode(htmlBody: String) -> ZynaMessageAttributes {
        guard let raw = extractDataZynaValue(from: htmlBody),
              let json = unescapeFromHTMLAttribute(raw).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return ZynaMessageAttributes() }

        return buildAttributes(from: root)
    }

    // MARK: - JSON shape

    /// JSON keys used inside the carrier. One source of truth.
    private enum JSONKey {
        static let version = "v"
        static let color = "color"
        static let checklist = "checklist"
        static let callSignal = "call"
        static let forwardedFrom = "fwd"
    }

    private static func buildJSON(from attrs: ZynaMessageAttributes) -> String? {
        var obj: [String: Any] = [JSONKey.version: currentVersion]

        if let color = attrs.color {
            obj[JSONKey.color] = color.hexString
        }

        if let checklist = attrs.checklist, !checklist.isEmpty {
            obj[JSONKey.checklist] = checklist.map {
                ["text": $0.text, "checked": $0.checked]
            }
        }

        if let signal = attrs.callSignal {
            obj[JSONKey.callSignal] = [
                "type": signal.type,
                "payload": signal.payload
            ] as [String: Any]
        }

        if let fwd = attrs.forwardedFrom {
            obj[JSONKey.forwardedFrom] = fwd
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys]
        ), let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func buildAttributes(from obj: [String: Any]) -> ZynaMessageAttributes {
        var result = ZynaMessageAttributes()

        if let hex = obj[JSONKey.color] as? String {
            result.color = UIColor.fromHexString(hex)
        }

        if let arr = obj[JSONKey.checklist] as? [[String: Any]] {
            result.checklist = arr.compactMap { dict -> ChecklistItem? in
                guard let text = dict["text"] as? String,
                      let checked = dict["checked"] as? Bool else { return nil }
                return ChecklistItem(text: text, checked: checked)
            }
        }

        if let s = obj[JSONKey.callSignal] as? [String: Any],
           let type = s["type"] as? String,
           let payload = s["payload"] as? String {
            result.callSignal = CallSignalData(type: type, payload: payload)
        }

        if let fwd = obj[JSONKey.forwardedFrom] as? String {
            result.forwardedFrom = fwd
        }

        return result
    }

    // MARK: - HTML attribute escaping

    /// Escapes a string for safe use as an HTML attribute value
    /// enclosed in double quotes.
    static func escapeForHTMLAttribute(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        return result
    }

    static func unescapeFromHTMLAttribute(_ s: String) -> String {
        var result = s
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }

    // MARK: - Extraction from raw HTML

    /// Finds a `<span data-zyna="VALUE" …>` (or with single-quoted value)
    /// anywhere in the HTML body and returns VALUE (still HTML-escaped).
    /// Uses a regex scoped to the data-zyna attribute only, to avoid
    /// false matches inside user-authored attribute values.
    static func extractDataZynaValue(from html: String) -> String? {
        // Matches: data-zyna="..." or data-zyna='...'
        // We look inside any tag; Zyna puts this on a `<span>` but the
        // regex is attribute-scoped so it works regardless of tag.
        let pattern = #"data-zyna\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: nsRange) else {
            return nil
        }
        // Group 1 is double-quoted value, group 2 is single-quoted.
        for i in 1...2 {
            let range = match.range(at: i)
            if range.location != NSNotFound, let r = Range(range, in: html) {
                return String(html[r])
            }
        }
        return nil
    }
}
