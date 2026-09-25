//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import GRDB
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Zyna

@Suite("Composer formatting", .serialized)
@MainActor
struct ComposerTextTests {
    @Test("Combined styles, emoji, whitespace and links survive serialization")
    func roundTrip() throws {
        let text = NSMutableAttributedString(
            string: "Hello 👨‍👩‍👧‍👦  <world>\nNext",
            attributes: ComposerText.attributes(style: [], color: .red)
        )
        let range = (text.string as NSString).range(of: "👨‍👩‍👧‍👦  <world>")
        let style: RichTextStyle = [.bold, .italic, .underline, .strikethrough, .inlineCode]
        text.addAttributes(ComposerText.attributes(style: style, color: .blue), range: range)
        text.addAttribute(.link, value: "https://example.com/?a=1&b=2", range: range)
        let message = ComposerText(attributedText: text)
        let html = try #require(message.formattedBody)
        #expect(html.contains("&lt;world&gt;"))
        #expect(html.hasPrefix("Hello "))
        #expect(html.contains("a=1&amp;b=2"))
        let restored = message.attributedText(color: .black)
        #expect(restored.string == text.string)
        #expect(ComposerText.style(in: restored.attributes(at: range.location, effectiveRange: nil)) == style)
        #expect(restored.attribute(.link, at: range.location, effectiveRange: nil) as? String == "https://example.com/?a=1&b=2")
        #expect(ComposerText(attributedText: restored) == message)
        let document = MatrixRichTextParser.parse(body: message.body, metadata: message.metadata)
        let bubble = RichTextRenderer.attributedString(from: document, foregroundColor: .black, linkColor: .blue)
        let font = try #require(bubble.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
        #expect(font.fontDescriptor.symbolicTraits.contains([.traitBold, .traitItalic, .traitMonoSpace]))
    }

    @Test("Fallback glyphs retain menu state, insertion style and unchanged edit snapshots")
    func fallbackFontsInEditor() throws {
        let cases: [(String, RichTextStyle, String, Int)] = [
            ("🙂", .bold, "strong", 0), ("🙂", .italic, "em", 1),
            ("🙂", .inlineCode, "code", 4), ("漢字", .italic, "em", 1)
        ]
        for (glyphs, style, tag, menuIndex) in cases {
            try withEditor { node in
                let body = "hi " + glyphs
                let original = ComposerText(body: body, formattedBody: "<\(tag)>\(body)</\(tag)>")
                // Same comparison path as sending an unchanged edit, before
                // and after TextKit has substituted its fallback glyph fonts.
                let snapshot = ComposerText(attributedText: original.attributedText(color: .label), trimming: true)
                node.setText(original)
                let storage = node.textView.textStorage
                let range = NSRange(location: 0, length: storage.length)
                storage.fixAttributes(in: range)
                node.textView.layoutManager.ensureLayout(for: node.textView.textContainer)
                if glyphs == "🙂" {
                    let font = try #require(storage.attribute(.font, at: 3, effectiveRange: nil) as? UIFont)
                    #expect(font.fontName.contains("Emoji"))
                }
                #expect(ComposerText.style(in: storage.attributes(at: 3, effectiveRange: nil)) == style)
                #expect(ComposerText(attributedText: storage, trimming: true) == snapshot)
                let menu = try #require(node.textView(node.textView, editMenuForTextIn: range, suggestedActions: []))
                let formats = try #require(menu.children.first as? UIMenu)
                let action = try #require(formats.children[menuIndex] as? UIAction)
                #expect(action.state == .on)

                node.toggle(style, range: range)
                #expect(ComposerText(attributedText: storage).formattedBody == nil)
                node.toggle(style, range: range)
                node.updateForeground(.black)
                #expect(ComposerText(attributedText: storage, trimming: true) == snapshot)
                node.textView.selectedRange = NSRange(location: storage.length, length: 0)
                try typeText("x", in: node)
                #expect(ComposerText.style(in: storage.attributes(at: storage.length - 1, effectiveRange: nil)) == style)
                #expect(ComposerText(attributedText: storage).formattedBody == "<\(tag)>\(body)x</\(tag)>")
            }
        }
    }

    @Test("HTML coalesces semantic spans despite appearance and link representation changes")
    func canonicalSpans() {
        let text = NSMutableAttributedString(
            string: "hello", attributes: ComposerText.attributes(style: .bold, color: .black)
        )
        let full = NSRange(location: 0, length: text.length)
        text.addAttribute(.link, value: "https://example.org", range: full)
        let original = ComposerText(attributedText: text)
        text.addAttributes([
            .foregroundColor: UIColor.red, .kern: 1,
            .font: UIFont.systemFont(ofSize: 16), .link: URL(string: "https://example.org")!
        ], range: NSRange(location: 2, length: 3))
        #expect(ComposerText(attributedText: text) == original)
        #expect(original.formattedBody == "<a href=\"https://example.org\"><strong>hello</strong></a>")
        // An explicit empty semantic style wins over stale visual attributes.
        text.addAttribute(.zynaComposerStyle, value: NSNumber(value: 0), range: full)
        #expect(ComposerText(attributedText: text).formattedBody == "<a href=\"https://example.org\">hello</a>")
    }

    @Test("Preformatted input retains the flat composer's supported monospace style")
    func importedCodeBlock() {
        let source = ComposerText(body: "let x = 1", formattedBody: "<pre><code>let x = 1</code></pre>")
        let text = source.attributedText(color: .black)
        #expect(ComposerText.style(in: text.attributes(at: 0, effectiveRange: nil)) == .inlineCode)
        #expect(ComposerText(attributedText: text).formattedBody == "<code>let x = 1</code>")
    }

    @MainActor
    private final class PasteItem: NSObject, UITextPasteItem {
        let itemProvider = NSItemProvider(object: "paste" as NSString)
        let localObject: Any?
        let defaultAttributes: [NSAttributedString.Key: Any] = [:]
        var result: NSAttributedString?
        init(_ text: NSAttributedString) { localObject = text }
        func setResult(string: String) { result = NSAttributedString(string: string) }
        func setResult(attributedString: NSAttributedString) { result = attributedString }
        func setResult(attachment: NSTextAttachment) {}
        func setNoResult() {}
        func setDefaultResult() {}
    }

