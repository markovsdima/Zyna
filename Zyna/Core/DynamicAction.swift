//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Builds selectors from encoded byte sequences.
enum DynamicAction {

    /// Resolves a selector from a mapped byte array.
    static func resolve(
        bytes: [UInt8],
        mask: UInt8
    ) -> Selector? {
        resolveString(bytes: bytes, mask: mask).map(NSSelectorFromString)
    }

    /// Decodes a masked byte array into a plain `String`.
    /// Used for KVC keys that aren't selectors.
    static func resolveString(
        bytes: [UInt8],
        mask: UInt8
    ) -> String? {
        var decoded = [UInt8](repeating: 0, count: bytes.count)
        for i in bytes.indices {
            decoded[i] = bytes[i] ^ mask
        }
        return String(bytes: decoded, encoding: .utf8)
    }
}
