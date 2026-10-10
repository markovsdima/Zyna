//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import CoreText
import Foundation
import Testing
import UIKit
@testable import Zyna

@Suite("Matrix rich text")
struct MatrixRichTextTests {

    @Test("Plain URLs are discovered without formatted_body")
    func detectsPlainURL() throws {
        let document = MatrixRichTextParser.parse(
            body: "Read https://example.com/docs now",
            metadata: nil
        )

        let link = try #require(document.links.first)
        #expect(link.destination == "https://example.com/docs")
        #expect(link.origin == .detected)
        #expect((document.text as NSString).substring(with: link.range) == "https://example.com/docs")
    }

    @Test("Explicit anchors retain their destination and visible label")
    func parsesExplicitAnchor() throws {
        let document = MatrixRichTextParser.parse(
            body: "Matrix site",
            metadata: html(#"<a href="https://matrix.org/docs">documentation</a>"#)
        )

        #expect(document.text == "documentation")
        let link = try #require(document.links.first)
        #expect(link.destination == "https://matrix.org/docs")
        #expect(link.origin == .explicit)
        #expect((document.text as NSString).substring(with: link.range) == "documentation")
    }

    @Test("Nested Matrix formatting becomes semantic runs")
    func parsesNestedFormatting() throws {
        let document = MatrixRichTextParser.parse(
            body: "Bold and code",
            metadata: html("<strong>Bold <em>and</em></strong> <code>code</code>")
        )

        #expect(document.text == "Bold and code")
        let andRange = try #require(document.text.range(of: "and"))
        let andLocation = NSRange(andRange, in: document.text).location
        let andRun = try #require(document.runs.first {
            NSLocationInRange(andLocation, $0.range)
        })
        #expect(andRun.style.contains(.bold))
        #expect(andRun.style.contains(.italic))

