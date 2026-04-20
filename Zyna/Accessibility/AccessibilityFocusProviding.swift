//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Implemented by view controllers, nodes, or any container that wants
/// to steer VoiceOver focus to a specific element on appear or present.
///
/// Consumed by `ZynaNavigationController` (push/pop `.screenChanged`
/// target) and `AnchoredPopupNode` (initial focus after animate-in).
/// Nil means "let VoiceOver choose" — usually the first a11y element
/// within the conformer's view subtree.
protocol AccessibilityFocusProviding {
    var initialAccessibilityFocus: UIView? { get }
}
