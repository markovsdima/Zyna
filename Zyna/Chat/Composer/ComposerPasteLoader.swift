//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import UniformTypeIdentifiers

enum ComposerPasteLoader {
    // Request a concrete representation before using UIKit's automatic choice.
    // Notes offers several formats; loadObject can return unformatted text
    // even when the provider advertises RTF/RTFD. This composer imports text
    // styles only, so RTF is sufficient and avoids decoding RTFD attachments.
    private static let formats: [(UTType, NSAttributedString.DocumentType)] = [
        (.rtf, .rtf), (.flatRTFD, .rtfd)
    ]

    static func canLoad(from provider: NSItemProvider) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(ComposerClipboard.contentType.identifier) { return true }
        if formats.contains(where: { provider.hasItemConformingToTypeIdentifier($0.0.identifier) }) {
            return true
        }
        // Keep plain-only paste on UIKit's default path so it inherits the
        // current insertion style. Native attributed text and web formats
        // still use UIKit's object loader when no RTF representation works.
        return provider.canLoadObject(ofClass: NSAttributedString.self)
            && NSAttributedString.readableTypeIdentifiersForItemProvider.contains { identifier in
                UTType(identifier)?.conforms(to: .plainText) != true
                    && provider.hasItemConformingToTypeIdentifier(identifier)
            }
    }

    // Explicitly keep decoding off the UI actor, including with Approachable
    // Concurrency enabled. HTML import remains owned by UIKit's loader.
    @concurrent
    static func load(from provider: NSItemProvider) async -> NSAttributedString? {
        let ownType = ComposerClipboard.contentType.identifier
        if provider.hasItemConformingToTypeIdentifier(ownType),
           let data = await data(from: provider, type: ownType),
           let text = ComposerClipboard.decode(data) {
            return text
        }
        for (type, documentType) in formats {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }
            guard let data = await data(from: provider, type: type.identifier) else { continue }
            if let text = try? NSAttributedString(
                data: data, options: [.documentType: documentType], documentAttributes: nil
            ) {
                return text
            }
        }
        guard provider.canLoadObject(ofClass: NSAttributedString.self) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSAttributedString.self) { object, _ in
                continuation.resume(returning: object as? NSAttributedString)
            }
        }
    }

    private static func data(from provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
