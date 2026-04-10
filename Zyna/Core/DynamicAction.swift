//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Builds selectors from encoded byte sequences.
enum DynamicAction {

    /// Resolves a selector from a mapped byte array.
    /// - Parameters:
    ///   - bytes: Encoded ASCII bytes.
    ///   - mask: Byte mask applied to each element.
    /// - Returns: The resolved `Selector`, or `nil` if
    ///   decoding produces invalid UTF-8.
    static func resolve(
        bytes: [UInt8],
        mask: UInt8
    ) -> Selector? {
        var decoded = [UInt8](repeating: 0, count: bytes.count)
        for i in bytes.indices {
            decoded[i] = bytes[i] ^ mask
        }
        guard let name = String(bytes: decoded, encoding: .utf8) else {
            return nil
        }
        return NSSelectorFromString(name)
    }
}
