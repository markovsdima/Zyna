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
}
