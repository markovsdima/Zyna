//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import UIKit

/// Texture owns UITextView's delegate callbacks. Its public editing delegate
/// lets the composer choose insertion styles before UIKit changes the text.
final class ComposerTextNode: ASEditableTextNode {
    var onTextChanged: (() -> Void)?
    var onEditLink: ((String?, @escaping (String?) -> Void) -> Void)?
    private var foreground: UIColor = .label

    override func didLoad() {
        super.didLoad()
        delegate = self
        MainActor.assumeIsolated { ComposerClipboard.install(on: textView) }
        updateForeground(foreground)
    }

    @objc(textView:editMenuForTextInRange:suggestedActions:)
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard textView.isEditable, range.length > 0, textView.markedTextRange == nil else {
            return UIMenu(children: suggestedActions)
        }
        let formats: [(String, RichTextStyle)] = [
            (String(localized: "Bold"), .bold), (String(localized: "Italic"), .italic),
            (String(localized: "Underline"), .underline), (String(localized: "Strikethrough"), .strikethrough),
            (String(localized: "Monospace"), .inlineCode)
        ]
        var actions: [UIMenuElement] = formats.map { title, style in
            UIAction(title: title, state: hasStyle(style, in: range) ? .on : .off) { [weak self] _ in
                self?.toggle(style, range: range)
            }
        }
        actions.append(UIAction(title: String(localized: "Link"), image: UIImage(systemName: "link")) { [weak self] _ in
            guard let self, NSMaxRange(range) <= self.textView.textStorage.length else { return }
            let text = self.textView.textStorage.copy() as! NSAttributedString
            let snapshot = ComposerText(attributedText: text)
            let existing = text.attribute(.link, at: range.location, effectiveRange: nil)
            self.onEditLink?((existing as? URL)?.absoluteString ?? existing as? String) { [weak self] destination in
                guard let self, ComposerText(attributedText: self.textView.textStorage) == snapshot else { return }
                self.change(range: range) { storage in
                    storage.removeAttribute(.link, range: range)
                    if let destination { storage.addAttribute(.link, value: destination, range: range) }
                }
            }
        })
        actions.append(UIAction(title: String(localized: "Remove Formatting")) { [weak self] _ in
            guard let self else { return }
            self.change(range: range) {
                $0.setAttributes(ComposerText.attributes(style: [], color: self.foreground), range: range)
            }
        })
        return UIMenu(children: suggestedActions + [UIMenu(title: String(localized: "Format"), children: actions)])
    }

    func setText(_ text: ComposerText) {
        attributedText = text.attributedText(color: foreground)
        applyTypingAttributes(ComposerText.attributes(style: [], color: foreground))
        textView.undoManager?.removeAllActions()
    }

    func updateForeground(_ color: UIColor) {
        foreground = color
        // Updating the material must not reset the insertion style or selection.
        var attributes = isNodeLoaded ? textView.typingAttributes
            : ComposerText.attributes(style: [], color: color)
        attributes[.foregroundColor] = color
        applyTypingAttributes(attributes)
        guard isNodeLoaded else { return }
        let storage = textView.textStorage
        storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: storage.length))
        textView.linkTextAttributes = [.foregroundColor: color, .underlineStyle: NSUnderlineStyle.single.rawValue]
    }

    func toggle(_ style: RichTextStyle, range: NSRange) {
        let remove = hasStyle(style, in: range)
        change(range: range) { storage in
            let snapshot = storage.copy() as! NSAttributedString
            snapshot.enumerateAttributes(in: range) { attributes, subrange, _ in
                var current = ComposerText.style(in: attributes)
                if remove { current.remove(style) } else { current.insert(style) }
                storage.addAttributes(ComposerText.attributes(style: current, color: self.foreground), range: subrange)
            }
        }
    }

    private func hasStyle(_ style: RichTextStyle, in range: NSRange) -> Bool {
        guard range.length > 0, range.location >= 0, NSMaxRange(range) <= textView.textStorage.length else { return false }
        var all = true
        textView.textStorage.enumerateAttributes(in: range) { attributes, _, _ in
            if !ComposerText.style(in: attributes).contains(style) { all = false }
        }
        return all
    }

    private func change(range: NSRange, edit: (NSMutableAttributedString) -> Void) {
        guard textView.markedTextRange == nil, range.location >= 0, range.length > 0,
              NSMaxRange(range) <= textView.textStorage.length else { return }
        let old = textView.textStorage.attributedSubstring(from: range)
        textView.undoManager?.registerUndo(withTarget: self) { target in target.restore(old, range: range) }
        textView.textStorage.beginEditing()
        edit(textView.textStorage)
        textView.textStorage.addAttribute(.foregroundColor, value: foreground, range: range)
        textView.textStorage.endEditing()
        textView.selectedRange = range
        applyTypingAttributes(textView.textStorage.attributes(at: NSMaxRange(range) - 1, effectiveRange: nil))
        onTextChanged?()
    }

    private func updateInsertionStyle(for range: NSRange, replacement: String = "") {
        guard textView.markedTextRange == nil else { return }
        let storage = textView.textStorage
        guard range.location >= 0, range.length >= 0, range.location <= storage.length,
              range.length <= storage.length - range.location else { return }
        var attributes = ComposerText.attributes(style: [], color: foreground)
        if storage.length > 0 {
            let index = range.length > 0 ? range.location : max(0, range.location - 1)
            let source = storage.attributes(at: index, effectiveRange: nil)
            var style = ComposerText.style(in: source)
            var link = Self.link(in: source)
            if range.length == 0, range.location > 0 {
                let previous = (storage.string as NSString).character(at: range.location - 1)
                let followsSpace = UnicodeScalar(previous).map {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                } ?? false
                let insertsSpace = replacement.unicodeScalars.first.map {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                } ?? false
                if followsSpace || insertsSpace {
                    let next = range.location < storage.length
                        ? storage.attributes(at: range.location, effectiveRange: nil) : [:]
                    // A separator extends only styles present on both sides.
                    // This ends a styled word, but preserves an outer style
                    // when inserting inside a longer formatted phrase.
                    style.formIntersection(ComposerText.style(in: next))
                    if link != Self.link(in: next) { link = nil }
                }
            }
            attributes = ComposerText.attributes(style: style, color: foreground)
            attributes[.link] = link
        }
        applyTypingAttributes(attributes)
    }

    private static func link(in attributes: [NSAttributedString.Key: Any]) -> String? {
        (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
    }

    private func applyTypingAttributes(_ attributes: [NSAttributedString.Key: Any]) {
        // Texture reapplies its cached typingAttributes on every selection
        // change, including each insertion. Update that cache as well as UIKit.
        typingAttributes = Dictionary(uniqueKeysWithValues: attributes.map { ($0.key.rawValue, $0.value) })
        if isNodeLoaded {
            // Texture skips equal assignments; UIKit may have changed its own
            // attributes since the last assignment to the node.
            textView.typingAttributes = attributes
        }
    }

    private func restore(_ text: NSAttributedString, range: NSRange) {
        change(range: range) { storage in
            storage.replaceCharacters(in: range, with: text)
        }
    }
}

extension ComposerTextNode: ASEditableTextNodeDelegate {
    func editableTextNode(_ editableTextNode: ASEditableTextNode,
                          shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // UIKit restores the original attributed text during undo/redo.
        // Insertion attributes would overwrite those restored styles.
        if !text.isEmpty, textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true {
            updateInsertionStyle(for: range, replacement: text)
        }
        return true
    }

    func editableTextNodeDidChangeSelection(_ editableTextNode: ASEditableTextNode,
                                           fromSelectedRange: NSRange, toSelectedRange: NSRange,
                                           dueToEditing: Bool) {
        guard !dueToEditing else { return }
        // Texture delivers this asynchronously. Use the current selection,
        // since more input or a formatting action may already have happened.
        updateInsertionStyle(for: textView.selectedRange)
    }

    func editableTextNodeDidUpdateText(_ editableTextNode: ASEditableTextNode) {
        onTextChanged?()
    }
}
