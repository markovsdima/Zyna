//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum MessageCellHelpers {

    static let maxBubbleWidthRatio: CGFloat = 0.75
    static let cellInsets = UIEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jj:mm")
        return formatter
    }()

    static let senderColors: [UIColor] = [
        .systemRed, .systemBlue, .systemGreen, .systemOrange,
        .systemPurple, .systemTeal, .systemIndigo, .systemPink
    ]

    /// djb2 hash — stable across app launches, unlike `hashValue`.
    static func stableHash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(hash % UInt64(Int.max))
    }
}