        let codeRange = try #require(document.text.range(of: "code"))
        let codeLocation = NSRange(codeRange, in: document.text).location
        let codeRun = try #require(document.runs.first {
            NSLocationInRange(codeLocation, $0.range)
        })
        #expect(codeRun.style.contains(.inlineCode))
    }

    @Test("Whitespace collapses once across formatting boundaries")
    func collapsesWhitespaceAcrossRuns() {
        let document = MatrixRichTextParser.parse(
            body: "a b",
            metadata: html("<em>a </em><strong> b</strong>")
        )

        #expect(document.text == "a b")
    }

    @Test("Explicit trailing breaks and pre whitespace survive structural trimming")
    func explicitWhitespace() {
        let inline = MatrixRichTextParser.parse(body: "fallback", metadata: html("<strong>a<br><br></strong>"))
        #expect(inline.text == "a\n\n")
        let pre = MatrixRichTextParser.parse(body: "fallback", metadata: html("<pre>a\t \n\n</pre>"))
        #expect(pre.text == "a\t \n\n")
        let block = MatrixRichTextParser.parse(body: "fallback", metadata: html("<p><em>a</em></p>  \n"))
        #expect(block.text == "a")
    }

    @MainActor
    @Test("A pre block's terminal newline adds no bubble height, but a blank line does")
    func preTerminalNewlineGeometry() {
        func measure(_ text: String) -> (size: CGSize, body: CGRect) {
            let document = MatrixRichTextParser.parse(
                body: "fallback", metadata: html("<pre><code>\(text)</code></pre>")
            )
            #expect(document.text == text)
            let attributed = RichTextRenderer.attributedString(
                from: document, foregroundColor: .label, linkColor: .link
            )
            // Go through the actual bubble, including its CoreText measurement
            // and timestamp placement, rather than an unrelated text view.
            let node = TextBubbleContentNode(
                bodyText: attributed,
                forwardedHeaderText: nil,
                replyHeader: nil,
                timeText: NSAttributedString(string: "12:34", attributes: [.font: UIFont.systemFont(ofSize: 11)]),
                statusIcon: nil,
                statusTintColor: .secondaryLabel,
                quoteBarColor: .link,
                maxTextWidth: 240
            )
            let size = node.calculateSizeThatFits(CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
            node.frame = CGRect(origin: .zero, size: size)
            node.layout()
            return (size, node.bodyFrame)
        }

        let plain = measure("x")
        let terminated = measure("x\n")
        let blankLine = measure("x\n\n")
        #expect(terminated.size == plain.size)
        #expect(terminated.body == plain.body)
        #expect(blankLine.body.height > terminated.body.height)
        #expect(blankLine.size.height > terminated.size.height)
    }

    @Test("Body whitespace is restored only when all other UTF-16 positions agree")
    func restoresOnlyMatchingBody() {
        let matching = MatrixRichTextParser.parse(body: "🙂\t x", metadata: html("<strong>🙂&#160; x</strong>"))
        #expect(matching.text == "🙂\t x")
        let differentLabel = MatrixRichTextParser.parse(body: "🙂\t y", metadata: html("<strong>🙂&#160; x</strong>"))
        #expect(differentLabel.text == "🙂\u{00a0} x")
        let differentLength = MatrixRichTextParser.parse(body: "a   b", metadata: html("<strong>a b</strong>"))
        #expect(differentLength.text == "a b")
    }

    @Test("Reply fallback is removed before rendering")
    func removesReplyFallback() {
        let document = MatrixRichTextParser.parse(
            body: "> <@alice:example.org> Old\n\nHello",
            metadata: html(
                #"<mx-reply><blockquote>Old</blockquote></mx-reply><strong>Hello</strong>"#
            )
        )

        #expect(document.text == "Hello")
        #expect(!document.text.contains("Old"))
        #expect(document.runs.first?.style.contains(.bold) == true)
    }

    @Test("Carrier-only HTML falls back to the plain multiline body")
    func carrierOnlyHTMLUsesFallback() {
        let document = MatrixRichTextParser.parse(
            body: "first\nsecond",
            metadata: html(
                #"""
                first
                second<span data-zyna="{}"></span>
                """#
            )
        )

        #expect(document.text == "first\nsecond")
    }

    @Test("Structural HTML preserves exact fallback whitespace")
    func structuralHTMLUsesExactFallback() {
        let body = "first  value\tcolumn\nsecond"
        let document = MatrixRichTextParser.parse(
            body: body,
            metadata: html(
                "first  value\tcolumn<br>second<span data-zyna=\"{}\"></span>"
            )
        )

        #expect(document.text == body)
    }

    @Test("Structural reply HTML removes only the plain reply fallback")
    func structuralReplyUsesUnquotedFallbackBody() {
        let document = MatrixRichTextParser.parse(
            body: "> <@alice:example.org> Old\n> message\n\nHello  world\nAgain",
            metadata: html(
                "<mx-reply><blockquote>Old message</blockquote></mx-reply>"
                    + "Hello  world<br>Again<span data-zyna=\"{}\"></span>"
            )
        )

        #expect(document.text == "Hello  world\nAgain")
    }

    @Test("Block elements, lists and entities keep readable structure")
    func parsesBlocksAndEntities() {
        let document = MatrixRichTextParser.parse(
            body: "Hello & goodbye",
            metadata: html(
                "<p>Hello&nbsp;&amp; goodbye</p><ol><li>One</li><li>Two</li></ol>"
            )
        )

        #expect(document.text == "Hello\u{00A0}& goodbye\n1. One\n2. Two")
    }

    @Test("Nested lists and unclosed formatting remain readable")
    func parsesNestedListsAndUnclosedTags() {
        let list = MatrixRichTextParser.parse(
            body: "Outer Inner Next",
            metadata: html(
                "<ul><li>Outer<ol><li>Inner</li></ol></li><li>Next</li></ul>"
            )
        )
        let unclosed = MatrixRichTextParser.parse(
            body: "bold",
            metadata: html("<strong>bold")
        )

        #expect(list.text == "• Outer\n1. Inner\n• Next")
        #expect(unclosed.text == "bold")
        #expect(unclosed.runs.first?.style.contains(.bold) == true)
    }

    @Test("Ordered list numbering saturates instead of overflowing")
    func orderedListNumberingAtIntegerLimit() {
        for start in [Int.max - 1, Int.max] {
            let document = MatrixRichTextParser.parse(
                body: "One Two Three",
                metadata: html(
                    "<ol start=\"\(start)\"><li>One</li><li>Two</li><li>Three</li></ol>"
                )
            )

            #expect(document.text == "\(start). One\n\(Int.max). Two\n\(Int.max). Three")
        }
    }

    @Test("Out-of-range list starts fall back to normal numbering")
    func orderedListNumberingOutsideIntegerRange() {
        let document = MatrixRichTextParser.parse(
            body: "One Two",
            metadata: html(
                "<ol start=\"\(Int.max)0\"><li>One</li><li>Two</li></ol>"
            )
        )

        #expect(document.text == "1. One\n2. Two")
    }

    @Test("Prepending emote text keeps explicit link ranges aligned")
    func prependingMovesLinkRanges() throws {
        let document = MatrixRichTextParser.parse(
            body: "site",
            metadata: html(#"<a href="https://example.com">site</a>"#)
        ).prepending("* Alice ")

        let link = try #require(document.links.first)
        #expect((document.text as NSString).substring(with: link.range) == "site")
        #expect(link.location == ("* Alice " as NSString).length)
    }

    @Test("Unsafe anchor schemes are never interactive")
    func rejectsUnsafeSchemes() {
        let document = MatrixRichTextParser.parse(
            body: "open",
            metadata: html(#"<a href="javascript:alert(1)">open</a>"#)
        )

        #expect(document.text == "open")
        #expect(document.links.isEmpty)
    }

    @Test("Unknown formatting falls back to body")
    func unknownFormatUsesFallback() {
        let document = MatrixRichTextParser.parse(
            body: "safe fallback",
            metadata: ChatTextMetadata(
                format: "com.example.future",
                formattedBody: "<strong>ignored</strong>"
            )
        )

        #expect(document.text == "safe fallback")
    }

    @Test("Stored messages retain Matrix formatting metadata")
    func storedMessageRoundTrip() throws {
        let metadata = html("<strong>Hello</strong>")
        let message = message(textMetadata: metadata)

        let stored = StoredMessage(from: message, roomId: "!room:example.org")
        let restored = try #require(stored.toChatMessage())

        #expect(stored.contentFormat == ChatTextMetadata.matrixHTMLFormat)
        #expect(stored.contentFormattedBody == "<strong>Hello</strong>")
        #expect(restored.textMetadata == metadata)
    }

    @Test("Stored plain text does not synthesize empty formatting metadata")
    func plainStoredMessageKeepsNilMetadata() throws {
        let stored = StoredMessage(
            from: message(textMetadata: nil),
            roomId: "!room:example.org"
        )
        let restored = try #require(stored.toChatMessage())

        #expect(restored.textMetadata == nil)
    }

    @MainActor
    @Test("A formatting-only change replaces the text cell")
    func formattingChangeRequiresCellReplacement() {
        let plain = message(textMetadata: nil)
        let formatted = message(textMetadata: html("<strong>Hello</strong>"))

        #expect(!MessageCellNode.canUpdateInPlace(old: plain, new: formatted))
    }

    @MainActor
    @Test("Flat Texture text maps a glyph tap back to its link")
    func linkHitTesting() throws {
        let document = MatrixRichTextParser.parse(
            body: "https://example.com",
            metadata: nil
        )
        let body = RichTextRenderer.attributedString(
            from: document,
            foregroundColor: .label,
            linkColor: .link
        )
        let time = NSAttributedString(
            string: "12:34",
            attributes: [.font: UIFont.systemFont(ofSize: 11)]
        )
        let node = TextBubbleContentNode(
            bodyText: body,
            forwardedHeaderText: nil,
            replyHeader: nil,
            timeText: time,
            statusIcon: nil,
            statusTintColor: .secondaryLabel,
            quoteBarColor: .link,
            maxTextWidth: 240
        )
        #expect(node.isLayerBacked)
        let size = node.calculateSizeThatFits(
            CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        )
        node.frame = CGRect(origin: .zero, size: size)
        node.layout()

        let url = try #require(node.linkURL(at: CGPoint(
            x: node.bodyFrame.minX + 8,
            y: node.bodyFrame.midY
        )))
        #expect(url.absoluteString == "https://example.com")
    }

    @MainActor
    @Test("Wrapped links share CoreText drawing and hit-test geometry")
    func wrappedLinkHitTesting() throws {
        let document = MatrixRichTextParser.parse(
            body: "https://example.com/a/very/long/path",
            metadata: nil
        )
        let body = RichTextRenderer.attributedString(
            from: document,
            foregroundColor: .label,
            linkColor: .link
        )
        let time = NSAttributedString(
            string: "12:34",
            attributes: [.font: UIFont.systemFont(ofSize: 11)]
        )
        let node = TextBubbleContentNode(
            bodyText: body,
            forwardedHeaderText: nil,
            replyHeader: nil,
            timeText: time,
            statusIcon: nil,
            statusTintColor: .secondaryLabel,
            quoteBarColor: .link,
            maxTextWidth: 100
        )
        let size = node.calculateSizeThatFits(
            CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        )
        node.frame = CGRect(origin: .zero, size: size)
        node.layout()

        #expect(node.bodyFrame.height > UIFont.systemFont(ofSize: 16).lineHeight)
        let url = try #require(node.linkURL(at: CGPoint(
            x: node.bodyFrame.minX + 8,
            y: node.bodyFrame.maxY - 5
        )))
        #expect(url.absoluteString == "https://example.com/a/very/long/path")
    }

    @MainActor
    @Test("Link hit regions exclude adjacent plain text")
    func linkHitRegionsExcludePlainText() throws {
        let prefix = "Before "
        let document = MatrixRichTextParser.parse(
            body: prefix + "https://example.com",
            metadata: nil
        )
        let body = RichTextRenderer.attributedString(
            from: document,
            foregroundColor: .label,
            linkColor: .link
        )
        let time = NSAttributedString(
            string: "12:34",
            attributes: [.font: UIFont.systemFont(ofSize: 11)]
        )
        let node = TextBubbleContentNode(
            bodyText: body,
            forwardedHeaderText: nil,
            replyHeader: nil,
            timeText: time,
            statusIcon: nil,
            statusTintColor: .secondaryLabel,
            quoteBarColor: .link,
            maxTextWidth: 240
        )
        let size = node.calculateSizeThatFits(
            CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        )
        node.frame = CGRect(origin: .zero, size: size)
        node.layout()

        #expect(node.linkURL(at: CGPoint(
            x: node.bodyFrame.minX + 2,
            y: node.bodyFrame.midY
        )) == nil)

        let prefixWidth = NSAttributedString(
            string: prefix,
            attributes: [.font: UIFont.systemFont(ofSize: 16)]
        ).size().width
        let url = try #require(node.linkURL(at: CGPoint(
            x: node.bodyFrame.minX + prefixWidth + 8,
            y: node.bodyFrame.midY
        )))
        #expect(url.absoluteString == "https://example.com")
    }

    @MainActor
    @Test("Block quotes expose decoration geometry without changing text")
    func quoteDecorationGeometry() {
        let document = MatrixRichTextParser.parse(
            body: "Quoted text",
            metadata: html("<blockquote>Quoted text</blockquote>")
        )
        let body = RichTextRenderer.attributedString(
            from: document,
            foregroundColor: .label,
            linkColor: .link
        )
        let time = NSAttributedString(
            string: "12:34",
            attributes: [.font: UIFont.systemFont(ofSize: 11)]
        )
        let node = TextBubbleContentNode(
            bodyText: body,
            forwardedHeaderText: nil,
            replyHeader: nil,
            timeText: time,
            statusIcon: nil,
            statusTintColor: .secondaryLabel,
            quoteBarColor: .link,
            maxTextWidth: 240
        )
        let size = node.calculateSizeThatFits(
            CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        )
        node.frame = CGRect(origin: .zero, size: size)
        node.layout()

        #expect(body.string == "Quoted text")
        #expect(node.quoteBarFrames.count == 1)
        #expect(node.quoteBarFrames.first?.width == 2)
    }

    @MainActor
    @Test("CoreText supplies explicit code and strikethrough decorations")
    func coreTextDecorationGeometry() {
        let document = MatrixRichTextParser.parse(
            body: "code gone",
            metadata: html("<code>code</code> <del>gone</del>")
        )
        let body = RichTextRenderer.attributedString(
            from: document,
            foregroundColor: .label,
            linkColor: .link
        )
        let time = NSAttributedString(
            string: "12:34",
            attributes: [.font: UIFont.systemFont(ofSize: 11)]
        )
        let node = TextBubbleContentNode(
            bodyText: body,
            forwardedHeaderText: nil,
            replyHeader: nil,
            timeText: time,
            statusIcon: nil,
            statusTintColor: .secondaryLabel,
            quoteBarColor: .link,
            maxTextWidth: 240
        )
        let size = node.calculateSizeThatFits(
            CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        )
        node.frame = CGRect(origin: .zero, size: size)
        node.layout()

        let codeRange = (body.string as NSString).range(of: "code")
        let strikeRange = (body.string as NSString).range(of: "gone")
        #expect(body.attribute(
            .zynaCodeBackground,
            at: codeRange.location,
            effectiveRange: nil
        ) != nil)
        #expect(body.attribute(
            .zynaStrikethrough,
            at: strikeRange.location,
            effectiveRange: nil
        ) != nil)
        #expect(node.bodyFrame.height > 0)
    }

    @Test("Sequential draws reuse the cached CoreText frame")
    func reusesTextFrame() {
        let (frame, reusable) = makeReusableTextFrame()

        for _ in 0..<3 {
            reusable.withExclusiveFrame { acquired in
                #expect(acquired === frame)
            }
        }
    }

    @Test("Overlapping frame access gets private matching geometry without waiting")
    func overlappingTextFrameAccess() {
        let (frame, reusable) = makeReusableTextFrame()

        // Nesting deterministically keeps the cached frame occupied. No
        // sleeps or scheduler timing are needed to exercise contention.
        reusable.withExclusiveFrame { outer in
            #expect(outer === frame)
            reusable.withExclusiveFrame { inner in
                #expect(inner !== outer)
                #expect(CTFrameGetPath(inner).boundingBoxOfPath
                    == CTFrameGetPath(outer).boundingBoxOfPath)
                let innerRange = CTFrameGetVisibleStringRange(inner)
                let outerRange = CTFrameGetVisibleStringRange(outer)
                #expect(innerRange.location == outerRange.location)
                #expect(innerRange.length == outerRange.length)
                let innerLines = CTFrameGetLines(inner) as! [CTLine]
                let outerLines = CTFrameGetLines(outer) as! [CTLine]
                #expect(innerLines.count == outerLines.count)
                for (lhs, rhs) in zip(innerLines, outerLines) {
                    let lhsRange = CTLineGetStringRange(lhs)
                    let rhsRange = CTLineGetStringRange(rhs)
                    #expect(lhsRange.location == rhsRange.location)
                    #expect(lhsRange.length == rhsRange.length)
                    #expect(CTLineGetTypographicBounds(lhs, nil, nil, nil)
                        == CTLineGetTypographicBounds(rhs, nil, nil, nil))
                }
            }
        }

        reusable.withExclusiveFrame { acquired in
            #expect(acquired === frame)
        }
    }

    @Test("Throwing from frame access releases the cached frame")
    func textFrameReleasedAfterThrow() {
        enum ExpectedFailure: Error { case draw }
        let (frame, reusable) = makeReusableTextFrame()

        #expect(throws: ExpectedFailure.self) {
            try reusable.withExclusiveFrame { _ in
                throw ExpectedFailure.draw
            }
        }
        reusable.withExclusiveFrame { acquired in
            #expect(acquired === frame)
        }
    }

    private func makeReusableTextFrame() -> (CTFrame, ReusableTextFrame) {
        let text = NSAttributedString(
            string: "A wrapped link https://example.com/a/long/path and more text",
            attributes: [.font: UIFont.systemFont(ofSize: 16)]
        )
        let size = CGSize(width: 120, height: 240)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: text.length),
            path,
            nil
        )
        return (frame, ReusableTextFrame(frame: frame, attributedText: text, size: size))
    }

    private func html(_ body: String) -> ChatTextMetadata {
        ChatTextMetadata(
            format: ChatTextMetadata.matrixHTMLFormat,
            formattedBody: body
        )
    }

    private func message(textMetadata: ChatTextMetadata?) -> ChatMessage {
        ChatMessage(
            id: "timeline-item",
            eventId: "$event",
            transactionId: nil,
            itemIdentifier: .eventId("$event"),
            senderId: "@alice:example.org",
            senderDisplayName: "Alice",
            senderAvatarUrl: nil,
            isOutgoing: false,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: .text(body: "Hello"),
            textMetadata: textMetadata,
            reactions: [],
            replyInfo: nil,
            isEditable: false,
            isEdited: false,
            isEditPending: false,
            isEditFailed: false,
            latestEditEventId: nil,
            zynaAttributes: ZynaMessageAttributes(),
            sendStatus: "synced"
        )
    }
}
