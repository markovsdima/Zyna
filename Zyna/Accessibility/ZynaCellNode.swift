//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import UIKit

/// Base class for every `ASCellNode` in the project.
/// Centralizes the accessibility forwarding pattern so subclasses
/// can't forget it: in `layout()` it makes the wrapping
/// `_ASTableViewCell`/`_ASCollectionViewCell` a transparent
/// accessibility container exposing the node's view.
///
/// Subclasses that need VoiceOver custom actions just set
/// `accessibilityActionsProvider` — the base wires it to the view.
class ZynaCellNode: ASCellNode {

    /// Optional provider for VoiceOver custom actions (Reply, Forward,
    /// Delete, etc.). The Texture bridge doesn't sync the custom actions
    /// property to the view reliably, so we set it explicitly each layout.
    var accessibilityActionsProvider: (() -> [UIAccessibilityCustomAction])?

    /// Pushes fresh VO custom actions to the wrapped cell immediately.
    /// Useful after lightweight in-place updates where the node may not
    /// get a layout pass soon enough on its own.
    func refreshAccessibilityForwarding() {
        guard isNodeLoaded, UIAccessibility.isVoiceOverRunning else { return }
        view.accessibilityCustomActions = accessibilityActionsProvider?()
        forwardAccessibilityToWrappingCell()
    }

    override func layout() {
        super.layout()
        refreshAccessibilityForwarding()
    }
}
