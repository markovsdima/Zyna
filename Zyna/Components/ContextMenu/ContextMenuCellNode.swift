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
    func restoreBubbleFromMenu()
}
