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

    override func layout() {
        super.layout()
        // Skip work entirely when VoiceOver is off — no observable cost
        // for the 99% of users who don't have it enabled.
        guard UIAccessibility.isVoiceOverRunning else { return }
        view.accessibilityCustomActions = accessibilityActionsProvider?()
        forwardAccessibilityToWrappingCell()
    }
}
