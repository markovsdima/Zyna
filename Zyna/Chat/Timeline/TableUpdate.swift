//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum TableUpdate {
    case reload
    case batch(
        deletions: [IndexPath],
        insertions: [IndexPath],
        moves: [(from: IndexPath, to: IndexPath)],
        updates: [IndexPath],
        animated: Bool
    )

    /// Database pagination and local presentation changes are not arrivals.
    /// Compute before submitting to Texture, while indices match `rows`.
    func unseenIncomingCount(
        rows: [ChatTimelineRow], origin: MessageWindowChangeOrigin,
        minimumVisibleRowBeforeUpdate: Int?
    ) -> Int {
        guard case .timelineFlush = origin,
              case .batch(_, let insertions, _, _, _) = self,
              let minimumVisibleRowBeforeUpdate else { return 0 }
        return insertions.reduce(into: 0) { count, indexPath in
            guard indexPath.row < minimumVisibleRowBeforeUpdate,
                  rows.indices.contains(indexPath.row),
                  let message = rows[indexPath.row].message,
                  !message.isOutgoing, !message.content.isRedacted else { return }
            count += 1
        }
    }
}
