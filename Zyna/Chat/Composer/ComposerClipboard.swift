//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import ObjectiveC.runtime
import UIKit
import UniformTypeIdentifiers

enum ComposerClipboard {
    // Conforms to data, not text: other apps must not paste the JSON itself.
    static let contentType = UTType(exportedAs: "com.app.zyna.composer-text", conformingTo: .data)

    private struct Payload: Codable {
        let version: Int
        let text: ComposerText
    }

    @MainActor private static var copyGeneration: UInt64 = 0

    static func decode(_ data: Data) -> NSAttributedString? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1 else { return nil }
        return payload.text.attributedText(color: .label)
    }

    /// Publish lossless composer data and portable HTML/text in one write.
    /// UIKit provides standard conversions (including RTF) from the HTML.
    @MainActor
    static func write(_ text: ComposerText) {
        copyGeneration &+= 1
        var item: [String: Data] = [UTType.utf8PlainText.identifier: Data(text.body.utf8)]
        if let html = text.formattedBody {
            item[contentType.identifier] = try? JSONEncoder().encode(Payload(version: 1, text: text))
            item[UTType.html.identifier] = Data(("<meta charset=\"utf-8\">" + html).utf8)
        }
        // Transfer actual bytes, not promises that require a live producer.
        // Do not enrich this item later: replacing it invalidates providers
        // that a paste may already be reading. HTML has no font or color theme.
        UIPasteboard.general.setItems([item], options: [:])
    }

    /// Message HTML can contain reply fallbacks and transport metadata.
    /// Export only the visible text and supported styles, as the editor does.
    @MainActor
    @discardableResult
    static func writeMessage(_ text: ComposerText) -> Task<Void, Never>? {
        guard text.formattedBody != nil else {
            write(text)
            return nil
        }
        copyGeneration &+= 1
        let generation = copyGeneration
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        return Task {
            let prepared = await prepareMessage(text)
            // A slow copy must not replace a later copy, including one made
            // by UIKit or another app while the message was being prepared.
            guard !Task.isCancelled, copyGeneration == generation,
                  pasteboard.changeCount == changeCount else { return }
            write(prepared)
        }
    }

    @concurrent
    private static func prepareMessage(_ text: ComposerText) async -> ComposerText {
        ComposerText(attributedText: text.attributedText(color: .label))
    }

    @MainActor private static var enabledKey: UInt8 = 0
    @MainActor private static var installedClasses = Set<ObjectIdentifier>()

    /// Texture creates its text view internally without a subclass hook.
    /// Intercept only public edit actions; UIKit still owns deletion and undo.
    @MainActor static func install(on view: UITextView) {
        objc_setAssociatedObject(view, &enabledKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        guard let viewClass = object_getClass(view),
              installedClasses.insert(ObjectIdentifier(viewClass)).inserted else { return }
        for selector in [#selector(UITextView.copy(_:)), #selector(UITextView.cut(_:))] {
            guard let method = class_getInstanceMethod(viewClass, selector) else { continue }
            typealias Action = @convention(c) (UITextView, Selector, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Action.self)
            let replacement: @convention(block) (UITextView, AnyObject?) -> Void = { view, sender in
                MainActor.assumeIsolated {
                    let isCut = selector == #selector(UITextView.cut(_:))
                    let selection = view.selectedTextRange
                    // Plain selections keep UIKit's insertion-style inheritance.
                    guard (!isCut || (view.isEditable && selection != nil)),
                          let snapshot = snapshotForCopy(view), snapshot.formattedBody != nil else {
                        original(view, selector, sender)
                        return
                    }
                    write(snapshot)
                    if isCut, let selection {
                        // Replacing a selected range is a discrete UIKit edit.
                        // deleteBackward coalesces with later typing; calling
                        // native Cut would publish a second clipboard item.
                        view.replace(selection, withText: "")
                    }
                }
            }
            // Adds an override on Texture's concrete class if it inherited
            // the action. UITextView and other text controls stay unchanged.
            class_replaceMethod(
                viewClass, selector, imp_implementationWithBlock(replacement),
                method_getTypeEncoding(method)
            )
        }
    }

    @MainActor private static func snapshotForCopy(_ view: UITextView) -> ComposerText? {
        guard (objc_getAssociatedObject(view, &enabledKey) as? Bool) == true,
              !view.isSecureTextEntry, view.markedTextRange == nil else { return nil }
        let range = view.selectedRange
        guard range.location >= 0, range.length > 0,
              range.location <= view.textStorage.length,
              range.length <= view.textStorage.length - range.location else { return nil }
        return ComposerText(attributedText: view.textStorage.attributedSubstring(from: range))
    }
}