    @Test("Pasting retains supported styles while discarding foreign appearance and attachments")
    func paste() throws {
        let text = NSMutableAttributedString(string: "Line 1\r\nLine 2", attributes: [
            .font: UIFont.boldSystemFont(ofSize: 80), .backgroundColor: UIColor.red,
            .link: "javascript:alert(1)"
        ])
        text.append(NSAttributedString(attachment: NSTextAttachment()))
        let input = ChatInputNode()
        let item = PasteItem(text)
        input.textPasteConfigurationSupporting(input.textInputNode.textView, transform: item)
        let result = try #require(item.result)
        #expect(result.string == "Line 1\nLine 2")
        #expect(result.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(result.attribute(.link, at: 0, effectiveRange: nil) == nil)
        let font = try #require(result.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(font.pointSize == 16)
        #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    @Test("RTF preserves emoji formatting and explicit style boundaries",
          arguments: [#"\b"#, #"\i"#], [false, true])
    func rtfEmojiFormatting(command: String, plainEmoji: Bool) throws {
        // Exercise UIKit's RTF reader, without Zyna's semantic attributes.
        // The fallback font is explicitly selected, as in foreign rich text.
        let reset = plainEmoji ? command + "0" : ""
        let rtf = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}{\f1 AppleColorEmoji;}}\fs32\uc1\f0"#
            + command + #" hi \f1"# + reset + #" \u-10179?\u-8638?}"#
        let imported = try NSAttributedString(
            data: Data(rtf.utf8),
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        #expect(imported.string == "hi 🙂")
        #expect(imported.attribute(.zynaComposerStyle, at: 3, effectiveRange: nil) == nil)
        let input = ChatInputNode()
        let item = PasteItem(imported)
        input.textPasteConfigurationSupporting(input.textInputNode.textView, transform: item)
        let result = try #require(item.result)
        let style: RichTextStyle = command == #"\b"# ? .bold : .italic
        let tag = style == .bold ? "strong" : "em"
        let expectedHTML = plainEmoji ? "<\(tag)>hi </\(tag)>🙂" : "<\(tag)>hi 🙂</\(tag)>"
        #expect(ComposerText(attributedText: result).formattedBody == expectedHTML)

        try withEditor { node in
            node.attributedText = result
            let storage = node.textView.textStorage
            let range = NSRange(location: 0, length: storage.length)
            storage.fixAttributes(in: range)
            node.textView.layoutManager.ensureLayout(for: node.textView.textContainer)
            let font = try #require(storage.attribute(.font, at: 3, effectiveRange: nil) as? UIFont)
            #expect(font.fontName.contains("Emoji"))
            #expect(ComposerText.style(in: storage.attributes(at: 3, effectiveRange: nil))
                == (plainEmoji ? [] : style))
            #expect(ComposerText(attributedText: storage).formattedBody == expectedHTML)
            let menu = try #require(node.textView(node.textView, editMenuForTextIn: range, suggestedActions: []))
            let formats = try #require(menu.children.first as? UIMenu)
            let action = try #require(formats.children[style == .bold ? 0 : 1] as? UIAction)
            #expect(action.state == (plainEmoji ? .off : .on))
        }
    }

