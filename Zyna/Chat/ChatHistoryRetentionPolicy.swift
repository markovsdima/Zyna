//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Bounds the full chat's retained presentation around its viewport.
/// Separate high/low watermarks avoid discarding a page on every scroll.
struct ChatHistoryRetentionPolicy {
    var maximumCount = 600
    var retainedCount = 400

    func retainedRange(count: Int, protected: Range<Int>) -> Range<Int>? {
        guard count > maximumCount, retainedCount > 0, retainedCount < maximumCount,
              !protected.isEmpty, protected.lowerBound >= 0, protected.upperBound <= count,
              protected.count < retainedCount else { return nil }
        let start = min(count - retainedCount, max(0,
            protected.lowerBound - (retainedCount - protected.count) / 2))
        return start..<(start + retainedCount)
    }
}
