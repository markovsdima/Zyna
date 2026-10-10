//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

protocol ContextMenuCellNode: ASCellNode {
    var onContextMenuActivated: ((CGPoint) -> Void)? { get set }
    var onDragChanged: ((CGPoint) -> Void)? { get set }
    var onDragEnded: ((CGPoint) -> Void)? { get set }
    var onInteractionLockChanged: ((Bool) -> Void)? { get set }
    func extractBubbleForMenu(in coordinateSpace: UICoordinateSpace) -> (node: ASDisplayNode, frame: CGRect)?
    /// Opaque bubble outline in the extracted content node's coordinates.
    /// Cover every extracted visual that must remain undimmed. Reactions
    /// currently stay outside this node; moving them inside requires
    /// extending the outline to cover them too, including outside bounds.
    func contextMenuContentPath() -> CGPath
    func restoreBubbleFromMenu()
}
