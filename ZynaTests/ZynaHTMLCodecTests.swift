//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Testing
import Foundation
import UIKit
@testable import Zyna

@Suite("ZynaHTMLCodec")
struct ZynaHTMLCodecTests {

    // MARK: - Empty attributes

    @Test("Empty attributes: HTML unchanged, no carrier span")
    func emptyAttributes() {
        let result = ZynaHTMLCodec.encode(
            userHTML: "Hello",
            attributes: ZynaMessageAttributes()
        )
        #expect(result == "Hello")
        #expect(!result.contains("data-zyna"))
    }

    @Test("Empty checklist treated as empty")
    func emptyChecklist() {
        let attrs = ZynaMessageAttributes(checklist: [])
        #expect(attrs.isEmpty)
    }

    // MARK: - Color

    @Test("Color round-trip")
    func colorRoundTrip() {
        let red = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        let html = ZynaHTMLCodec.encode(
            userHTML: "Hi",
            attributes: ZynaMessageAttributes(color: red)
        )
        #expect(html.hasPrefix("Hi"))
        #expect(html.contains("data-zyna"))
        #expect(html.contains("#FF0000"))

        let decoded = ZynaHTMLCodec.decode(htmlBody: html)
        #expect(decoded.color?.hexString == "#FF0000")
        #expect(decoded.checklist == nil)
        #expect(decoded.callSignal == nil)
    }

    // MARK: - Checklist

    @Test("Checklist round-trip")
    func checklistRoundTrip() {
        let items = [
            ChecklistItem(text: "buy milk", checked: false),
            ChecklistItem(text: "call mom", checked: true)
        ]
        let html = ZynaHTMLCodec.encode(
            userHTML: "Todo",
            attributes: ZynaMessageAttributes(checklist: items)
        )
        let decoded = ZynaHTMLCodec.decode(htmlBody: html)
        #expect(decoded.checklist == items)
    }

    // MARK: - Call signal

    @Test("Call signal (ICE candidate) round-trip")
    func callSignalRoundTrip() {
        let signal = CallSignalData(
            type: "ice-candidate",
            callId: "call-123",
            sdp: nil,
            candidate: "candidate:foundation 1 udp 2130706431 192.168.1.1 54321 typ host"
        )
        let html = ZynaHTMLCodec.encode(
            userHTML: "📞",
            attributes: ZynaMessageAttributes(callSignal: signal)
        )
        let decoded = ZynaHTMLCodec.decode(htmlBody: html)
        #expect(decoded.callSignal == signal)
    }

    @Test("Call signal (offer with SDP) round-trip")
    func callOfferRoundTrip() {
        let signal = CallSignalData(
            type: "offer",
            callId: "call-abc",
            sdp: "v=0\r\no=- 123 2 IN IP4 0.0.0.0\r\n",
            candidate: nil
        )
        let html = ZynaHTMLCodec.encode(
            userHTML: "📞",
            attributes: ZynaMessageAttributes(callSignal: signal)
        )
        let decoded = ZynaHTMLCodec.decode(htmlBody: html)
        #expect(decoded.callSignal?.sdp == signal.sdp)
        #expect(decoded.callSignal?.candidate == nil)
    }

    // MARK: - All fields

    @Test("All attributes together round-trip")
    func allFieldsRoundTrip() {
        let attrs = ZynaMessageAttributes(
            color: UIColor(red: 0, green: 0.5, blue: 1, alpha: 1),
            checklist: [ChecklistItem(text: "x", checked: true)],
            callSignal: nil
        )
        let html = ZynaHTMLCodec.encode(userHTML: "Hello", attributes: attrs)
        let decoded = ZynaHTMLCodec.decode(htmlBody: html)
        #expect(decoded.color?.hexString == "#0080FF")
        #expect(decoded.checklist?.count == 1)
        #expect(decoded.checklist?.first?.text == "x")
        #expect(decoded.checklist?.first?.checked == true)
    }

    // MARK: - HTML preservation