    @Test("System paste loads rich providers without a local object, including those without RTF",
          arguments: ["rtf", "rtfd", "native", "competing"])
    func richProviderPaste(kind: String) async throws {
        let source = NSAttributedString(string: "Bold 🙂", attributes: [
            .font: UIFont.boldSystemFont(ofSize: 32), .foregroundColor: UIColor.red,
            .backgroundColor: UIColor.yellow, .link: URL(string: "https://example.org")!
        ])
        let provider: NSItemProvider
        if kind == "native" {
            provider = NSItemProvider(object: source)
        } else {
            let documentType: NSAttributedString.DocumentType = kind == "rtfd" ? .rtfd : .rtf
            let type: UTType = kind == "rtfd" ? .flatRTFD : .rtf
            let data = try source.data(
                from: NSRange(location: 0, length: source.length),
                documentAttributes: [.documentType: documentType]
            )
            // Model a provider whose automatic attributed representation has
            // already lost formatting, while its explicit RTF is still rich.
            // This is a negotiation regression fixture, not a Notes payload.
            provider = kind == "competing"
                ? NSItemProvider(object: NSAttributedString(string: source.string, attributes: [
                    .font: UIFont.systemFont(ofSize: 17)
                ])) : NSItemProvider()
            let plainData = Data(source.string.utf8)
            // A plain representation can be offered first alongside rich text.
            provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
                completion(plainData, nil)
                return nil
            }
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
        }
        if kind == "rtfd" || kind == "native" {
            #expect(!provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier))
        }
        if kind == "competing" {
            let automatic: NSAttributedString? = await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: NSAttributedString.self) { object, _ in
                    continuation.resume(returning: object as? NSAttributedString)
                }
            }
            #expect(ComposerText(attributedText: try #require(automatic)).formattedBody == nil)
        }
        try await withInputBar { input in
            input.setCurrentText("before after")
            let editor = input.textInputNode
            let material = GlassAdaptiveMaterial(appearance: 0, contrast: 0)
            input.applyGlassAdaptiveMaterial(material)
            let view = editor.textView
            view.selectedRange = NSRange(location: 7, length: 5)
            #expect(view.pasteDelegate === input)
            #expect(view.canPaste([provider]))
            // UIKit creates the real UITextPasteItem and performs replacement.
            // Supplying a localObject or assigning attributedText bypasses this
            // path and misses format loss during cross-app paste.
            view.paste(itemProviders: [provider])
            try await waitForText("before Bold 🙂", in: input)
            let storage = view.textStorage
            for index in 7..<storage.length {
                let attributes = storage.attributes(at: index, effectiveRange: nil)
                #expect(ComposerText.style(in: attributes) == .bold)
                #expect(attributes[.foregroundColor] as? UIColor == material.primaryForeground)
                #expect(attributes[.backgroundColor] == nil)
                #expect((attributes[.font] as? UIFont)?.pointSize == 16)
            }
            #expect(ComposerText(attributedText: storage).formattedBody
                == "before <a href=\"https://example.org\"><strong>Bold 🙂</strong></a>")
        }
    }

    @Test("An unavailable or malformed RTF representation falls back to RTFD",
          arguments: [false, true])
    func richPasteRepresentationFallback(loadError: Bool) async throws {
        let source = NSAttributedString(string: "Rich", attributes: [.font: UIFont.boldSystemFont(ofSize: 24)])
        let rtfd = try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in
            if loadError {
                completion(nil, NSError(domain: NSItemProvider.errorDomain, code: -1000))
            } else {
                completion(Data([0, 1, 255]), nil)
            }
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.flatRTFD.identifier, visibility: .all) { completion in
            completion(rtfd, nil)
            return nil
        }
        let loaded = try #require(await ComposerPasteLoader.load(from: provider))
        #expect(ComposerText(attributedText: loaded).formattedBody == "<strong>Rich</strong>")
    }

    @Test("Providers with only native attributed text keep the system fallback")
    func nativePasteRepresentationFallback() async throws {
        let source = NSAttributedString(string: "Native", attributes: [.font: UIFont.boldSystemFont(ofSize: 24)])
        // Register only the native data, rather than NSItemProvider(object:),
        // which also advertises RTFD representations on current UIKit.
        let type = try #require(NSAttributedString.writableTypeIdentifiersForItemProvider.first)
        let nativeData: Data = try await withCheckedThrowingContinuation { continuation in
            source.loadData(withTypeIdentifier: type, forItemProviderCompletionHandler: { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? NSError(domain: "Test", code: 1)) }
            })
        }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
            completion(nativeData, nil)
            return nil
        }
        #expect(ComposerPasteLoader.canLoad(from: provider))
        #expect(!provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier))
        #expect(!provider.hasItemConformingToTypeIdentifier(UTType.flatRTFD.identifier))
        let loaded = try #require(await ComposerPasteLoader.load(from: provider))
        #expect(ComposerText(attributedText: loaded).formattedBody == "<strong>Native</strong>")
    }

    @Test("Plain-only system paste inherits the insertion style")
    func plainProviderPaste() async throws {
        try await withInputBar { input in
            input.setCurrentText(ComposerText(body: "A", formattedBody: "<strong>A</strong>"))
            let editor = input.textInputNode
            editor.updateForeground(.white)
            editor.textView.selectedRange = NSRange(location: 1, length: 0)
            // Set the insertion style through Texture's keyboard preflight.
            let accepted = try #require(editor.textView.delegate?.textView?(
                editor.textView, shouldChangeTextIn: editor.textView.selectedRange, replacementText: "B"
            ) as Bool?)
            #expect(accepted)
            editor.textView.paste(itemProviders: [NSItemProvider(object: "B" as NSString)])
            try await waitForText("AB", in: input)
            #expect(ComposerText(attributedText: editor.textView.textStorage).formattedBody == "<strong>AB</strong>")
        }
    }

    @Test("System copy and cut preserve semantic styles across fallback fonts",
          arguments: ["copy", "cut"], ["strong", "em", "code"])
    func semanticClipboard(action: String, tag: String) async throws {
        // This suite uses the test simulator's clipboard. Do not clear it
        // between cases: the simulator can invalidate backing files reused
        // by the next copy. Each action replaces the previous test contents.
        // Never read pasteboard.items synchronously; providers may need main.
        try await withInputBar { input in
            let body = "before hi 🙂 漢字 after"
            let selected = "hi 🙂 漢字"
            input.setCurrentText(body)
            let node = input.textInputNode
            let view = node.textView
            let range = (body as NSString).range(of: selected)
            view.selectedRange = range
            let style: RichTextStyle = tag == "strong" ? .bold : tag == "em" ? .italic : .inlineCode
            let undo = try #require(view.undoManager)
            undo.beginUndoGrouping()
            node.toggle(style, range: range)
            undo.endUndoGrouping()
            view.textStorage.fixAttributes(in: NSRange(location: 0, length: view.textStorage.length))
            view.layoutManager.ensureLayout(for: view.textContainer)
            let emoji = (body as NSString).range(of: "🙂")
            #expect((view.textStorage.attribute(.font, at: emoji.location, effectiveRange: nil) as? UIFont)?.fontName.contains("Emoji") == true)
            let original = ComposerText(attributedText: view.textStorage)
            let expected = "<\(tag)>\(selected)</\(tag)>"
            #expect(ComposerText(attributedText: view.textStorage.attributedSubstring(from: range)).formattedBody == expected)

            // Formatting and cutting are separate user actions. Clear the
            // setup group so a same-run-loop undo does not undo both at once.
            undo.removeAllActions()
            undo.beginUndoGrouping()
            if action == "cut" { view.cut(nil) } else { view.copy(nil) }
            undo.endUndoGrouping()
            let providers = UIPasteboard.general.itemProviders
            let provider = try #require(providers.first)
            #expect(providers.count == 1)
            #expect(provider.hasItemConformingToTypeIdentifier(ComposerClipboard.contentType.identifier))
            if action == "cut" {
                #expect(input.currentText == "before  after")
                undo.undo()
                #expect(ComposerText(attributedText: view.textStorage) == original)
                undo.redo()
                #expect(input.currentText == "before  after")
            } else {
                #expect(ComposerText(attributedText: view.textStorage) == original)
                #expect(view.selectedRange == range)
            }

            // Test the formats a foreign client sees, independently of our
            // custom reader. Clipboard data contains only the selection.
            let plain = try #require(await clipboardData(provider, type: UTType.utf8PlainText.identifier))
            #expect(String(decoding: plain, as: UTF8.self) == selected)
            let html = try #require(await clipboardData(provider, type: UTType.html.identifier))
            #expect(String(decoding: html, as: UTF8.self) == "<meta charset=\"utf-8\">" + expected)
            // UIKit vends standard RTF from the published, theme-free HTML.
            let rtf = try #require(await clipboardData(provider, type: UTType.rtf.identifier))
            let foreign = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            #expect(ComposerText(attributedText: foreign).formattedBody == expected)
            foreign.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: foreign.length)) { color, _, _ in
                #expect(color == nil)
            }

            // Clipboard data must not depend on the live editor's contents.
            input.setCurrentText("")
            input.applyGlassAdaptiveMaterial(GlassAdaptiveMaterial(appearance: 0, contrast: 0))
            #expect(view.canPaste(providers))
            view.paste(itemProviders: providers)
            try await waitForText(selected, in: input)
            #expect(ComposerText(attributedText: view.textStorage).formattedBody == expected)
            #expect(view.delegate === node)
            #expect(node.delegate === node)
            #expect(view.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
                == GlassAdaptiveMaterial(appearance: 0, contrast: 0).primaryForeground)
        }
    }

    @Test("Cut has its own undo step between earlier and later typing", arguments: [false, true])
    func cutUndoBoundary(typedBefore: Bool) async throws {
        try await withInputBar { input in
            let body = "before hi 🙂 漢字 after"
            let selected = "hi 🙂 漢字"
            input.setCurrentText(body)
            let node = input.textInputNode
            let view = node.textView
            node.toggle(.bold, range: (body as NSString).range(of: selected))
            let initial = ComposerText(attributedText: view.textStorage)
            let undo = try #require(view.undoManager)
            undo.removeAllActions()
            view.selectedRange = NSRange(location: 0, length: 0)
            try await nextEditingEvent()
            if typedBefore {
                try typeText("x", in: node)
                try await nextEditingEvent()
            }
            view.selectedRange = (view.text as NSString).range(of: selected)
            try await nextEditingEvent()
            let beforeCut = ComposerText(attributedText: view.textStorage)
            var changes = 0
            let onTextChanged = node.onTextChanged
            node.onTextChanged = { changes += 1; onTextChanged?() }
            defer { node.onTextChanged = onTextChanged }
            // No manual undo groups: UIKit must isolate this edit itself.
            view.cut(nil)
            let afterCut = ComposerText(attributedText: view.textStorage)
            #expect(afterCut.body == (typedBefore ? "x" : "") + "before  after")
            try await nextEditingEvent()
            #expect(changes > 0)
            #expect(view.isFirstResponder)
            #expect(view.delegate === node)
            try typeText("123", in: node)
            try await nextEditingEvent()
            try typeText("456", in: node)
            try await nextEditingEvent()
            let afterTyping = ComposerText(attributedText: view.textStorage)

            undo.undo()
            #expect(ComposerText(attributedText: view.textStorage) == afterCut)
            undo.undo()
            #expect(ComposerText(attributedText: view.textStorage) == beforeCut)
            if typedBefore {
                undo.undo()
                #expect(ComposerText(attributedText: view.textStorage) == initial)
                undo.redo()
                #expect(ComposerText(attributedText: view.textStorage) == beforeCut)
            }
            undo.redo()
            #expect(ComposerText(attributedText: view.textStorage) == afterCut)
            undo.redo()
            #expect(ComposerText(attributedText: view.textStorage) == afterTyping)
        }
    }

    @Test("Clipboard publishes ready data that remains readable through UIKit conversions")
    func readyClipboard() async throws {
        // Use the same system pasteboard as copy/cut, including its conversions.
        let pasteboard = UIPasteboard.general
        let text = ComposerText(body: "hi 🙂 漢字", formattedBody: "<em>hi 🙂 漢字</em>")
        ComposerClipboard.write(text)
        let changeCount = pasteboard.changeCount
        // All authored data must be readable synchronously when copy returns.
        let own = try #require(pasteboard.data(forPasteboardType: ComposerClipboard.contentType.identifier))
        let html = try #require(pasteboard.data(forPasteboardType: UTType.html.identifier))
        let plain = try #require(pasteboard.data(forPasteboardType: UTType.utf8PlainText.identifier))
        let decoded = try #require(ComposerClipboard.decode(own))
        #expect(ComposerText(attributedText: decoded) == text)
        #expect(String(decoding: html, as: UTF8.self) == "<meta charset=\"utf-8\">" + text.formattedBody!)
        #expect(String(decoding: plain, as: UTF8.self) == text.body)
        let provider = try #require(pasteboard.itemProviders.first)

        let rtf = try #require(await clipboardData(provider, type: UTType.rtf.identifier))
        let foreign = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(ComposerText(attributedText: foreign) == text)
        foreign.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: foreign.length)) { color, _, _ in
            #expect(color == nil)
        }
        // Conversion must not replace the clipboard item under an active paste.
        #expect(await clipboardData(provider, type: ComposerClipboard.contentType.identifier) == own)
        #expect(pasteboard.changeCount == changeCount)
    }

    @Test("Message copy exports styles without Matrix reply fallbacks or transport metadata")
    func messageClipboard() async throws {
        let body = "hi 🙂 漢字 link"
        let html = "<strong>hi 🙂</strong> <em>漢字</em> <a href=\"https://example.org/docs\">link</a>"
        let reply = "<mx-reply><blockquote>Earlier message</blockquote></mx-reply>"
        let source = ComposerText(
            body: "> <@alice:example.org> Earlier message\n\n" + body,
            metadata: ChatTextMetadata(
                format: ChatTextMetadata.matrixHTMLFormat,
                formattedBody: ZynaHTMLCodec.encode(
                    userHTML: reply + html, attributes: ZynaMessageAttributes(color: .red)
                )
            )
        )
        let copying = ComposerClipboard.writeMessage(source)
        await copying?.value
        let providers = UIPasteboard.general.itemProviders
        let provider = try #require(providers.first)
        let plain = try #require(await clipboardData(provider, type: UTType.utf8PlainText.identifier))
        #expect(String(decoding: plain, as: UTF8.self) == body)
        let exportedHTML = try #require(await clipboardData(provider, type: UTType.html.identifier))
        #expect(String(decoding: exportedHTML, as: UTF8.self) == "<meta charset=\"utf-8\">" + html)
        let rtf = try #require(await clipboardData(provider, type: UTType.rtf.identifier))
        let foreign = try NSAttributedString(
            data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        #expect(foreign.string == body)
        #expect(ComposerText.style(in: foreign.attributes(at: 0, effectiveRange: nil)).contains(.bold))
        let cjk = (body as NSString).range(of: "漢字").location
        #expect(ComposerText.style(in: foreign.attributes(at: cjk, effectiveRange: nil)).contains(.italic))
        // UIKit can add the receiver's default underline to an HTML link.
        let link = foreign.attribute(.link, at: foreign.length - 1, effectiveRange: nil)
        let destination = (link as? URL)?.absoluteString ?? link as? String
        #expect(destination == "https://example.org/docs")
        try await withInputBar { input in
            input.textInputNode.textView.paste(itemProviders: providers)
            try await waitForText(body, in: input)
            #expect(ComposerText(attributedText: input.textInputNode.textView.textStorage)
                == ComposerText(body: body, formattedBody: html))
        }
    }

    @Test("Plain message copy ignores unknown formats and keeps insertion-style inheritance")
    func plainMessageClipboard() async throws {
        ComposerClipboard.writeMessage(ComposerText(
            body: "plain", metadata: ChatTextMetadata(format: "unknown", formattedBody: "<strong>ignored</strong>")
        ))
        let providers = UIPasteboard.general.itemProviders
        #expect(providers.count == 1)
        #expect(providers.allSatisfy { !ComposerPasteLoader.canLoad(from: $0) })
        try await withInputBar { input in
            input.setCurrentText(ComposerText(body: "A", formattedBody: "<strong>A</strong>"))
            let view = input.textInputNode.textView
            view.selectedRange = NSRange(location: 1, length: 0)
            _ = view.delegate?.textView?(view, shouldChangeTextIn: view.selectedRange, replacementText: "p")
            view.paste(itemProviders: providers)
            try await waitForText("Aplain", in: input)
            #expect(ComposerText(attributedText: view.textStorage).formattedBody == "<strong>Aplain</strong>")
        }
    }

    @Test("Preparing a message cannot overwrite a later copy", arguments: ["composer", "message", "external"])
    func supersededMessageClipboard(replacement: String) async {
        let pending = ComposerClipboard.writeMessage(ComposerText(body: "old", formattedBody: "<strong>old</strong>"))
        var newer: Task<Void, Never>?
        switch replacement {
        case "composer": ComposerClipboard.write(ComposerText(body: "new"))
        case "message": newer = ComposerClipboard.writeMessage(ComposerText(body: "new", formattedBody: "<em>new</em>"))
        default: UIPasteboard.general.string = "new"
        }
        await pending?.value
        await newer?.value
        #expect(UIPasteboard.general.string == "new")
    }

    private func nextEditingEvent() async throws {
        // Let UIKit close its event group; do not create a boundary manually.
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test("Plain copy inherits insertion style and unrelated Texture editors keep native copy")
    func plainAndUnrelatedClipboard() async throws {
        try await withInputBar { input in
            input.setCurrentText("plain")
            let view = input.textInputNode.textView
            view.selectedRange = NSRange(location: 0, length: 5)
            view.copy(nil)
            let providers = UIPasteboard.general.itemProviders
            #expect(providers.count == 1)
            #expect(providers.allSatisfy { !ComposerPasteLoader.canLoad(from: $0) })
            input.setCurrentText(ComposerText(body: "A", formattedBody: "<strong>A</strong>"))
            view.selectedRange = NSRange(location: 1, length: 0)
            _ = view.delegate?.textView?(view, shouldChangeTextIn: view.selectedRange, replacementText: "p")
            view.paste(itemProviders: providers)
            try await waitForText("Aplain", in: input)
            #expect(ComposerText(attributedText: view.textStorage).formattedBody == "<strong>Aplain</strong>")

            let other = ASEditableTextNode()
            input.view.addSubview(other.view)
            other.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
            other.attributedText = NSAttributedString(string: "other", attributes: [.font: UIFont.boldSystemFont(ofSize: 16)])
            other.textView.becomeFirstResponder()
            other.textView.selectedRange = NSRange(location: 0, length: 5)
            other.textView.copy(nil)
            let otherProviders = UIPasteboard.general.itemProviders
            #expect(otherProviders.count == 1)
            #expect(otherProviders.allSatisfy { !ComposerPasteLoader.canLoad(from: $0) })
            let otherProvider = try #require(otherProviders.first)
            let plain = try #require(await clipboardData(otherProvider, type: UTType.utf8PlainText.identifier))
            #expect(String(decoding: plain, as: UTF8.self) == "other")
        }
    }

    @Test("Malformed or future clipboard payloads fall back to RTF", arguments: ["invalid", "future"])
    func invalidOwnClipboard(kind: String) async throws {
        let provider = NSItemProvider()
        let own = kind == "future" ? #"{"version":2,"text":{"body":"wrong"}}"# : "invalid"
        provider.registerDataRepresentation(forTypeIdentifier: ComposerClipboard.contentType.identifier, visibility: .all) { completion in
            completion(Data(own.utf8), nil)
            return nil
        }
        let rtf = Data(#"{\rtf1\ansi{\fonttbl{\f0 Helvetica;}}\f0\b Rich}"#.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in
            completion(rtf, nil)
            return nil
        }
        let loaded = try #require(await ComposerPasteLoader.load(from: provider))
        #expect(ComposerText(attributedText: loaded).formattedBody == "<strong>Rich</strong>")
    }

    @Test("Semantic clipboard preserves links and edge whitespace without send-time trimming")
    func clipboardWhitespaceAndLink() async throws {
        try await withInputBar { input in
            let body = " \thi 🙂\n\n"
            input.setCurrentText(body)
            let node = input.textInputNode
            let view = node.textView
            let range = NSRange(location: 0, length: view.textStorage.length)
            view.selectedRange = range
            node.toggle(.bold, range: range)
            view.textStorage.addAttribute(.link, value: "https://example.org", range: (body as NSString).range(of: "hi"))
            let expected = ComposerText(attributedText: view.textStorage)
            view.copy(nil)
            let providers = UIPasteboard.general.itemProviders
            input.setCurrentText("")
            view.paste(itemProviders: providers)
            try await waitForText(body, in: input)
            #expect(ComposerText(attributedText: view.textStorage) == expected)
        }
    }

    @Test("HTML-only providers preserve formatting through UIKit's importer")
    func htmlOnlyPaste() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier, visibility: .all) { completion in
            completion(Data("<meta charset=\"utf-8\"><b>Bold</b> <i>Italic</i>".utf8), nil)
            return nil
        }
        try await withInputBar { input in
            input.textInputNode.textView.paste(itemProviders: [provider])
            try await waitForText("Bold Italic", in: input)
            #expect(ComposerText(attributedText: input.textInputNode.textView.textStorage).formattedBody
                == "<strong>Bold</strong> <em>Italic</em>")
        }
    }

    private func clipboardData(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private func withInputBar(_ operation: (ChatInputNode) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let input = ChatInputNode()
        window.rootViewController!.view.addSubview(input.view)
        input.frame = CGRect(x: 0, y: 100, width: 350, height: 150)
        input.layoutIfNeeded()
        #expect(input.textInputNode.textView.window === window)
        input.textInputNode.textView.becomeFirstResponder()
        try await operation(input)
    }

    private func waitForText(_ expected: String, in input: ChatInputNode) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while input.currentText != expected && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(input.currentText == expected)
    }

    @Test("Attributed paste preserves whitespace and only explicit safe links")
    func pasteWhitespace() throws {
        let body = "\t\thi 🙂\u{2028}next\u{2029}https://example.org \n\n"
        let text = NSMutableAttributedString(string: body, attributes: [
            .font: UIFont.boldSystemFont(ofSize: 30), .backgroundColor: UIColor.red
        ])
        let label = (body as NSString).range(of: "hi 🙂")
        text.addAttribute(.link, value: URL(string: "https://example.org/explicit")!, range: label)
        let input = ChatInputNode()
        let item = PasteItem(text)
        input.textPasteConfigurationSupporting(input.textInputNode.textView, transform: item)
        let result = try #require(item.result)
        #expect(result.string == body)
        #expect(result.attribute(.link, at: label.location, effectiveRange: nil) as? String == "https://example.org/explicit")
        let detectedLocation = (body as NSString).range(of: "https:").location
        #expect(result.attribute(.link, at: detectedLocation, effectiveRange: nil) == nil)
        #expect(ComposerText.style(in: result.attributes(at: label.location, effectiveRange: nil)) == .bold)
    }

    @Test("Whitespace and link ranges survive sending, rendering and reopening",
          arguments: ["\t\ta\t\tb", "a\u{2028}b\u{2029}c", " a  \n\n", "a\u{2003}b"])
    func whitespaceRoundTrip(body: String) throws {
        let text = NSMutableAttributedString(
            string: body, attributes: ComposerText.attributes(style: .bold, color: .black)
        )
        let range = (body as NSString).range(of: "a")
        text.addAttribute(.link, value: "https://example.org", range: range)
        let message = ComposerText(attributedText: text)
        let json = try DirectRawTextSender.rawTextMessageContentJSON(
            roomId: "!room:example.org", body: message.body, formattedBody: message.formattedBody,
            replyInfo: nil, zynaAttributes: ZynaMessageAttributes(color: .red), transactionId: "tx"
        )
        let content = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let sent = ComposerText(
            body: try #require(content["body"] as? String),
            metadata: ChatTextMetadata(format: content["format"] as? String, formattedBody: content["formatted_body"] as? String)
        )
        let document = MatrixRichTextParser.parse(body: sent.body, metadata: sent.metadata)
        #expect(document.text == body)
        #expect(document.links.first?.range == range)
        #expect(RichTextRenderer.attributedString(from: document, foregroundColor: .black, linkColor: .blue).string == body)
        let restored = sent.attributedText(color: .white)
        #expect(restored.string == body)
        #expect(restored.attribute(.link, at: range.location, effectiveRange: nil) as? String == "https://example.org")
        #expect(ComposerText(attributedText: restored) == message)
    }

    @Test("Unknown or absent formats are not imported or forwarded as Matrix HTML",
          arguments: [nil, "text/markdown", ChatTextMetadata.matrixHTMLFormat])
    func incomingFormat(format: String?) throws {
        let metadata = ChatTextMetadata(format: format, formattedBody: "<strong>different label</strong>")
        let source = ComposerText(body: "original body", metadata: metadata)
        let supportsHTML = format == ChatTextMetadata.matrixHTMLFormat
        #expect(metadata.matrixHTML == (supportsHTML ? metadata.formattedBody : nil))
        #expect(source.formattedBody == metadata.matrixHTML)
        try withEditor { node in
            node.setText(source)
            #expect(node.textView.text == (supportsHTML ? "different label" : "original body"))
            #expect(ComposerText(attributedText: node.textView.textStorage, trimming: true)
                == ComposerText(attributedText: source.attributedText(color: .label), trimming: true))
        }
    }

    @Test("Plain text stays plain; trimming shifts styles with their characters")
    func trim() {
        let plain = ComposerText(attributedText: NSAttributedString(string: "  hi  "), trimming: true)
        #expect(plain == ComposerText(body: "hi"))
        let rich = NSAttributedString(string: "\n 🙂 yes \n", attributes: ComposerText.attributes(style: .bold, color: .red))
        let message = ComposerText(attributedText: rich, trimming: true)
        #expect(message.body == "🙂 yes")
        #expect(message.attributedText(color: .black).string == "🙂 yes")
        #expect(message.formattedBody != nil)
    }

    @Test("Editor keeps Texture's delegate and restores formatting through undo and redo")
    func undoAndTheme() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let node = ComposerTextNode()
        window.rootViewController!.view.addSubview(node.view)
        node.frame = CGRect(x: 0, y: 100, width: 300, height: 100)
        node.setText(ComposerText(body: "Hello world"))
        #expect(node.textView.delegate === node)
        let range = NSRange(location: 6, length: 5)
        let undo = try #require(node.textView.undoManager)
        undo.beginUndoGrouping()
        node.toggle(.bold, range: range)
        undo.endUndoGrouping()
        node.updateForeground(.white)
        #expect(node.textView.selectedRange == range)
        #expect(ComposerText.style(in: node.textView.typingAttributes).contains(.bold))
        let menu = try #require(node.textView(node.textView, editMenuForTextIn: range, suggestedActions: []))
        #expect(menu.children.count == 1)
        undo.undo()
        #expect(ComposerText(attributedText: node.textView.textStorage).formattedBody == nil)
        undo.redo()
        #expect(ComposerText(attributedText: node.textView.textStorage).formattedBody?.contains("<strong>") == true)
    }

    @Test("Typing retains the glass foreground and formatting after every character")
    func typingAndTheme() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let node = ComposerTextNode()
        // The input starts on light glass, then adapts to a dark background.
        node.typingAttributes = [
            NSAttributedString.Key.font.rawValue: UIFont.systemFont(ofSize: 16),
            NSAttributedString.Key.foregroundColor.rawValue: UIColor.black
        ]
        window.rootViewController!.view.addSubview(node.view)
        node.frame = CGRect(x: 0, y: 100, width: 300, height: 100)
        node.setText(ComposerText(body: ""))
        node.updateForeground(.white)
        node.textView.becomeFirstResponder()
        for character in ["a", "b", "c"] { node.textView.insertText(character) }
        for index in 0..<3 {
            #expect(node.textView.textStorage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor == .white)
        }

        node.toggle(.bold, range: NSRange(location: 0, length: 3))
        node.textView.selectedRange = NSRange(location: 3, length: 0)
        for character in ["d", "e"] { node.textView.insertText(character) }
        for index in 3..<5 {
            let attributes = node.textView.textStorage.attributes(at: index, effectiveRange: nil)
            #expect(attributes[.foregroundColor] as? UIColor == .white)
            #expect(ComposerText.style(in: attributes) == .bold)
        }

        node.updateForeground(.black)
        for character in ["f", "g"] { node.textView.insertText(character) }
        for index in 0..<7 {
            let attributes = node.textView.textStorage.attributes(at: index, effectiveRange: nil)
            #expect(attributes[.foregroundColor] as? UIColor == .black)
            #expect(ComposerText.style(in: attributes) == .bold)
        }

        // Sending clears the previous style, but keeps the current glass color.
        node.setText(ComposerText(body: ""))
        node.updateForeground(.white)
        for character in ["h", "i"] { node.textView.insertText(character) }
        for index in 0..<2 {
            let attributes = node.textView.textStorage.attributes(at: index, effectiveRange: nil)
            #expect(attributes[.foregroundColor] as? UIColor == .white)
            #expect(ComposerText.style(in: attributes).isEmpty)
        }
    }

    @Test("Formatting adjacent words preserves their spaces through sending and editing",
          arguments: [" ", "  "], [0, 1, 2])
    func spacesBetweenStyles(separator: String, spaceOwner: Int) throws {
        let node = ComposerTextNode()
        let body = "курсив" + separator + "жирный"
        node.setText(ComposerText(body: body))
        let first = (body as NSString).range(of: "курсив")
        let second = (body as NSString).range(of: "жирный")
        node.toggle(.italic, range: NSRange(
            location: first.location, length: first.length + (spaceOwner == 1 ? separator.utf16.count : 0)
        ))
        node.toggle(.bold, range: NSRange(
            location: spaceOwner == 2 ? NSMaxRange(first) : second.location,
            length: second.length + (spaceOwner == 2 ? separator.utf16.count : 0)
        ))
        let message = ComposerText(attributedText: node.textView.textStorage, trimming: true)
        #expect(message.body == body)
        let json = try DirectRawTextSender.rawTextMessageContentJSON(
            roomId: "!room:example.org", body: message.body, formattedBody: message.formattedBody,
            replyInfo: nil, zynaAttributes: ZynaMessageAttributes(color: .red), transactionId: "tx"
        )
        let content = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let sent = ComposerText(
            body: try #require(content["body"] as? String),
            formattedBody: try #require(content["formatted_body"] as? String)
        )
        let document = MatrixRichTextParser.parse(body: sent.body, metadata: sent.metadata)
        #expect(document.text.replacingOccurrences(of: "\u{00a0}", with: " ") == body)
        let bubble = RichTextRenderer.attributedString(from: document, foregroundColor: .black, linkColor: .blue)
        #expect(bubble.string == document.text)
        node.setText(sent)
        #expect(node.textView.text == body)
        #expect(ComposerText(attributedText: node.textView.textStorage) == message)
    }

    private func withEditor(_ operation: (ComposerTextNode) throws -> Void) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let node = ComposerTextNode()
        window.rootViewController!.view.addSubview(node.view)
        node.frame = CGRect(x: 0, y: 100, width: 300, height: 100)
        node.updateForeground(.white)
        node.textView.becomeFirstResponder()
        try operation(node)
    }

    private func typeText(_ text: String, in node: ComposerTextNode) throws {
        let view = node.textView
        #expect(view.delegate === node)
        #expect(node.delegate === node)
        // insertText alone is a programmatic edit. Exercise the keyboard's
        // delegate preflight as well, through Texture rather than the helper
        // that computes attributes inside ComposerTextNode.
        let accepted = try #require(view.delegate?.textView?(
            view, shouldChangeTextIn: view.selectedRange, replacementText: text
        ) as Bool?)
        #expect(accepted)
        if accepted { view.insertText(text) }
    }

    @Test("A space or newline after a styled word starts plain text", arguments: [" ", "\n"])
    func typingBeyondStyledWord(separator: String) throws {
        try withEditor { node in
            node.setText(ComposerText(body: "Раз пять"))
            node.toggle([.inlineCode, .underline], range: NSRange(location: 4, length: 4))
            node.textView.selectedRange = NSRange(location: 8, length: 0)
            try typeText(separator, in: node)
            for character in "шесть" { try typeText(String(character), in: node) }
            #expect(node.textView.text == "Раз пять" + separator + "шесть")
            let storage = node.textView.textStorage
            for index in 0..<storage.length {
                let attributes = storage.attributes(at: index, effectiveRange: nil)
                let expected: RichTextStyle = (4..<8).contains(index) ? [.inlineCode, .underline] : []
                #expect(ComposerText.style(in: attributes) == expected)
                #expect(attributes[.foregroundColor] as? UIColor == .white)
            }
        }
    }

    @Test("Spaces inside an already styled phrase retain its formatting")
    func typingInsideStyledPhrase() throws {
        try withEditor { node in
            node.setText(ComposerText(body: "пять шесть"))
            node.toggle([.bold, .italic], range: NSRange(location: 0, length: 10))
            node.textView.selectedRange = NSRange(location: 4, length: 0)
            try typeText(" ", in: node)
            try typeText("и", in: node)
            #expect(node.textView.text == "пять и шесть")
            node.textView.textStorage.enumerateAttributes(in: NSRange(location: 0, length: 12)) { attributes, _, _ in
                #expect(ComposerText.style(in: attributes) == [.bold, .italic])
            }
        }
    }

    @Test("Typing uses the style at the caret instead of the last formatting action")
    func typingFollowsCaret() throws {
        try withEditor { node in
            node.setText(ComposerText(body: "пять шесть семь"))
            node.toggle([.inlineCode, .underline], range: NSRange(location: 0, length: 4))
            node.toggle(.bold, range: NSRange(location: 5, length: 5))
            let cases: [(String, RichTextStyle)] = [
                ("пять", [.inlineCode, .underline]),
                ("шесть", .bold), ("семь", [])
            ]
            for (word, expected) in cases {
                let range = (node.textView.text as NSString).range(of: word)
                let index = range.location + 2
                node.textView.selectedRange = NSRange(location: index, length: 0)
                try typeText("А", in: node)
                let attributes = node.textView.textStorage.attributes(at: index, effectiveRange: nil)
                #expect(ComposerText.style(in: attributes) == expected)
                #expect(attributes[.foregroundColor] as? UIColor == .white)
            }
        }
    }

    @Test("A trailing space included in formatting does not style the next word")
    func typingAfterStyledSeparator() throws {
        try withEditor { node in
            node.setText(ComposerText(body: "пять "))
            node.toggle([.inlineCode, .underline], range: NSRange(location: 0, length: 5))
            node.textView.selectedRange = NSRange(location: 5, length: 0)
            for character in "шесть" { try typeText(String(character), in: node) }
            #expect(node.textView.text == "пять шесть")
            for index in 5..<10 {
                let attributes = node.textView.textStorage.attributes(at: index, effectiveRange: nil)
                #expect(ComposerText.style(in: attributes).isEmpty)
            }
        }
    }

    @Test("A separator ends the inner style but retains the surrounding phrase style")
    func typingAtNestedStyleBoundary() throws {
        try withEditor { node in
            node.setText(ComposerText(body: "пять шесть"))
            node.toggle(.bold, range: NSRange(location: 0, length: 10))
            node.toggle(.underline, range: NSRange(location: 0, length: 4))
            node.textView.selectedRange = NSRange(location: 4, length: 0)
            try typeText(" и", in: node)
            #expect(node.textView.text == "пять и шесть")
            for index in 4..<6 {
                #expect(ComposerText.style(in: node.textView.textStorage.attributes(at: index, effectiveRange: nil)) == .bold)
            }
        }
    }

    @Test("Typing and formatting still notify the input bar about size changes")
    func inputBarNotifications() async {
        let input = ChatInputNode()
        _ = input.view
        var updates = 0
        input.onSizeChanged = { updates += 1 }
        input.textInputNode.textView.insertText("word")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(input.currentText == "word")
        #expect(updates > 0)
        let beforeFormatting = updates
        input.textInputNode.toggle(.bold, range: NSRange(location: 0, length: 4))
        #expect(updates > beforeFormatting)
    }

    @Test("Old envelopes decode and new envelopes retain HTML across storage")
    func envelope() throws {
        let old = try #require(OutgoingEnvelopePayload.decodeJSON(#"{"kind":"text","body":"old"}"#))
        #expect(old == .text(OutgoingTextPayload(body: "old")))
        let value = OutgoingEnvelopePayload.text(OutgoingTextPayload(body: "bold", formattedBody: "<strong>bold</strong>"))
        #expect(OutgoingEnvelopePayload.decodeJSON(value.encodeJSON()) == value)
    }

    @Test("Reply and edit events retain HTML together with Zyna attributes")
    func wireContent() throws {
        let html = "<strong>Hello</strong>"
        let attrs = ZynaMessageAttributes(color: .red)
        let reply = ReplyInfo(eventId: "$old", senderId: "@alice:example.org", senderDisplayName: nil, body: "Earlier")
        let json = try DirectRawTextSender.rawTextMessageContentJSON(
            roomId: "!room:example.org", body: "Hello", formattedBody: html,
            replyInfo: reply, zynaAttributes: attrs, transactionId: "tx"
        )
        let content = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let sentHTML = try #require(content["formatted_body"] as? String)
        #expect(sentHTML.contains("<mx-reply>"))
        #expect(sentHTML.contains(html))
        #expect(ZynaHTMLCodec.decode(htmlBody: sentHTML).color != nil)
        let edit = try DirectRawTextSender.rawTextEditContentJSON(
            body: "Hello", formattedBody: html, eventId: "$event", zynaAttributes: attrs, transactionId: "edit"
        )
        let editContent = try #require(JSONSerialization.jsonObject(with: Data(edit.utf8)) as? [String: Any])
        let replacement = try #require(editContent["m.new_content"] as? [String: Any])
        #expect(replacement["body"] as? String == "Hello")
        #expect((replacement["formatted_body"] as? String)?.contains(html) == true)
        #expect((editContent["formatted_body"] as? String)?.hasPrefix("* ") == true)
    }

    @Test("Re-encoding forwarded HTML replaces its carrier without touching text or other attributes")
    func forwardedCarrier() {
        let original = ZynaHTMLCodec.encode(userHTML: "<strong>Hello</strong>", attributes: ZynaMessageAttributes(color: .red))
        let forwarded = ZynaHTMLCodec.encode(userHTML: original, attributes: ZynaMessageAttributes(forwardedFrom: "Alice"))
        let decoded = ZynaHTMLCodec.decode(htmlBody: forwarded)
        #expect(decoded.forwardedFrom == "Alice")
        #expect(decoded.color == nil)
        #expect(forwarded.contains("<strong>Hello</strong>"))
        let literal = #"data-zyna='text' <span title=" data-zyna='title'">value</span>"#
        #expect(ZynaHTMLCodec.encode(userHTML: literal, attributes: ZynaMessageAttributes()) == literal)
    }

    @Test("Link entry accepts bare hosts with ports and preserves explicit web schemes", arguments: [
        ("example.com:8443/path", "https://example.com:8443/path"),
        ("localhost:8080", "https://localhost:8080"),
        ("127.0.0.1:8080/path", "https://127.0.0.1:8080/path"),
        ("[::1]:8080/path", "https://[::1]:8080/path"),
        ("https://example.com:8443/path", "https://example.com:8443/path"),
        ("http://localhost:8080", "http://localhost:8080"),
        ("//example.com:8443/path", "https://example.com:8443/path"),
        (" example.com:8443/path \n", "https://example.com:8443/path"),
        ("example.com", "https://example.com"),
        ("https://example.com", "https://example.com"),
        ("example.com/path?next=https://example.org", "https://example.com/path?next=https://example.org")
    ])
    func linkDestination(input: String, expected: String) {
        #expect(ComposerLinkPrompt.destination(from: input) == expected)
    }

    @Test("Link entry does not reinterpret unsupported schemes or credentials as host ports", arguments: [
        "javascript:alert(1)", "javascript:80", "mailto:alice@example.com", "tel:123",
        "ftp://example.com:21", "example.com:not-a-port", "example.com:8443@other.example", "", "   "
    ])
    func invalidLinkDestination(input: String) {
        #expect(ComposerLinkPrompt.destination(from: input) == nil)
    }

    @Test("A theme change while editing a link does not discard the link update")
    func linkAndTheme() throws {
        let node = ComposerTextNode()
        node.setText(ComposerText(body: "Link"))
        let range = NSRange(location: 0, length: 4)
        var apply: ((String?) -> Void)?
        node.onEditLink = { _, completion in apply = completion }
        let menu = try #require(node.textView(node.textView, editMenuForTextIn: range, suggestedActions: []))
        let format = try #require(menu.children.first as? UIMenu)
        let link = try #require(format.children.compactMap { $0 as? UIAction }.first { $0.title == String(localized: "Link") })
        // UIKit invokes actions via their owning control; use an actual button.
        let button = UIButton(primaryAction: link)
        button.sendActions(for: .primaryActionTriggered)
        let completion = try #require(apply)
        node.updateForeground(.white)
        completion("https://example.com")
        #expect(node.textView.textStorage.attribute(.link, at: 0, effectiveRange: nil) as? String == "https://example.com")
    }

    @Test("Pending edits persist HTML, project locally, accept it and can remove it")
    func pendingEdit() throws {
        let message = ChatMessage(
            id: "message", eventId: "$event", transactionId: nil, itemIdentifier: nil,
            senderId: "@me:example.org", senderDisplayName: nil, senderAvatarUrl: nil,
            isOutgoing: true, timestamp: Date(), content: .text(body: "Hello"),
            reactions: [], replyInfo: nil, isEditable: true, isEdited: false,
            isEditPending: false, isEditFailed: false, latestEditEventId: nil,
            zynaAttributes: ZynaMessageAttributes(), sendStatus: "sent"
        )
        let record = StoredMessage(from: message, roomId: "room")
        let db = try DatabaseQueue()
        let columns = Mirror(reflecting: record).children.compactMap(\.label)
        try db.write {
            let definitions = columns.map { "\"\($0)\"" + ($0 == "id" ? " TEXT PRIMARY KEY" : "") }
            try $0.execute(sql: "CREATE TABLE storedMessage (\(definitions.joined(separator: ",")))")
            try record.insert($0)
        }
        let service = PendingMessageEditService(database: db)
        let html = "<strong>Hello</strong>"
        #expect(service.prepareDirectRawEdit(roomId: "room", eventId: "$event", body: "Hello", formattedBody: html, zynaAttributes: ZynaMessageAttributes(), transactionId: "one"))
        let recreated = PendingMessageEditService(database: db)
        #expect(recreated.pendingDirectRawEdits().first?.formattedBody == html)
        let pending = try db.read { try StoredMessage.fetchOne($0, key: record.id) }
        #expect(pending?.toChatMessage()?.textMetadata?.formattedBody == html)
        #expect(recreated.applyAcceptedDirectRawEdit(roomId: "room", eventId: "$event", transactionId: "one", editEventId: "$edit", body: "Hello", formattedBody: html, zynaAttributes: ZynaMessageAttributes()))
        let accepted = try db.read { try StoredMessage.fetchOne($0, key: record.id) }
        #expect(accepted?.toChatMessage()?.textMetadata?.formattedBody == html)
        #expect(recreated.prepareDirectRawEdit(roomId: "room", eventId: "$event", body: "Hello", zynaAttributes: ZynaMessageAttributes(), transactionId: "two"))
        let plain = try db.read { try StoredMessage.fetchOne($0, key: record.id) }
        #expect(plain?.toChatMessage()?.textMetadata == nil)
        #expect(!recreated.applyAcceptedDirectRawEdit(roomId: "room", eventId: "$event", transactionId: "one", editEventId: "$stale", body: "Hello", formattedBody: html, zynaAttributes: ZynaMessageAttributes()))
    }
}
