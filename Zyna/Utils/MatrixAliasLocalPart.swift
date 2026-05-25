//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import MatrixRustSDK

enum MatrixAliasLocalPart {

    static func generated(from displayName: String) -> String {
        normalizedLocalPart(displayName)
    }

    static func normalizedUserInput(_ value: String, serverName: String?) -> String {
        let localPart = strippedAliasLocalPart(from: value, serverName: serverName)
        return normalizedLocalPart(localPart)
    }

    private static func normalizedLocalPart(_ value: String) -> String {
        roomAliasNameFromRoomDisplayName(roomName: transliteratedToLatin(value))
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func transliteratedToLatin(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let latin = result.applyingTransform(.toLatin, reverse: false) {
            result = latin
        }
        if let stripped = result.applyingTransform(.stripCombiningMarks, reverse: false) {
            result = stripped
        }

        return result
    }

    private static func strippedAliasLocalPart(from value: String, serverName: String?) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.hasPrefix("#") {
            result.removeFirst()
        }

        if let serverName,
           result.hasSuffix(":\(serverName)"),
           let colon = result.lastIndex(of: ":") {
            result = String(result[..<colon])
        } else if let colon = result.firstIndex(of: ":") {
            result = String(result[..<colon])
        }

        return result
    }
}
