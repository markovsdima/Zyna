//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import AsyncDisplayKit

extension ASCellNode {

    /// Makes the wrapping `_ASTableViewCell` (or `_ASCollectionViewCell`)
    /// a transparent accessibility container that exposes the node's view
    /// as the element. Without this, the cell wrapper takes precedence
    /// over our node, and `accessibilityActivate`/`accessibilityCustomActions`
    /// overrides on the node never fire.
    ///
    /// Handled by `ZynaCellNode.layout()` — subclasses don't need to call
    /// this directly.
    func forwardAccessibilityToWrappingCell() {
        var current: UIView? = view.superview
        while let v = current {
            if let tableCell = v as? UITableViewCell {
                tableCell.isAccessibilityElement = false
                tableCell.accessibilityElements = [view]
                return
            }
            if let collectionCell = v as? UICollectionViewCell {
                collectionCell.isAccessibilityElement = false
                collectionCell.accessibilityElements = [view]
                return
            }
            current = v.superview
        }
    }
}