    @Test("User HTML with formatting is preserved")
    func userHTMLPreserved() {
        let userHTML = "<b>Bold</b> and <i>italic</i>"
        let html = ZynaHTMLCodec.encode(
            userHTML: userHTML,
            attributes: ZynaMessageAttributes(color: .red)
        )
        #expect(html.hasPrefix(userHTML))
    }

    @Test("User HTML with quotes doesn't break carrier extraction")
    func userHTMLWithQuotes() {
        let userHTML = #"<a href="https://example.com">link</a>"#
        let attrs = ZynaMessageAttributes(color: UIColor.red)
        let html = ZynaHTMLCodec.encode(userHTML: userHTML, attributes: attrs)
        let decoded = ZynaHTMLCodec.decode(htmlBody: html)
        #expect(decoded.color?.hexString == "#FF0000")
    }

    // MARK: - Decoding edge cases

    @Test("Decode empty HTML returns empty attributes")
    func decodeEmpty() {
        let decoded = ZynaHTMLCodec.decode(htmlBody: "")
        #expect(decoded.isEmpty)
    }

    @Test("Decode HTML without carrier returns empty")
    func decodeNoCarrier() {
        let decoded = ZynaHTMLCodec.decode(htmlBody: "<b>Just text</b>")
        #expect(decoded.isEmpty)
    }

    @Test("Decode malformed JSON returns empty")
    func decodeMalformedJSON() {
        let decoded = ZynaHTMLCodec.decode(
            htmlBody: #"Hi<span data-zyna="not json"></span>"#
        )
        #expect(decoded.isEmpty)
    }

    @Test("Decode tolerates unknown keys (forward-compat)")
    func decodeUnknownKeys() {
        // Simulates a future Zyna version adding new keys.
        let html = #"Hi<span data-zyna="{&quot;v&quot;:99,&quot;color&quot;:&quot;#FF0000&quot;,&quot;futureThing&quot;:&quot;ignoreMe&quot;}"></span>"#
        let decoded = ZynaHTMLCodec.decode(htmlBody: html)
        #expect(decoded.color?.hexString == "#FF0000")
    }

    @Test("Decode finds carrier anywhere in the HTML")
    func decodeCarrierAnywhere() {
        // Attribute span could appear at any position — parser must find it.
        let html = #"<span data-zyna="{&quot;v&quot;:1,&quot;color&quot;:&quot;#00FF00&quot;}"></span>Hello world"#
        let decoded = ZynaHTMLCodec.decode(htmlBody: html)
        #expect(decoded.color?.hexString == "#00FF00")
    }

    // MARK: - JSON shape stability

    @Test("Encoded JSON contains version v:1")
    func encodedIncludesVersion() {
        let html = ZynaHTMLCodec.encode(
            userHTML: "x",
            attributes: ZynaMessageAttributes(color: .red)
        )
        #expect(html.contains("&quot;v&quot;:1"))
    }

    @Test("Encode is deterministic (sorted keys)")
    func encodeDeterministic() {
        let attrs = ZynaMessageAttributes(
            color: .red,
            checklist: [ChecklistItem(text: "a", checked: false)]
        )
        let a = ZynaHTMLCodec.encode(userHTML: "x", attributes: attrs)
        let b = ZynaHTMLCodec.encode(userHTML: "x", attributes: attrs)
        #expect(a == b)
    }

    // MARK: - HTML escaping

    @Test("Escape and unescape round-trip")
    func escapeRoundTrip() {
        let samples = [
            "plain",
            "has \"quotes\"",
            "with <tag> inside",
            "ampersand & more",
            "mixed \"<tag>\" & \"other\""
        ]
        for s in samples {
            let escaped = ZynaHTMLCodec.escapeForHTMLAttribute(s)
            let unescaped = ZynaHTMLCodec.unescapeFromHTMLAttribute(escaped)
            #expect(unescaped == s, "round-trip failed for: \(s)")
        }
    }
}
